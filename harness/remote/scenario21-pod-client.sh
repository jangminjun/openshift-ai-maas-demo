#!/usr/bin/env bash
# Scenario 21: an in-cluster Pod as the MaaS client. A ServiceAccount token
# (projected, audience https://kubernetes.default.svc) is the credential --
# the gateway's "openshift-identities" kubernetesTokenReview path resolves it
# to system:serviceaccount:<ns>:<sa>, which a MaaSSubscription/MaaSAuthPolicy
# can name directly under owner.users / subjects.users.
#
# Creates: CLIENT_NAMESPACE, two ServiceAccounts (one subscribed, one not),
# one MaaSSubscription + MaaSAuthPolicy for the subscribed SA, then runs one
# curl Job per SA and asserts the HTTP codes. Idempotent; runs on the bastion
# or locally against an existing `oc login` session.
#
# Creating a MaaSAuthPolicy regenerates the gateway AuthPolicy -- re-run
# scenario17-wire-authpolicy afterward if Keycloak (scenario 17) is in use.
set -euo pipefail
[ -f "$HOME/ocp-install/auth/kubeconfig" ] && export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

CLIENT_NAMESPACE="${CLIENT_NAMESPACE:-maas-pod-client}"
CLIENT_SA="${CLIENT_SA:-maas-client}"
DENIED_SA="${DENIED_SA:-maas-client-nosub}"
MODEL_NAMESPACE="${MODEL_NAMESPACE:-maas-demo}"
MODEL_NAME="${MODEL_NAME:-maas-demo-model}"
TENANT_NAMESPACE="${TENANT_NAMESPACE:-models-as-a-service}"
TOKEN_LIMIT="${TOKEN_LIMIT:-1000}"
TOKEN_WINDOW="${TOKEN_WINDOW:-1h}"
# internal: Pod -> gateway Service (172.30.x.x) directly, SNI/Host unchanged
# external: Pod -> public ELB hostname, same path an outside client takes
MAAS_PATH_MODE="${MAAS_PATH_MODE:-internal}"
CLIENT_IMAGE="${CLIENT_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MAAS_HOST="maas.${CLUSTER_DOMAIN}"
GW_SVC=$(oc get svc -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
  -o jsonpath='{.items[0].metadata.name}')
GW_FQDN="${GW_SVC}.openshift-ingress.svc.cluster.local"
WORKLOAD_SVC="${MODEL_NAME}-kserve-workload-svc.${MODEL_NAMESPACE}.svc.cluster.local"
MODEL_ID="publishers/${MODEL_NAMESPACE}/models/$(oc get llminferenceservice "$MODEL_NAME" -n "$MODEL_NAMESPACE" -o jsonpath='{.spec.model.name}')"
CONNECT_TO=""
[ "$MAAS_PATH_MODE" = "internal" ] && CONNECT_TO="--connect-to ${MAAS_HOST}:443:${GW_FQDN}:443"

echo "== Namespace / ServiceAccounts: ${CLIENT_NAMESPACE} =="
oc get ns "$CLIENT_NAMESPACE" &>/dev/null || oc create ns "$CLIENT_NAMESPACE"
for sa in "$CLIENT_SA" "$DENIED_SA"; do
  oc get sa "$sa" -n "$CLIENT_NAMESPACE" &>/dev/null || oc create sa "$sa" -n "$CLIENT_NAMESPACE"
done
SUBJECT="system:serviceaccount:${CLIENT_NAMESPACE}:${CLIENT_SA}"

echo "== MaaSSubscription / MaaSAuthPolicy for ${SUBJECT} =="
oc apply -f - <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: ${CLIENT_NAMESPACE}-sub
  namespace: ${TENANT_NAMESPACE}
spec:
  owner:
    users: ["${SUBJECT}"]
  modelRefs:
  - name: ${MODEL_NAME}
    namespace: ${MODEL_NAMESPACE}
    tokenRateLimits: [{limit: ${TOKEN_LIMIT}, window: "${TOKEN_WINDOW}"}]
    billingRate: {perToken: "0"}
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: ${CLIENT_NAMESPACE}-access
  namespace: ${TENANT_NAMESPACE}
spec:
  modelRefs:
  - name: ${MODEL_NAME}
    namespace: ${MODEL_NAMESPACE}
  subjects:
    users: ["${SUBJECT}"]
YAML
oc wait "maassubscription/${CLIENT_NAMESPACE}-sub" "maasauthpolicy/${CLIENT_NAMESPACE}-access" \
  -n "$TENANT_NAMESPACE" --for=jsonpath='{.status.phase}'=Active --timeout=120s
