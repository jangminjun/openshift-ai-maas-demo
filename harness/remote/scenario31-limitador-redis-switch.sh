#!/usr/bin/env bash
# Scenario 31 (MaaS side): point Limitador's Redis store at another URL
# (e.g. the remote Redis from scenario31-remote-redis-up.sh) or restore the
# original one. Run with `oc` logged in to the MaaS cluster.
#
#   bash remote/scenario31-limitador-redis-switch.sh                 # connect, REDIS_URL from STATE_FILE
#   REDIS_URL='rediss://default:pw@host:6379' bash remote/scenario31-limitador-redis-switch.sh
#   REDIS_ACTION=restore bash remote/scenario31-limitador-redis-switch.sh
#   REDIS_ACTION=probe   bash remote/scenario31-limitador-redis-switch.sh   # PING + RTT only
#   REDIS_ACTION=mode REDIS_MODE=redis bash remote/scenario31-limitador-redis-switch.sh   # or redis-cached
#
# Limitador reads the URL from Secret limitador-redis-config (key URL) via
# env LIMITADOR_OPERATOR_REDIS_URL, so a Secret change + rollout restart applies it.
set -euo pipefail

LIMITADOR_NS="${LIMITADOR_NS:-kuadrant-system}"
LIMITADOR_DEPLOY="${LIMITADOR_DEPLOY:-limitador-limitador}"
REDIS_SECRET="${REDIS_SECRET:-limitador-redis-config}"
REDIS_ACTION="${REDIS_ACTION:-connect}"
PROBE_IMAGE="${PROBE_IMAGE:-registry.redhat.io/rhel9/redis-7:latest}"
STATE_DIR="${STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/remote-redis.env}"
ORIG_FILE="${STATE_DIR}/limitador-redis-url.orig"

current_url() { oc get secret "$REDIS_SECRET" -n "$LIMITADOR_NS" -o jsonpath='{.data.URL}' | base64 -d; }
mask() { sed -E 's#(://[^:@]*:)[^@]*@#\1****@#'; }

# redis_probe URL -- PING and 10s RTT sample from a Pod in LIMITADOR_NS (same egress path as Limitador).
redis_probe() {
  local url=$1 tls=""
  case "$url" in rediss://*) tls="--tls"; case "$url" in *'#insecure') tls="--tls --insecure";; esac;; esac
  oc delete pod redis-probe -n "$LIMITADOR_NS" --ignore-not-found >/dev/null 2>&1
  oc run redis-probe -n "$LIMITADOR_NS" --rm -i --restart=Never --quiet --image="$PROBE_IMAGE" \
    --env=RURL="${url%%#*}" --env=TLS="$tls" --command -- sh -c '
      sleep 3
      echo "PING: $(redis-cli -u "$RURL" $TLS --no-auth-warning PING 2>&1 | tail -1)"
      echo "RTT ms (min max avg samples): $(timeout 12 redis-cli -u "$RURL" $TLS --no-auth-warning --latency --raw 2>&1)"
    ' 2>/dev/null
}

restart_limitador() {
  oc rollout restart deploy/"$LIMITADOR_DEPLOY" -n "$LIMITADOR_NS" >/dev/null
  oc rollout status deploy/"$LIMITADOR_DEPLOY" -n "$LIMITADOR_NS" --timeout=180s
  sleep 5
  echo "-- Limitador log (redis/partition/error)"
  oc logs deploy/"$LIMITADOR_DEPLOY" -n "$LIMITADOR_NS" --tail=200 | grep -iE 'redis|partition|error|panic' | tail -5 || echo "(none)"
}

case "$REDIS_ACTION" in
  probe)
    url="${REDIS_URL:-$(current_url)}"
    echo "== probe $(echo "$url" | mask) =="
    redis_probe "$url"
    ;;
  connect)
    if [ -z "${REDIS_URL:-}" ]; then
      [ -f "$STATE_FILE" ] || { echo "REDIS_URL not set and ${STATE_FILE} missing"; exit 1; }
      REDIS_URL=$(grep '^REDIS_URL=' "$STATE_FILE" | cut -d= -f2-)
    fi
    echo "== 1) preflight: $(echo "$REDIS_URL" | mask) =="
    out=$(redis_probe "$REDIS_URL"); echo "$out"
    echo "$out" | grep -q 'PING: PONG' || { echo "preflight failed -- Limitador not changed"; exit 1; }

    echo "== 2) backup current URL =="
    if [ -f "$ORIG_FILE" ]; then echo "kept existing ${ORIG_FILE}"; else current_url > "$ORIG_FILE"; echo "saved to ${ORIG_FILE}"; fi

    echo "== 3) Secret ${REDIS_SECRET} + rollout restart =="
    oc set data secret/"$REDIS_SECRET" -n "$LIMITADOR_NS" URL="$REDIS_URL" >/dev/null
    restart_limitador
    echo "Limitador store: $(current_url | mask)"
    ;;
  restore)
    [ -f "$ORIG_FILE" ] || { echo "${ORIG_FILE} missing -- nothing to restore"; exit 1; }
    echo "== restore $(mask < "$ORIG_FILE") =="
    oc set data secret/"$REDIS_SECRET" -n "$LIMITADOR_NS" URL="$(cat "$ORIG_FILE")" >/dev/null
    restart_limitador
    rm -f "$ORIG_FILE"
    echo "Limitador store: $(current_url | mask)"
    ;;
  mode)
    # REDIS_MODE=redis (every check waits for Redis) | redis-cached (local cache + async flush)
    REDIS_MODE="${REDIS_MODE:?set REDIS_MODE=redis|redis-cached}"
    if [ "$REDIS_MODE" = redis ]; then
      patch='{"spec":{"storage":{"redis-cached":null,"redis":{"configSecretRef":{"name":"'"$REDIS_SECRET"'"}}}}}'
    else
      patch='{"spec":{"storage":{"redis":null,"redis-cached":{"configSecretRef":{"name":"'"$REDIS_SECRET"'"},
        "options":{"flush-period":'"${FLUSH_PERIOD:-500}"',"max-cached":10000,"batch-size":100,"response-timeout":'"${RESPONSE_TIMEOUT:-500}"'}}}}}'
    fi
    echo "== Limitador storage -> ${REDIS_MODE} =="
    oc patch limitador limitador -n "$LIMITADOR_NS" --type=merge -p "$patch" >/dev/null
    sleep 5
    oc rollout status deploy/"$LIMITADOR_DEPLOY" -n "$LIMITADOR_NS" --timeout=180s
    oc get limitador limitador -n "$LIMITADOR_NS" -o jsonpath='{.spec.storage}{"\n"}'
    ;;
  *) echo "REDIS_ACTION must be connect|restore|probe|mode"; exit 1 ;;
esac
