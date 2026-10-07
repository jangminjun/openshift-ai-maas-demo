#!/usr/bin/env bash
# Scenario 26: one subject owning two MaaSSubscriptions for the same model.
# Checks explicit selection (x-maas-subscription), the default choice
# (priority), quota isolation between the two, a not-owned subscription,
# and the SpecPriorityDuplicate condition. Requires jq.
set -euo pipefail
declare -F maas_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib-maas-client.sh"

LOW_LIMIT="${LOW_LIMIT:-100}"; HIGH_LIMIT="${HIGH_LIMIT:-100000}"; WINDOW="${WINDOW:-10m}"
maas_init
SUBJ=$(maas_sa maas-multi)
maas_subscription maas-multi-low  "$LOW_LIMIT"  "$WINDOW" 0  "$SUBJ"
maas_subscription maas-multi-high "$HIGH_LIMIT" "$WINDOW" 10 "$SUBJ"
maas_subscription maas-multi-other 100000 "$WINDOW" 0 "$(maas_sa maas-multi-other)"   # not owned by SUBJ
maas_settle
T=$(maas_token maas-multi)

echo "== 0) GET /maas-api/v1/subscriptions (주체가 보는 구독) =="
maas_request "$T" "${MAAS_URL}/maas-api/v1/subscriptions"
maas_jq -r '.[] | "\(.subscription_id_header)\tpriority=\(.priority)\tlimit=\(.model_refs[0].token_rate_limits[0].limit)"' <<<"$BODY_OUT"

echo ""; echo "== 1) API key 발급 시 기본 선택 구독 =="
maas_request "$T" "${MAAS_URL}/maas-api/v1/api-keys" -X POST -H 'Content-Type: application/json' -d '{"name":"s26-default","expiresIn":300}'
KEY_DEFAULT_SUB=$(maas_jq -r .subscription <<<"$BODY_OUT"); KEY_DEFAULT=$(maas_jq -r .key <<<"$BODY_OUT"); echo "subscription=${KEY_DEFAULT_SUB}"

echo ""; echo "== 2) x-maas-subscription: maas-multi-low 반복 (한도 ${LOW_LIMIT}) =="
LOW_429=""
for i in $(seq 1 10); do
  maas_chat "$T" 64 -H 'x-maas-subscription: maas-multi-low'; echo "  #${i} HTTP ${HTTP} tokens=$(maas_usage)"
  [ "$HTTP" = 429 ] && { LOW_429=$i; break; }
done

echo ""; echo "== 3) low 소진 상태에서 =="
maas_chat "$T" 16 -H 'x-maas-subscription: maas-multi-high'; HTTP_HIGH=$HTTP; echo "x-maas-subscription: maas-multi-high -> ${HTTP}"
maas_chat "$T" 16; HTTP_DEFAULT=$HTTP; echo "SA token, 헤더 없음 -> ${HTTP} $(head -c 100 <<<"$BODY_OUT")"
maas_chat "$KEY_DEFAULT" 16; HTTP_KEY_DEFAULT=$HTTP; echo "API key(구독 ${KEY_DEFAULT_SUB}), 헤더 없음 -> ${HTTP}"
maas_chat "$T" 16 -H 'x-maas-subscription: maas-multi-other'; HTTP_OTHER=$HTTP; echo "x-maas-subscription: maas-multi-other (미소유) -> ${HTTP} $(head -c 60 <<<"$BODY_OUT")"
maas_chat "$T" 16 -H 'x-maas-subscription: does-not-exist'; HTTP_NONE=$HTTP; echo "x-maas-subscription: does-not-exist -> ${HTTP} $(head -c 60 <<<"$BODY_OUT")"

echo ""; echo "== 4) priority 중복 (low도 10으로) =="
oc patch maassubscription maas-multi-low -n "$TENANT_NAMESPACE" --type=merge -p '{"spec":{"priority":10}}' >/dev/null
sleep 10
DUP=$(oc get maassubscription maas-multi-low -n "$TENANT_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="SpecPriorityDuplicate")].status}')
DUP_MSG=$(oc get maassubscription maas-multi-low -n "$TENANT_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="SpecPriorityDuplicate")].message}')
echo "SpecPriorityDuplicate=${DUP} ${DUP_MSG}"
maas_settle
maas_chat "$T" 16; HTTP_DUP_DEFAULT=$HTTP; echo "priority 중복 상태 헤더 없음 -> ${HTTP} $(head -c 80 <<<"$BODY_OUT")"
oc patch maassubscription maas-multi-low -n "$TENANT_NAMESPACE" --type=merge -p '{"spec":{"priority":0}}' >/dev/null

echo ""; echo "== Assertions =="
maas_check "API key 기본 구독 = priority 높은 구독" "$KEY_DEFAULT_SUB" maas-multi-high
maas_check "low 지정 시 한도 초과 429 (#${LOW_429:-none})" "$([ -n "$LOW_429" ] && echo 429 || echo none)" 429
maas_check "동시점 high 지정" "$HTTP_HIGH" 200
maas_check "SA token 헤더 없음 = 구독 명시 요구" "$HTTP_DEFAULT" 403
maas_check "API key 헤더 없음 = key에 고정된 high 적용" "$HTTP_KEY_DEFAULT" 200
maas_check "미소유 구독 지정" "$HTTP_OTHER" 403
maas_check "존재하지 않는 구독 지정" "$HTTP_NONE" '403|404'
maas_check "priority 중복 condition" "$DUP" True
echo "INFO  priority 중복 상태 헤더 없음 -> ${HTTP_DUP_DEFAULT}"
maas_finish
