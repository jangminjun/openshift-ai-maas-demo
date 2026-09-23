#!/usr/bin/env bash
# Installs RHCL (Kuadrant: Authorino + Limitador) and stands up RHOAI 3.5's
# MaaS gateway end to end. Runs ON the bastion, after the base cluster +
# RHOAI 3.5 operator/DataScienceCluster already exist (openshift-aws-harness
# -> harness.sh rhoai). Idempotent -- every step checks before creating.
#
# This is a from-scratch RHOAI 3.5 port of an RHOAI 3.3/3.4-era script this
# project used to depend on (monitoring-llmd-rhoai/harness/remote/maas.sh),
# folding in every bug that script's steps hit on 3.5 (all documented in
# lessonlearn.md) so this repo no longer needs that one:
#   - Authorino listener TLS must be OFF on 3.5 (the generated EnvoyFilter
#     connects plaintext) -- no cert-manager/self-signed cert dance needed.
#   - MaaS moved from spec.components.kserve.modelsAsService to
#     spec.components.aigateway.modelsAsAService.
#   - RHOAI 3.5 needs a Gateway named EXACTLY "maas-default-gateway" (not
#     just "openshift-ai-inference"), a real TLS cert (the placeholder
#     "default-gateway-tls" secret never exists -- use the cluster's own
#     router-certs-default), and a Postgres DB for maas-api that nothing
#     else provisions.
#   - maas-default-gateway needs opendatahub.io/managed=false BEFORE any
#     model is ever deployed to it, or odh-model-controller will hijack its
#     AuthPolicy the moment a model shows up.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

echo "== Step 1: RHCL (Kuadrant: Authorino + Limitador) operator =="
oc get namespace kuadrant-system &>/dev/null || oc create namespace kuadrant-system
if oc get csv -n kuadrant-system 2>/dev/null | grep -qi rhcl-operator; then
  echo "RHCL operator already installed."
else
  oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kuadrant-system
  namespace: kuadrant-system
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: kuadrant-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML
  echo "Waiting for RHCL operator CRDs (up to 5m)..."
  for _ in $(seq 1 30); do
    oc get crd kuadrants.kuadrant.io &>/dev/null && break
    sleep 10
  done
  oc get crd kuadrants.kuadrant.io &>/dev/null || { echo "Timed out waiting for RHCL CRDs" >&2; exit 1; }
fi

if oc get kuadrant kuadrant -n kuadrant-system &>/dev/null; then
  echo "Kuadrant instance already exists."
else
  oc apply -f - <<'YAML'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
YAML
  echo "Waiting for Authorino service (up to 2m)..."
  for _ in $(seq 1 12); do
    oc get svc/authorino-authorino-authorization -n kuadrant-system &>/dev/null && break
    sleep 10
  done
fi

echo "== Step 2: Authorino instance (listener TLS OFF -- required on RHOAI 3.5, see lessonlearn.md) =="
oc apply -f - <<'YAML'
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: authorino
  namespace: kuadrant-system
spec:
  replicas: 1
  clusterWide: true
  listener:
    tls:
      enabled: false
  oidcServer:
    tls:
      enabled: false
YAML

echo "== Step 3: Enable MaaS (aigateway.modelsAsAService) in DataScienceCluster =="
current_state=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}' 2>/dev/null || echo "")
if [ "$current_state" = "Managed" ]; then
  echo "aigateway.modelsAsAService already Managed."
else
  oc patch datasciencecluster default-dsc --type=merge -p '{
    "spec": {"components": {"aigateway": {
      "managementState": "Managed",
      "modelsAsAService": {"managementState": "Managed"}
    }}}
  }'
  echo "Waiting 30s for DataScienceCluster to reconcile..."
  sleep 30
fi

echo "== Step 4: GatewayClass + Gateways (inference + MaaS) =="
oc get gatewayclass openshift-ai-inference &>/dev/null || oc apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-ai-inference
spec:
  controllerName: openshift.io/gateway-controller/v1
YAML

# Both Gateways use the cluster's own default ingress router cert -- no
# cert-manager Certificate needed for a *.apps.<domain> hostname.
if oc get gateway openshift-ai-inference -n openshift-ingress &>/dev/null; then
  echo "Gateway openshift-ai-inference already exists."
else
  oc apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: openshift-ai-inference
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-ai-inference
  listeners:
    - allowedRoutes:
        namespaces:
          from: All
      hostname: inference-gateway.${CLUSTER_DOMAIN}
      name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - group: ''
            kind: Secret
            name: router-certs-default
        mode: Terminate
YAML
fi

if oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null; then
  echo "Gateway maas-default-gateway already exists."
