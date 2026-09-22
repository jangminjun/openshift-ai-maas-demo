#!/usr/bin/env bash
# Run this DIRECTLY from your own laptop (no SSH/bastion needed) -- everything
# here is a public/external endpoint. Requires: curl, jq.
#
# Tests scenario 17 (docs/scenarios/17-maas-external-oidc-auth.md) as of
# 2026-09-22 06:57 UTC (3 of 4 known TLS/policy issues fixed -- see doc
# section 6-8 for the full trace):
#   1) get an OIDC token from Keycloak for a user with NO OpenShift account
#   2) decode it to show the "groups" claim MaaS keys off
#   3) call MaaS /v1/models with it -> HTTP 200, real model + subscription listed
#   4) call MaaS with no token at all -> HTTP 401 (proves (3) is a real auth pass)
#   5) hit /maas-api/health as a sanity check (bypasses auth entirely, HTTP 200)
#   6) attempt an actual chat completion -> currently HTTP 403 (KNOWN, see below)
#   7) repeat 1-2 for premium-user
#
# Status of the pipeline (4 distinct TLS/policy bugs found and fixed/tracked
# this session, full detail + real log evidence in the scenario doc):
#   1. Authorino -> Keycloak CA trust ................ FIXED
#   2. Envoy -> Authorino gRPC TLS mismatch ........... FIXED
#   3. odh-model-controller vs maas-controller AuthPolicy
#      ownership conflict (only appears once a real model
#      is deployed) .................................. FIXED (Gateway
#      annotation `opendatahub.io/managed: "false"` on
#      maas-default-gateway -- see doc section 7)
#   4. Authorino -> maas-api mTLS ("bad certificate")
#      blocking the `subscription-valid` authorization
#      check specifically ............................ NOT YET FIXED
#
# Because of #4, step 6 (an actual model call through MaaS's own group-based
# governance path) currently returns 403 even though the token, the identity
# resolution, and the group match (Keycloak "groups" -> MaaSSubscription /
# MaaSAuthPolicy) all succeed -- the 403 comes specifically from Authorino's
# outbound mTLS call to maas-api failing, not from anything wrong with the
# token or the group. It is NOT a regression of anything above and NOT
# something this script or the Keycloak setup can fix on its own.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/../state/keycloak-users.env"
[ -f "$STATE_FILE" ] || { echo "Missing ${STATE_FILE} -- run ./harness.sh scenario17-keycloak-realm first." >&2; exit 1; }
set -a; source "$STATE_FILE"; set +a

KC="https://maas-keycloak.apps.myocp.sandbox1314.opentlc.com"
REALM="maas-demo"
CLIENT_ID="maas-test-client"
CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:?missing KEYCLOAK_CLIENT_SECRET in ${STATE_FILE}}"
MAAS="https://maas.apps.myocp.sandbox1314.opentlc.com"
MODEL_PATH="maas-demo/maas-demo-model"
MODEL_NAME="Qwen2.5-1.5B-Instruct"

BASIC_USER="basic-user";     BASIC_PASSWORD="${KEYCLOAK_USER_BASIC_PASSWORD:?missing in ${STATE_FILE}}"
PREMIUM_USER="premium-user"; PREMIUM_PASSWORD="${KEYCLOAK_USER_PREMIUM_PASSWORD:?missing in ${STATE_FILE}}"

decode_jwt() {  # prints the JWT payload as pretty JSON
  local jwt="$1" payload
  payload=$(echo "$jwt" | cut -d. -f2)
  case $(( ${#payload} % 4 )) in 2) payload="${payload}==";; 3) payload="${payload}=";; esac
  echo "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
}

get_token() {  # get_token USERNAME PASSWORD
  curl -sk -X POST "${KC}/realms/${REALM}/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&username=${1}&password=${2}" \
    | jq -r .access_token
}

echo "== 1) basic-user 토큰 발급 (OpenShift 계정 전혀 없음, Keycloak 계정만 있음) =="
TOKEN=$(get_token "$BASIC_USER" "$BASIC_PASSWORD")
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "FAILED to get token"; exit 1; }
echo "토큰 획득 성공."

echo ""
echo "== 2) 토큰 디코드 -- groups 클레임 확인 =="
decode_jwt "$TOKEN" | jq '{preferred_username, groups, iss, exp}'

echo ""
echo "== 3) MaaS /v1/models 호출 -- HTTP 200 + 실제 모델/구독 정보 기대 =="
curl -sk "${MAAS}/v1/models" -H "Authorization: Bearer ${TOKEN}" -w "\nHTTP %{http_code}\n"

echo ""
echo "== 4) 대조군: 토큰 없이 호출 -- HTTP 401 기대 (3번이 진짜 인증 통과였음을 증명) =="
curl -sk "${MAAS}/v1/models" -w "\nHTTP %{http_code}\n"

echo ""
echo "== 5) 헬스체크 (인증 없이도 되는 경로) -- HTTP 200 기대 =="
curl -sk "${MAAS}/maas-api/health" -w "\nHTTP %{http_code}\n"

echo ""
echo "== 6) 실제 채팅 완성 -- 현재 HTTP 403 기대 (알려진 이슈#4, 토큰/그룹 문제 아님) =="
curl -sk "${MAAS}/${MODEL_PATH}/v1/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"1+1?\"}],\"max_tokens\":10}" \
  -w "\nHTTP %{http_code}\n"
echo "(403이 뜨면 정상입니다 -- Authorino->maas-api mTLS 미해결 이슈 때문입니다. 토큰이나 그룹 설정"
echo " 문제가 아닙니다. 자세한 원인: docs/scenarios/17-maas-external-oidc-auth.md 8번 섹션)"

echo ""
echo "== 7) premium-user도 동일하게 토큰+groups 확인 =="
TOKEN2=$(get_token "$PREMIUM_USER" "$PREMIUM_PASSWORD")
decode_jwt "$TOKEN2" | jq '{preferred_username, groups}'
