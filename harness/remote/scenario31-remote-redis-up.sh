#!/usr/bin/env bash
# Scenario 31 (remote side): standalone Redis (TLS + password + AOF on a PVC)
# exposed through an AWS NLB, to serve as the Limitador store of a MaaS
# cluster in another region. Run with `oc` logged in to the REMOTE cluster.
# Only Redis is needed there -- no RHCL/Limitador/MaaS.
#
#   ALLOWED_CIDRS=1.2.3.4/32,5.6.7.8/32 bash remote/scenario31-remote-redis-up.sh
#   REDIS_ACTION=down bash remote/scenario31-remote-redis-up.sh
#   REDIS_CPU=4 REDIS_CPU_REQUEST=4 REDIS_IO_THREADS=4 bash remote/scenario31-remote-redis-up.sh   # resize
#
# Writes REDIS_URL (rediss://...#insecure, self-signed cert) to STATE_FILE.
set -euo pipefail

REDIS_NS="${REDIS_NS:-remote-redis}"
REDIS_IMAGE="${REDIS_IMAGE:-registry.redhat.io/rhel9/redis-7:latest}"
REDIS_PVC_SIZE="${REDIS_PVC_SIZE:-1Gi}"
REDIS_ACTION="${REDIS_ACTION:-up}"
REDIS_CPU="${REDIS_CPU:-1}"                   # cpu limit
REDIS_CPU_REQUEST="${REDIS_CPU_REQUEST:-100m}"
REDIS_MEMORY="${REDIS_MEMORY:-512Mi}"         # memory limit
REDIS_IO_THREADS="${REDIS_IO_THREADS:-1}"     # >1 offloads socket/TLS I/O from the main thread
STATE_FILE="${STATE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state/remote-redis.env}"

if [ "$REDIS_ACTION" = down ]; then
  oc delete ns "$REDIS_NS" --ignore-not-found --wait=true
  rm -f "$STATE_FILE"
  echo "deleted namespace ${REDIS_NS}"
  exit 0
fi

# on re-run (resize), reuse the source ranges already on the Service
: "${ALLOWED_CIDRS:=$(oc get svc redis -n "$REDIS_NS" -o jsonpath='{.spec.loadBalancerSourceRanges[*]}' 2>/dev/null | tr ' ' ',')}"
ALLOWED_CIDRS="${ALLOWED_CIDRS:?comma-separated source CIDRs (egress IPs of the MaaS cluster)}"
oc get ns "$REDIS_NS" &>/dev/null || oc create ns "$REDIS_NS" >/dev/null

echo "== 1) Service type=LoadBalancer (NLB), source ranges: ${ALLOWED_CIDRS} =="
ranges=$(echo "$ALLOWED_CIDRS" | tr ',' '\n' | sed 's/^/  - /')
oc apply -n "$REDIS_NS" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: redis
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  type: LoadBalancer
  selector:
    app: redis
  ports:
  - name: tls
    port: 6379
    targetPort: 6379
  loadBalancerSourceRanges:
${ranges}
EOF
host=""
for _ in $(seq 1 60); do
  host=$(oc get svc redis -n "$REDIS_NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  [ -n "$host" ] && break; sleep 5
done
[ -n "$host" ] || { echo "NLB hostname not assigned"; exit 1; }
echo "NLB: ${host}"

echo "== 2) password / TLS Secrets =="
if ! oc get secret redis-auth -n "$REDIS_NS" &>/dev/null; then
  oc create secret generic redis-auth -n "$REDIS_NS" \
    --from-literal=password="$(openssl rand -hex 24)" >/dev/null
fi
password=$(oc get secret redis-auth -n "$REDIS_NS" -o jsonpath='{.data.password}' | base64 -d)

if ! oc get secret redis-tls -n "$REDIS_NS" &>/dev/null; then
  # relative paths + MSYS_NO_PATHCONV keep -subj intact under Git Bash on Windows
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  (
    cd "$tmp"
    MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=remote-redis-ca" \
      -keyout ca.key -out ca.crt 2>/dev/null
    # NLB hostnames exceed the 64-char CN limit -> hostname only in SAN
    MSYS_NO_PATHCONV=1 openssl req -newkey rsa:2048 -nodes -subj "/CN=remote-redis" \
      -keyout tls.key -out tls.csr 2>/dev/null
    printf 'subjectAltName=DNS:%s\n' "$host" > san.ext
    openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
      -days 30 -extfile san.ext -out tls.crt 2>/dev/null
    oc create secret generic redis-tls -n "$REDIS_NS" \
      --from-file=tls.crt --from-file=tls.key --from-file=ca.crt >/dev/null
  )
fi

echo "== 3) PVC + Deployment (${REDIS_IMAGE}, cpu ${REDIS_CPU_REQUEST}/${REDIS_CPU}, io-threads ${REDIS_IO_THREADS}) =="
oc apply -n "$REDIS_NS" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${REDIS_PVC_SIZE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  labels:
    app: redis
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: ${REDIS_IMAGE}
        command: [redis-server]
        args:
        - --port
        - "0"
        - --tls-port
        - "6379"
        - --tls-cert-file
        - /tls/tls.crt
        - --tls-key-file
        - /tls/tls.key
        - --tls-ca-cert-file
        - /tls/ca.crt
        - --tls-auth-clients
        - "no"
        - --requirepass
        - \$(REDIS_PASSWORD)
        - --appendonly
        - "yes"
        - --appendfsync
        - everysec
        - --maxmemory-policy
        - noeviction
        - --dir
        - /var/lib/redis/data
        - --io-threads
        - "${REDIS_IO_THREADS}"
        - --io-threads-do-reads
        - "yes"
        env:
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: redis-auth
              key: password
        ports:
        - containerPort: 6379
        readinessProbe:
          tcpSocket:
            port: 6379
          periodSeconds: 5
        resources:
          requests:
            cpu: "${REDIS_CPU_REQUEST}"
            memory: 128Mi
          limits:
            cpu: "${REDIS_CPU}"
            memory: ${REDIS_MEMORY}
        volumeMounts:
        - name: data
          mountPath: /var/lib/redis/data
        - name: tls
          mountPath: /tls
          readOnly: true
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: redis-data
      - name: tls
        secret:
          secretName: redis-tls
EOF
oc rollout status deploy/redis -n "$REDIS_NS" --timeout=300s

echo "== 4) in-pod check =="
oc exec -n "$REDIS_NS" deploy/redis -- sh -c \
  'redis-cli --tls --insecure -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning PING'

mkdir -p "$(dirname "$STATE_FILE")"
cat > "$STATE_FILE" <<EOF
REDIS_HOST=${host}
REDIS_PASSWORD=${password}
REDIS_URL=rediss://default:${password}@${host}:6379#insecure
EOF
echo ""
echo "REDIS_URL written to ${STATE_FILE}"
echo "rediss://default:****@${host}:6379#insecure"
