#!/usr/bin/env bash
# Scenario 32: MaaS behaviour when the remote Redis (Limitador store) fails.
# Sends steady load (per-request timestamp + HTTP code), injects one fault at
# PRE seconds, removes it CUT seconds later, and prints a 10 s timeline of
# HTTP codes / latency plus Limitador and Redis counters.
# Run with `oc` logged in to the MaaS cluster. Reuses Secret maas-load-tokens
# (MaaS API keys) made by scenario31-remote-redis-load.sh -- run that once first.
#
#   FAULT=F1 bash remote/scenario32-redis-failure.sh   # link cut 60 s (redis-cached)
#   FAULT=F2 bash remote/scenario32-redis-failure.sh   # quota enforcement during the cut
#   FAULT=F3 bash remote/scenario32-redis-failure.sh   # Limitador memory loss (Pod deleted): is an exhausted quota kept?
#   FAULT=F4 bash remote/scenario32-redis-failure.sh   # link cut 60 s (redis, control)
#   FAULT=F5 bash remote/scenario32-redis-failure.sh   # remote Redis restart
#   FAULT=F6 bash remote/scenario32-redis-failure.sh   # remote Redis stopped for CUT s (connection refused, not a silent drop)
#
# The link cut is a NetworkPolicy on the Limitador Pod allowing only DNS egress.
# F5 restarts the Redis container over SSH (DS_HOST in harness/state/remote-datastore.env).
set -euo pipefail
declare -F maas_init >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib-maas-client.sh"

FAULT="${FAULT:-F1}"
PRE="${PRE:-30}"; CUT="${CUT:-60}"; POST="${POST:-180}"
CONCURRENCY="${CONCURRENCY:-16}"
MAX_TOKENS="${MAX_TOKENS:-16}"
LIMITADOR_NS="${LIMITADOR_NS:-kuadrant-system}"
LIMITADOR_DEPLOY="${LIMITADOR_DEPLOY:-limitador-limitador}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/myocp-bastion}"
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DS_STATE="${DS_STATE:-${HARNESS_DIR}/state/remote-datastore.env}"
RESULTS_DIR="${RESULTS_DIR:-${HARNESS_DIR}/results/scenario32}"
# F2: low-limit subscription (scenario 22 values)
QUOTA_LIMIT="${QUOTA_LIMIT:-200}"; QUOTA_WINDOW="${QUOTA_WINDOW:-2m}"; QUOTA_WINDOW_SECONDS="${QUOTA_WINDOW_SECONDS:-120}"
QUOTA_TOKENS="${QUOTA_TOKENS:-64}"; QUOTA_REQUESTS="${QUOTA_REQUESTS:-15}"

maas_init
# shellcheck disable=SC1090
. "$DS_STATE"
mkdir -p "$RESULTS_DIR"
OUT="${RESULTS_DIR}/$(date +%Y%m%d-%H%M%S)-${FAULT}"

# ---- helpers ------------------------------------------------------------------
# lmetric NAME -- sum over labels; 0 if the metric is not exported yet, "-" if Limitador is unreachable
lmetric() { oc exec -n "$LIMITADOR_NS" deploy/"$LIMITADOR_DEPLOY" -- curl -s --max-time 3 localhost:8080/metrics 2>/dev/null \
  | tr -d '\r' | awk -v m="$1" 'NF {seen=1} $1==m || index($1, m"{")==1 {s+=$2} END {if (seen) printf "%d", s; else print "-"}'; }
num() { [ "$1" = - ] && echo 0 || echo "$1"; }
rsh() { { ssh -o ConnectTimeout=5 -i "$SSH_KEY_PATH" "ec2-user@${DS_HOST}" "$@" 2>/dev/null || true; } | tr -d '\r'; }   # never fatal: Redis may be down
rcli() { rsh "sudo docker exec redis redis-cli --tls --insecure -a '${REDIS_PASSWORD}' --no-auth-warning $*"; }
rcmds() { rcli INFO stats | awk -F: '/^total_commands_processed/{print $2}'; }
# sum of all Limitador counters (token usage) stored in Redis
rsum() { rsh "sudo docker exec redis sh -c 'redis-cli --tls --insecure -a ${REDIS_PASSWORD} --no-auth-warning --scan \
  | while read -r k; do redis-cli --tls --insecure -a ${REDIS_PASSWORD} --no-auth-warning GET \"\$k\"; done' | awk '/^[0-9]+\$/{s+=\$1} END{print s+0}'"; }
