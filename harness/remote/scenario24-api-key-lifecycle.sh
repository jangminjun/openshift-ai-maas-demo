#!/usr/bin/env bash
# Scenario 24: MaaS API key lifecycle -- issue (POST /maas-api/v1/api-keys),
# use, self-management denial, forged key, revoke (DELETE .../{id}) with
# propagation latency, and expiry (expiresIn). The key owner is a
# ServiceAccount with its own subscription; requires jq.
set -euo pipefail
declare -F maas_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib-maas-client.sh"

OWNER_SA="${OWNER_SA:-maas-apikey-owner}"
KEY_TTL_SECONDS="${KEY_TTL_SECONDS:-60}"
REVOKE_POLL_MAX="${REVOKE_POLL_MAX:-120}"


maas_init
API="${MAAS_URL}/maas-api/v1/api-keys"
maas_subscription maas-apikey-sub 100000 1h 0 "$(maas_sa "$OWNER_SA")"
maas_settle
OWNER_TOKEN=$(maas_token "$OWNER_SA")

echo "== 0) 기존 active key 정리 =="
maas_request "$OWNER_TOKEN" "${API}/search" -X POST -H 'Content-Type: application/json' -d '{}'
for id in $(maas_jq -r '.data[] | select(.status != "revoked") | .id' <<<"$BODY_OUT"); do
  maas_request "$OWNER_TOKEN" "${API}/${id}" -X DELETE; echo "revoked ${id} (${HTTP})"
done

echo ""; echo "== 1) 발급: K1(기본 만료), K2(expiresIn=${KEY_TTL_SECONDS}s) =="
maas_request "$OWNER_TOKEN" "$API" -X POST -H 'Content-Type: application/json' -d '{"name":"s24-k1"}'
HTTP_ISSUE=$HTTP; K1=$(maas_jq -r .key <<<"$BODY_OUT"); K1_ID=$(maas_jq -r .id <<<"$BODY_OUT")
maas_jq -c '{id, keyPrefix, subscription, createdAt, expiresAt}' <<<"$BODY_OUT"
maas_request "$OWNER_TOKEN" "$API" -X POST -H 'Content-Type: application/json' -d "{\"name\":\"s24-k2\",\"expiresIn\":${KEY_TTL_SECONDS}}"
K2=$(maas_jq -r .key <<<"$BODY_OUT"); K2_EXP=$(maas_jq -r .expiresAt <<<"$BODY_OUT")
maas_jq -c '{id, keyPrefix, subscription, createdAt, expiresAt}' <<<"$BODY_OUT"

echo ""; echo "== 2) K1 사용 =="
maas_request "$K1" "${MAAS_URL}/v1/models"; HTTP_K1_MODELS=$HTTP; echo "GET /v1/models -> ${HTTP}"
maas_chat "$K1" 16; HTTP_K1_CHAT=$HTTP; echo "POST /v1/chat/completions -> ${HTTP}"

echo ""; echo "== 3) K1으로 key 관리 API 호출 (자기 관리 금지) =="
maas_request "$K1" "$API" -X POST -H 'Content-Type: application/json' -d '{"name":"s24-from-key"}'; HTTP_K1_ISSUE=$HTTP; echo "POST api-keys -> ${HTTP}"
maas_request "$K1" "${API}/search" -X POST -H 'Content-Type: application/json' -d '{}'; HTTP_K1_SEARCH=$HTTP; echo "POST api-keys/search -> ${HTTP}"
maas_request "$K1" "${API}/${K1_ID}" -X DELETE; HTTP_K1_DELETE=$HTTP; echo "DELETE api-keys/{K1} -> ${HTTP}"

echo ""; echo "== 4) 형식만 맞춘 위조 key =="
maas_chat "sk-oai-forged$(date +%s)xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" 16; HTTP_FORGED=$HTTP; echo "-> ${HTTP}"

echo ""; echo "== 5) K1 폐기 후 반영 지연 측정 =="
maas_request "$OWNER_TOKEN" "${API}/${K1_ID}" -X DELETE; HTTP_REVOKE=$HTTP
echo "DELETE (owner) -> ${HTTP} status=$(maas_jq -r .status <<<"$BODY_OUT")"
t0=$(date +%s); HTTP_AFTER_REVOKE=""
while [ $(( $(date +%s) - t0 )) -le "$REVOKE_POLL_MAX" ]; do
  maas_chat "$K1" 8; echo "  +$(( $(date +%s) - t0 ))s -> ${HTTP}"
  [ "$HTTP" = 401 ] || [ "$HTTP" = 403 ] && { HTTP_AFTER_REVOKE=$HTTP; break; }
  sleep 10
done
REVOKE_LATENCY=$(( $(date +%s) - t0 ))

echo ""; echo "== 6) K2 만료 (expiresAt=${K2_EXP}) =="
maas_chat "$K2" 8; HTTP_K2_BEFORE=$HTTP; echo "만료 전 -> ${HTTP}"
wait_s=$(( $(date -d "$K2_EXP" +%s) - $(date +%s) + 5 )); [ "$wait_s" -gt 0 ] && sleep "$wait_s"
t1=$(date +%s); HTTP_K2_AFTER=""
while [ $(( $(date +%s) - t1 )) -le "$REVOKE_POLL_MAX" ]; do
  maas_chat "$K2" 8; echo "  만료 +$(( $(date +%s) - $(date -d "$K2_EXP" +%s) ))s -> ${HTTP}"
  [ "$HTTP" = 401 ] || [ "$HTTP" = 403 ] && { HTTP_K2_AFTER=$HTTP; break; }
  sleep 10
done

echo ""; echo "== Assertions =="
maas_check "발급 (SA token)" "$HTTP_ISSUE" 201
maas_check "K1 GET /v1/models" "$HTTP_K1_MODELS" 200
maas_check "K1 chat" "$HTTP_K1_CHAT" 200
maas_check "K1으로 key 발급 금지" "$HTTP_K1_ISSUE" 403
maas_check "K1으로 key 조회 금지" "$HTTP_K1_SEARCH" 403
maas_check "K1으로 key 폐기 금지" "$HTTP_K1_DELETE" 403
maas_check "위조 key" "$HTTP_FORGED" '401|403'
maas_check "폐기 (owner)" "$HTTP_REVOKE" 200
maas_check "폐기 후 거부 (${REVOKE_LATENCY}s 내)" "${HTTP_AFTER_REVOKE:-none}" '401|403'
maas_check "K2 만료 전" "$HTTP_K2_BEFORE" 200
maas_check "K2 만료 후 거부" "${HTTP_K2_AFTER:-none}" '401|403'
maas_finish
