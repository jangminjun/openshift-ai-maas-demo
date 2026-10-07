# 시나리오 26: 다중 구독 보유 시 구독 선택

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5)
**관련 컴포넌트:** MaaSSubscription(`priority`), `x-maas-subscription` 헤더, TokenRateLimitPolicy

## 목적

한 주체가 동일 모델에 대해 복수의 `MaaSSubscription`을 보유할 때 어느 구독의 한도가 적용되는지 검증한다.
명시적 선택(`x-maas-subscription` 헤더)과 기본 선택(`priority`)의 동작을 확인한다.

## 구성

| 리소스 | 한도 | priority |
|---|---|---|
| MaaSSubscription `maas-multi-low` | 100 tok/h | 0 |
| MaaSSubscription `maas-multi-high` | 100000 tok/h | 10 |
| 주체 | `maas-pod-client/maas-multi` SA (두 구독 모두 owner) | — |

```sh
oc get maassubscription -n models-as-a-service \
  -o custom-columns=NAME:.metadata.name,PRIORITY:.spec.priority,OWNER:.spec.owner
```

## 절차

1. 구독을 지정하지 않고 API key를 발급하여 고정된 구독을 확인하고, SA token과 API key로 각각 헤더 없이 요청한다.
2. `x-maas-subscription: maas-multi-low`로 요청을 반복하여 100 tok에서 429가 발생하는지 확인한다.
3. 같은 시점에 `x-maas-subscription: maas-multi-high`로 요청하여 200인지 확인한다.
4. 소유하지 않은 구독명을 헤더로 지정한다.
5. 두 구독의 `priority`를 동일하게 설정하고 `SpecPriorityDuplicate` condition을 확인한다.

## 판정 기준

| 케이스 | 기대 (실측으로 확정) |
|---|---|
| API key 발급 (구독 미지정) | priority 높은 `maas-multi-high`에 고정 |
| SA token, 헤더 없음 | 403 — 구독 명시 요구 |
| API key, 헤더 없음 | 200 — key에 고정된 구독 적용 |
| `maas-multi-low` 지정, 한도 초과 | 429 |
| 동시점 `maas-multi-high` 지정 | 200 |
| 미소유 구독 지정 | 403 |
| 존재하지 않는 구독 지정 | 403 |
| priority 중복 | `SpecPriorityDuplicate=True` |

## 자동화

```sh
bash harness/remote/scenario26-multi-subscription.sh
```

## 실측 결과 (2026-10-07, sandbox49)

첫 실행에서 `maas-multi-low`는 1회차 200(102 tok) 후 2회차 429였다. 아래는 판정 기준 수정 후 재실행 결과이며,
low 한도(10m 창)가 이미 소진된 상태라 1회차부터 429이다.

```text
== 0) GET /maas-api/v1/subscriptions (주체가 보는 구독) ==
maas-multi-high	priority=10	limit=100000
maas-multi-low	priority=0	limit=100

== 1) API key 발급 시 기본 선택 구독 ==
subscription=maas-multi-high

== 2) x-maas-subscription: maas-multi-low 반복 (한도 100) ==
  #1 HTTP 429 tokens=0

== 3) low 소진 상태에서 ==
x-maas-subscription: maas-multi-high -> 200
SA token, 헤더 없음 -> 403 user has access to multiple subscriptions, must specify subscription using X-MaaS-Subscription heade
API key(구독 maas-multi-high), 헤더 없음 -> 200
x-maas-subscription: maas-multi-other (미소유) -> 403 access denied to requested subscription
x-maas-subscription: does-not-exist -> 403 requested subscription not found

== 4) priority 중복 (low도 10으로) ==
SpecPriorityDuplicate=True spec.priority 10 is shared with: models-as-a-service/maas-multi-high
priority 중복 상태 헤더 없음 -> 403 user has access to multiple subscriptions, must specify subscription using X-Maa

== Assertions ==
PASS  API key 기본 구독 = priority 높은 구독 -> maas-multi-high
PASS  low 지정 시 한도 초과 429 (#1) -> 429
PASS  동시점 high 지정 -> 200
PASS  SA token 헤더 없음 = 구독 명시 요구 -> 403
PASS  API key 헤더 없음 = key에 고정된 high 적용 -> 200
PASS  미소유 구독 지정 -> 403
PASS  존재하지 않는 구독 지정 -> 403
PASS  priority 중복 condition -> True
INFO  priority 중복 상태 헤더 없음 -> 403

RESULT: ALL PASS
```

| 관찰 | 내용 |
|---|---|
| `priority`의 역할 | 요청 시점 선택이 아니라 API key 발급 시 key에 고정할 구독을 결정한다 |
| token 호출 | 다중 구독 주체는 `X-MaaS-Subscription` 헤더가 필수다. 미지정 시 403 `must specify subscription` |
| API key 호출 | key에 구독이 고정되어 헤더 없이 동작한다 |
| 쿼터 분리 | 같은 주체라도 구독별 카운터가 독립적이다 (low 429, high 200) |
| priority 중복 | `SpecPriorityDuplicate=True`로 경고만 하며 생성은 허용된다 |
