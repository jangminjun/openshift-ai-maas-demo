#!/usr/bin/env bash
# Makes Authorino trust every internal CA the MaaS external-OIDC path (scenario
# 17) depends on: the ingress router CA (Keycloak's edge-TLS route) and the
# OpenShift service-serving-signer CA (maas-api's TLS cert, which Authorino's
# own outbound "subscription-valid" mTLS call must verify). Idempotent -- CN
# prefixes are matched instead of exact certs since both CAs are regenerated
# (new random suffix) on every cluster rebuild. Safe to re-run.
#
# Background: docs/scenarios/17-maas-external-oidc-auth.md section 8,
# lessonlearn.md "Authorino makes its own outbound mTLS call to maas-api" and
# "Getting Authorino to trust a self-signed-route OIDC issuer".
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

CM_NS="kuadrant-system"
CM_NAME="authorino-extra-ca"
CM_KEY="ca-bundle.crt"
AUTHORINO_NAME="${AUTHORINO_NAME:-authorino}"
MOUNT_PATH="/etc/pki/ca-trust/extracted/pem"

tmp_bundle=$(mktemp)
trap 'rm -f "$tmp_bundle" /tmp/router-ca.crt /tmp/service-ca.crt' EXIT

# Start from whatever's already there (first run: base RHEL9 UBI bundle read
# straight off a live Authorino pod, since the configmap doesn't exist yet).
if oc get configmap "$CM_NAME" -n "$CM_NS" &>/dev/null; then
  oc get configmap "$CM_NAME" -n "$CM_NS" -o jsonpath="{.data.${CM_KEY//./\\.}}" > "$tmp_bundle"
else
  pod=$(oc get pod -n "$CM_NS" -l app=authorino -o jsonpath='{.items[0].metadata.name}')
  oc exec -n "$CM_NS" "$pod" -- cat /etc/pki/tls/certs/ca-bundle.crt > "$tmp_bundle"
fi

changed=false

# PEM certs are base64 -- a plain `grep` for "CN=..." on the bundle file
# never matches (the text isn't literally in the encoded bytes). Decode all
# certs' subjects at once instead.
bundle_subjects() {
  openssl crl2pkcs7 -nocrl -certfile "$1" 2>/dev/null | openssl pkcs7 -print_certs -noout 2>/dev/null
}

oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/router-ca.crt
if ! bundle_subjects "$tmp_bundle" | grep -q "subject=CN=ingress-operator@"; then
  cat /tmp/router-ca.crt >> "$tmp_bundle"
  changed=true
  echo "Added ingress router CA (Keycloak Route TLS)."
else
  echo "Ingress router CA already trusted."
fi

oc get configmap service-ca -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > /tmp/service-ca.crt
if ! bundle_subjects "$tmp_bundle" | grep -q "subject=CN=openshift-service-serving-signer@"; then
  cat /tmp/service-ca.crt >> "$tmp_bundle"
  changed=true
  echo "Added openshift-service-serving-signer CA (maas-api TLS)."
else
  echo "Service-serving-signer CA already trusted."
fi

if [ "$changed" = true ]; then
  oc create configmap "$CM_NAME" -n "$CM_NS" --from-file="${CM_KEY}=${tmp_bundle}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "Updated configmap/${CM_NAME}."
fi

# Ensure the Authorino CR actually mounts this configmap (declarative --
# survives operator reconciliation; not a raw Deployment patch).
has_mount=$(oc get authorino "$AUTHORINO_NAME" -n "$CM_NS" \
  -o jsonpath="{.spec.volumes.items[?(@.name=='extra-ca')].name}" 2>/dev/null || true)
if [ "$has_mount" != "extra-ca" ]; then
  oc patch authorino "$AUTHORINO_NAME" -n "$CM_NS" --type=merge -p "{
    \"spec\": {\"volumes\": {\"items\": [{
      \"name\": \"extra-ca\",
      \"configMaps\": [\"${CM_NAME}\"],
      \"items\": [{\"key\": \"${CM_KEY}\", \"path\": \"tls-ca-bundle.pem\"}],
      \"mountPath\": \"${MOUNT_PATH}\"
    }]}}
  }"
  changed=true
  echo "Patched Authorino CR to mount ${CM_NAME} at ${MOUNT_PATH}."
else
  echo "Authorino CR already mounts ${CM_NAME}."
fi

if [ "$changed" = true ]; then
  oc rollout restart deploy/authorino -n "$CM_NS"
  oc rollout status deploy/authorino -n "$CM_NS" --timeout=90s
  echo "Restarted Authorino to pick up the updated CA trust bundle."
else
  echo "Nothing changed -- Authorino already trusts both CAs."
fi
