#!/usr/bin/env bash
# Run this DIRECTLY from your own laptop (no SSH/bastion needed).
# Tests scenario 18 (docs/scenarios/18-maas-openai-body-routing.md): fixed
# /v1/chat/completions endpoint, model selected purely via the request
# body's "model" field. Requires: curl, jq, and harness/state/keycloak-users.env
# (run ./harness.sh scenario17-keycloak-realm first if missing).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/../state/keycloak-users.env"
[ -f "$STATE_FILE" ] || { echo "Missing ${STATE_FILE} -- run ./harness.sh scenario17-keycloak-realm first." >&2; exit 1; }
set -a; source "$STATE_FILE"; set +a

KC="https://maas-keycloak.apps.myocp.sandbox1314.opentlc.com"
REALM="maas-demo"
CLIENT_ID="maas-test-client"
CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:?missing KEYCLOAK_CLIENT_SECRET in ${STATE_FILE}}"
MAAS_URL="https://maas.apps.myocp.sandbox1314.opentlc.com/v1/chat/completions"

# MUST be the full "id" from GET /v1/models (publishers/<ns>/models/<name>) --
# a short name (just <name>) does NOT route, it 404s.
MODEL_ID="${MAAS_TEST_MODEL:-publishers/maas-demo/models/Qwen2.5-1.5B-Instruct}"

BASIC_USER="basic-user"; BASIC_PASSWORD="${KEYCLOAK_USER_BASIC_PASSWORD:?missing in ${STATE_FILE}}"

TOKEN=$(curl -sk -X POST "${KC}/realms/${REALM}/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&username=${BASIC_USER}&password=${BASIC_PASSWORD}" \
  | jq -r .access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "FAILED to get token"; exit 1; }

echo "== 1) model=${MODEL_ID} (fixed endpoint, body-based routing) -- HTTP 200 기대 =="
curl -sk -X POST "$MAAS_URL" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"1+1?\"}],\"max_tokens\":30}" \
  -w "\nHTTP %{http_code}\n"
echo "(403이면 Authorino가 maas-api TLS 인증서를 다시 못 믿는 상태로 되돌아간 것 --"
echo " ./harness.sh scenario17-authorino-trust-ca 재실행)"

echo ""
echo "== 2) 대조군: 존재하지 않는 모델명 -- HTTP 404 기대 (조용히 다른 모델로 안 새는지 확인) =="
curl -sk -X POST "$MAAS_URL" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"model\":\"definitely-not-a-registered-model-$(date +%s)\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
  -w "\nHTTP %{http_code}\n"
