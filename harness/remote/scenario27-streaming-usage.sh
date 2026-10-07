#!/usr/bin/env bash
# Scenario 27: are streamed (SSE) responses counted against the token quota?
# Three modes, each with its own SA + identical low-limit subscription so the
# counters are independent: C = non-stream (baseline), A = stream,
# B = stream + stream_options.include_usage. Each sends requests until 429.
set -euo pipefail
declare -F maas_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib-maas-client.sh"

LIMIT="${LIMIT:-300}"; WINDOW="${WINDOW:-10m}"; MAX_TOKENS="${MAX_TOKENS:-64}"; MAX_REQUESTS="${MAX_REQUESTS:-12}"
maas_init
for m in c a b; do maas_subscription "maas-stream-$m" "$LIMIT" "$WINDOW" 0 "$(maas_sa "maas-stream-$m")"; done
maas_settle

body() {  # body MODE
  case $1 in
    c) echo "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 50.\"}],\"max_tokens\":${MAX_TOKENS}}" ;;
    a) echo "{\"model\":\"${MODEL_ID}\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 50.\"}],\"max_tokens\":${MAX_TOKENS}}" ;;
    b) echo "{\"model\":\"${MODEL_ID}\",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 50.\"}],\"max_tokens\":${MAX_TOKENS}}" ;;
  esac
}

declare -A FIRST_429
for m in c a b; do
  T=$(maas_token "maas-stream-$m"); label=$([ $m = c ] && echo "C 비스트리밍" || ([ $m = a ] && echo "A stream" || echo "B stream+include_usage"))
  echo ""; echo "== ${label} (SA maas-stream-$m, 한도 ${LIMIT} tok/${WINDOW}) =="
  printf '%-4s %-5s %-7s %-7s %-10s %s\n' '#' 'HTTP' 'chunks' 'tokens' 'TTFB/total' 'usage 출처'
  FIRST_429[$m]=none
  for i in $(seq 1 "$MAX_REQUESTS"); do
    out=$(mktemp)
    read -r HTTP ttfb ttotal < <(curl -skN --max-time 120 -o "$out" -w '%{http_code} %{time_starttransfer} %{time_total}' \
      -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "$(body $m)" "${MAAS_URL}/v1/chat/completions" || true) || true
    chunks=$(grep -c '^data: {' "$out" || true)
    used=$(grep -o '"total_tokens":[0-9]*' "$out" | tail -1 | cut -d: -f2 || true); src=$([ -n "$used" ] && echo "응답" || echo "없음")
    printf '%-4s %-5s %-7s %-7s %-10s %s\n' "$i" "$HTTP" "$chunks" "${used:--}" "${ttfb%???}/${ttotal%???}s" "$src"
    rm -f "$out"
    [ "$HTTP" = 429 ] && { FIRST_429[$m]=$i; break; }
  done
done

echo ""; echo "== Assertions =="
maas_check "C 비스트리밍: 한도 도달 시 429 (#${FIRST_429[c]})" "$([ "${FIRST_429[c]}" != none ] && echo 429 || echo none)" 429
maas_check "A stream: 한도 도달 시 429 (#${FIRST_429[a]})" "$([ "${FIRST_429[a]}" != none ] && echo 429 || echo none)" 429
maas_check "B stream+usage: 한도 도달 시 429 (#${FIRST_429[b]})" "$([ "${FIRST_429[b]}" != none ] && echo 429 || echo none)" 429
maas_finish