# vtok -- prompt + generated tokens served by the model (vLLM), i.e. what the quota counters should grow by
vtok() { oc exec -n "$MODEL_NAMESPACE" "$(oc get pod -n "$MODEL_NAMESPACE" -o name | grep kserve | head -1)" -c main --   curl -sk --max-time 3 https://localhost:8000/metrics 2>/dev/null | tr -d ''   | awk '/^vllm:(prompt|generation)_tokens_total/{s+=$2} END{printf "%d", s}'; }
lim_ready() { oc get deploy "$LIMITADOR_DEPLOY" -n "$LIMITADOR_NS" -o jsonpath='{.status.readyReplicas}/{.status.replicas}'; }

cut_on() {
  oc apply -n "$LIMITADOR_NS" -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: limitador-redis-cut}
spec:
  podSelector: {matchLabels: {app: limitador}}
  policyTypes: [Egress]
  egress:
  - ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}, {protocol: UDP, port: 5353}, {protocol: TCP, port: 5353}]
YAML
}
cut_off() { oc delete networkpolicy limitador-redis-cut -n "$LIMITADOR_NS" --ignore-not-found >/dev/null; }
set_mode() { REDIS_ACTION=mode REDIS_MODE="$1" bash "${HARNESS_DIR}/remote/scenario31-limitador-redis-switch.sh" >/dev/null; }
trap 'cut_off; [ "$FAULT" = F6 ] && rsh "sudo docker start redis" >/dev/null' EXIT   # never leave Limitador cut off or Redis stopped

# ---- F2: quota enforcement while the link is cut ------------------------------
if [ "$FAULT" = F2 ]; then
  sa=$(maas_sa maas-s32-quota)
  maas_subscription maas-s32-quota "$QUOTA_LIMIT" "$QUOTA_WINDOW" 0 "$sa"
  maas_settle
  tok=$(maas_token maas-s32-quota 1h | tr -d '\r')
  maas_request "$tok" "${MAAS_URL}/maas-api/v1/api-keys" -X POST -H 'Content-Type: application/json' -d '{"name":"s32-quota","expiresIn":3600}'
  key=$(maas_jq -r .key <<<"$BODY_OUT")
  run_quota() {  # $1 label
    local cum=0 i used first=""
    printf '%-10s %-4s %-5s %-7s %s\n' phase '#' HTTP tokens cumulative
    for i in $(seq 1 "$QUOTA_REQUESTS"); do
      maas_chat "$key" "$QUOTA_TOKENS"; used=$(maas_usage); cum=$((cum + used))
      printf '%-10s %-4s %-5s %-7s %s\n' "$1" "$i" "$HTTP" "$used" "$cum"
      [ "$HTTP" = 429 ] && [ -z "$first" ] && first=$i
    done
    echo "$1: limit ${QUOTA_LIMIT} tok, first 429 at #${first:-none}, tokens served ${cum}"
  }
  {
    echo "== F2 baseline (link up): ${QUOTA_LIMIT} tok / ${QUOTA_WINDOW}, max_tokens ${QUOTA_TOKENS} =="
    run_quota up
    echo "-- wait ${QUOTA_WINDOW_SECONDS}s for the window to reset"; sleep "$QUOTA_WINDOW_SECONDS"
    echo "== F2 link cut =="
    cut_on; sleep 5
    echo "datastore_partitioned=$(lmetric datastore_partitioned)"
    run_quota cut
    echo "datastore_partitioned=$(lmetric datastore_partitioned)"
    cut_off
  } | tee "${OUT}.log"
  exit 0
fi

