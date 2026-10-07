# 시나리오 28: 구독별 사용량 측정 (Metering)

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5)
**관련 컴포넌트:** Limitador metrics, User Workload Monitoring, MaaSSubscription(`billingRate`), Grafana

## 목적

구독·주체·모델 단위 토큰 사용량이 metrics로 노출되어 사후 집계(chargeback)가 가능한지 검증한다.
쿼터 집행(시나리오 22)과 별개로, 플랫폼 운영자가 "누가 얼마나 사용했는가"를 조회할 수 있어야 한다.

## 구성

| 항목 | 내용 |
|---|---|
| 부하 | 시나리오 21의 `maas-client` SA로 고정 횟수 요청 (예: 10회) |
| 기준값 | 클라이언트 측 `usage.total_tokens` 합계 |
| 조회 | OpenShift Console > Observe > Metrics, Grafana |
| 단가 | `MaaSSubscription.spec.modelRefs[].billingRate.perToken` |

```sh
oc get servicemonitor,podmonitor -n kuadrant-system
oc get pods -n kuadrant-system -l app=limitador
```

## 절차

1. 부하 전 Limitador 및 MaaS 관련 metric 목록을 조회한다.
2. 고정 횟수 요청을 전송하고 클라이언트 측 토큰 합계를 기록한다.
3. metric에서 주체·구독·모델 label로 사용량을 조회하여 클라이언트 합계와 비교한다.
4. `billingRate.perToken`을 0이 아닌 값으로 설정하고 비용 산출 metric 또는 API가 존재하는지 확인한다.

## 판정 기준

| 항목 | 기대 |
|---|---|
| 사용량 metric 존재 | 주체 또는 구독 label 포함 |
| 정확도 | 클라이언트 합계와 일치 |
| 비용 산출 | `billingRate` 반영 여부 기록 |

## 자동화

```sh
bash harness/remote/scenario28-usage-metering.sh
```

전용 주체 `maas-pod-client/maas-meter`, 구독 `maas-meter-sub`(`billingRate.perToken: "0.002"`)를 사용한다.
Prometheus scrape 간격(기본 30s)을 고려하여 snapshot 전후 75초 대기한다. 실행 중 다른 모델 트래픽이 없어야 한다.

## 실측 결과 (2026-10-07, sandbox49)

```text
== 0) 부하 전 snapshot (scrape 반영 대기 75s) ==
authorized_hits=2909 authorized_calls=41 vllm_tokens=3410

== 1) SA maas-meter: 10회 요청 ==
  #1 HTTP 200 total_tokens=70
  #2 HTTP 200 total_tokens=70
  #3 HTTP 200 total_tokens=70
  #4 HTTP 200 total_tokens=70
  #5 HTTP 200 total_tokens=70
  #6 HTTP 200 total_tokens=70
  #7 HTTP 200 total_tokens=70
  #8 HTTP 200 total_tokens=70
  #9 HTTP 200 total_tokens=70
  #10 HTTP 200 total_tokens=70
client 합계: 10건, 700 tok

== 2) 부하 후 snapshot (75s 대기) ==
authorized_hits +700  authorized_calls +10  vllm_tokens +700

== 3) 사용량 metric label (주체/구독 구분 가능 여부) ==
{"__name__":"authorized_hits","limitador_namespace":"maas-demo/maas-demo-model-kserve-route"}

== 4) billingRate.perToken=0.002 반영 여부 ==
cost/billing/charge 이름의 metric series: 0
GET /maas-api/v1/subscriptions billing 필드: [{"token_rate_limits":[{"limit":100000,"window":"1h"}],"billing_rate":{"per_token":"0.002"}}]
client 합계 기준 산출 비용: 700 tok × 0.002 = 1.400

== Assertions ==
PASS  요청 성공 -> 10
PASS  Limitador authorized_hits 증가 = client 합계 -> 700
PASS  Limitador authorized_calls 증가 = 요청 수 -> 10
PASS  vLLM prompt+generation 증가 = client 합계 -> 700
FAIL  주체/구독별 사용량 label 존재 -> no (expected yes)
FAIL  billingRate 기반 비용 metric 존재 -> no (expected yes)

RESULT: FAILURES
```

사용량 조회 API 부재 확인:

```text
/maas-api/v1/usage -> 404
/maas-api/v1/usage/me -> 404
/maas-api/v1/subscriptions/maas-meter-sub/usage -> 404
/maas-api/v1/metrics -> 404
/v1/usage -> 404
```

| 관찰 | 내용 |
|---|---|
| 정확도 | Limitador `authorized_hits`, vLLM `prompt_tokens_total + generation_tokens_total` 증가분이 client `usage.total_tokens` 합계(700)와 정확히 일치 |
| 집계 단위 | `authorized_hits`의 label은 `limitador_namespace`(HTTPRoute 단위)뿐이다. 주체·구독별 사용량은 metric으로 구분할 수 없다 |
| Limitador 설정 | `--metric-labels-default descriptors[1]`이 지정되어 있으나 해당 descriptor가 비어 있어 추가 label이 생성되지 않는다 |
| 비용 | `billingRate.perToken`은 `GET /maas-api/v1/subscriptions`에 `billing_rate`로 노출될 뿐, 사용량과 결합한 비용 metric·API는 없다 |
| 결론 | 모델(route) 단위 총량 측정은 가능하나, 구독·주체 단위 chargeback은 RHOAI 3.5 기본 구성으로 불가하다. 외부 집계(Gateway access log, Authorino 연계 등)가 필요하다 |
