#!/usr/bin/env bash
# Scales the cluster's GPU MachineSet up/down (e.g. to add a second GPU node
# for a second model -- see docs/scenarios/18-maas-openai-body-routing.md).
# Finds the MachineSet by name containing "-gpu-" (this install's naming
# convention: <infra-id>-gpu-<instance-type>-<zone>) since there's no
# dedicated label distinguishing it from worker MachineSets. Before scaling
# up, re-check the actual AWS quota (see lessonlearn.md 2026-09-23 -- an
# earlier note saying "quota=4, can't add a second GPU node" was true for a
# since-rotated sandbox account, not necessarily this one).
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

: "${GPU_REPLICAS:?set GPU_REPLICAS, e.g. GPU_REPLICAS=2 ./harness.sh scenario17-scale-gpu}"

mapfile -t GPU_MACHINESETS < <(oc get machineset -n openshift-machine-api \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -- '-gpu-' || true)

if [ ${#GPU_MACHINESETS[@]} -eq 0 ]; then
  echo "No GPU MachineSet found (looked for '-gpu-' in the name). List them yourself:" >&2
  oc get machineset -n openshift-machine-api >&2
  exit 1
fi

MS="${GPU_MACHINESET_NAME:-${GPU_MACHINESETS[0]}}"
if [ ${#GPU_MACHINESETS[@]} -gt 1 ] && [ -z "${GPU_MACHINESET_NAME:-}" ]; then
  echo "Multiple GPU MachineSets found: ${GPU_MACHINESETS[*]}" >&2
  echo "Defaulting to '${MS}' -- set GPU_MACHINESET_NAME to pick a different one." >&2
fi

current=$(oc get machineset "$MS" -n openshift-machine-api -o jsonpath='{.spec.replicas}')
echo "Scaling MachineSet ${MS}: ${current} -> ${GPU_REPLICAS} replicas"
oc scale machineset "$MS" -n openshift-machine-api --replicas="$GPU_REPLICAS"

if [ "$GPU_REPLICAS" -le "$current" ]; then
  echo "Scaling down (or no change) -- not waiting for new nodes."
  exit 0
fi

echo "Waiting for ${GPU_REPLICAS} node(s) with nvidia.com/gpu allocatable (up to ~8 min --"
echo "covers instance boot + GPU Operator driver install, same as the first GPU node took)..."
for i in $(seq 1 48); do
  ready=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -c '^1$' || true)
  echo "  [$i/48] GPU-ready nodes: ${ready}/${GPU_REPLICAS}"
  [ "$ready" -ge "$GPU_REPLICAS" ] && { echo "Done."; exit 0; }
  sleep 10
done
echo "Timed out waiting -- check 'oc get nodes' / 'oc get pods -n nvidia-gpu-operator' manually." >&2
exit 1
