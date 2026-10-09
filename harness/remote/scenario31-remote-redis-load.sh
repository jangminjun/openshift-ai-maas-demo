#!/usr/bin/env bash
# Scenario 31: MaaS load against whatever Redis Limitador currently uses
# (switch with scenario31-limitador-redis-switch.sh). Measures client latency,
# Redis usage (ops, network bytes, memory, keys), Limitador -> Redis RTT under
# load and Limitador flush batches. Run once per store/mode and compare.
#
#   LOAD_LABEL=remote-cached bash remote/scenario31-remote-redis-load.sh
#   SUBJECTS=50 CONCURRENCY=32 DURATION=300 bash remote/scenario31-remote-redis-load.sh
#   CONCURRENCY=256 LOAD_PODS=8 MAX_TOKENS=1 bash remote/scenario31-remote-redis-load.sh   # high load (31-B)
set -euo pipefail
declare -F maas_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib-maas-client.sh"

LOAD_LABEL="${LOAD_LABEL:-run}"
SUBJECTS="${SUBJECTS:-20}"            # distinct SAs = distinct Limitador counters
CONCURRENCY="${CONCURRENCY:-16}"     # total concurrent requests, split over LOAD_PODS
LOAD_PODS="${LOAD_PODS:-1}"           # curl forks per request -> spread high concurrency over Pods
WORKERS=$(( (CONCURRENCY + LOAD_PODS - 1) / LOAD_PODS ))
DURATION="${DURATION:-180}"           # seconds
MAX_TOKENS="${MAX_TOKENS:-16}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-15}"
LIMITADOR_NS="${LIMITADOR_NS:-kuadrant-system}"
REDIS_SECRET="${REDIS_SECRET:-limitador-redis-config}"
REDIS_IMAGE="${REDIS_IMAGE:-registry.redhat.io/rhel9/redis-7:latest}"
RESULTS_DIR="${RESULTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results/scenario31}"

maas_init

# ---- helpers -----------------------------------------------------------------
# restricted-PSA pod spec; $1 name, $2 namespace, $3 image, $4 SA (optional)
pod_up() {
  oc delete pod "$1" -n "$2" --ignore-not-found >/dev/null
  oc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $2}
spec:
  ${4:+serviceAccountName: $4}
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: main
    image: $3
    command: [sleep, "3600"]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
  oc wait pod "$1" -n "$2" --for=condition=Ready --timeout=180s >/dev/null
}

