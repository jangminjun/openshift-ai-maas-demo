#!/usr/bin/env bash
# Scenario 29: isolation between two AITenants. Creates tenant B (its own
# Gateway -> new AWS ELB, AITenant, subscription), issues one API key per
# tenant and crosses keys/tokens between the two gateways. Tenant B's host
# has no DNS record; requests reach it with curl --connect-to <ELB>.
# Cleans tenant B up at the end unless KEEP_TENANT=1. Requires jq.
set -euo pipefail
declare -F maas_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib-maas-client.sh"

TENANT_B="${TENANT_B:-tenant-b}"
GW_B="maas-${TENANT_B}-gateway"
KEEP_TENANT="${KEEP_TENANT:-0}"
maas_init
B_HOST="maas-b.${MAAS_HOST#maas.}"

cleanup() {
  [ "$KEEP_TENANT" = 1 ] && { echo "KEEP_TENANT=1: ${TENANT_B} 유지"; return; }
  echo ""; echo "== cleanup: ${TENANT_B} =="
  oc delete aitenant "$TENANT_B" -n ai-tenants --ignore-not-found --wait=false
  oc delete gateway "$GW_B" -n openshift-ingress --ignore-not-found --wait=false
}
trap cleanup EXIT

echo "== 1) Tenant B: Gateway ${GW_B} (${B_HOST}) + AITenant ${TENANT_B} =="
oc apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GW_B}
  namespace: openshift-ingress
  annotations: {opendatahub.io/managed: "false", security.opendatahub.io/authorino-tls-bootstrap: "true"}
  labels: {istio.io/rev: openshift-gateway}
spec:
  gatewayClassName: maas-gateway-class
  listeners:
  - name: https
    hostname: ${B_HOST}
    port: 443
    protocol: HTTPS
    allowedRoutes: {namespaces: {from: All}}
    tls: {mode: Terminate, certificateRefs: [{group: "", kind: Secret, name: apps-wildcard-tls}]}
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: AITenant
metadata: {name: ${TENANT_B}, namespace: ai-tenants}
spec:
  gateway: {name: ${GW_B}}
YAML
oc wait gateway "$GW_B" -n openshift-ingress --for=condition=Programmed --timeout=300s >/dev/null
oc wait aitenant "$TENANT_B" -n ai-tenants --for=condition=Ready --timeout=300s >/dev/null
NS_B=$(oc get aitenant "$TENANT_B" -n ai-tenants -o jsonpath='{.status.tenantNamespace}')
B_LB=$(oc get gateway "$GW_B" -n openshift-ingress -o jsonpath='{.status.addresses[0].value}')
CT=(--connect-to "${B_HOST}:443:${B_LB}:443")
oc get aitenant -n ai-tenants
echo "tenant B namespace=${NS_B}, ELB=${B_LB}"
# A freshly created AWS ELB answers only minutes after the Gateway is Programmed.
t0=$(date +%s)
until [ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "${CT[@]}" "https://${B_HOST}/v1/models" || true)" != 000 ]; do
  [ $(( $(date +%s) - t0 )) -gt "${ELB_WAIT_MAX:-600}" ] && { echo "ELB 응답 없음" >&2; exit 1; }
  sleep 10
done
echo "ELB 응답 시작: $(( $(date +%s) - t0 ))s"
echo "생성된 정책: $(oc get authpolicy,tokenratelimitpolicy -n openshift-ingress -o name | grep "$TENANT_B" | tr '\n' ' ')"

echo ""; echo "== 2) 구독: A(models-as-a-service), B(${NS_B}) — 둘 다 ${MODEL_NAMESPACE}/${MODEL_NAME} 참조 =="
maas_subscription maas-tenant-a-sub 100000 1h 0 "$(maas_sa maas-tenant-a-user)"
SUBJ_B=$(maas_sa maas-tenant-b-user)
TENANT_NAMESPACE="$NS_B" maas_subscription maas-tenant-b-sub 100000 1h 0 "$SUBJ_B" 2>/dev/null || true
SUB_B_PHASE=$(oc get maassubscription maas-tenant-b-sub -n "$NS_B" -o jsonpath='{.status.phase}')
echo "maas-tenant-b-sub phase=${SUB_B_PHASE}: $(oc get maassubscription maas-tenant-b-sub -n "$NS_B" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
maas_settle
TA=$(maas_token maas-tenant-a-user); TB=$(maas_token maas-tenant-b-user)

