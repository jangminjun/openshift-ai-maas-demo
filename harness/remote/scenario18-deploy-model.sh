#!/usr/bin/env bash
# Deploys a GPU-backed LLMInferenceService (any HuggingFace model) and waits
# for it to be Ready -- used to stand up a SECOND (third, ...) model so
# scenario 18's body-based routing can be verified against two genuinely
# different backends instead of just one. Requires a free GPU (see
# scenario17-scale-gpu.sh). Idempotent. Deliberately does NOT also run
# scenario17-register-model.sh itself -- these remote/*.sh scripts are piped
# over SSH stdin (no on-disk path to chain to a sibling file from); harness.sh's
# cmd_scenario18_deploy_model calls both in sequence instead.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

: "${MODEL_NAMESPACE:?set MODEL_NAMESPACE, e.g. maas-demo}"
: "${MODEL_NAME:?set MODEL_NAME -- this becomes the LLMInferenceService/MaaSModelRef name, e.g. maas-demo-model-deepseek}"
: "${MODEL_URI:?set MODEL_URI, e.g. hf://deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$(basename "$MODEL_URI")}"
GATEWAY_NAME="${GATEWAY_NAME:-maas-default-gateway}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"
GPU_NODE_INSTANCE_TYPE="${GPU_NODE_INSTANCE_TYPE:-g4dn.xlarge}"
VLLM_ADDITIONAL_ARGS="${VLLM_ADDITIONAL_ARGS:---max-model-len=8192 --enforce-eager --gpu-memory-utilization=0.85}"

echo "== LLMInferenceService: ${MODEL_NAMESPACE}/${MODEL_NAME} (${SERVED_MODEL_NAME}) =="
oc apply -f - <<YAML
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: ${MODEL_NAME}
  namespace: ${MODEL_NAMESPACE}
  labels:
    opendatahub.io/dashboard: "true"
spec:
  model:
    name: ${SERVED_MODEL_NAME}
    uri: ${MODEL_URI}
  replicas: 1
  router:
    gateway:
      refs:
      - name: ${GATEWAY_NAME}
        namespace: ${GATEWAY_NAMESPACE}
    route: {}
  template:
    containers:
    - name: main
      env:
      - name: VLLM_ADDITIONAL_ARGS
        value: "${VLLM_ADDITIONAL_ARGS}"
      resources:
        limits:
          cpu: "2"
          memory: 8Gi
          nvidia.com/gpu: "1"
        requests:
          cpu: "2"
          memory: 8Gi
          nvidia.com/gpu: "1"
    nodeSelector:
      node.kubernetes.io/instance-type: ${GPU_NODE_INSTANCE_TYPE}
    tolerations:
    - effect: NoSchedule
      key: nvidia.com/gpu
      operator: Exists
YAML

echo "Waiting for the model pod to be Ready (up to ~6 min -- image pull + HF download)..."
for i in $(seq 1 36); do
  ready=$(oc get llminferenceservice "$MODEL_NAME" -n "$MODEL_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  echo "  [$i/36] Ready=${ready:-<none>}"
  [ "$ready" = "True" ] && break
  sleep 10
done
if [ "$ready" != "True" ]; then
  echo "Not Ready yet -- check: oc describe llminferenceservice ${MODEL_NAME} -n ${MODEL_NAMESPACE}" >&2
  exit 1
fi

echo ""
echo "Model Ready. Catalog id will be: publishers/${MODEL_NAMESPACE}/models/${SERVED_MODEL_NAME}"
echo "Next: ./harness.sh scenario17-register-model (MODEL_NAMESPACE=${MODEL_NAMESPACE} MODEL_NAME=${MODEL_NAME} ...)"
echo "-- done automatically if you called this via './harness.sh scenario18-deploy-model'."
