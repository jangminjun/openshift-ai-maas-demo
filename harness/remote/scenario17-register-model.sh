#!/usr/bin/env bash
# Runs ON the bastion, after a model (LLMInferenceService) is already Ready
# (see monitoring-llmd-rhoai's llmd-deploy-model) and after scenario17-wire-authpolicy.sh.
# Registers that model with MaaS's governance layer so it shows up in
# /v1/models and (once the maas-api mTLS issue below is fixed) is actually
# callable: creates a MaaSModelRef, one MaaSSubscription per group (with its
# own token-rate-limit), and one MaaSAuthPolicy granting those groups access.
# Idempotent -- every step checks before creating.
#
# KNOWN GAP (2026-09-22, not yet fixed): even after this script, an actual
# chat-completion call returns 403 -- Authorino's own outbound mTLS call to
# maas-api (made internally during the AuthPolicy's subscription-info
# metadata phase) is rejected by maas-api ("remote error: tls: bad
# certificate"). This is unrelated to Keycloak/group config -- confirmed by
# matching the failing connection's source IP to the Authorino pod's IP
# exactly. /v1/models still works fine (that path doesn't need this mTLS
# call). See docs/scenarios/17-maas-external-oidc-auth.md section 8 for the
# full trace; fixing it is a prerequisite for this script's registration to
# actually let calls through end to end.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

: "${MODEL_NAMESPACE:?set MODEL_NAMESPACE}"
: "${MODEL_NAME:?set MODEL_NAME}"
# Comma-separated "group:limit" pairs, e.g. "maas-basic:100,maas-premium:100000"
# (tokens per TOKEN_WINDOW). Groups must already exist in the external IDP's
# token "groups" claim (see scenario17-keycloak-realm.sh).
: "${MODEL_GROUP_LIMITS:?set MODEL_GROUP_LIMITS, e.g. maas-basic:100,maas-premium:100000}"
TOKEN_WINDOW="${TOKEN_WINDOW:-1h}"
# Namespace of MaaS's default (already-bootstrapped) tenant -- Subscriptions/
# AuthPolicies must live in a namespace enabled for MaaS tenant resources;
# reusing the pre-existing default tenant avoids having to bootstrap a new
# one (which needs a MasTenantConfig named literally "default-tenant" and,
# per this run, didn't auto-provision cleanly for an ad-hoc namespace).
TENANT_NAMESPACE="${TENANT_NAMESPACE:-models-as-a-service}"

echo "== MaaSModelRef: ${MODEL_NAMESPACE}/${MODEL_NAME} =="
oc get maasmodelref "$MODEL_NAME" -n "$MODEL_NAMESPACE" &>/dev/null || oc apply -f - <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: ${MODEL_NAME}
  namespace: ${MODEL_NAMESPACE}
spec:
  modelRef:
    kind: LLMInferenceService
    name: ${MODEL_NAME}
YAML

echo "== MaaSSubscriptions (one per group) =="
IFS=',' read -ra PAIRS <<< "$MODEL_GROUP_LIMITS"
GROUP_NAMES=()
for pair in "${PAIRS[@]}"; do
  group="${pair%%:*}"; limit="${pair##*:}"
  GROUP_NAMES+=("$group")
  sub_name="${group}-sub"
  if oc get maassubscription "$sub_name" -n "$TENANT_NAMESPACE" &>/dev/null; then
    echo "Subscription $sub_name already exists."
  else
    oc apply -f - <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: ${sub_name}
  namespace: ${TENANT_NAMESPACE}
spec:
  owner:
    groups: [{name: ${group}}]
  modelRefs:
    - name: ${MODEL_NAME}
      namespace: ${MODEL_NAMESPACE}
      tokenRateLimits: [{limit: ${limit}, window: ${TOKEN_WINDOW}}]
      billingRate: {perToken: "0"}
YAML
  fi
done

echo "== MaaSAuthPolicy (grants the same groups access) =="
AUTHPOLICY_NAME="${MODEL_NAME}-access"
if oc get maasauthpolicy "$AUTHPOLICY_NAME" -n "$TENANT_NAMESPACE" &>/dev/null; then
  echo "MaaSAuthPolicy $AUTHPOLICY_NAME already exists."
else
  groups_yaml=""
  for g in "${GROUP_NAMES[@]}"; do groups_yaml="${groups_yaml}      - {name: ${g}}
"; done
  oc apply -f - <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: ${AUTHPOLICY_NAME}
  namespace: ${TENANT_NAMESPACE}
spec:
  modelRefs:
    - {name: ${MODEL_NAME}, namespace: ${MODEL_NAMESPACE}}
  subjects:
    groups:
${groups_yaml}
YAML
fi

echo "Waiting for governance pairing (up to 30s)..."
for _ in $(seq 1 6); do
  status=$(oc get maasmodelref "$MODEL_NAME" -n "$MODEL_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="GovernanceAttached")].status}' 2>/dev/null || true)
  [ "$status" = "True" ] && break
  sleep 5
done
oc get maasmodelref "$MODEL_NAME" -n "$MODEL_NAMESPACE" \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.message}{"\n"}{end}'
