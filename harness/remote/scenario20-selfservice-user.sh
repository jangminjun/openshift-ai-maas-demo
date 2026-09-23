#!/usr/bin/env bash
# Creates a plain (non-admin) htpasswd user for testing scenario 20's
# self-service Subscriptions tab, AND puts them in an OpenShift Group so
# their identity resolves to a MaaS subscription via the AuthPolicy's
# "openshift-identities" (kubernetesTokenReview) path -- that path reads
# auth.identity.user.groups, which comes from real Kubernetes Group
# membership, not the Keycloak "groups" JWT claim scenario 17 uses.
# No bastion-side file needed -- manipulates the htpass-secret Secret
# directly, so this runs the same locally or on the bastion. Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

SELF_SERVICE_USERNAME="${SELF_SERVICE_USERNAME:?set SELF_SERVICE_USERNAME}"
SELF_SERVICE_PASSWORD="${SELF_SERVICE_PASSWORD:?set SELF_SERVICE_PASSWORD}"
SELF_SERVICE_GROUP="${SELF_SERVICE_GROUP:-maas-basic}"

echo "== htpasswd IDP: add user '${SELF_SERVICE_USERNAME}' =="
oc get secret htpass-secret -n openshift-config &>/dev/null || {
  echo "No htpass-secret in openshift-config -- set up the htpasswd IDP first (create-admin-user in openshift-aws-harness)." >&2
  exit 1
}

TMP_HTPASSWD=$(mktemp)
trap 'rm -f "$TMP_HTPASSWD"' EXIT
oc get secret htpass-secret -n openshift-config -o jsonpath='{.data.htpasswd}' | base64 -d > "$TMP_HTPASSWD"

# APR1 (Apache MD5) hash -- htpasswd-format files accept this alongside
# bcrypt (the existing admin entry uses bcrypt; both are valid in the same
# file). Avoids depending on the `htpasswd` CLI (httpd-tools), which isn't
# available on every machine this harness runs from.
HASH=$(openssl passwd -apr1 "$SELF_SERVICE_PASSWORD")
if grep -q "^${SELF_SERVICE_USERNAME}:" "$TMP_HTPASSWD"; then
  sed -i "s#^${SELF_SERVICE_USERNAME}:.*#${SELF_SERVICE_USERNAME}:${HASH}#" "$TMP_HTPASSWD"
  echo "Updated existing entry for ${SELF_SERVICE_USERNAME}."
else
  echo "${SELF_SERVICE_USERNAME}:${HASH}" >> "$TMP_HTPASSWD"
  echo "Added new entry for ${SELF_SERVICE_USERNAME}."
fi

oc create secret generic htpass-secret --from-file=htpasswd="$TMP_HTPASSWD" \
  -n openshift-config --dry-run=client -o yaml | oc apply -f -

echo "Waiting for oauth-openshift pods to roll out with the updated identity provider..."
oc rollout status deploy/oauth-openshift -n openshift-authentication --timeout=120s 2>&1 || true

echo "== OpenShift Group: ${SELF_SERVICE_GROUP} =="
# Deliberately no cluster-role grant -- this account should only have
# whatever a self-service dashboard user gets by default. Group membership
# alone is what MaaS's group-based subscription matching needs.
oc get group "$SELF_SERVICE_GROUP" &>/dev/null || oc adm groups new "$SELF_SERVICE_GROUP"
current_members=$(oc get group "$SELF_SERVICE_GROUP" -o jsonpath='{.users}' 2>/dev/null || echo "")
if echo "$current_members" | grep -q "$SELF_SERVICE_USERNAME"; then
  echo "${SELF_SERVICE_USERNAME} already in group ${SELF_SERVICE_GROUP}."
else
  oc adm groups add-users "$SELF_SERVICE_GROUP" "$SELF_SERVICE_USERNAME"
fi

echo ""
echo "Non-admin user '${SELF_SERVICE_USERNAME}' ready, in group '${SELF_SERVICE_GROUP}'."
echo "Log into the RHOAI dashboard as this user to test scenario 20's Subscriptions tab,"
echo "or run local/scenario20-manual-test.sh to check the same data via the API."
