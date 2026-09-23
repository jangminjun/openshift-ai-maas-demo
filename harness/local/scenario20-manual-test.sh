#!/usr/bin/env bash
# Run this DIRECTLY from your own laptop (no SSH/bastion needed). Verifies
# scenario 20 (docs/scenarios/20-maas-self-service-subscriptions.md)'s
# self-service Subscriptions tab via the same API the RHOAI dashboard's Gen
# AI Studio > API Keys > Subscriptions tab reads -- no browser needed to
# confirm the data itself is correct end to end.
#
# Requires: state/selfservice-user.env (run ./harness.sh
# scenario20-selfservice-user first) and an existing admin `oc login`
# session (used only to read the cluster API URL/domain). Logging in as the
# self-service user happens in an ISOLATED kubeconfig via --kubeconfig, so
# your current oc session is never touched or overwritten.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/../state/selfservice-user.env"
[ -f "$STATE_FILE" ] || { echo "Missing ${STATE_FILE} -- run ./harness.sh scenario20-selfservice-user first." >&2; exit 1; }
set -a; source "$STATE_FILE"; set +a
: "${SELF_SERVICE_USERNAME:?missing in ${STATE_FILE}}"
: "${SELF_SERVICE_PASSWORD:?missing in ${STATE_FILE}}"

API_URL="${API_URL:-$(oc whoami --show-server 2>/dev/null || true)}"
[ -n "$API_URL" ] || { echo "Couldn't determine cluster API URL -- log in as an admin first (oc login), or set API_URL." >&2; exit 1; }
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')}"
MAAS_URL="https://maas.${CLUSTER_DOMAIN}/v1/subscriptions"

TMP_KUBECONFIG=$(mktemp)
trap 'rm -f "$TMP_KUBECONFIG"' EXIT

echo "== 1) 일반 사용자(${SELF_SERVICE_USERNAME})로 로그인 (격리된 kubeconfig -- 현재 oc 세션 안 건드림) =="
oc login -u "$SELF_SERVICE_USERNAME" -p "$SELF_SERVICE_PASSWORD" "$API_URL" \
  --insecure-skip-tls-verify=true --kubeconfig="$TMP_KUBECONFIG" >/dev/null
echo "로그인 확인: $(oc whoami --kubeconfig="$TMP_KUBECONFIG") (cluster-admin 아님)"
TOKEN=$(oc whoami -t --kubeconfig="$TMP_KUBECONFIG")

echo ""
echo "== 2) GET /v1/subscriptions -- Gen AI Studio > API Keys > Subscriptions 탭이 읽는 것과 동일한 API =="
curl -sk "$MAAS_URL" -H "Authorization: Bearer ${TOKEN}" -w "\nHTTP %{http_code}\n"
echo "(빈 배열 []이면 이 사용자가 아직 어떤 MaaS 그룹에도 없는 것 -- SELF_SERVICE_GROUP으로"
echo " ./harness.sh scenario20-selfservice-user 재실행해서 그룹에 넣을 것)"
