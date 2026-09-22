#!/usr/bin/env bash
# Runs ON the bastion. Scenario 19 (unified MaaS Governance page) can't be
# driven from a script -- it's a dashboard UI flow. What this script does
# instead: dump every CR that plausibly backs "Subscriptions" and
# "Authorization Policies" so a snapshot taken before a UI change can be
# diffed against one taken after, to find out what the page actually
# writes. Run once before touching the UI, once after, then:
#   diff harness/state/governance-snapshot-<ts1>.yaml harness/state/governance-snapshot-<ts2>.yaml
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

echo "# Governance-relevant CRs, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "## AuthPolicy / AuthConfig (Kuadrant/Authorino)"
oc get authpolicy,authconfig -A -o yaml 2>&1
echo ""
echo "## RateLimitPolicy (Limitador)"
oc get ratelimitpolicy -A -o yaml 2>&1
echo ""
echo "## Any CRD under the maas.opendatahub.io / kuadrant.io groups (discover what exists)"
oc get crd -o name 2>/dev/null | grep -E 'maas\.opendatahub\.io|kuadrant\.io' | while read -r crd; do
  kind="${crd#customresourcedefinition.apiextensions.k8s.io/}"
  echo "--- ${kind} ---"
  oc get "${kind%%.*}" -A -o yaml 2>&1
done
echo ""
echo "## DataScienceCluster modelsAsService state"
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService}' 2>&1
echo ""
echo "## odhdashboardconfig (dashboard feature flags, incl. MaaS Governance UI toggle)"
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications -o yaml 2>&1
