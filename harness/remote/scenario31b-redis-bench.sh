#!/usr/bin/env bash
# Scenario 31-B: capacity of the Limitador store itself (Redis + inter-DC link),
# without the MaaS data path (Gateway/Authorino/GPU cap end-to-end load first).
# Runs redis-benchmark from Pods in the Limitador namespace (same egress path)
# against the URL in Secret limitador-redis-config, with Limitador's command
# mix (Lua script + INCRBY + GET) on ~1.3 KB keys like Limitador's counters.
# Samples Redis CPU/ops/network during each step.
#
#   bash remote/scenario31b-redis-bench.sh
#   BENCH_STEPS="50 200 800" BENCH_PODS=4 BENCH_ROUNDS=600 bash remote/scenario31b-redis-bench.sh
#   REDIS_CONTEXT=<kubeconfig context of the Redis cluster> bash remote/scenario31b-redis-bench.sh   # + CPU throttling
set -euo pipefail

LIMITADOR_NS="${LIMITADOR_NS:-kuadrant-system}"
REDIS_SECRET="${REDIS_SECRET:-limitador-redis-config}"
REDIS_IMAGE="${REDIS_IMAGE:-registry.redhat.io/rhel9/redis-7:latest}"
BENCH_STEPS="${BENCH_STEPS:-25 100 400 1600}"   # total client connections per step
BENCH_PODS="${BENCH_PODS:-4}"
BENCH_ROUNDS="${BENCH_ROUNDS:-600}"   # pipelined round trips per connection per command (no timeout: it did not stop redis-benchmark reliably)
KEY_BYTES="${KEY_BYTES:-1300}"
BENCH_PIPELINE="${BENCH_PIPELINE:-8}"   # in-flight cmds per connection (Limitador multiplexes, so not 1)
REDIS_CONTEXT="${REDIS_CONTEXT:-}"   # optional: read the Redis Pod's cgroup cpu.stat (throttling) on its own cluster
REDIS_NS="${REDIS_NS:-remote-redis}"
RESULTS_DIR="${RESULTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results/scenario31b}"

REDIS_URL=$(oc get secret "$REDIS_SECRET" -n "$LIMITADOR_NS" -o jsonpath='{.data.URL}' | base64 -d)
TLS=""; case "$REDIS_URL" in rediss://*) TLS="--tls"; case "$REDIS_URL" in *'#insecure') TLS="--tls --insecure";; esac;; esac
U="${REDIS_URL%%#*}"; U="${U#*://}"; CRED="${U%@*}"; HOSTPORT="${U#*@}"; HOSTPORT="${HOSTPORT%%/*}"
RHOST="${HOSTPORT%:*}"; RPORT="${HOSTPORT##*:}"; RPASS="${CRED#*:}"; RUSER="${CRED%%:*}"
[ "$CRED" = "$U" ] && { RPASS=""; RUSER=""; }

for p in $(seq 0 $((BENCH_PODS - 1))) mon; do
  oc delete pod "redis-bench-${p}" -n "$LIMITADOR_NS" --ignore-not-found >/dev/null
  oc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: redis-bench-${p}, namespace: ${LIMITADOR_NS}, labels: {app: redis-bench}}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: main
    image: ${REDIS_IMAGE}
    command: [sleep, "7200"]
    resources: {requests: {cpu: "1", memory: 256Mi}}
    env:
    - {name: RHOST, value: "${RHOST}"}
    - {name: RPORT, value: "${RPORT}"}
    - {name: RUSER, value: "${RUSER}"}
    - {name: RPASS, value: "${RPASS}"}
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
done
oc wait pod -n "$LIMITADOR_NS" -l app=redis-bench --for=condition=Ready --timeout=300s >/dev/null

# redis-cli/benchmark args built inside the Pod from env (password never on the oc command line)
AUTH='${RUSER:+--user $RUSER} ${RPASS:+-a $RPASS}'
mon() { oc exec -n "$LIMITADOR_NS" redis-bench-mon -- sh -c "redis-cli -h \$RHOST -p \$RPORT $TLS $AUTH --no-auth-warning $*" 2>/dev/null | tr -d '\r'; }
field() { grep "^$1:" <<<"$2" | cut -d: -f2; }
# "nr_periods nr_throttled" of the Redis container (cgroup v2), or "- -" without REDIS_CONTEXT
cgstat() {
  [ -n "$REDIS_CONTEXT" ] || { echo "- -"; return; }
  oc --context "$REDIS_CONTEXT" exec -n "$REDIS_NS" deploy/redis -- sh -c "cat /sys/fs/cgroup/cpu.stat" 2>/dev/null | tr -d '\r' | awk '$1=="nr_periods"{p=$2} $1=="nr_throttled"{t=$2} END{print p+0, t+0}'
}