# ---- F3: Limitador memory loss (Pod deleted) -- is an exhausted quota kept? ---
if [ "$FAULT" = F3 ]; then
  F3_WINDOW="${F3_WINDOW:-10m}"        # long enough not to reset during the test
  F3_MODE="${F3_MODE:-redis-cached}"   # redis = control (no local cache)
  user="maas-s32-${F3_MODE}-$(date +%H%M)"   # fresh user -> fresh quota window per run
  [ "$F3_MODE" = redis ] && set_mode redis
  sa=$(maas_sa "$user")
  maas_subscription "$user" "$QUOTA_LIMIT" "$F3_WINDOW" 0 "$sa"
  maas_settle
  tok=$(maas_token "$user" 1h | tr -d '\r')
  maas_request "$tok" "${MAAS_URL}/maas-api/v1/api-keys" -X POST -H 'Content-Type: application/json' -d "{\"name\":\"${user}\",\"expiresIn\":3600}"
  key=$(maas_jq -r .key <<<"$BODY_OUT")
  # liveness probe uses a load key: a 429 on the exhausted key does not raise authorized_calls
  lkey=$(oc get secret maas-load-tokens -n "$CLIENT_NAMESPACE" -o jsonpath='{.data.tokens}' | base64 -d | head -1 | tr -d '\r')
  probe() {  # $1 phase, $2 count
    local i; for i in $(seq 1 "$2"); do
      maas_chat "$key" "$QUOTA_TOKENS"
      printf '%-28s #%-3s HTTP %s  tokens %s  (%ss)\n' "$1" "$i" "$HTTP" "$(maas_usage)" "$(( $(date +%s) - T0 ))"
    done; }
  lim_pod() { oc get pod -n "$LIMITADOR_NS" -l app=limitador -o jsonpath='{range .items[*]}{.metadata.name}({.status.containerStatuses[0].ready}) {end}'; }
  kill_limitador() { oc delete pod -n "$LIMITADOR_NS" -l app=limitador --wait=false >/dev/null; }
  T0=$(date +%s)
  {
    echo "== F3 (${F3_MODE}): user ${user}, limit ${QUOTA_LIMIT} tok / ${F3_WINDOW}, max_tokens ${QUOTA_TOKENS} =="
    echo "-- 1) exhaust the quota (link up)"
    probe "1 exhaust" 4
    echo "-- 3a) delete Limitador Pod (link up): $(lim_pod)"
    kill_limitador
    oc rollout status deploy/"$LIMITADOR_DEPLOY" -n "$LIMITADOR_NS" --timeout=180s >/dev/null
    echo "   new Pod: $(lim_pod)"
    probe "3a after restart" 3
    echo "   Limitador metrics after 3a: authorized $(lmetric authorized_calls), limited $(lmetric limited_calls)"
    echo "-- 3b) cut + delete Limitador Pod"
    cut_on; sleep 3; kill_limitador; sleep 10
    echo "   Pods during cut: $(lim_pod)"
    probe "3b during cut" 3
    echo "   Pods during cut (+30s): $(lim_pod)"
    cut_off; echo "   link restored ($(( $(date +%s) - T0 ))s)"
    oc rollout status deploy/"$LIMITADOR_DEPLOY" -n "$LIMITADOR_NS" --timeout=300s >/dev/null
    echo "   Pod Ready ($(( $(date +%s) - T0 ))s): $(lim_pod)"
    alive() { local i a b; for i in $(seq 1 90); do a=$(num "$(lmetric authorized_calls)"); maas_chat "$lkey" 1; b=$(num "$(lmetric authorized_calls)")
      [ "$b" -gt "$a" ] && return 0; sleep 2; done; return 1; }
    if alive; then echo "   Limitador answering ($(( $(date +%s) - T0 ))s)"; else echo "   Limitador not answering after 180s"; fi
    probe "3b after restore" 3
    [ "$F3_MODE" = redis ] && set_mode redis-cached
  } | tee "${OUT}-${F3_MODE}.log"
  exit 0
fi

