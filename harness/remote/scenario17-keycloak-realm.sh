#!/usr/bin/env bash
# Runs ON the bastion, after scenario17-keycloak-up.sh (Keycloak must be
# Ready). Creates the demo realm, two groups (basic/premium -- these are
# what MaaS's OIDC Group Mapping is supposed to key off in scenario 17),
# two users in those groups, and an OIDC client with a "groups" claim
# mapper so the group membership actually shows up in the issued token.
# Idempotent -- every step checks before creating. Prints (and saves to
# ../state/keycloak-users.env, gitignored) the generated user passwords and
# client secret -- these never go in git or in AGENT.md's committed history.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

: "${KEYCLOAK_NAMESPACE:?set KEYCLOAK_NAMESPACE}"
: "${KEYCLOAK_REALM:?set KEYCLOAK_REALM}"
: "${KEYCLOAK_CLIENT_ID:?set KEYCLOAK_CLIENT_ID}"
: "${KEYCLOAK_GROUP_BASIC:?set KEYCLOAK_GROUP_BASIC}"
: "${KEYCLOAK_GROUP_PREMIUM:?set KEYCLOAK_GROUP_PREMIUM}"
: "${KEYCLOAK_USER_BASIC:?set KEYCLOAK_USER_BASIC}"
: "${KEYCLOAK_USER_PREMIUM:?set KEYCLOAK_USER_PREMIUM}"

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
KC="https://maas-keycloak.${CLUSTER_DOMAIN}"

ADMIN_USER=$(oc get secret maas-keycloak-initial-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(oc get secret maas-keycloak-initial-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

TOKEN=$(curl -sk -X POST "${KC}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=${ADMIN_USER}&password=${ADMIN_PASS}" \
  | jq -r .access_token)
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "Failed to get Keycloak admin token" >&2; exit 1; }

kc_api() {  # kc_api METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sk -X "$method" "${KC}/admin/realms${path}" -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/json' -d "$body" -w '\n%{http_code}'
  else
    curl -sk -X "$method" "${KC}/admin/realms${path}" -H "Authorization: Bearer ${TOKEN}" -w '\n%{http_code}'
  fi
}

echo "== Realm: ${KEYCLOAK_REALM} =="
if curl -sk -o /dev/null -w '%{http_code}' "${KC}/admin/realms/${KEYCLOAK_REALM}" -H "Authorization: Bearer ${TOKEN}" | grep -q 200; then
  echo "Realm already exists."
else
  kc_api POST "" "{\"realm\":\"${KEYCLOAK_REALM}\",\"enabled\":true}" >/dev/null
fi

echo "== Client: ${KEYCLOAK_CLIENT_ID} =="
CLIENT_UUID=$(curl -sk "${KC}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_CLIENT_ID}" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id // empty')
if [ -n "$CLIENT_UUID" ]; then
  echo "Client already exists (id=${CLIENT_UUID})."
else
  kc_api POST "/${KEYCLOAK_REALM}/clients" "{
    \"clientId\": \"${KEYCLOAK_CLIENT_ID}\",
    \"enabled\": true,
    \"publicClient\": false,
    \"directAccessGrantsEnabled\": true,
    \"serviceAccountsEnabled\": true,
    \"standardFlowEnabled\": false,
    \"protocol\": \"openid-connect\"
  }" >/dev/null
  CLIENT_UUID=$(curl -sk "${KC}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_CLIENT_ID}" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id')

  # "groups" claim mapper -- without this, group membership never shows up
  # in the access token, and scenario 17's whole point (OIDC Group Mapping)
  # can't be verified downstream.
  kc_api POST "/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" '{
    "name": "groups",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "config": {
      "full.path": "false",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "claim.name": "groups",
      "userinfo.token.claim": "true"
    }
  }' >/dev/null
fi

CLIENT_SECRET=$(curl -sk "${KC}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r .value)

echo "== Groups: ${KEYCLOAK_GROUP_BASIC}, ${KEYCLOAK_GROUP_PREMIUM} =="
declare -A GROUP_ID
for g in "$KEYCLOAK_GROUP_BASIC" "$KEYCLOAK_GROUP_PREMIUM"; do
  gid=$(curl -sk "${KC}/admin/realms/${KEYCLOAK_REALM}/groups?search=${g}" -H "Authorization: Bearer ${TOKEN}" | jq -r ".[] | select(.name==\"${g}\") | .id")
  if [ -z "$gid" ]; then
    kc_api POST "/${KEYCLOAK_REALM}/groups" "{\"name\":\"${g}\"}" >/dev/null
    gid=$(curl -sk "${KC}/admin/realms/${KEYCLOAK_REALM}/groups?search=${g}" -H "Authorization: Bearer ${TOKEN}" | jq -r ".[] | select(.name==\"${g}\") | .id")
  fi
  GROUP_ID[$g]="$gid"
done

STATE_FILE_LOCAL="keycloak-users.env"  # written on the bastion; harness.sh scp's it back
: > "/tmp/${STATE_FILE_LOCAL}"
echo "KEYCLOAK_CLIENT_SECRET=${CLIENT_SECRET}" >> "/tmp/${STATE_FILE_LOCAL}"

echo "== Users =="
create_user() {  # create_user USERNAME GROUP_NAME STATE_VAR_SUFFIX (e.g. BASIC, PREMIUM --
                 # kept separate from USERNAME so the state file's var names stay stable even
                 # if KEYCLOAK_USER_BASIC/PREMIUM are overridden to something else)
  local user="$1" group="$2" suffix="$3" pass
  uid=$(curl -sk "${KC}/admin/realms/${KEYCLOAK_REALM}/users?username=${user}&exact=true" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id // empty')
  if [ -z "$uid" ]; then
    pass=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)
    # firstName/lastName are required here, not just cosmetic: RHBK's declarative
    # User Profile marks an account "not fully set up" (direct-grant login refused
    # with a generic invalid_grant) if they're missing -- found the hard way.
    kc_api POST "/${KEYCLOAK_REALM}/users" "{
      \"username\": \"${user}\",
      \"enabled\": true,
      \"emailVerified\": true,
      \"email\": \"${user}@maas-demo.local\",
      \"firstName\": \"${suffix}\",
      \"lastName\": \"User\",
      \"credentials\": [{\"type\":\"password\",\"value\":\"${pass}\",\"temporary\":false}]
    }" >/dev/null
    uid=$(curl -sk "${KC}/admin/realms/${KEYCLOAK_REALM}/users?username=${user}&exact=true" \
      -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id')
    echo "KEYCLOAK_USER_${suffix}_PASSWORD=${pass}" >> "/tmp/${STATE_FILE_LOCAL}"
  else
    echo "User ${user} already exists (password not re-generated -- see state/keycloak-users.env from a prior run)."
  fi
  curl -sk -X PUT "${KC}/admin/realms/${KEYCLOAK_REALM}/users/${uid}/groups/${GROUP_ID[$group]}" \
    -H "Authorization: Bearer ${TOKEN}" -o /dev/null
}
create_user "$KEYCLOAK_USER_BASIC" "$KEYCLOAK_GROUP_BASIC" "BASIC"
create_user "$KEYCLOAK_USER_PREMIUM" "$KEYCLOAK_GROUP_PREMIUM" "PREMIUM"

echo ""
echo "Realm setup complete: ${KC}/realms/${KEYCLOAK_REALM}"
echo "Discovery: ${KC}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration"
echo "Credentials written to /tmp/${STATE_FILE_LOCAL} on the bastion (harness.sh will pull this back to harness/state/)."
cat "/tmp/${STATE_FILE_LOCAL}"
