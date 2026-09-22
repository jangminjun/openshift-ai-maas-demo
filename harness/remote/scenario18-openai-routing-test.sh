#!/usr/bin/env bash
# Runs ON the bastion. Scenario 18 (OpenAI-compatible body-based model
# routing) -- automated version of the before/after comparison in
# docs/scenarios/18-maas-openai-body-routing.md. Uses curl (not the openai
# pip package, to avoid a dependency install on the bastion) against the
# fixed /v1/chat/completions endpoint, switching only the "model" field in
# the JSON body between calls -- exactly what the OpenAI SDK does under
# the hood.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

: "${MAAS_TEST_MODEL:?set MAAS_TEST_MODEL to a model name/alias registered with MaaS}"
MAAS_TEST_MODEL_B="${MAAS_TEST_MODEL_B:-}"  # optional second model, to prove routing actually differs

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MAAS_URL="https://maas.${CLUSTER_DOMAIN}/v1/chat/completions"

# Falls back to the caller's own oc token -- swap for a real Gen AI Studio
# MaaS API key (scenario 20 surfaces where to find one) once available.
TOKEN="${MAAS_API_KEY:-$(oc whoami -t)}"

call_model() {  # call_model MODEL_NAME
  curl -sk -X POST "$MAAS_URL" \
    -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"model\":\"${1}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping from ${1}\"}]}" \
    -w '\nHTTP %{http_code}\n'
}

echo "== Fixed endpoint: ${MAAS_URL} (never changes below) =="

echo ""
echo "== Call 1: model=${MAAS_TEST_MODEL} =="
call_model "$MAAS_TEST_MODEL"

if [ -n "$MAAS_TEST_MODEL_B" ]; then
  echo ""
  echo "== Call 2: model=${MAAS_TEST_MODEL_B} (same URL, only the body changed) =="
  call_model "$MAAS_TEST_MODEL_B"
fi

echo ""
echo "== Negative test: nonexistent model name should fail clearly, not silently fall back =="
call_model "definitely-not-a-registered-model-$(date +%s)"
