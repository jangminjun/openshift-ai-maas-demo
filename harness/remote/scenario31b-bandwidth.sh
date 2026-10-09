#!/usr/bin/env bash
# Scenario 31-B: measure the inter-cluster link (MaaS cluster -> remote Redis
# cluster) with iperf3 over the same path Limitador uses (NAT Gateway ->
# inter-region -> NLB). Two clusters, so run each action with `oc` logged in
# to the right one:
#
#   remote:  ALLOWED_CIDRS=1.2.3.4/32,... BW_ACTION=server-up   bash remote/scenario31b-bandwidth.sh
#   MaaS:    BW_HOST=<NLB hostname>       BW_ACTION=client      bash remote/scenario31b-bandwidth.sh
#   remote:                              BW_ACTION=server-down bash remote/scenario31b-bandwidth.sh
set -euo pipefail

BW_NS="${BW_NS:-remote-redis}"            # remote side namespace (reuses scenario 31's)
CLIENT_NS="${CLIENT_NS:-kuadrant-system}" # client side: same namespace/egress as Limitador
# network-tools-rhel9 does not ship iperf3; this image is iperf3 only (no curl/sh tools needed)
BW_IMAGE="${BW_IMAGE:-docker.io/networkstatic/iperf3:latest}"
BW_SECONDS="${BW_SECONDS:-15}"
BW_PARALLEL="${BW_PARALLEL:-8}"
BW_ACTION="${BW_ACTION:?server-up|client|server-down}"

pod_spec() {  # $1 name $2 ns $3 command... (restricted PSA)
  local name=$1 ns=$2; shift 2
  local cmd; cmd=$(printf '"%s",' "$@"); cmd="[${cmd%,}]"
  oc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: ${name}, namespace: ${ns}, labels: {app: ${name}}}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: main
    image: ${BW_IMAGE}
    command: ${cmd}
    ports: [{containerPort: 5201}]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
}

case "$BW_ACTION" in
  server-up)
    ALLOWED_CIDRS="${ALLOWED_CIDRS:?comma-separated source CIDRs}"
    oc get ns "$BW_NS" &>/dev/null || oc create ns "$BW_NS" >/dev/null
    pod_spec iperf3-server "$BW_NS" iperf3 -s -p 5201
    ranges=$(echo "$ALLOWED_CIDRS" | tr ',' '\n' | sed 's/^/  - /')
    oc apply -n "$BW_NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: iperf3
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
spec:
  type: LoadBalancer
  selector: {app: iperf3-server}
  ports: [{name: iperf3, port: 5201, targetPort: 5201}]
  loadBalancerSourceRanges:
${ranges}
EOF
    oc wait pod iperf3-server -n "$BW_NS" --for=condition=Ready --timeout=180s >/dev/null
    host=""
    for _ in $(seq 1 60); do
      host=$(oc get svc iperf3 -n "$BW_NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); [ -n "$host" ] && break; sleep 5
    done
    echo "BW_HOST=${host}"
    echo "(NLB DNS/targets can take 2-3 min to become reachable)"
    ;;
  client)
    BW_HOST="${BW_HOST:?NLB hostname from server-up}"
    oc delete pod iperf3-client -n "$CLIENT_NS" --ignore-not-found >/dev/null
    pod_spec iperf3-client "$CLIENT_NS" sleep 1800
    oc wait pod iperf3-client -n "$CLIENT_NS" --for=condition=Ready --timeout=180s >/dev/null
    run() { oc exec -n "$CLIENT_NS" iperf3-client -- iperf3 -c "$BW_HOST" -p 5201 -t "$BW_SECONDS" -f m "$@" 2>&1 \
              | grep -E 'sender|receiver|error' | tail -2; }
    echo "== upload (MaaS -> remote), 1 stream, ${BW_SECONDS}s ==";            run
    echo "== upload (MaaS -> remote), ${BW_PARALLEL} streams, ${BW_SECONDS}s =="; run -P "$BW_PARALLEL"
    echo "== download (remote -> MaaS), 1 stream, ${BW_SECONDS}s ==";          run -R
    echo "== download (remote -> MaaS), ${BW_PARALLEL} streams, ${BW_SECONDS}s =="; run -R -P "$BW_PARALLEL"
    oc delete pod iperf3-client -n "$CLIENT_NS" --ignore-not-found --wait=false >/dev/null
    ;;
  server-down)
    oc delete svc iperf3 -n "$BW_NS" --ignore-not-found >/dev/null
    oc delete pod iperf3-server -n "$BW_NS" --ignore-not-found --wait=false >/dev/null
    echo "iperf3 server + NLB removed from ${BW_NS}"
    ;;
  *) echo "BW_ACTION must be server-up|client|server-down"; exit 1 ;;
esac
