#!/usr/bin/env bash
# Self-contained MaaS harness for this repo (openshift-ai-maas-demo).
# Assumes only the base cluster + RHOAI 3.5 operator/DataScienceCluster
# already exist (openshift-aws-harness -> harness.sh rhoai) -- everything
# MaaS-specific (RHCL/Kuadrant, the gateways, Postgres, Keycloak, scenarios
# 17-20) is provisioned by this harness alone; it does not depend on any
# other application-level repo.
#
# Usage: ./harness.sh <subcommand> [args]
#   maas-up                           RHCL(Kuadrant)+Authorino+Gateways+Postgres+dashboard flags -- run this first
#   scenario17-keycloak-up            RHBK operator + Postgres + Keycloak instance + Route
#   scenario17-keycloak-realm         realm + basic/premium groups + 2 users + OIDC client (pulls secrets to state/keycloak-users.env)
#   scenario17-keycloak-token-test    standalone Keycloak check: both users get a token with a "groups" claim
#   scenario17-wire-authpolicy        add Keycloak as a JWT identity source on the MaaS AuthPolicy (idempotent, re-run if it disappears)
#   scenario17-authorino-trust-ca     make Authorino trust the router CA (Keycloak) + service-serving-signer CA (maas-api mTLS) -- idempotent, re-run after any cluster rebuild
#   scenario17-register-model         MaaSModelRef + per-group MaaSSubscription + MaaSAuthPolicy for a deployed model (safe to re-run for a 2nd/3rd model -- appends to existing subscriptions)
#   scenario17-scale-gpu              scale the GPU MachineSet (e.g. GPU_REPLICAS=2 to add a 2nd GPU node for a 2nd model) -- re-check AWS quota first, don't trust old notes
#   scenario18-deploy-model           deploy a GPU-backed LLMInferenceService (any model/namespace) + register it with MaaS in one step
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

cmd_maas_up() {
  ssh_bastion "bash -s" < ./remote/maas-up.sh
}

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
  # A new MaaSAuthPolicy above triggers maas-controller to regenerate the
  # gateway AuthPolicy, wiping the Keycloak identity source patch -- restore it.
  cmd_scenario17_wire_authpolicy
}

cmd_scenario17_scale_gpu() {
  ssh_bastion "GPU_REPLICAS='${GPU_REPLICAS:?set GPU_REPLICAS}' GPU_MACHINESET_NAME='${GPU_MACHINESET_NAME:-}' \
    bash -s" < ./remote/scenario17-scale-gpu.sh
}

cmd_scenario18_deploy_model() {
  : "${MODEL_NAMESPACE:?set MODEL_NAMESPACE}"; : "${MODEL_NAME:?set MODEL_NAME}"; : "${MODEL_URI:?set MODEL_URI}"
  ssh_bastion "MODEL_NAMESPACE='${MODEL_NAMESPACE}' MODEL_NAME='${MODEL_NAME}' \
    MODEL_URI='${MODEL_URI}' SERVED_MODEL_NAME='${SERVED_MODEL_NAME:-}' \
    GATEWAY_NAME='${GATEWAY_NAME:-maas-default-gateway}' GATEWAY_NAMESPACE='${GATEWAY_NAMESPACE:-openshift-ingress}' \
    GPU_NODE_INSTANCE_TYPE='${GPU_NODE_INSTANCE_TYPE:-g4dn.xlarge}' VLLM_ADDITIONAL_ARGS='${VLLM_ADDITIONAL_ARGS:-}' \
    bash -s" < ./remote/scenario18-deploy-model.sh
  MODEL_GROUP_LIMITS="${MODEL_GROUP_LIMITS:-maas-basic:500,maas-premium:100000}" cmd_scenario17_register_model
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
  maas-up)                         cmd_maas_up ;;
  scenario17-keycloak-up)          cmd_scenario17_keycloak_up ;;
  scenario17-keycloak-realm)       cmd_scenario17_keycloak_realm ;;
  scenario17-keycloak-token-test)  cmd_scenario17_keycloak_token_test ;;
  scenario17-wire-authpolicy)      cmd_scenario17_wire_authpolicy ;;
  scenario17-authorino-trust-ca)   cmd_scenario17_authorino_trust_ca ;;
  scenario17-register-model)       cmd_scenario17_register_model ;;
  scenario17-scale-gpu)            cmd_scenario17_scale_gpu ;;
  scenario18-deploy-model)         cmd_scenario18_deploy_model ;;
  scenario18-openai-routing-test)  cmd_scenario18_openai_routing_test ;;
  scenario19-governance-snapshot)  cmd_scenario19_governance_snapshot ;;
  scenario20-selfservice-user)     cmd_scenario20_selfservice_user ;;
  *)
    err "Unknown subcommand '$cmd'. See header comment in ./harness.sh for the list."
    ;;
esac
