# 시나리오 22: MaaS 토큰 쿼터 초과 시 차단

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5)
**관련 컴포넌트:** MaaSSubscription(`tokenRateLimits`), TokenRateLimitPolicy, Limitador

## 목적

`MaaSSubscription`에 설정한 토큰 한도가 실제 요청 흐름에서 집행되는지 검증한다. 시나리오 17~21은 한도를
설정만 했을 뿐 초과 상황은 관찰하지 않았다. 본 시나리오는 한도 소진 시 차단, 시간 창 경과 후 복구,
주체 간 한도 독립성을 확인한다.

## 구성

| 리소스 | 이름 | 비고 |
|---|---|---|
| MaaSSubscription | `models-as-a-service/maas-quota-sub` | 낮은 한도 (예: `limit: 200, window: 2m`) |
| MaaSAuthPolicy | `models-as-a-service/maas-quota-access` | 동일 주체 |
| ServiceAccount | `maas-pod-client/maas-quota-a`, `maas-quota-b` | 동일 구독 소유, 한도 독립성 확인용 |
| TokenRateLimitPolicy | `maas-demo/maas-trlp-maas-demo-model` | maas-controller가 생성 |

```sh
oc get tokenratelimitpolicy -A
oc get tokenratelimitpolicy maas-trlp-maas-demo-model -n maas-demo -o yaml
```

## 절차

1. 한도 200 tok/2m 구독을 생성한다.
2. `max_tokens: 64` 요청을 반복 전송하며 응답의 `usage.total_tokens` 누적값과 HTTP 코드를 기록한다.
3. 누적이 한도를 초과한 직후 요청의 HTTP 코드와 응답 헤더(`x-ratelimit-*`, `retry-after`)를 확인한다.
4. 차단 상태에서 `maas-quota-b`로 요청하여 한도가 주체별로 분리되는지 확인한다.
5. 시간 창(2m) 경과 후 `maas-quota-a`의 요청이 다시 200을 반환하는지 확인한다.

## 판정 기준

| 단계 | 기대 |
|---|---|
| 한도 이내 | 200 |
| 한도 초과 | 429 |
| 다른 주체 | 200 (한도 독립) |
| 시간 창 경과 | 200 (복구) |

## 확인 사항

- 차단 기준이 요청 시점(prompt)인지 응답 후(completion 포함 total)인지 — 마지막 허용 요청이 한도를 얼마나 초과하는지로 판단
- 구독 단위 한도인지 주체 단위 한도인지

## 자동화

```sh
bash harness/remote/scenario22-token-quota.sh
QUOTA_LIMIT=500 QUOTA_WINDOW=5m QUOTA_WINDOW_SECONDS=300 bash harness/remote/scenario22-token-quota.sh
```

## 실측 결과 (2026-10-07, sandbox49)

```text
== MaaSSubscription maas-quota-sub: 200 tok / 2m, owners: system:serviceaccount:maas-pod-client:maas-quota-a, system:serviceaccount:maas-pod-client:maas-quota-b ==

== SA maas-quota-a: max_tokens=64 요청 반복 ==
#    HTTP  tokens   cumulative
1    200   102      102
2    200   102      204
3    429   0        204

-- 429 응답 헤더/본문 --
Too Many Requests

== SA maas-quota-b: 동일 구독, 별도 주체 ==
HTTP 200

== SA maas-quota-a: 차단 직후 재요청 ==
HTTP 429

== 시간 창 경과 대기 (125s) 후 SA maas-quota-a 재요청 ==
HTTP 200 (차단 후 131s)

== Assertions ==
PASS  한도 내 요청 성공 (마지막 성공 시 누적 204 tok) -> 200
PASS  한도 초과 시 차단 (#3) -> 429
PASS  차단 직후 재요청 -> 429
PASS  다른 주체 (한도 독립) -> 200
PASS  시간 창 경과 후 복구 -> 200

RESULT: ALL PASS
```

| 관찰 | 내용 |
|---|---|
| 집계 대상 | `usage.total_tokens` (prompt + completion) |
| 차단 시점 | 요청 수신 시 직전까지의 누적값으로 판정. 2번째 요청은 누적 102(<200)에서 허용된 뒤 204로 한도를 초과하였다. 한도 초과폭은 최대 1회 요청분이다 |
| 카운터 단위 | 구독 × 주체(`auth.identity.userid`). 같은 구독의 다른 SA는 영향 없음 |
| 429 응답 | 본문 `Too Many Requests`, `x-ratelimit-*`/`retry-after` 헤더 없음 — client가 복구 시점을 알 수 없다 |

```sh
oc get tokenratelimitpolicy maas-trlp-maas-demo-model -n maas-demo -o yaml   # limits.<sub>-tokens.counters: auth.identity.userid
```
