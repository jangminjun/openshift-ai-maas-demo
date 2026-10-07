# 시나리오 23: NetworkPolicy를 이용한 vLLM 직접 호출 차단

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5)
**관련 컴포넌트:** NetworkPolicy, MaaS Gateway, LLMInferenceService

## 목적

시나리오 21에서 클러스터 내부 Pod가 `maas-demo-model-kserve-workload-svc:8000`을 직접 호출하여
Gateway의 인가·쿼터를 우회할 수 있음을 확인하였다. 본 시나리오는 모델 namespace에 `NetworkPolicy`를
적용하여 Gateway 경유 트래픽만 허용하고, 우회 경로가 차단되는지 검증한다.

## 구성

| 리소스 | 이름 | 비고 |
|---|---|---|
| NetworkPolicy | `maas-demo/allow-from-maas-gateway` | `openshift-ingress` namespace발 ingress만 허용 |
| NetworkPolicy | `maas-demo/allow-from-monitoring` | metrics 수집 유지 (필요 시) |
| 대상 Pod | `kserve.io/component=workload` | vLLM |

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-from-maas-gateway, namespace: maas-demo}
spec:
  podSelector:
    matchLabels: {kserve.io/component: workload}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: openshift-ingress}
```

## 절차

1. 적용 전 시나리오 21 수동 테스트를 실행하여 4) 직접 호출이 200임을 기록한다.
2. 위 `NetworkPolicy`를 적용한다.
3. 시나리오 21 수동 테스트를 다시 실행한다.
4. Gateway 경유 호출, `oc get llminferenceservice` Ready 상태, metrics 수집 여부를 확인한다.

```sh
oc apply -f allow-from-maas-gateway.yaml
oc get networkpolicy -n maas-demo
.\harness\local\scenario21-manual-test.ps1
oc get llminferenceservice maas-demo-model -n maas-demo
```

## 판정 기준

| 케이스 | 적용 전 | 적용 후 기대 |
|---|---|---|
| Gateway 경유 chat (구독 SA) | 200 | 200 |
| vLLM 직접 호출 | 200 | 연결 실패 (timeout, HTTP 000) |
| LLMInferenceService Ready | True | True |

## 확인 사항

- KServe controller의 readiness 확인, llm-d EPP 등 Gateway 외 정상 트래픽 경로가 차단되지 않는지
- `openshift-user-workload-monitoring`의 vLLM metrics scrape가 유지되는지

## 자동화

```sh
bash harness/remote/scenario23-gateway-bypass-networkpolicy.sh                  # 적용 (기본)
NP_ACTION=remove bash harness/remote/scenario23-gateway-bypass-networkpolicy.sh # 원복
```

전용 주체 `maas-pod-client/maas-np-client`와 구독 `maas-np-sub`(100000 tok/h)를 사용한다. 다른 시나리오의
쿼터 소진(429)이 Gateway 경유 판정에 섞이지 않도록 분리하였다.

## 실측 결과 (2026-10-07, sandbox49)

```text
== Before (NetworkPolicy in maas-demo: 0) ==
before     gateway-chat=200  direct-chat=200  direct-metrics=200  LLMInferenceService Ready=True

== Apply NetworkPolicy ==
networkpolicy.networking.k8s.io/allow-from-maas-gateway created
networkpolicy.networking.k8s.io/allow-from-monitoring created
after      gateway-chat=200  direct-chat=000  direct-metrics=000  LLMInferenceService Ready=True

== 60s 후 재확인 (Ready 유지 여부) ==
after+60s  gateway-chat=200  direct-chat=000  direct-metrics=000  LLMInferenceService Ready=True

== Assertions ==
PASS  before: direct chat 열림 (우회 재현) -> 200
PASS  after: gateway chat -> 200
PASS  after: direct chat 차단 -> 000
PASS  after: direct metrics 차단 (monitoring ns만 허용) -> 000
PASS  after: LLMInferenceService Ready -> True

RESULT: ALL PASS
```

적용 후 User Workload Monitoring의 vLLM scrape 상태:

```sh
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=up{namespace="maas-demo"}'
```

```json
{"job": "maas-demo/kserve-llm-isvc-vllm-engine", "pod": "maas-demo-model-kserve-c5d95d86f-ml9tn", "value": "1"}
```

| 관찰 | 내용 |
|---|---|
| 우회 차단 | 클러스터 내부 Pod의 vLLM 직접 호출이 연결 단계에서 차단됨 (curl exit 28, timeout) |
| Gateway 경로 | `openshift-ingress` namespace 허용만으로 정상 동작 |
| 운영 영향 | `LLMInferenceService` Ready 유지, PodMonitor scrape `up=1` 유지 |
| 현재 상태 | NetworkPolicy 2개 적용 유지. 시나리오 21의 4) 직접 호출은 이후 000이 된다 |
