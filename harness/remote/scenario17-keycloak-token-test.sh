#!/usr/bin/env bash
# Runs ON the bastion, after scenario17-keycloak-realm.sh. Standalone
# verification of Keycloak itself (no Authorino/MaaS involved yet) --
# confirms both demo users can get a token via Resource Owner Password
# Credentials, and that the token actually carries the "groups" claim
# scenario 17's OIDC Group Mapping needs downstream.
set -euo pipefail

: "${KEYCLOAK_REALM:?set KEYCLOAK_REALM}"
: "${KEYCLOAK_CLIENT_ID:?set KEYCLOAK_CLIENT_ID}"
: "${KEYCLOAK_CLIENT_SECRET:?set KEYCLOAK_CLIENT_SECRET (from harness/state/keycloak-users.env)}"
: "${KEYCLOAK_USER_BASIC:?}"; : "${KEYCLOAK_USER_BASIC_PASSWORD:?set from state file}"
: "${KEYCLOAK_USER_PREMIUM:?}"; : "${KEYCLOAK_USER_PREMIUM_PASSWORD:?set from state file}"

export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
KC="https://maas-keycloak.${CLUSTER_DOMAIN}"

decode_jwt_claims() {  # prints the payload of a JWT as JSON
  local jwt="$1" payload
  payload=$(echo "$jwt" | cut -d. -f2)
  # base64url -> base64 padding
  case $(( ${#payload} % 4 )) in 2) payload="${payload}==";; 3) payload="${payload}=";; esac
  echo "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
}

get_token() {  # get_token USERNAME PASSWORD
  curl -sk -X POST "${KC}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=${KEYCLOAK_CLIENT_ID}&client_secret=${KEYCLOAK_CLIENT_SECRET}&username=${1}&password=${2}" \
    | jq -r .access_token
}

echo "== ${KEYCLOAK_USER_BASIC} (expected group: basic) =="
T1=$(get_token "$KEYCLOAK_USER_BASIC" "$KEYCLOAK_USER_BASIC_PASSWORD")
[ -n "$T1" ] && [ "$T1" != "null" ] || { echo "FAILED to get token for ${KEYCLOAK_USER_BASIC}" >&2; exit 1; }
decode_jwt_claims "$T1" | jq '{preferred_username, groups, exp}'

echo ""
echo "== ${KEYCLOAK_USER_PREMIUM} (expected group: premium) =="
T2=$(get_token "$KEYCLOAK_USER_PREMIUM" "$KEYCLOAK_USER_PREMIUM_PASSWORD")
[ -n "$T2" ] && [ "$T2" != "null" ] || { echo "FAILED to get token for ${KEYCLOAK_USER_PREMIUM}" >&2; exit 1; }
decode_jwt_claims "$T2" | jq '{preferred_username, groups, exp}'

echo ""
echo "Keycloak issuer verified standalone. Tokens saved to /tmp/maas-basic-token, /tmp/maas-premium-token"
echo "$T1" > /tmp/maas-basic-token
echo "$T2" > /tmp/maas-premium-token
echo ""
echo "Next (not yet automated -- see docs/scenarios/17-maas-external-oidc-auth.md '리스크' section):"
echo "  wire these as a trusted external OIDC identity source in the AuthConfig/AuthPolicy the"
echo "  MaaS Gateway already uses (find it with: oc get authconfig,authpolicy -A), then re-run"
echo "  this test's step 2 by curling the MaaS endpoint directly with these tokens instead of an"
echo "  'oc whoami -t' token."
