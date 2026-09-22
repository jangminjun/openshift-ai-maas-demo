#!/usr/bin/env bash
# Runs ON the bastion. Scenario 17 (docs/scenarios/17-maas-external-oidc-auth.md)
# step 1: stand up Keycloak on-cluster as the external OIDC IDP, using the
# Red Hat build of Keycloak (RHBK) operator -- not a Bitnami/community image,
# per the decision to test this the "OpenShift-native operator" way.
# Idempotent -- every step checks before creating.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

: "${KEYCLOAK_NAMESPACE:?set KEYCLOAK_NAMESPACE}"

oc get namespace "$KEYCLOAK_NAMESPACE" &>/dev/null || oc create namespace "$KEYCLOAK_NAMESPACE"

echo "== Step 1: Red Hat build of Keycloak (RHBK) operator =="

if oc get csv -n "$KEYCLOAK_NAMESPACE" 2>/dev/null | grep -qi rhbk-operator; then
  echo "RHBK operator already installed."
else
  CHANNEL=$(oc get packagemanifest rhbk-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}' 2>/dev/null || true)
  [ -n "$CHANNEL" ] || { echo "rhbk-operator package not found in catalog. Available Keycloak-ish packages:" >&2; \
    oc get packagemanifest -n openshift-marketplace 2>/dev/null | grep -i keycloak >&2 || true; exit 1; }
  echo "Using channel: $CHANNEL"
  oc apply -f - <<YAML
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${KEYCLOAK_NAMESPACE}
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  targetNamespaces:
    - ${KEYCLOAK_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: rhbk-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML
  echo "Waiting for RHBK operator CRDs (up to 5m)..."
  for _ in $(seq 1 30); do
    oc get crd keycloaks.k8s.keycloak.org &>/dev/null && break
    sleep 10
  done
  oc get crd keycloaks.k8s.keycloak.org &>/dev/null || { echo "Timed out waiting for RHBK CRDs" >&2; exit 1; }
fi

echo "== Step 2: ephemeral Postgres for Keycloak (demo/test only, not HA) =="

if oc get deployment keycloak-db -n "$KEYCLOAK_NAMESPACE" &>/dev/null; then
  echo "keycloak-db already exists."
else
  DB_PASSWORD=$(openssl rand -hex 16)
  oc create secret generic keycloak-db-secret -n "$KEYCLOAK_NAMESPACE" \
    --from-literal=username=keycloak \
    --from-literal=password="$DB_PASSWORD" \
    --dry-run=client -o yaml | oc apply -f -
  oc apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak-db
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels: {app: keycloak-db}
  template:
    metadata:
      labels: {app: keycloak-db}
    spec:
      containers:
        - name: postgres
          image: registry.redhat.io/rhel9/postgresql-15:latest
          env:
            - {name: POSTGRESQL_USER, valueFrom: {secretKeyRef: {name: keycloak-db-secret, key: username}}}
            - {name: POSTGRESQL_PASSWORD, valueFrom: {secretKeyRef: {name: keycloak-db-secret, key: password}}}
            - {name: POSTGRESQL_DATABASE, value: keycloak}
          ports: [{containerPort: 5432}]
          volumeMounts: [{name: data, mountPath: /var/lib/pgsql/data}]
      volumes: [{name: data, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak-db
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  selector: {app: keycloak-db}
  ports: [{port: 5432, targetPort: 5432}]
YAML
  echo "Waiting for keycloak-db to be ready (up to 2m)..."
  oc rollout status deployment/keycloak-db -n "$KEYCLOAK_NAMESPACE" --timeout=120s
fi

echo "== Step 3: Keycloak instance + Route =="

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
KEYCLOAK_HOST="maas-keycloak.${CLUSTER_DOMAIN}"

if oc get keycloak maas-keycloak -n "$KEYCLOAK_NAMESPACE" &>/dev/null; then
  echo "Keycloak CR already exists."
else
  oc apply -f - <<YAML
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: maas-keycloak
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  instances: 1
  db:
    vendor: postgres
    host: keycloak-db.${KEYCLOAK_NAMESPACE}.svc
    usernameSecret: {name: keycloak-db-secret, key: username}
    passwordSecret: {name: keycloak-db-secret, key: password}
  http:
    httpEnabled: true
  hostname:
    hostname: ${KEYCLOAK_HOST}
  ingress:
    enabled: false
  proxy:
    # Required because TLS terminates at the Route (edge), not at Keycloak
    # itself -- without this, Keycloak doesn't trust the X-Forwarded-Proto
    # header from the router and reports its own issuer/endpoints as
    # "http://..." instead of "https://...", which then fails OIDC discovery
    # validation on the Authorino/relying-party side ("issuer did not match").
    # Found the hard way -- see docs/scenarios/17-maas-external-oidc-auth.md
    # section 6(b) in openshift-ai-maas-demo.
    headers: xforwarded
YAML
fi

# The operator's built-in Ingress targets HTTPS with a self-signed cert
# Authorino won't trust by default -- use an edge Route instead (terminates
# TLS with the cluster's own ingress cert, backend stays plain HTTP), same
# pattern as this project's other routes (see AGENT.md).
if oc get route maas-keycloak -n "$KEYCLOAK_NAMESPACE" &>/dev/null; then
  echo "Route already exists."
else
  oc create route edge maas-keycloak -n "$KEYCLOAK_NAMESPACE" \
    --service=maas-keycloak-service --port=8080 --hostname="$KEYCLOAK_HOST"
fi

echo "Waiting for Keycloak to report Ready (up to 5m)..."
for _ in $(seq 1 30); do
  oc get keycloak maas-keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True && break
  sleep 10
done
oc get keycloak maas-keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True \
  || { echo "Keycloak not Ready yet -- check: oc describe keycloak maas-keycloak -n ${KEYCLOAK_NAMESPACE}" >&2; exit 1; }

echo ""
echo "Keycloak up: https://${KEYCLOAK_HOST}"
echo "Admin credentials: oc get secret maas-keycloak-initial-admin -n ${KEYCLOAK_NAMESPACE} -o jsonpath='{.data.username}' | base64 -d; echo"
echo "                    oc get secret maas-keycloak-initial-admin -n ${KEYCLOAK_NAMESPACE} -o jsonpath='{.data.password}' | base64 -d; echo"
echo "Next: ./harness.sh scenario17-keycloak-realm"
