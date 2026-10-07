#!/usr/bin/env bash
# Scenario 25: client-injected identity headers (x-maas-username,
# x-maas-group, x-maas-subscription) must not let a caller impersonate
# another subject, group or subscription.
set -euo pipefail
declare -F maas_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib-maas-client.sh"

maas_init
GOOD_SUBJECT=$(maas_sa maas-spoof-good)
maas_sa maas-spoof-nosub >/dev/null
maas_subscription maas-spoof-sub 100000 1h 0 "$GOOD_SUBJECT"
maas_settle
T_GOOD=$(maas_token maas-spoof-good)
T_NOSUB=$(maas_token maas-spoof-nosub)

run() {  # run LABEL TOKEN EXPECTED [header...]
  local label=$1 token=$2 expected=$3; shift 3
  local hargs=(); for h in "$@"; do hargs+=(-H "$h"); done
  maas_chat "$token" 8 "${hargs[@]}"
  printf '%-58s HTTP %s  %s\n' "$label" "$HTTP" "$(head -c 60 <<<"$BODY_OUT" | tr -d '\n')"
  RESULTS+=("$label|$HTTP|$expected")
}
RESULTS=()

echo "== 구독 없는 SA (maas-spoof-nosub) =="
run "1 대조군 (헤더 없음)"                       "$T_NOSUB" 403
run "2 x-maas-username: 구독 SA 사칭"            "$T_NOSUB" 403 "x-maas-username: ${GOOD_SUBJECT}"
run "3 x-maas-group: maas-premium"               "$T_NOSUB" 403 "x-maas-group: maas-premium"
run "4 X-MaaS-Group (대소문자 변형)"             "$T_NOSUB" 403 "X-MaaS-Group: maas-premium"
run "5 x-maas-subscription: 타인 구독 지정"      "$T_NOSUB" 403 "x-maas-subscription: maas-spoof-sub"
run "6 username+group+subscription 동시"         "$T_NOSUB" 403 "x-maas-username: ${GOOD_SUBJECT}" "x-maas-group: system:authenticated" "x-maas-subscription: maas-spoof-sub"

echo ""; echo "== 구독 SA (maas-spoof-good) =="
run "7 대조군 (헤더 없음)"                       "$T_GOOD" 200
run "8 정상 주체 + x-maas-group 주입"            "$T_GOOD" 403 "x-maas-group: maas-premium"
run "9 정상 주체 + x-maas-username 주입"         "$T_GOOD" 403 "x-maas-username: admin"
run "10 정상 주체 + 자기 구독 x-maas-subscription" "$T_GOOD" 200 "x-maas-subscription: maas-spoof-sub"

echo ""; echo "== Assertions =="
for r in "${RESULTS[@]}"; do IFS='|' read -r l g e <<<"$r"; maas_check "$l" "$g" "$e"; done
maas_finish
