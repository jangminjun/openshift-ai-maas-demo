#!/usr/bin/env bash
# Scenario 30: MCP server (SearXNG) behind the MaaS Gateway's "mcp"
# listener. Checks authentication, whether MaaS subscriptions gate MCP
# access, the MCP streamable-HTTP flow (initialize -> tools/list ->
# tools/call), rate limiting, and the in-cluster direct-to-Service path.
# Requires jq.
set -euo pipefail
declare -F maas_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib-maas-client.sh"

MCP_NAMESPACE="${MCP_NAMESPACE:-mcp-servers}"; MCP_SERVICE="${MCP_SERVICE:-mcp-searxng}"
BURST="${BURST:-20}"
maas_init
MCP_URL="https://mcp.${MAAS_HOST#maas.}/mcp"
SUBJ=$(maas_sa maas-mcp-client); maas_sa maas-mcp-nosub >/dev/null
maas_subscription maas-mcp-sub 100000 1h 0 "$SUBJ"
maas_settle
T=$(maas_token maas-mcp-client); TN=$(maas_token maas-mcp-nosub)
maas_request "$T" "${MAAS_URL}/maas-api/v1/api-keys" -X POST -H 'Content-Type: application/json' -d '{"name":"s30","expiresIn":3600}'
KEY=$(maas_jq -r .key <<<"$BODY_OUT")

# mcp CRED SESSION JSON -- POST to MCP endpoint; data line of SSE (or JSON body) in MCP_DATA.
mcp() {
  local sess=(); [ -n "$2" ] && sess=(-H "mcp-session-id: $2")
  maas_request "$1" "$MCP_URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' "${sess[@]}" -d "$3"
  MCP_DATA=$(sed -n 's/^data: //p' <<<"$BODY_OUT" | tail -1); [ -z "$MCP_DATA" ] && MCP_DATA=$BODY_OUT
  MCP_SESSION=$(grep -i '^mcp-session-id:' <<<"$HDR_OUT" | awk '{print $2}' | tr -d '\r' || true)
}
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"s30","version":"1"}}}'

declare -A R
echo "== 1) initialize — 자격 증명별 =="
for c in none:"" sa-sub:"$T" sa-nosub:"$TN" apikey:"$KEY"; do
  name=${c%%:*}; cred=${c#*:}; mcp "$cred" "" "$INIT"; R[init_$name]=$HTTP
  printf '%-10s HTTP %s  %s\n' "$name" "$HTTP" "$(maas_jq -r '.result.serverInfo // empty | "\(.name) \(.version)"' <<<"$MCP_DATA" 2>/dev/null || true)"
done

echo ""; echo "== 2) MCP 흐름 (SA maas-mcp-client) =="
mcp "$T" "" "$INIT"; S=$MCP_SESSION; echo "session=${S}"
mcp "$T" "$S" '{"jsonrpc":"2.0","method":"notifications/initialized"}'; echo "notifications/initialized -> ${HTTP}"
mcp "$T" "$S" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; R[list]=$HTTP
TOOLS=$(maas_jq -r '[.result.tools[].name] | join(",")' <<<"$MCP_DATA" 2>/dev/null || true); echo "tools/list -> ${HTTP} [${TOOLS}]"
TOOL=${TOOLS%%,*}
mcp "$T" "$S" "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"${TOOL}\",\"arguments\":{\"query\":\"OpenShift AI\"}}}"; R[call]=$HTTP
echo "tools/call ${TOOL} -> ${HTTP} isError=$(maas_jq -r '.result.isError // false' <<<"$MCP_DATA" 2>/dev/null) $(maas_jq -r '.result.content[0].text // .error.message // empty' <<<"$MCP_DATA" 2>/dev/null | head -c 160 | tr '\n' ' ')"

echo ""; echo "== 3) 구독 없는 SA로 tools/call =="
mcp "$TN" "" "$INIT"; SN=$MCP_SESSION
mcp "$TN" "$SN" '{"jsonrpc":"2.0","method":"notifications/initialized"}'
mcp "$TN" "$SN" "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"${TOOL}\",\"arguments\":{\"query\":\"OpenShift AI\"}}}"; R[call_nosub]=$HTTP
echo "tools/call (nosub) -> ${HTTP}"

echo ""; echo "== 4) 연속 ${BURST}회 tools/list (요청 수 제한 여부) =="
codes=""; for i in $(seq 1 "$BURST"); do mcp "$T" "$S" '{"jsonrpc":"2.0","id":9,"method":"tools/list"}'; codes+="$HTTP "; done
echo "$codes"; R[burst429]=$(grep -c 429 <<<"$(tr ' ' '\n' <<<"$codes")" || true)

echo ""; echo "== 5) 클러스터 내부 Pod에서 Service 직접 호출 (Gateway 우회) =="
POD=maas-mcp-probe; trap 'maas_pod_stop "$POD"' EXIT; maas_pod_start "$POD" maas-mcp-nosub
R[direct]=$(maas_pod_code "$POD" "http://${MCP_SERVICE}.${MCP_NAMESPACE}.svc.cluster.local:8000/mcp" \
  -X POST -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$INIT")
echo "direct ${MCP_SERVICE}:8000/mcp -> ${R[direct]}"

echo ""; echo "== Assertions =="
maas_check "token 없음 거부" "${R[init_none]}" 401
maas_check "구독 SA initialize" "${R[init_sa-sub]}" 200
maas_check "API key initialize" "${R[init_apikey]}" 200
maas_check "tools/list" "${R[list]}" 200
maas_check "tools/call" "${R[call]}" 200
maas_check "구독 없는 SA 거부 (구독 연계 인가)" "${R[init_sa-nosub]}" 403
maas_check "구독 없는 SA tools/call 거부" "${R[call_nosub]}" 403
maas_check "Service 직접 호출 차단" "${R[direct]}" 000
echo "INFO  연속 ${BURST}회 중 429: ${R[burst429]}건"
maas_finish
