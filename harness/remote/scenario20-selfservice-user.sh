#!/usr/bin/env bash
# Runs ON the bastion. Scenario 20 (self-service MaaS Subscriptions tab)
# needs an ordinary (non-admin) dashboard login -- create-admin-user only
# ever makes one cluster-admin account. Adds a plain user to the same
# htpasswd IDP that create-admin-user already set up, with no elevated
# RBAC, so logging in as them exercises exactly what a real self-service
# user would see.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

SELF_SERVICE_USERNAME="${SELF_SERVICE_USERNAME:?set SELF_SERVICE_USERNAME}"
SELF_SERVICE_PASSWORD="${SELF_SERVICE_PASSWORD:?set SELF_SERVICE_PASSWORD}"

HTPASSWD_FILE="$HOME/ocp-install/users.htpasswd"
[ -f "$HTPASSWD_FILE" ] || { echo "No ${HTPASSWD_FILE} -- run create-admin-user (openshift-aws-harness) first." >&2; exit 1; }
command -v htpasswd >/dev/null 2>&1 || sudo dnf install -y httpd-tools >/tmp/dnf-htpasswd.log 2>&1

htpasswd -B -b "$HTPASSWD_FILE" "$SELF_SERVICE_USERNAME" "$SELF_SERVICE_PASSWORD"

oc create secret generic htpass-secret --from-file=htpasswd="$HTPASSWD_FILE" \
  -n openshift-config --dry-run=client -o yaml | oc apply -f -

echo "Waiting for the oauth-openshift pods to roll out with the updated identity provider..."
for _ in $(seq 1 30); do
  oc get pods -n openshift-authentication 2>/dev/null | grep -q Running && break
  sleep 10
done

# Deliberately no cluster-role grant -- this account should only have
# whatever a self-service dashboard user gets by default.
echo "Non-admin user '${SELF_SERVICE_USERNAME}' ready (no cluster-admin, no extra RBAC)."
echo "Log into the RHOAI dashboard as this user to test scenario 20's Subscriptions tab."
