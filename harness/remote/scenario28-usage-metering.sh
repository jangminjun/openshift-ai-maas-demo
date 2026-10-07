#!/usr/bin/env bash
# Scenario 28: usage metering. Sends a fixed number of requests as a
# dedicated SA, then compares the client-side usage.total_tokens sum with
# the deltas of Limitador (authorized_hits) and vLLM (prompt+generation
# tokens) metrics in User Workload Monitoring, and checks whether any
# metric carries a per-subject/per-subscription label. Requires jq.
# Assumes no other model traffic during the run.
set -euo pipefail
declare -F maas_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib-maas-client.sh"

REQUESTS="${REQUESTS:-10}"; MAX_TOKENS="${MAX_TOKENS:-32}"; SCRAPE_WAIT="${SCRAPE_WAIT:-75}"
ROUTE_NS="${MODEL_NAMESPACE:-maas-demo}/${MODEL_NAME:-maas-demo-model}-kserve-route"

promq() {  # promq QUERY -- scalar result (0 if empty)
  oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
    curl -s --data-urlencode "query=$1" http://localhost:9090/api/v1/query 2>/dev/null \
    | maas_jq -r '[.data.result[].value[1] | tonumber] | add // 0'
}
snapshot() {
  HITS=$(promq "sum(authorized_hits{limitador_namespace=\"${ROUTE_NS}\"})")
  CALLS=$(promq "sum(authorized_calls{limitador_namespace=\"${ROUTE_NS}\"})")
  VLLM=$(promq "sum(vllm:prompt_tokens_total{namespace=\"${MODEL_NAMESPACE}\"}) + sum(vllm:generation_tokens_total{namespace=\"${MODEL_NAMESPACE}\"})")
}

maas_init
maas_subscription maas-meter-sub 100000 1h 0 "$(maas_sa maas-meter)"
oc patch maassubscription maas-meter-sub -n "$TENANT_NAMESPACE" --type=json \
  -p '[{"op":"replace","path":"/spec/modelRefs/0/billingRate/perToken","value":"0.002"}]' >/dev/null
maas_settle
T=$(maas_token maas-meter)

echo "== 0) 부하 전 snapshot (scrape 반영 대기 ${SCRAPE_WAIT}s) =="
sleep "$SCRAPE_WAIT"; snapshot; H0=$HITS; C0=$CALLS; V0=$VLLM
echo "authorized_hits=${H0} authorized_calls=${C0} vllm_tokens=${V0}"

echo ""; echo "== 1) SA maas-meter: ${REQUESTS}회 요청 =="
SUM=0; OK=0
for i in $(seq 1 "$REQUESTS"); do
  maas_chat "$T" "$MAX_TOKENS"; u=$(maas_usage); SUM=$((SUM + u)); [ "$HTTP" = 200 ] && OK=$((OK + 1))
  echo "  #${i} HTTP ${HTTP} total_tokens=${u}"
done
echo "client 합계: ${OK}건, ${SUM} tok"

echo ""; echo "== 2) 부하 후 snapshot (${SCRAPE_WAIT}s 대기) =="
sleep "$SCRAPE_WAIT"; snapshot
DH=$(awk "BEGIN{print ${HITS}-${H0}}"); DC=$(awk "BEGIN{print ${CALLS}-${C0}}"); DV=$(awk "BEGIN{print ${VLLM}-${V0}}")
echo "authorized_hits +${DH}  authorized_calls +${DC}  vllm_tokens +${DV}"

echo ""; echo "== 3) 사용량 metric label (주체/구독 구분 가능 여부) =="
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s --data-urlencode 'query=authorized_hits' http://localhost:9090/api/v1/query 2>/dev/null \
  | maas_jq -c '.data.result[].metric | del(.container,.endpoint,.instance,.job,.namespace,.pod)'
LABELED=$(promq "count(authorized_hits{limitador_namespace=\"${ROUTE_NS}\"} ) > 1" )

echo ""; echo "== 4) billingRate.perToken=0.002 반영 여부 =="
COST_SERIES=$(promq 'count({__name__=~".*(cost|billing|charge).*"})')
echo "cost/billing/charge 이름의 metric series: ${COST_SERIES}"
maas_request "$T" "${MAAS_URL}/maas-api/v1/subscriptions"
echo "GET /maas-api/v1/subscriptions billing 필드: $(maas_jq -c '[.[] | select(.subscription_id_header=="maas-meter-sub") | .model_refs[0] | with_entries(select(.key|test("bill|cost|rate")))]' <<<"$BODY_OUT")"
EST=$(awk "BEGIN{printf \"%.3f\", ${SUM}*0.002}"); echo "client 합계 기준 산출 비용: ${SUM} tok × 0.002 = ${EST}"

echo ""; echo "== Assertions =="
maas_check "요청 성공" "$OK" "$REQUESTS"
maas_check "Limitador authorized_hits 증가 = client 합계" "$DH" "$SUM"
maas_check "Limitador authorized_calls 증가 = 요청 수" "$DC" "$REQUESTS"
maas_check "vLLM prompt+generation 증가 = client 합계" "$DV" "$SUM"
maas_check "주체/구독별 사용량 label 존재" "$([ "${LABELED:-0}" != 0 ] && echo yes || echo no)" yes
maas_check "billingRate 기반 비용 metric 존재" "$([ "${COST_SERIES:-0}" != 0 ] && echo yes || echo no)" yes
maas_finish
