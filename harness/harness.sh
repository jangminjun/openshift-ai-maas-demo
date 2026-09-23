#!/usr/bin/env bash
# MaaS 3.5-GA-features harness for this repo (openshift-ai-maas-demo).
# Assumes the base cluster + RHOAI 3.5 + MaaS gateway already exist --
# built via openshift-aws-harness (base cluster) and
# monitoring-llmd-rhoai/harness (`./harness.sh maas`, RHCL/Kuadrant +
# modelsAsService). This harness only adds what scenarios 17-20
# (docs/scenarios/17-20*.md) need on top of that.
#
# Usage: ./harness.sh <subcommand> [args]
#   scenario17-keycloak-up            RHBK operator + Postgres + Keycloak instance + Route
#   scenario17-keycloak-realm         realm + basic/premium groups + 2 users + OIDC client (pulls secrets to state/keycloak-users.env)
#   scenario17-keycloak-token-test    standalone Keycloak check: both users get a token with a "groups" claim
#   scenario17-wire-authpolicy        add Keycloak as a JWT identity source on the MaaS AuthPolicy (idempotent, re-run if it disappears)
#   scenario17-authorino-trust-ca     make Authorino trust the router CA (Keycloak) + service-serving-signer CA (maas-api mTLS) -- idempotent, re-run after any cluster rebuild
#   scenario17-register-model         MaaSModelRef + per-group MaaSSubscription + MaaSAuthPolicy for a deployed model
#   scenario18-openai-routing-test    fixed-endpoint /v1/chat/completions, model switched via body only
#   scenario19-governance-snapshot    dump Authorino/Kuadrant/DSC CRs relevant to the Governance page, for before/after diffing
#   scenario20-selfservice-user       add a non-admin htpasswd user for testing the self-service Subscriptions tab
#
# Config: harness/config.env (bastion IP, SSH key, cluster name). Cluster
# access details also documented in ../AGENT.md.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HARNESS_DIR"
source ./config.env
source ./lib.sh

cmd="${1:-}"
[ -n "$cmd" ] && shift || true

cmd_scenario17_keycloak_up() {
  ssh_bastion "KEYCLOAK_NAMESPACE='${KEYCLOAK_NAMESPACE}' bash -s" < ./remote/scenario17-keycloak-up.sh
}

cmd_scenario17_keycloak_realm() {
  ssh_bastion "KEYCLOAK_NAMESPACE='${KEYCLOAK_NAMESPACE}' KEYCLOAK_REALM='${KEYCLOAK_REALM}' \
    KEYCLOAK_CLIENT_ID='${KEYCLOAK_CLIENT_ID}' KEYCLOAK_GROUP_BASIC='${KEYCLOAK_GROUP_BASIC}' \
    KEYCLOAK_GROUP_PREMIUM='${KEYCLOAK_GROUP_PREMIUM}' KEYCLOAK_USER_BASIC='${KEYCLOAK_USER_BASIC}' \
    KEYCLOAK_USER_PREMIUM='${KEYCLOAK_USER_PREMIUM}' bash -s" < ./remote/scenario17-keycloak-realm.sh
  mkdir -p ./state
  ssh_bastion "cat /tmp/keycloak-users.env" > ./state/keycloak-users.env
  log "Pulled secrets to state/keycloak-users.env (gitignored -- never commit this)."
}

cmd_scenario17_keycloak_token_test() {
  [ -f ./state/keycloak-users.env ] || err "Run scenario17-keycloak-realm first (no state/keycloak-users.env)."
  set -a; source ./state/keycloak-users.env; set +a
  ssh_bastion "KEYCLOAK_REALM='${KEYCLOAK_REALM}' KEYCLOAK_CLIENT_ID='${KEYCLOAK_CLIENT_ID}' \
    KEYCLOAK_CLIENT_SECRET='${KEYCLOAK_CLIENT_SECRET:?}' \
    KEYCLOAK_USER_BASIC='${KEYCLOAK_USER_BASIC}' KEYCLOAK_USER_BASIC_PASSWORD='${KEYCLOAK_USER_BASIC_PASSWORD:?}' \
    KEYCLOAK_USER_PREMIUM='${KEYCLOAK_USER_PREMIUM}' KEYCLOAK_USER_PREMIUM_PASSWORD='${KEYCLOAK_USER_PREMIUM_PASSWORD:?}' \
    bash -s" < ./remote/scenario17-keycloak-token-test.sh
}