echo ""; echo "== 3) API key 발급 (B는 생성 직후 일시 500 가능 — 최대 6회 재시도) =="
maas_request "$TA" "${MAAS_URL}/maas-api/v1/api-keys" -X POST -H 'Content-Type: application/json' -d '{"name":"s29-a","expiresIn":3600}'
KA=$(maas_jq -r .key <<<"$BODY_OUT"); HTTP_KA=$HTTP; echo "key-A on A: ${HTTP} subscription=$(maas_jq -r .subscription <<<"$BODY_OUT")"
for i in 1 2 3 4 5 6; do
  maas_request "$TB" "https://${B_HOST}/maas-api/v1/api-keys" "${CT[@]}" -X POST -H 'Content-Type: application/json' -d '{"name":"s29-b","expiresIn":3600}'
  echo "key-B on B (try ${i}): ${HTTP}"; [ "$HTTP" = 201 ] && break; sleep 10
done
KB=$(maas_jq -r '.key // empty' <<<"$BODY_OUT"); HTTP_KB=$HTTP; echo "key-B subscription=$(maas_jq -r '.subscription // empty' <<<"$BODY_OUT")"

declare -A R
call() {  # call ID LABEL CRED URL [curl args]
  local id=$1 label=$2 cred=$3 url=$4; shift 4
  maas_request "$cred" "$url" "$@"; R[$id]=$HTTP
  printf '%-44s HTTP %s  %s\n' "$label" "$HTTP" "$(head -c 70 <<<"$BODY_OUT" | tr -d '\n')"
}
CHAT=(-H 'Content-Type: application/json' -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}")

echo ""; echo "== 4) 교차 호출 =="
call a_a_chat   "key-A → Gateway A chat"            "$KA" "${MAAS_URL}/v1/chat/completions" "${CHAT[@]}"
call a_b_models "key-A → Gateway B /v1/models"      "$KA" "https://${B_HOST}/v1/models" "${CT[@]}"
call a_b_chat   "key-A → Gateway B chat"            "$KA" "https://${B_HOST}/v1/chat/completions" "${CT[@]}" "${CHAT[@]}"
call b_a_models "key-B → Gateway A /v1/models"      "$KB" "${MAAS_URL}/v1/models"
call b_a_chat   "key-B → Gateway A chat"            "$KB" "${MAAS_URL}/v1/chat/completions" "${CHAT[@]}"
call b_b_models "key-B → Gateway B /v1/models"      "$KB" "https://${B_HOST}/v1/models" "${CT[@]}"
call ta_b_models "SA token A → Gateway B /v1/models" "$TA" "https://${B_HOST}/v1/models" "${CT[@]}"
call ta_b_chat  "SA token A → Gateway B chat"       "$TA" "https://${B_HOST}/v1/chat/completions" "${CT[@]}" "${CHAT[@]}"
call tb_a_chat  "SA token B → Gateway A chat"       "$TB" "${MAAS_URL}/v1/chat/completions" "${CHAT[@]}"

echo ""; echo "== Assertions =="
maas_check "B 구독이 A 모델 참조 시 거부 (phase)" "$SUB_B_PHASE" Failed
maas_check "key-A 발급" "$HTTP_KA" 201
maas_check "key-B 발급" "$HTTP_KB" 201
maas_check "key-A → A chat" "${R[a_a_chat]}" 200
maas_check "key-A → B 거부" "${R[a_b_models]}" 403
maas_check "key-A → B chat 거부" "${R[a_b_chat]}" '403|404'
maas_check "key-B → A 거부" "${R[b_a_models]}" 403
maas_check "key-B → A chat 거부" "${R[b_a_chat]}" 403
maas_check "SA token A → B chat (route 없음)" "${R[ta_b_chat]}" '403|404'
maas_check "SA token B → A chat (구독 없음)" "${R[tb_a_chat]}" 403
echo "INFO  key-B → B /v1/models -> ${R[b_b_models]} (Failed 구독에 묶인 key)"
echo "INFO  SA token A → B /v1/models -> ${R[ta_b_models]}"
maas_finish
