# 시나리오 27: 스트리밍 응답의 사용량 집계

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5)
**관련 컴포넌트:** MaaS Gateway, payload-processing, TokenRateLimitPolicy, Limitador

## 목적

`stream: true` 요청은 응답이 SSE 청크로 분할되어 전송되며, 토큰 사용량은 마지막 청크에만 포함되거나
아예 포함되지 않는다. 스트리밍 응답에서도 토큰 사용량이 쿼터에 반영되는지 검증한다. 반영되지 않으면
스트리밍만 사용하여 쿼터를 무력화할 수 있다.

## 구성

| 항목 | 내용 |
|---|---|
| 구독 | 시나리오 22의 낮은 한도 구독 (200 tok/2m) |
| 요청 A | `stream: true` |
| 요청 B | `stream: true`, `stream_options: {include_usage: true}` |
| 요청 C | `stream: false` (대조군) |

## 절차

1. 요청 C를 반복하여 한도 소진까지의 요청 수 N을 측정한다.
2. 시간 창 경과 후 요청 A를 반복하여 429 발생 여부와 요청 수를 측정한다.
3. 시간 창 경과 후 요청 B로 동일하게 측정한다.
4. 각 경우 클라이언트 측 SSE 수신이 중간 지연 없이 청크 단위로 도착하는지 확인한다 (`curl -N`).

```sh
curl -skN https://maas.apps.<domain>/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"publishers/maas-demo/models/Qwen2.5-1.5B-Instruct","stream":true,"messages":[{"role":"user","content":"Count to 20."}],"max_tokens":64}'
```

## 판정 기준

| 요청 | 기대 |
|---|---|
| C (비스트리밍) | N회 후 429 |
| A (스트리밍) | C와 유사한 횟수 후 429 — 무한히 200이면 집계 누락 |
| B (usage 포함) | C와 유사한 횟수 후 429 |
| SSE 전달 | 청크가 버퍼링 없이 순차 도착 |

## 자동화

```sh
bash harness/remote/scenario27-streaming-usage.sh
```

모드별로 별도 SA(`maas-stream-c/a/b`)와 동일 한도 구독(300 tok/10m)을 사용하여 카운터 간섭 없이 동시 비교한다.

## 실측 결과 (2026-10-07, sandbox49)

```text
== C 비스트리밍 (SA maas-stream-c, 한도 300 tok/10m) ==
#    HTTP  chunks  tokens  TTFB/total usage 출처
1    200   0       102     2.483/2.484s 응답
2    200   0       102     2.221/2.222s 응답
3    429   0       -       0.632/0.633s 없음

== A stream (SA maas-stream-a, 한도 300 tok/10m) ==
#    HTTP  chunks  tokens  TTFB/total usage 출처
1    200   66      102     0.717/2.302s 응답
2    200   66      102     0.712/2.281s 응답
3    200   66      102     0.685/2.249s 응답
4    429   0       -       0.630/0.632s 없음

== B stream+include_usage (SA maas-stream-b, 한도 300 tok/10m) ==
#    HTTP  chunks  tokens  TTFB/total usage 출처
1    200   66      102     0.694/2.261s 응답
2    200   66      102     0.705/2.264s 응답
3    200   66      102     0.755/2.362s 응답
4    429   0       -       0.656/0.657s 없음

== Assertions ==
PASS  C 비스트리밍: 한도 도달 시 429 (#3) -> 429
PASS  A stream: 한도 도달 시 429 (#4) -> 429
PASS  B stream+usage: 한도 도달 시 429 (#4) -> 429

RESULT: ALL PASS
```

C는 직전 중단된 실행에서 1회(102 tok)가 이미 집계되어 있어 3회차에 차단되었다. 세 모드 모두 누적 306 tok 이후 차단된 것으로 결과는 동일하다.

| 관찰 | 내용 |
|---|---|
| 스트리밍 집계 | `stream: true`도 비스트리밍과 동일하게 쿼터에 반영된다. 스트리밍으로 쿼터를 회피할 수 없다 |
| `include_usage` | 지정 여부와 무관하게 마지막 청크에 `usage`가 포함되고 동일하게 집계된다 |
| SSE 전달 | TTFB 약 0.7s, 완료 약 2.3s. Gateway가 응답을 버퍼링하지 않고 청크 단위로 전달한다 (비스트리밍 TTFB 2.4s와 대비) |
| 청크 수 | 64 token 생성에 `data:` 청크 66개 (role, 내용 64, 종료/usage) |