# ---- F1/F4/F5: load + fault timeline ------------------------------------------
oc get secret maas-load-tokens -n "$CLIENT_NAMESPACE" >/dev/null || { echo "run scenario31-remote-redis-load.sh once to create maas-load-tokens"; exit 1; }
# a previous cut leaves Limitador unresponsive for ~45 s -- start only once it answers again
lim_wait() {
  local key i a b; key=$(oc get secret maas-load-tokens -n "$CLIENT_NAMESPACE" -o jsonpath='{.data.tokens}' | base64 -d | head -1 | tr -d '\r')
  for i in $(seq 1 36); do
    a=$(num "$(lmetric authorized_calls)"); maas_chat "$key" 1; b=$(num "$(lmetric authorized_calls)")
    [ "$b" -gt "$a" ] && { echo "Limitador answering (waited $((i * 5 - 5))s)"; return 0; }
    sleep 5
  done
  echo "Limitador still not answering after 180s"; return 1
}
lim_wait
[ "$FAULT" = F4 ] && { echo "storage -> redis"; set_mode redis; }
TOTAL=$((PRE + CUT + POST))
oc delete pod maas-fault-load -n "$CLIENT_NAMESPACE" --ignore-not-found >/dev/null
oc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: maas-fault-load, namespace: ${CLIENT_NAMESPACE}, labels: {app: maas-fault-load}}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  volumes: [{name: tok, secret: {secretName: maas-load-tokens}}]
  containers:
  - name: load
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    resources: {requests: {cpu: 500m, memory: 256Mi}}
    volumeMounts: [{name: tok, mountPath: /tok}]
    env:
    - {name: URL, value: "${MAAS_URL}/v1/chat/completions"}
    - {name: BODY, value: '{"model":"${MODEL_ID}","messages":[{"role":"user","content":"Say hi."}],"max_tokens":${MAX_TOKENS}}'}
    - {name: C, value: "${CONCURRENCY}"}
    command: [bash, -c]
    args:
    - |
      mapfile -t T < /tok/tokens; n=\${#T[@]}
      until [ -f /tmp/go ]; do sleep 0.2; done; END=\$(cat /tmp/go)
      for w in \$(seq 1 \$C); do
        ( i=\$w
          while [ \$(date +%s) -lt \$END ]; do
            t=\${T[\$((i % n))]}; i=\$((i + C)); s=\$(date +%s)
            echo "\$s \$(curl -sk -o /dev/null --max-time 30 -w '%{http_code} %{time_total}' \
              -H "Authorization: Bearer \$t" -H 'Content-Type: application/json' -d "\$BODY" "\$URL")" >> /tmp/w\$w
          done ) &
      done
      wait; cat /tmp/w* > /tmp/result; touch /tmp/done; sleep 900
YAML
oc wait pod/maas-fault-load -n "$CLIENT_NAMESPACE" --for=condition=Ready --timeout=180s >/dev/null

sum0=$(rsum); v0=$(vtok); a0=$(lmetric authorized_calls); l0=$(lmetric limited_calls)
start=$(date +%s); END=$((start + TOTAL))
oc exec -n "$CLIENT_NAMESPACE" maas-fault-load -- sh -c "echo ${END} > /tmp/go"
{
echo "== ${FAULT}: load ${CONCURRENCY} concurrent, fault at +${PRE}s for ${CUT}s, total ${TOTAL}s =="
echo "Limitador storage: $(oc get limitador limitador -n "$LIMITADOR_NS" -o jsonpath='{.spec.storage}' | grep -o '"redis[a-z-]*"' | head -1)"
printf '%-6s %-10s %-12s %-10s %-10s %-10s %s\n' 't(s)' event partitioned authorized limited redis_cmds limitador_ready
fault_on=0; fault_off=0; pa=$a0; pl=$l0; pc=$(rcmds)
while [ "$(date +%s)" -lt "$END" ]; do
  t=$(( $(date +%s) - start )); ev=""
  if [ "$fault_on" = 0 ] && [ "$t" -ge "$PRE" ]; then
    fault_on=1
    case "$FAULT" in
      F1|F4) cut_on; ev=cut ;;
      F6) rsh "sudo docker stop redis" >/dev/null; ev=redis-stop ;;
      F5) echo "-- Redis counters sum before restart: $(rsum), keys $(rcli DBSIZE)"; rsh "sudo docker restart redis" >/dev/null; ev=redis-restart ;;
    esac
  fi
  if [ "$fault_on" = 1 ] && [ "$fault_off" = 0 ] && [ "$t" -ge $((PRE + CUT)) ]; then
    fault_off=1
    case "$FAULT" in F5) ;; F6) rsh "sudo docker start redis" >/dev/null; ev=redis-start ;; *) cut_off; ev=restore ;; esac
  fi
  a=$(lmetric authorized_calls); l=$(lmetric limited_calls); c=$(rcmds)
  da=$([ "$a" != - ] && [ "$pa" != - ] && echo $((a - pa)) || echo -)
  dl=$([ "$l" != - ] && [ "$pl" != - ] && echo $((l - pl)) || echo -)
  dc=$([ -n "$c" ] && [ -n "$pc" ] && echo $((c - pc)) || echo -)
  printf '%-6s %-10s %-12s %-10s %-10s %-10s %s\n' "$t" "${ev:--}" "$(lmetric datastore_partitioned)" "+$da" "+$dl" "+$dc" "$(lim_ready)"
  pa=$a; pl=$l; [ -n "$c" ] && pc=$c
  [ "$FAULT" = F5 ] && [ "$ev" = redis-restart ] && echo "-- Redis counters sum right after restart: $(rsum), keys $(rcli DBSIZE)"
  sleep 5
