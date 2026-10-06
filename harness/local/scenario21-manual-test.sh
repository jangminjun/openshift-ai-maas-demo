#!/usr/bin/env bash
# Run this DIRECTLY from your own laptop (no SSH/bastion needed). Tests
# scenario 21 (docs/scenarios/21-maas-in-cluster-pod-client.md): a Pod in
# the cluster calls the model through the MaaS Gateway using only its
# ServiceAccount token. Starts one client Pod per SA, runs curl inside it
# via `oc exec`, prints each response, then deletes the Pods.
#
# Requires: an admin `oc login` session, and the namespace/SAs/subscription
# from `./harness.sh scenario21-pod-client` (or remote/scenario21-pod-client.sh).
#
# Usage:
#   ./scenario21-manual-test.sh                          # 기본 질문
#   PROMPT='쿠버네티스를 한 문장으로 설명해줘' ./scenario21-manual-test.sh
#   MAAS_PATH_MODE=external ./scenario21-manual-test.sh  # ELB 경유
set -euo pipefail

CLIENT_NAMESPACE="${CLIENT_NAMESPACE:-maas-pod-client}"
CLIENT_SA="${CLIENT_SA:-maas-client}"
DENIED_SA="${DENIED_SA:-maas-client-nosub}"
MODEL_NAMESPACE="${MODEL_NAMESPACE:-maas-demo}"
MODEL_NAME="${MODEL_NAME:-maas-demo-model}"
MAAS_PATH_MODE="${MAAS_PATH_MODE:-internal}"
PROMPT="${PROMPT:-Say hello in one word.}"
MAX_TOKENS="${MAX_TOKENS:-64}"
CLIENT_IMAGE="${CLIENT_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"

oc whoami &>/dev/null || { echo "oc login 먼저 필요." >&2; exit 1; }
oc get sa "$CLIENT_SA" "$DENIED_SA" -n "$CLIENT_NAMESPACE" &>/dev/null \
  || { echo "${CLIENT_NAMESPACE}의 SA 없음 -- ./harness.sh scenario21-pod-client 먼저 실행." >&2; exit 1; }

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MAAS_HOST="maas.${CLUSTER_DOMAIN}"
GW_SVC=$(oc get svc -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
  -o jsonpath='{.items[0].metadata.name}')
CONNECT_TO=""
[ "$MAAS_PATH_MODE" = "internal" ] && CONNECT_TO="--connect-to ${MAAS_HOST}:443:${GW_SVC}.openshift-ingress.svc.cluster.local:443"
MODEL_ID="publishers/${MODEL_NAMESPACE}/models/$(oc get llminferenceservice "$MODEL_NAME" -n "$MODEL_NAMESPACE" -o jsonpath='{.spec.model.name}')"
WORKLOAD_SVC="${MODEL_NAME}-kserve-workload-svc.${MODEL_NAMESPACE}.svc.cluster.local"
# JSON-escape the prompt (backslash, double quote) so any text can be passed.
PROMPT_JSON=$(printf '%s' "$PROMPT" | sed 's/\\/\\\\/g; s/"/\\"/g')
BODY="{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PROMPT_JSON}\"}],\"max_tokens\":${MAX_TOKENS}}"

POD_OK="maas-client-manual-${CLIENT_SA}"
POD_NO="maas-client-manual-${DENIED_SA}"
cleanup() { oc delete pod "$POD_OK" "$POD_NO" -n "$CLIENT_NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

start_pod() {  # start_pod POD SA
  oc delete pod "$1" -n "$CLIENT_NAMESPACE" --ignore-not-found >/dev/null
  oc run "$1" -n "$CLIENT_NAMESPACE" --image="$CLIENT_IMAGE" --restart=Never \
    --overrides="{\"spec\":{\"serviceAccountName\":\"$2\",
      \"securityContext\":{\"runAsNonRoot\":true,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},
      \"containers\":[{\"name\":\"$1\",\"image\":\"${CLIENT_IMAGE}\",\"command\":[\"sleep\",\"600\"],
        \"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}}}]}}" >/dev/null
}

# pod_curl POD URL [curl-args...] -- runs curl INSIDE the Pod with its own SA token.
pod_curl() {
  local pod=$1 url=$2; shift 2
  oc exec -n "$CLIENT_NAMESPACE" "$pod" -- bash -c '
    T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    curl -sk '"$CONNECT_TO"' --max-time 120 -w "\nHTTP %{http_code}\n" "$@" -H "Authorization: Bearer $T"
  ' _ "$url" "$@"
}

echo "== 0) client Pod 기동 (${CLIENT_NAMESPACE}: SA ${CLIENT_SA}, ${DENIED_SA}) =="
start_pod "$POD_OK" "$CLIENT_SA"
start_pod "$POD_NO" "$DENIED_SA"
oc wait pod "$POD_OK" "$POD_NO" -n "$CLIENT_NAMESPACE" --for=condition=Ready --timeout=180s >/dev/null
echo "경로: ${MAAS_PATH_MODE} | host: ${MAAS_HOST} | model: ${MODEL_ID}"

echo ""
echo "== 1) [${CLIENT_SA}] GET /v1/models -- HTTP 200, 모델 1개 기대 =="
pod_curl "$POD_OK" "https://${MAAS_HOST}/v1/models"

echo ""
echo "== 2) [${CLIENT_SA}] POST /v1/chat/completions -- HTTP 200 기대 =="
echo "질문: ${PROMPT}"
pod_curl "$POD_OK" "https://${MAAS_HOST}/v1/chat/completions" -H 'Content-Type: application/json' -d "$BODY"

echo ""
echo "== 3) [${DENIED_SA}] POST /v1/chat/completions -- HTTP 403 기대 (구독 없음) =="
pod_curl "$POD_NO" "https://${MAAS_HOST}/v1/chat/completions" -H 'Content-Type: application/json' -d "$BODY"

echo ""
echo "== 4) [${DENIED_SA}] vLLM Service 직접 호출 (Gateway 우회) -- NetworkPolicy 없으면 200 =="
pod_curl "$POD_NO" "https://${WORKLOAD_SVC}:8000/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "$(printf '%s' "$BODY" | sed "s#\"${MODEL_ID}\"#\"$(basename "$MODEL_ID")\"#")"