mkdir -p "$RESULTS_DIR"
OUT="${RESULTS_DIR}/$(date +%Y%m%d-%H%M%S)-redis-bench.log"
run_bench() {
echo "== redis-benchmark -> ${RHOST}:${RPORT} ($TLS) pods=${BENCH_PODS} pipeline=${BENCH_PIPELINE} key=${KEY_BYTES}B rounds=${BENCH_ROUNDS}"
echo "== RTT idle: $(oc exec -n "$LIMITADOR_NS" redis-bench-mon -- sh -c "timeout 6 redis-cli -h \$RHOST -p \$RPORT $TLS $AUTH --no-auth-warning --latency --raw" 2>/dev/null | tr -d '\r')"

pad=$(head -c "$KEY_BYTES" /dev/zero | tr '\0' 'k')
# Limitador-like mix per "request": EVAL (check/update script) + INCRBY + GET on a long key
CMDS=(
  "EVAL 'return(redis.call([[incrby]],KEYS[1],ARGV[1]))' 1 ${pad}__rand_int__ 3"
  "INCRBY ${pad}__rand_int__ 3"
  "GET ${pad}__rand_int__"
)

echo "== Redis: $(mon INFO server | grep -E '^redis_version:' | tr -d '\r'), io_threads $(mon CONFIG GET io-threads | tail -1)"
printf '\n%-6s %-10s %-14s %-10s %-10s %-10s %-10s %s\n' conns cmd/s 'p50 ms' 'redis CPU' 'throttled' 'net Mbps' 'RTT ms' 'MaaS req/s eq.'
for conns in $BENCH_STEPS; do
  per=$(( (conns + BENCH_PODS - 1) / BENCH_PODS ))
  s0=$(mon INFO all); g0=$(cgstat); t0=$(date +%s)
  pids=()
  for p in $(seq 0 $((BENCH_PODS - 1))); do
    ( for cmd in "${CMDS[@]}"; do
        # -n large + timeout = fixed duration per command type
        # </dev/null: a backgrounded oc.exe (Git Bash on Windows) otherwise blocks on the console
        oc exec -n "$LIMITADOR_NS" "redis-bench-${p}" </dev/null -- sh -c \
          "redis-benchmark -h \$RHOST -p \$RPORT $TLS $AUTH -c ${per} -P ${BENCH_PIPELINE} -n $((per * BENCH_PIPELINE * BENCH_ROUNDS)) -r 100000 --threads 2 -q --precision 2 ${cmd}" 2>&1 \
          | tr '\r' '\n' | grep -E 'requests per second' | tail -1   # -q summary: "<cmd>: N requests per second, p50=X msec"
      done ) > "${RESULTS_DIR}/.bench-${conns}-${p}" &
    pids+=($!)
  done
  sleep 5; r=$(oc exec -n "$LIMITADOR_NS" redis-bench-mon -- sh -c "timeout 5 redis-cli -h \$RHOST -p \$RPORT $TLS $AUTH --no-auth-warning --latency --raw" 2>/dev/null | tr -d '\r' || true)   # timeout exits 124
  wait "${pids[@]}" || echo "   warn: a redis-benchmark run failed at ${conns} connections"
  s1=$(mon INFO all); g1=$(cgstat); t1=$(date +%s); dt=$((t1 - t0))
  # share of 100 ms CFS periods in which the Redis container hit its cpu limit
  thr=$(awk -v a="$g0" -v b="$g1" 'BEGIN{split(a,x," "); split(b,y," "); if (x[1]=="-" || y[1]==x[1]) print "-"; else printf "%.0f%%", (y[2]-x[2])/(y[1]-x[1])*100}')
  cmds=$(( $(field total_commands_processed "$s1") - $(field total_commands_processed "$s0") ))
  net=$(( $(field total_net_input_bytes "$s1") + $(field total_net_output_bytes "$s1") - $(field total_net_input_bytes "$s0") - $(field total_net_output_bytes "$s0") ))
  cpu=$(awk -v a="$(field used_cpu_sys "$s0")" -v b="$(field used_cpu_user "$s0")" -v c="$(field used_cpu_sys "$s1")" -v d="$(field used_cpu_user "$s1")" -v t="$dt" 'BEGIN{printf "%.0f%%", (c+d-a-b)/t*100}')
  lat=$(cat "${RESULTS_DIR}"/.bench-"${conns}"-* | grep -oE 'p50=[0-9.]+' | cut -d= -f2 | awk '{s+=$1; n++} END {if (n) printf "%.2f", s/n; else print "-"}')
  printf '%-6s %-10s %-14s %-10s %-10s %-10s %-10s %s\n' "$conns" "$((cmds / dt))" "$lat" "$cpu" "$thr" \
    "$(awk -v n="$net" -v t="$dt" 'BEGIN{printf "%.1f", n*8/t/1e6}')" "$(awk '{print $3}' <<<"$r")" "$((cmds / dt / 3))"
  echo "   detail: $(cat "${RESULTS_DIR}"/.bench-"${conns}"-* | tr '\n' ' ' | cut -c1-400)"
  rm -f "${RESULTS_DIR}"/.bench-"${conns}"-*
done
echo ""
echo "MaaS req/s eq. = Redis cmd/s / 3 (Limitador issues 3 commands per MaaS request, scenario 31)"
echo "log: ${OUT}"
}
# tee via a pipe, not exec > >(tee): a process substitution stalled the backgrounded oc exec calls
run_bench 2>&1 | tee "$OUT"
oc delete pod -n "$LIMITADOR_NS" -l app=redis-bench --ignore-not-found --wait=false >/dev/null
