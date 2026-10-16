#!/usr/bin/env bash
# Point maas-api's PostgreSQL (API keys, subscriptions) at another database,
# e.g. the remote one from local/remote-datastore-ec2.sh, or restore the
# original. Run with `oc` logged in to the MaaS cluster.
#
#   bash remote/maas-db-switch.sh                                   # connect, PG_URL from STATE_FILE
#   PG_URL='postgresql://u:pw@host:5432/maas?sslmode=require' bash remote/maas-db-switch.sh
#   DB_ACTION=probe   bash remote/maas-db-switch.sh                 # SELECT 1 + RTT only
#   DB_ACTION=restore bash remote/maas-db-switch.sh
#
# maas-api reads DB_CONNECTION_URL from Secret maas-db-config in its own
# namespace at startup and applies its schema, so Secret + rollout restart applies it.
# API keys stored in the previous database are not migrated -- issue new ones.
set -euo pipefail

MAAS_NS="${MAAS_NS:-redhat-ai-gateway-infra}"
MAAS_DEPLOY="${MAAS_DEPLOY:-maas-api}"
DB_SECRET="${DB_SECRET:-maas-db-config}"
DB_ACTION="${DB_ACTION:-connect}"
PROBE_IMAGE="${PROBE_IMAGE:-registry.redhat.io/rhel9/postgresql-16:latest}"
STATE_DIR="${STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/remote-datastore.env}"
ORIG_FILE="${STATE_DIR}/maas-db-url.orig"

current_url() { oc get secret "$DB_SECRET" -n "$MAAS_NS" -o jsonpath='{.data.DB_CONNECTION_URL}' | base64 -d; }
mask() { sed -E 's#(://[^:@]*:)[^@]*@#\1****@#'; }

# db_probe URL -- SELECT 1 and 10 timed round trips from a Pod in MAAS_NS (same egress path as maas-api).
db_probe() {
  oc delete pod db-probe -n "$MAAS_NS" --ignore-not-found >/dev/null 2>&1
  oc run db-probe -n "$MAAS_NS" --rm -i --restart=Never --quiet --image="$PROBE_IMAGE" \
    --env=PGURL="$1" --command -- sh -c '
      sleep 3
      echo "SELECT 1: $(psql "$PGURL" -Atc "select 1" 2>&1 | tail -1)"
      echo "server: $(psql "$PGURL" -Atc "show server_version" 2>&1 | tail -1), ssl: $(psql "$PGURL" -Atc "select ssl from pg_stat_ssl where pid = pg_backend_pid()" 2>&1 | tail -1)"
      s=$(date +%s%N); i=0; while [ $i -lt 10 ]; do psql "$PGURL" -Atc "select 1" >/dev/null 2>&1; i=$((i+1)); done
      echo "connect+query ms (avg of 10): $(( ($(date +%s%N) - s) / 10000000 ))"
    ' 2>/dev/null
}

restart_maas_api() {
  oc rollout restart deploy/"$MAAS_DEPLOY" -n "$MAAS_NS" >/dev/null
  oc rollout status deploy/"$MAAS_DEPLOY" -n "$MAAS_NS" --timeout=180s
  sleep 5
  echo "-- maas-api log (database)"
  oc logs deploy/"$MAAS_DEPLOY" -n "$MAAS_NS" --tail=200 | grep -iE 'database|postgres|schema|error|fatal' | tail -5 || echo "(none)"
}

case "$DB_ACTION" in
  probe)
    url="${PG_URL:-$(current_url)}"
    echo "== probe $(echo "$url" | mask) =="
    db_probe "$url"
    ;;
  connect)
    if [ -z "${PG_URL:-}" ]; then
      [ -f "$STATE_FILE" ] || { echo "PG_URL not set and ${STATE_FILE} missing"; exit 1; }
      PG_URL=$(grep '^PG_URL=' "$STATE_FILE" | cut -d= -f2-)
    fi
    echo "== 1) preflight: $(echo "$PG_URL" | mask) =="
    out=$(db_probe "$PG_URL"); echo "$out"
    echo "$out" | grep -q 'SELECT 1: 1$' || { echo "preflight failed -- maas-api not changed"; exit 1; }

    echo "== 2) backup current URL =="
    if [ -f "$ORIG_FILE" ]; then echo "kept existing ${ORIG_FILE}"; else current_url > "$ORIG_FILE"; echo "saved to ${ORIG_FILE}"; fi

    echo "== 3) Secret ${DB_SECRET} + rollout restart =="
    oc set data secret/"$DB_SECRET" -n "$MAAS_NS" DB_CONNECTION_URL="$PG_URL" >/dev/null
    restart_maas_api
    echo "maas-api database: $(current_url | mask)"
    ;;
  restore)
    [ -f "$ORIG_FILE" ] || { echo "${ORIG_FILE} missing -- nothing to restore"; exit 1; }
    echo "== restore $(mask < "$ORIG_FILE") =="
    oc set data secret/"$DB_SECRET" -n "$MAAS_NS" DB_CONNECTION_URL="$(cat "$ORIG_FILE")" >/dev/null
    restart_maas_api
    rm -f "$ORIG_FILE"
    echo "maas-api database: $(current_url | mask)"
    ;;
  *) echo "DB_ACTION must be connect|restore|probe"; exit 1 ;;
esac