done
until oc exec -n "$CLIENT_NAMESPACE" maas-fault-load -- sh -c 'test -f /tmp/done' 2>/dev/null; do sleep 3; done
cut_off
[ "$FAULT" = F4 ] && { echo "storage -> redis-cached"; set_mode redis-cached; }
sleep 3
res=$(oc exec -n "$CLIENT_NAMESPACE" maas-fault-load -- sh -c 'cat /tmp/result' | tr -d '\r')
echo "$res" > "${OUT}.requests"   # inside the tee block (subshell)
echo ""
echo "== client timeline (10 s buckets; fault window +${PRE}..+$((PRE + CUT))s) =="
printf '%-8s %-7s %-7s %-7s %-7s %-8s %s\n' 't(s)' total 200 429 5xx other 'p50 ms'
awk -v s="$start" '{b=int(($1-s)/10)*10; n[b]++; if($2==200){ok[b]++; lat[b]=lat[b]" "$3*1000} else if($2==429)q[b]++; else if($2~/^5/)e[b]++; else o[b]++}
  END {for (b in n) {m=split(lat[b],a," "); asort(a); printf "%-8s %-7d %-7d %-7d %-7d %-8d %s\n", b, n[b], ok[b], q[b], e[b], o[b], (m? int(a[int((m+1)/2)]) : "-")}}' <<<"$res" | sort -n
echo ""
echo "HTTP codes total: $(awk '{print $2}' <<<"$res" | sort | uniq -c | awk '{printf "%s:%s ", $2, $1}')"
echo "Limitador authorized/limited: $(( $(num "$(lmetric authorized_calls)") - $(num "$a0") )) / $(( $(num "$(lmetric limited_calls)") - $(num "$l0") )) (counters reset if Limitador restarted)"
sum1=$(rsum); v1=$(vtok)
echo "Redis counters sum: before ${sum0} -> after ${sum1} (+$((sum1 - sum0)))"
echo "model tokens served (vLLM): +$((v1 - v0))  -> counted in Redis: $(awk -v r="$((sum1 - sum0))" -v v="$((v1 - v0))" 'BEGIN{printf "%.1f%%", (v? r/v*100 : 0)}')"
} | tee "${OUT}.log"
oc delete pod maas-fault-load -n "$CLIENT_NAMESPACE" --ignore-not-found --wait=false >/dev/null
echo "saved ${OUT}.log"
