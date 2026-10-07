#!/usr/bin/env bash
# Scenario 23: close the direct-to-vLLM bypass found in scenario 21 with a
# NetworkPolicy on the model namespace that admits only the MaaS Gateway
# (openshift-ingress) and cluster monitoring. Measures before/after from an
# in-cluster Pod. NP_ACTION=apply (default) keeps the policy; NP_ACTION=remove
# deletes it and re-measures (rollback).
set -euo pipefail
declare -F maas_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib-maas-client.sh"

NP_ACTION="${NP_ACTION:-apply}"
CLIENT_SA="${CLIENT_SA:-maas-np-client}"
POD=maas-np-probe
maas_init
WORKLOAD_URL="https://${MODEL_NAME}-kserve-workload-svc.${MODEL_NAMESPACE}.svc.cluster.local:8000"
GW_SVC=$(oc get svc -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway -o jsonpath='{.items[0].metadata.name}')
CONNECT_TO="${MAAS_HOST}:443:${GW_SVC}.openshift-ingress.svc.cluster.local:443"
BODY="{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}"
DIRECT_BODY="{\"model\":\"${SERVED_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":8}"

maas_subscription maas-np-sub 100000 1h 0 "$(maas_sa "$CLIENT_SA")"
maas_settle
trap 'maas_pod_stop "$POD"' EXIT
maas_pod_start "$POD" "$CLIENT_SA"

measure() {  # measure LABEL -- sets G (gateway chat) / D (direct chat) / M (direct metrics)
  G=$(maas_pod_code "$POD" "${MAAS_URL}/v1/chat/completions" --connect-to "$CONNECT_TO" -H 'Content-Type: application/json' -d "$BODY")
  D=$(maas_pod_code "$POD" "${WORKLOAD_URL}/v1/chat/completions" -H 'Content-Type: application/json' -d "$DIRECT_BODY")
  M=$(maas_pod_code "$POD" "${WORKLOAD_URL}/metrics")
  R=$(oc get llminferenceservice "$MODEL_NAME" -n "$MODEL_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  printf '%-10s gateway-chat=%s  direct-chat=%s  direct-metrics=%s  LLMInferenceService Ready=%s\n' "$1" "$G" "$D" "$M" "$R"
}

[ "$NP_ACTION" = apply ] && oc delete networkpolicy allow-from-maas-gateway allow-from-monitoring \
  -n "$MODEL_NAMESPACE" --ignore-not-found >/dev/null && sleep 5   # true baseline on re-runs
echo "== Before (NetworkPolicy in ${MODEL_NAMESPACE}: $(oc get networkpolicy -n "$MODEL_NAMESPACE" --no-headers 2>/dev/null | wc -l)) =="
measure before; G0=$G; D0=$D

if [ "$NP_ACTION" = remove ]; then
  echo ""; echo "== Remove NetworkPolicy =="
  oc delete networkpolicy allow-from-maas-gateway allow-from-monitoring -n "$MODEL_NAMESPACE" --ignore-not-found
  sleep 5; measure after
  echo ""; echo "== Assertions =="
  maas_check "gateway chat (rollback 후)" "$G" 200
  maas_check "direct chat (rollback 후 다시 열림)" "$D" 200
  maas_finish
fi

echo ""; echo "== Apply NetworkPolicy =="
oc apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-from-maas-gateway, namespace: ${MODEL_NAMESPACE}}
spec:
  podSelector: {matchLabels: {kserve.io/component: workload}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: openshift-ingress}}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-from-monitoring, namespace: ${MODEL_NAMESPACE}}
spec:
  podSelector: {matchLabels: {kserve.io/component: workload}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: openshift-user-workload-monitoring}}
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: openshift-monitoring}}
YAML
sleep "${NP_SETTLE_SECONDS:-10}"
measure after

echo ""; echo "== 60s 후 재확인 (Ready 유지 여부) =="
sleep 60; measure after+60s

echo ""; echo "== Assertions =="
maas_check "before: direct chat 열림 (우회 재현)" "$D0" 200
maas_check "after: gateway chat" "$G" 200
maas_check "after: direct chat 차단" "$D" 000
maas_check "after: direct metrics 차단 (monitoring ns만 허용)" "$M" 000
maas_check "after: LLMInferenceService Ready" "$R" True
maas_finish