# Authorino caches auth decisions for 60s (AuthPolicy cache ttl) and the
# regenerated AuthPolicy needs to reach Enforced -- give it a moment.
oc wait authpolicy maas-gateway-auth -n openshift-ingress --for=condition=Enforced --timeout=120s
sleep "${POLICY_SETTLE_SECONDS:-20}"

# Curl script executed inside the client Pod. Prints "RESULT <case> <http>".
POD_SCRIPT=$(cat <<'SH'
set -u
T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
U="https://${MAAS_HOST}"
BODY="{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word.\"}],\"max_tokens\":16}"
req() {  # req CASE curl-args...
  local name=$1; shift
  code=$(curl -sk ${CONNECT_TO} -o /tmp/out -w '%{http_code}' --max-time 60 "$@")
  echo "RESULT ${name} ${code}"; head -c 400 /tmp/out; echo
}
req models     "$U/v1/models" -H "Authorization: Bearer $T"
req chat       "$U/v1/chat/completions" -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "$BODY"
req chat-path  "$U/${MODEL_NAMESPACE}/${MODEL_NAME}/v1/chat/completions" -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "$BODY"
req no-token   "$U/v1/chat/completions" -H 'Content-Type: application/json' -d "$BODY"
req direct-vllm "https://${WORKLOAD_SVC}:8000/v1/models"
SH
)
oc create configmap maas-client-script -n "$CLIENT_NAMESPACE" --from-literal=run.sh="$POD_SCRIPT" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null

run_job() {  # run_job SA
  local sa=$1 job="maas-client-test-${1}"
  oc delete job "$job" -n "$CLIENT_NAMESPACE" --ignore-not-found >/dev/null
  oc apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${CLIENT_NAMESPACE}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      serviceAccountName: ${sa}
      restartPolicy: Never
      containers:
      - name: client
        image: ${CLIENT_IMAGE}
        command: ["/bin/bash", "/scripts/run.sh"]
        volumeMounts: [{name: scripts, mountPath: /scripts}]
        env:
        - {name: MAAS_HOST, value: "${MAAS_HOST}"}
        - {name: MODEL_ID, value: "${MODEL_ID}"}
        - {name: MODEL_NAMESPACE, value: "${MODEL_NAMESPACE}"}
        - {name: MODEL_NAME, value: "${MODEL_NAME}"}
        - {name: WORKLOAD_SVC, value: "${WORKLOAD_SVC}"}
        - {name: CONNECT_TO, value: "${CONNECT_TO}"}
      volumes: [{name: scripts, configMap: {name: maas-client-script}}]
YAML
  oc wait job "$job" -n "$CLIENT_NAMESPACE" --for=condition=Complete --timeout=300s >/dev/null 2>&1 \
    || oc wait job "$job" -n "$CLIENT_NAMESPACE" --for=condition=Failed --timeout=5s >/dev/null 2>&1 || true
  oc logs "job/${job}" -n "$CLIENT_NAMESPACE"
}

FAIL=0
check() {  # check LOG CASE EXPECTED_REGEX
  local got; got=$(grep "^RESULT $2 " <<<"$1" | awk '{print $3}')
  if [[ "$got" =~ ^($3)$ ]]; then echo "PASS  $2 -> $got"; else echo "FAIL  $2 -> $got (expected $3)"; FAIL=1; fi
}

echo ""
echo "== Path mode: ${MAAS_PATH_MODE} (host ${MAAS_HOST}${CONNECT_TO:+ via ${GW_FQDN}}) | model id: ${MODEL_ID} =="
echo ""
echo "== Job as subscribed SA: ${SUBJECT} =="
LOG_OK=$(run_job "$CLIENT_SA"); echo "$LOG_OK"
echo ""
echo "== Job as unsubscribed SA: system:serviceaccount:${CLIENT_NAMESPACE}:${DENIED_SA} =="
LOG_NO=$(run_job "$DENIED_SA"); echo "$LOG_NO"

echo ""
echo "== Assertions =="
check "$LOG_OK" models    200
check "$LOG_OK" chat      200
check "$LOG_OK" chat-path 200
check "$LOG_OK" no-token  401
check "$LOG_NO" chat      403
check "$LOG_NO" chat-path 403
echo "INFO  direct-vllm (gateway bypass) -> $(grep '^RESULT direct-vllm ' <<<"$LOG_OK" | awk '{print $3}')"
exit $FAIL
