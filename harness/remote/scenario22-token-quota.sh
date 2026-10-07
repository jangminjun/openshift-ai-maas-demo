#!/usr/bin/env bash
# Scenario 22: token quota enforcement. Two SAs share one low-limit
# MaaSSubscription; SA a sends requests until it is rate limited, SA b
# checks the counter is per-subject, then SA a retries after the window.
set -euo pipefail
declare -F maas_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib-maas-client.sh"

QUOTA_LIMIT="${QUOTA_LIMIT:-200}"
QUOTA_WINDOW="${QUOTA_WINDOW:-2m}"
QUOTA_WINDOW_SECONDS="${QUOTA_WINDOW_SECONDS:-120}"
MAX_TOKENS="${MAX_TOKENS:-64}"
MAX_REQUESTS="${MAX_REQUESTS:-20}"

maas_init
SUB_A=$(maas_sa maas-quota-a); SUB_B=$(maas_sa maas-quota-b)
echo "== MaaSSubscription maas-quota-sub: ${QUOTA_LIMIT} tok / ${QUOTA_WINDOW}, owners: ${SUB_A}, ${SUB_B} =="
maas_subscription maas-quota-sub "$QUOTA_LIMIT" "$QUOTA_WINDOW" 0 "$SUB_A" "$SUB_B"
maas_settle
TOKEN_A=$(maas_token maas-quota-a); TOKEN_B=$(maas_token maas-quota-b)

echo ""
echo "== SA maas-quota-a: max_tokens=${MAX_TOKENS} 요청 반복 =="
printf '%-4s %-5s %-8s %s\n' '#' 'HTTP' 'tokens' 'cumulative'
cum=0; first_429=""; last_ok_cum=0
for i in $(seq 1 "$MAX_REQUESTS"); do
  maas_chat "$TOKEN_A" "$MAX_TOKENS"
  used=$(maas_usage); cum=$((cum + used))
  printf '%-4s %-5s %-8s %s\n' "$i" "$HTTP" "$used" "$cum"
  if [ "$HTTP" = 429 ]; then first_429=$i; break; fi
  last_ok_cum=$cum
done
[ -n "$first_429" ] && { echo ""; echo "-- 429 응답 헤더/본문 --"; grep -i -E '^(x-ratelimit|retry-after|ratelimit)' <<<"$HDR_OUT" || true; echo "$BODY_OUT" | head -c 300; echo; }
T_BLOCKED=$(date +%s)

echo ""
echo "== SA maas-quota-b: 동일 구독, 별도 주체 =="
maas_chat "$TOKEN_B" "$MAX_TOKENS"; HTTP_B=$HTTP; echo "HTTP ${HTTP_B}"

echo ""
echo "== SA maas-quota-a: 차단 직후 재요청 =="
maas_chat "$TOKEN_A" "$MAX_TOKENS"; HTTP_A_AGAIN=$HTTP; echo "HTTP ${HTTP_A_AGAIN}"

wait_s=$((QUOTA_WINDOW_SECONDS + 5))
echo ""
echo "== 시간 창 경과 대기 (${wait_s}s) 후 SA maas-quota-a 재요청 =="
sleep "$wait_s"
maas_chat "$TOKEN_A" "$MAX_TOKENS"; HTTP_A_RECOVER=$HTTP; echo "HTTP ${HTTP_A_RECOVER} (차단 후 $(( $(date +%s) - T_BLOCKED ))s)"

echo ""
echo "== Assertions =="
maas_check "한도 내 요청 성공 (마지막 성공 시 누적 ${last_ok_cum} tok)" "$([ "$last_ok_cum" -gt 0 ] && echo 200 || echo none)" 200
maas_check "한도 초과 시 차단 (#${first_429:-none})" "$([ -n "$first_429" ] && echo 429 || echo none)" 429
maas_check "차단 직후 재요청" "$HTTP_A_AGAIN" 429
maas_check "다른 주체 (한도 독립)" "$HTTP_B" 200
maas_check "시간 창 경과 후 복구" "$HTTP_A_RECOVER" 200
maas_finish