cmd_scenario17_wire_authpolicy() {
  ssh_bastion "KEYCLOAK_NAMESPACE='${KEYCLOAK_NAMESPACE}' KEYCLOAK_REALM='${KEYCLOAK_REALM}' \
    bash -s" < ./remote/scenario17-wire-authpolicy.sh
}

cmd_scenario17_authorino_trust_ca() {
  ssh_bastion "bash -s" < ./remote/scenario17-authorino-trust-ca.sh
}

cmd_scenario17_register_model() {
  ssh_bastion "MODEL_NAMESPACE='${MODEL_NAMESPACE:?set MODEL_NAMESPACE}' MODEL_NAME='${MODEL_NAME:?set MODEL_NAME}' \
    MODEL_GROUP_LIMITS='${MODEL_GROUP_LIMITS:?set MODEL_GROUP_LIMITS, e.g. maas-basic:100,maas-premium:100000}' \
    TOKEN_WINDOW='${TOKEN_WINDOW:-1h}' TENANT_NAMESPACE='${TENANT_NAMESPACE:-models-as-a-service}' \
    bash -s" < ./remote/scenario17-register-model.sh
}

cmd_scenario18_openai_routing_test() {
  ssh_bastion "MAAS_TEST_MODEL='${MAAS_TEST_MODEL:?set MAAS_TEST_MODEL}' MAAS_TEST_MODEL_B='${MAAS_TEST_MODEL_B:-}' \
    MAAS_API_KEY='${MAAS_API_KEY:-}' bash -s" < ./remote/scenario18-openai-routing-test.sh
}

cmd_scenario19_governance_snapshot() {
  mkdir -p ./state
  local out="./state/governance-snapshot-$(date -u +%Y%m%dT%H%M%SZ).yaml"
  ssh_bastion 'bash -s' < ./remote/scenario19-governance-snapshot.sh > "$out"
  log "Snapshot written to ${out}"
}

cmd_scenario20_selfservice_user() {
  [ -n "${SELF_SERVICE_PASSWORD:-}" ] || { SELF_SERVICE_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20); \
    save_state selfservice-user.env SELF_SERVICE_USERNAME "$SELF_SERVICE_USERNAME"; \
    save_state selfservice-user.env SELF_SERVICE_PASSWORD "$SELF_SERVICE_PASSWORD"; \
    log "Generated password, saved to state/selfservice-user.env (gitignored)."; }
  ssh_bastion "SELF_SERVICE_USERNAME='${SELF_SERVICE_USERNAME}' SELF_SERVICE_PASSWORD='${SELF_SERVICE_PASSWORD}' \
    bash -s" < ./remote/scenario20-selfservice-user.sh
}

case "$cmd" in
  scenario17-keycloak-up)          cmd_scenario17_keycloak_up ;;
  scenario17-keycloak-realm)       cmd_scenario17_keycloak_realm ;;
  scenario17-keycloak-token-test)  cmd_scenario17_keycloak_token_test ;;
  scenario17-wire-authpolicy)      cmd_scenario17_wire_authpolicy ;;
  scenario17-authorino-trust-ca)   cmd_scenario17_authorino_trust_ca ;;
  scenario17-register-model)       cmd_scenario17_register_model ;;
  scenario18-openai-routing-test)  cmd_scenario18_openai_routing_test ;;
  scenario19-governance-snapshot)  cmd_scenario19_governance_snapshot ;;
  scenario20-selfservice-user)     cmd_scenario20_selfservice_user ;;
  *)
    err "Unknown subcommand '$cmd'. See header comment in ./harness.sh for the list."
    ;;
esac