REDIS_URL=$(oc get secret "$REDIS_SECRET" -n "$LIMITADOR_NS" -o jsonpath='{.data.URL}' | base64 -d)
RTLS=""; case "$REDIS_URL" in rediss://*) RTLS="--tls"; case "$REDIS_URL" in *'#insecure') RTLS="--tls --insecure";; esac;; esac
RURL="${REDIS_URL%%#*}"
rcli() { oc exec -n "$LIMITADOR_NS" redis-mon -- redis-cli -u "$RURL" $RTLS --no-auth-warning "$@" 2>/dev/null | tr -d '\r'; }
rtt() { oc exec -n "$LIMITADOR_NS" redis-mon -- timeout "${1:-6}" redis-cli -u "$RURL" $RTLS --no-auth-warning --latency --raw 2>/dev/null | tr -d '\r'; }
# Monitoring traffic (redis-cli PING/INFO/AUTH...) is excluded from Limitador's
# share: commands via INFO commandstats, bytes approximately (PING 14B in / 7B out,
# INFO replies by their measured size).
MON_CMDS='ping|info|dbsize|auth|hello|client\|[a-z]*|command|scan|select'
MON_OUT_BYTES=0
snap() {  # sets S_<field> globals from one INFO all
  local s; s=$(rcli INFO all); MON_OUT_BYTES=$((MON_OUT_BYTES + ${#s}))
  S_IN=$(grep '^total_net_input_bytes:' <<<"$s" | cut -d: -f2)
  S_OUT=$(grep '^total_net_output_bytes:' <<<"$s" | cut -d: -f2)
  S_MEM=$(grep '^used_memory:' <<<"$s" | cut -d: -f2)
  S_PEAK=$(grep '^used_memory_peak:' <<<"$s" | cut -d: -f2)
  # anchor on the first "calls=" (a greedy .* would hit failed_calls=)
  S_PING=$(grep -E '^cmdstat_ping:' <<<"$s" | sed -E 's/^[^:]+:calls=([0-9]+).*/\1/'); S_PING=${S_PING:-0}
  S_LIM=$(grep '^cmdstat_' <<<"$s" | grep -vE "^cmdstat_(${MON_CMDS}):" | sed -E 's/^[^:]+:calls=([0-9]+).*/\1/' | awk '{s+=$1} END {print s+0}')
  S_MIX=$(grep '^cmdstat_' <<<"$s" | grep -vE "^cmdstat_(${MON_CMDS}):" | sed -E 's/^cmdstat_([^:]+):calls=([0-9]+).*/\1=\2/' | tr '\n' ' ')
}

LIM_POD=$(oc get pod -n "$LIMITADOR_NS" -l app=limitador -o jsonpath='{.items[0].metadata.name}')
lmetric() {
  oc get --raw "/api/v1/namespaces/${LIMITADOR_NS}/pods/${LIM_POD}:8080/proxy/metrics" \
    | { grep -E "^$1(\{| )" || true; } | awk '{s+=$NF} END {printf "%d", s}'   # absent until first hit
}

# ---- setup -------------------------------------------------------------------
STORE=$(oc get limitador limitador -n "$LIMITADOR_NS" -o jsonpath='{.spec.storage}' | grep -oE '"(redis|redis-cached|disk)"' | head -1 | tr -d '"')
echo "== [${LOAD_LABEL}] Limitador storage=${STORE:-memory}, Redis=$(echo "$REDIS_URL" | sed -E 's#(://[^:@]*:)[^@]*@#\1****@#') =="
echo "   subjects=${SUBJECTS} concurrency=${CONCURRENCY} (${LOAD_PODS} pod x ${WORKERS}) duration=${DURATION}s max_tokens=${MAX_TOKENS}"

subjects=()
for i in $(seq -w 1 "$SUBJECTS"); do subjects+=("$(maas_sa "maas-load-${i}")"); done
maas_subscription maas-load-sub 100000000 1h 0 "${subjects[@]}"
maas_settle

# CRED=apikey (default): one MaaS API key per SA -- validation is cached by Authorino.
# CRED=satoken: raw SA tokens -- every request does an uncached TokenReview
# against the API server, which saturates under load (401 "context canceled").
CRED="${CRED:-apikey}"
tokfile=$(mktemp)
for i in $(seq -w 1 "$SUBJECTS"); do
  # oc on Windows emits CR and no trailing newline -> strip, one credential per line
  sa_tok=$(maas_token "maas-load-${i}" 2h | tr -d '\r')
  if [ "$CRED" = apikey ]; then
    maas_request "$sa_tok" "${MAAS_URL}/maas-api/v1/api-keys" -X POST -H 'Content-Type: application/json' \
      -d "{\"name\":\"s31-load-${i}\",\"expiresIn\":7200}"
    key=$(maas_jq -r .key <<<"$BODY_OUT")
    [[ "$key" == sk-oai-* ]] || { echo "API key issue failed for maas-load-${i}: HTTP ${HTTP} ${BODY_OUT}"; exit 1; }
    printf '%s\n' "$key" >> "$tokfile"
  else
    printf '%s\n' "$sa_tok" >> "$tokfile"
  fi
done
echo "   credentials: ${CRED} x ${SUBJECTS}"
oc delete secret maas-load-tokens -n "$CLIENT_NAMESPACE" --ignore-not-found >/dev/null
oc create secret generic maas-load-tokens -n "$CLIENT_NAMESPACE" --from-file=tokens="$tokfile" >/dev/null
rm -f "$tokfile"

pod_up redis-mon "$LIMITADOR_NS" "$REDIS_IMAGE"
oc delete pod -n "$CLIENT_NAMESPACE" -l app=maas-load --ignore-not-found >/dev/null

# ---- before ------------------------------------------------------------------
echo ""
echo "== RTT idle (Limitador namespace -> Redis): min max avg samples = $(rtt 8)"
snap; b_in=$S_IN; b_out=$S_OUT; b_ping=$S_PING; b_lim=$S_LIM; b_mix=$S_MIX
b_keys=$(rcli DBSIZE)
b_auth=$(lmetric authorized_calls); b_limited=$(lmetric limited_calls)
# ---- load --------------------------------------------------------------------
# Pods start workers immediately and run until a shared wall-clock END, so all
# LOAD_PODS stop together even though they become Ready at slightly different times.
t0=$(date +%s)
END=$(( $(date +%s) + DURATION + 30 + LOAD_PODS * 2 ))
for p in $(seq 0 $((LOAD_PODS - 1))); do
oc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: maas-load-${p}, namespace: ${CLIENT_NAMESPACE}, labels: {app: maas-load}}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  volumes: [{name: tok, secret: {secretName: maas-load-tokens}}]
  containers:
  - name: load
    image: ${CLIENT_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    resources: {requests: {cpu: 500m, memory: 256Mi}}
    volumeMounts: [{name: tok, mountPath: /tok}]
    env:
    - {name: URL, value: "${MAAS_URL}/v1/chat/completions"}
    - {name: BODY, value: '{"model":"${MODEL_ID}","messages":[{"role":"user","content":"Say hi."}],"max_tokens":${MAX_TOKENS}}'}
    - {name: C, value: "${WORKERS}"}
    - {name: WOFF, value: "$((p * WORKERS))"}
    - {name: END, value: "${END}"}
    command: [bash, -c]
    args:
    - |
      mapfile -t T < /tok/tokens; n=\${#T[@]}
      for w in \$(seq 1 \$C); do
        ( i=\$((WOFF + w))
          while [ \$(date +%s) -lt \$END ]; do
            t=\${T[\$((i % n))]}; i=\$((i + C))
            curl -sk -o /dev/null --max-time 60 -w '%{http_code} %{time_total}\n' \
              -H "Authorization: Bearer \$t" -H 'Content-Type: application/json' -d "\$BODY" "\$URL" >> /tmp/w\$w
          done ) &
      done
      wait; cat /tmp/w* > /tmp/result; touch /tmp/done; sleep 900
YAML
done
oc wait pod -n "$CLIENT_NAMESPACE" -l app=maas-load --for=condition=Ready --timeout=300s >/dev/null
start=$(date +%s)
DURATION=$(( END - t0 ))   # load window: pods send from creation until END (throughput = total / this)
echo ""
echo "== under load (every ${SAMPLE_INTERVAL}s; Limitador commands only) =="
printf '%-6s %-14s %s\n' 't(s)' 'Redis cmd/s' 'RTT min/max/avg(ms)'
rtt_samples=(); p_lim=$b_lim; p_t=$start
# paths inside sh -c so Git Bash on Windows does not rewrite /tmp/...
all_done() { local p; for p in $(seq 0 $((LOAD_PODS - 1))); do
  oc exec -n "$CLIENT_NAMESPACE" "maas-load-${p}" -- sh -c 'test -f /tmp/done' 2>/dev/null || return 1; done; }
while ! all_done; do
  snap; now=$(date +%s)
  rate=$(awk -v d="$((S_LIM - p_lim))" -v t="$((now - p_t))" 'BEGIN{printf "%.1f", (t? d/t : 0)}'); p_lim=$S_LIM; p_t=$now
  r=$(rtt 5); rtt_samples+=("$r")
  printf '%-6s %-14s %s\n' "$((now - start))" "$rate" "$(awk '{print $1"/"$2"/"$3}' <<<"$r")"
  sleep "$SAMPLE_INTERVAL"
done
elapsed=$(( $(date +%s) - start ))

# ---- after -------------------------------------------------------------------
snap; a_in=$S_IN; a_out=$S_OUT; a_ping=$S_PING; a_lim=$S_LIM; a_mix=$S_MIX; a_mem=$S_MEM; peak_mem=$S_PEAK
a_keys=$(rcli DBSIZE)
a_auth=$(lmetric authorized_calls); a_limited=$(lmetric limited_calls)

res=$(for p in $(seq 0 $((LOAD_PODS - 1))); do
  oc exec -n "$CLIENT_NAMESPACE" "maas-load-${p}" -- sh -c 'cat /tmp/result'; done | tr -d '\r')
total=$(wc -l <<<"$res")
lat=$(awk '$1==200 {print $2*1000}' <<<"$res" | sort -n)
ok=$(wc -l <<<"$lat")
pct() { awk -v p="$1" '{a[NR]=$1} END {i=int(NR*p/100); if(i<1)i=1; printf "%.0f", a[i]}' <<<"$lat"; }
pings=$((a_ping - b_ping))
net_in=$(( a_in - b_in - pings * 14 )); net_out=$(( a_out - b_out - pings * 7 - MON_OUT_BYTES ))
[ "$net_out" -lt 0 ] && net_out=0
lim_cmds=$((a_lim - b_lim))
mix=$(for kv in $a_mix; do k=${kv%%=*}; v=${kv#*=}; bv=$(tr ' ' '\n' <<<"$b_mix" | grep "^${k}=" | cut -d= -f2); d=$((v - ${bv:-0})); [ "$d" -gt 0 ] && printf '%s=%s ' "$k" "$d"; done)

echo ""
echo "== [${LOAD_LABEL}] result =="
printf '%-36s %s\n' "requests (200 / total)" "${ok} / ${total}"
printf '%-36s %s\n' "HTTP codes" "$(awk '{print $1}' <<<"$res" | sort | uniq -c | awk '{printf "%s:%s ", $2, $1}')"
printf '%-36s %.1f\n' "throughput (req/s)" "$(awk -v n="$total" -v d="$DURATION" 'BEGIN{print n/d}')"
printf '%-36s %s / %s / %s / %s\n' "client latency p50/p95/p99/max ms" "$(pct 50)" "$(pct 95)" "$(pct 99)" "$(pct 100)"
printf '%-36s %s / %s\n' "Limitador authorized/limited calls" "$((a_auth - b_auth))" "$((a_limited - b_limited))"
printf '%-36s %s (%.1f/s, %.2f per request)\n' "Redis commands from Limitador" "$lim_cmds" \
  "$(awk -v n="$lim_cmds" -v d="$elapsed" 'BEGIN{print n/d}')" "$(awk -v n="$lim_cmds" -v r="$total" 'BEGIN{print (r? n/r : 0)}')"
printf '%-36s %s\n' "  command mix" "$mix"
printf '%-36s in %.1f KB/s, out %.1f KB/s = %.3f Mbps (%.0f B/request)\n' "Redis network from Limitador (approx)" \
  "$(awk -v n="$net_in" -v d="$elapsed" 'BEGIN{print n/d/1024}')" \
  "$(awk -v n="$net_out" -v d="$elapsed" 'BEGIN{print n/d/1024}')" \
  "$(awk -v n="$((net_in + net_out))" -v d="$elapsed" 'BEGIN{print n*8/d/1000000}')" \
  "$(awk -v n="$((net_in + net_out))" -v r="$total" 'BEGIN{print (r? n/r : 0)}')"
printf '%-36s %s -> %s\n' "Redis keys" "$b_keys" "$a_keys"
printf '%-36s %.2f MB (peak %.2f MB)\n' "Redis used_memory" "$(awk -v m="$a_mem" 'BEGIN{print m/1048576}')" "$(awk -v m="$peak_mem" 'BEGIN{print m/1048576}')"
printf '%-36s %s\n' "RTT under load, avg of samples (ms)" "$(printf '%s\n' "${rtt_samples[@]}" | awk '{s+=$3; if($2>m)m=$2; n++} END {printf "%.2f (max %s)", s/n, m}')"

# keep raw per-request data locally (the cluster may not survive)
mkdir -p "$RESULTS_DIR"
raw="${RESULTS_DIR}/$(date +%Y%m%d-%H%M%S)-${LOAD_LABEL}.requests"
printf '# %s storage=%s concurrency=%s pods=%s duration=%ss max_tokens=%s\n# http_code time_total_s\n' \
  "$LOAD_LABEL" "${STORE:-memory}" "$CONCURRENCY" "$LOAD_PODS" "$DURATION" "$MAX_TOKENS" > "$raw"
echo "$res" >> "$raw"
echo ""
echo "raw requests saved: ${raw}"

oc delete pod -n "$CLIENT_NAMESPACE" -l app=maas-load --ignore-not-found --wait=false >/dev/null
oc delete pod redis-mon -n "$LIMITADOR_NS" --ignore-not-found --wait=false >/dev/null
