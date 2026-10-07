#!/usr/bin/env bash
# Shared helpers for MaaS client-side scenarios (22+). Sourced by
# remote/scenarioNN-*.sh when run locally; harness.sh prepends it to the
# script on stdin when running over ssh_bastion (`cat lib script | bash -s`).
#
# Callers set at most: MODEL_NAMESPACE, MODEL_NAME, TENANT_NAMESPACE,
# CLIENT_NAMESPACE before calling maas_init.

[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

MODEL_NAMESPACE="${MODEL_NAMESPACE:-maas-demo}"
MODEL_NAME="${MODEL_NAME:-maas-demo-model}"
TENANT_NAMESPACE="${TENANT_NAMESPACE:-models-as-a-service}"
CLIENT_NAMESPACE="${CLIENT_NAMESPACE:-maas-pod-client}"
MAAS_FAIL=0

# maas_init -- resolves MAAS_HOST, MAAS_URL, MODEL_ID, SERVED_NAME.
maas_init() {
  local domain
  domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
  MAAS_HOST="maas.${domain}"
  MAAS_URL="https://${MAAS_HOST}"
  SERVED_NAME=$(oc get llminferenceservice "$MODEL_NAME" -n "$MODEL_NAMESPACE" -o jsonpath='{.spec.model.name}')
  MODEL_ID="publishers/${MODEL_NAMESPACE}/models/${SERVED_NAME}"
  oc get ns "$CLIENT_NAMESPACE" &>/dev/null || oc create ns "$CLIENT_NAMESPACE" >/dev/null
}

# maas_sa NAME -- ensures ServiceAccount in CLIENT_NAMESPACE; echoes its MaaS subject.
maas_sa() {
  oc get sa "$1" -n "$CLIENT_NAMESPACE" &>/dev/null || oc create sa "$1" -n "$CLIENT_NAMESPACE" >/dev/null
  echo "system:serviceaccount:${CLIENT_NAMESPACE}:$1"
}

# maas_token SA [DURATION] -- short-lived SA token (audience defaults to the API server).
maas_token() { oc create token "$1" -n "$CLIENT_NAMESPACE" --duration="${2:-1h}"; }

# maas_subscription NAME LIMIT WINDOW PRIORITY SUBJECT... -- MaaSSubscription + matching
# MaaSAuthPolicy (NAME-access) for one model, owned by the given users. Idempotent.
maas_subscription() {
  local name=$1 limit=$2 window=$3 priority=$4; shift 4
  local users; users=$(printf '"%s",' "$@"); users="[${users%,}]"
  oc apply -f - >/dev/null <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata: {name: ${name}, namespace: ${TENANT_NAMESPACE}}
spec:
  priority: ${priority}
  owner: {users: ${users}}
  modelRefs:
  - name: ${MODEL_NAME}
    namespace: ${MODEL_NAMESPACE}
    tokenRateLimits: [{limit: ${limit}, window: "${window}"}]
    billingRate: {perToken: "0"}
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata: {name: ${name}-access, namespace: ${TENANT_NAMESPACE}}
spec:
  modelRefs: [{name: ${MODEL_NAME}, namespace: ${MODEL_NAMESPACE}}]
  subjects: {users: ${users}}
YAML
  oc wait "maassubscription/${name}" "maasauthpolicy/${name}-access" -n "$TENANT_NAMESPACE" \
    --for=jsonpath='{.status.phase}'=Active --timeout=120s >/dev/null
}

# maas_settle -- wait for regenerated AuthPolicy/TokenRateLimitPolicy + Authorino cache.
maas_settle() {
  oc wait authpolicy maas-gateway-auth -n openshift-ingress --for=condition=Enforced --timeout=120s >/dev/null
  oc wait tokenratelimitpolicy -n "$MODEL_NAMESPACE" --all --for=condition=Enforced --timeout=120s >/dev/null
  sleep "${MAAS_SETTLE_SECONDS:-20}"
}

# maas_chat TOKEN [MAX_TOKENS] [extra curl args...] -- POST /v1/chat/completions.
# Sets globals: HTTP (status code), BODY_OUT (response body), HDR_OUT (response headers).
maas_chat() {
  local token=$1 max=${2:-32}; shift 2 || shift $#
  maas_request "$token" "${MAAS_URL}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 50.\"}],\"max_tokens\":${max}}" "$@"
}

# maas_request TOKEN URL [curl args...] -- generic request; empty TOKEN sends no Authorization.
maas_request() {
  local token=$1 url=$2; shift 2
  local hdr body; hdr=$(mktemp); body=$(mktemp)
  local auth=(); [ -n "$token" ] && auth=(-H "Authorization: Bearer ${token}")
  HTTP=$(curl -sk --max-time 120 -D "$hdr" -o "$body" -w '%{http_code}' "${auth[@]}" "$@" "$url" || true)
  HDR_OUT=$(cat "$hdr"); BODY_OUT=$(cat "$body"); rm -f "$hdr" "$body"
}

# maas_pod_start POD SA -- long-running curl Pod in CLIENT_NAMESPACE (restricted PSA compliant).
maas_pod_start() {
  oc delete pod "$1" -n "$CLIENT_NAMESPACE" --ignore-not-found >/dev/null
  oc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: ${CLIENT_NAMESPACE}}
spec:
  serviceAccountName: $2
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: client
    image: ${CLIENT_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}
    command: [sleep, "1800"]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
  oc wait pod "$1" -n "$CLIENT_NAMESPACE" --for=condition=Ready --timeout=180s >/dev/null
}

# maas_pod_code POD URL [curl args...] -- HTTP code of a request made INSIDE the Pod
# with its own SA token (000 = connection failed/timed out).
maas_pod_code() {
  local pod=$1 url=$2; shift 2
  oc exec -n "$CLIENT_NAMESPACE" "$pod" -- bash -c \
    'curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 60 \
       -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" "$@"' _ "$@" "$url" 2>/dev/null || true
}

maas_pod_stop() { oc delete pod "$@" -n "$CLIENT_NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }

# maas_usage -- total_tokens from BODY_OUT (0 if absent).
maas_usage() { grep -o '"total_tokens":[0-9]*' <<<"$BODY_OUT" | head -1 | cut -d: -f2 | grep . || echo 0; }

# maas_check LABEL GOT EXPECTED_REGEX -- PASS/FAIL line; any FAIL makes maas_finish exit 1.
maas_check() {
  if [[ "$2" =~ ^($3)$ ]]; then echo "PASS  $1 -> $2"; else echo "FAIL  $1 -> $2 (expected $3)"; MAAS_FAIL=1; fi
}

maas_finish() { echo ""; [ "$MAAS_FAIL" = 0 ] && echo "RESULT: ALL PASS" || echo "RESULT: FAILURES"; exit "$MAAS_FAIL"; }

# maas_jq ARGS... -- jq without CR (Windows jq.exe emits CRLF, which breaks ids in URLs).
maas_jq() { jq "$@" | tr -d '\r'; }