else
  oc apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-ai-inference
  listeners:
    - allowedRoutes:
        namespaces:
          from: All
      hostname: maas.${CLUSTER_DOMAIN}
      name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - group: ''
            kind: Secret
            name: router-certs-default
        mode: Terminate
YAML
fi

# Must be applied before any model is ever deployed to this Gateway, or
# odh-model-controller creates a competing AuthPolicy the moment one is.
oc annotate gateway maas-default-gateway -n openshift-ingress \
  opendatahub.io/managed="false" \
  security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite

echo "== Step 5: Postgres DB for maas-api =="
if oc get secret maas-db-config -n redhat-ai-gateway-infra &>/dev/null; then
  echo "maas-db-config secret already exists."
else
  oc get namespace redhat-ai-gateway-infra &>/dev/null || oc create namespace redhat-ai-gateway-infra
  DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
  oc create secret generic maas-postgres-creds -n redhat-ai-gateway-infra \
    --from-literal=username=maasapi --from-literal=password="$DB_PASSWORD" \
    --dry-run=client -o yaml | oc apply -f -
  oc apply -f - <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: maas-db
  namespace: redhat-ai-gateway-infra
spec:
  selector: {app: maas-db}
  ports: [{port: 5432, targetPort: 5432}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: maas-db
  namespace: redhat-ai-gateway-infra
spec:
  replicas: 1
  selector: {matchLabels: {app: maas-db}}
  template:
    metadata: {labels: {app: maas-db}}
    spec:
      containers:
      - name: postgres
        image: registry.redhat.io/rhel9/postgresql-15:latest
        ports: [{containerPort: 5432}]
        env:
        - {name: POSTGRESQL_USER, valueFrom: {secretKeyRef: {name: maas-postgres-creds, key: username}}}
        - {name: POSTGRESQL_PASSWORD, valueFrom: {secretKeyRef: {name: maas-postgres-creds, key: password}}}
        - {name: POSTGRESQL_DATABASE, value: maasdb}
        volumeMounts: [{name: data, mountPath: /var/lib/pgsql/data}]
      volumes: [{name: data, emptyDir: {}}]
YAML
  echo "Waiting for maas-db to be ready (up to 2m)..."
  for _ in $(seq 1 12); do
    oc get pods -n redhat-ai-gateway-infra -l app=maas-db 2>/dev/null | grep -q "1/1.*Running" && break
    sleep 10
  done
  DB_USER=$(oc get secret maas-postgres-creds -n redhat-ai-gateway-infra -o jsonpath='{.data.username}' | base64 -d)
  DB_PASS=$(oc get secret maas-postgres-creds -n redhat-ai-gateway-infra -o jsonpath='{.data.password}' | base64 -d)
  oc create secret generic maas-db-config -n redhat-ai-gateway-infra \
    --from-literal=DB_CONNECTION_URL="postgresql://${DB_USER}:${DB_PASS}@maas-db.redhat-ai-gateway-infra.svc:5432/maasdb" \
    --dry-run=client -o yaml | oc apply -f -
fi

echo "== Step 6: ClusterStorageContainer for hf:// model URIs =="
oc get clusterstoragecontainer hf-hub &>/dev/null || oc apply -f - <<'YAML'
apiVersion: serving.kserve.io/v1alpha1
kind: ClusterStorageContainer
metadata:
  name: hf-hub
spec:
  container:
    name: storage-initializer
    image: registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9@sha256:c2db37bfe06f62b4ead20a975afe9df1c00e0178492c4bcd75968b60b1fbee79
    resources:
      requests: {memory: 100Mi, cpu: 100m}
      limits: {memory: 4Gi, cpu: "1"}
  supportedUriFormats:
  - regex: "^hf://"
YAML

echo "== Step 7: Dashboard MaaS feature flags =="
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge -p '{
  "spec": {"dashboardConfig": {"disableModelRegistry": false, "disableModelCatalog": false,
  "disableKServeMetrics": false, "genAiStudio": true, "modelAsService": true, "disableLMEval": false}}
}' 2>/dev/null || echo "Could not patch odhdashboardconfig (may not exist yet) -- continuing."

echo "== Step 8: Restart controllers to pick up the new config =="
oc delete pod -n redhat-ods-applications -l app=odh-model-controller --ignore-not-found=true
oc delete pod -n redhat-ods-applications -l control-plane=kserve-controller-manager --ignore-not-found=true

echo ""
echo "MaaS setup complete."
echo "MaaS endpoint:       https://maas.${CLUSTER_DOMAIN}"
echo "Inference gateway:   https://inference-gateway.${CLUSTER_DOMAIN}"
echo "Verify: oc get aitenant -A ; oc get gateway -A ; oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions}'"
echo "Next: ./harness.sh scenario17-keycloak-up (external OIDC) or scenario18-deploy-model (a model) -- see docs/scenarios/17,18."
