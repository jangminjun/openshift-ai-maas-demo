# 시나리오 25: MaaS 신원 헤더 위조 방어

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5)
**관련 컴포넌트:** AuthPolicy `maas-gateway-auth`(`deny-client-identity-headers`), Authorino

## 목적

MaaS Gateway는 인증 후 내부적으로 `x-maas-username`, `x-maas-group` 헤더를 사용하여 주체를 하위
컴포넌트에 전달한다. client가 이 헤더를 직접 주입하여 다른 주체나 상위 구독 Group을 사칭할 수 없는지
검증한다.

## 구성

| 항목 | 내용 |
|---|---|
| 주체 | `maas-pod-client/maas-spoof-nosub` (구독 없음), `maas-pod-client/maas-spoof-good` (구독 `maas-spoof-sub`) |
| 검증 규칙 | `deny-client-identity-headers` — 요청에 `x-maas-username` 또는 `x-maas-group`이 있으면 거부 |

```sh
oc get authpolicy maas-gateway-auth -n openshift-ingress -o yaml | grep -A6 'deny-client-identity-headers'
```

## 절차

구독 없는 SA token으로 다음 요청을 각각 전송한다.

| # | 추가 헤더 |
|---|---|
| 1 | 없음 (대조군) |
| 2 | `x-maas-username: system:serviceaccount:maas-pod-client:maas-client` |
| 3 | `x-maas-group: maas-premium` |
| 4 | `X-MaaS-Group: maas-premium` (대소문자 변형) |
| 5 | `x-maas-subscription: maas-pod-client-sub` (타인 구독 지정) |
| 6 | 구독 SA token + `x-maas-group: maas-premium` (정상 주체의 권한 상승 시도) |

## 판정 기준

| # | 기대 |
|---|---|
| 1 | 403 |
| 2~4 | 403 (헤더 존재만으로 거부) |
| 5 | 403 (타인 구독 사용 불가) |
| 6 | 403 (정상 주체라도 헤더 주입 시 거부) |

## 확인 사항

- vLLM Pod 수신 로그에서 client가 보낸 헤더가 전달되지 않는지
- 시나리오 23 미적용 시 vLLM 직접 호출에는 본 방어가 적용되지 않음

## 자동화

```sh
bash harness/remote/scenario25-identity-header-spoofing.sh
```

주체: `maas-pod-client/maas-spoof-good`(구독 `maas-spoof-sub`), `maas-pod-client/maas-spoof-nosub`(구독 없음).
정상 주체에 대한 헤더 주입(8~10)을 추가로 검증하였다.

## 실측 결과 (2026-10-07, sandbox49)

```text
== 구독 없는 SA (maas-spoof-nosub) ==
1 대조군 (헤더 없음)                                HTTP 403  no matching subscription found for user
2 x-maas-username: 구독 SA 사칭                        HTTP 403  no matching subscription found for user
3 x-maas-group: maas-premium                               HTTP 403  no matching subscription found for user
4 X-MaaS-Group (대소문자 변형)                       HTTP 403  no matching subscription found for user
5 x-maas-subscription: 타인 구독 지정                HTTP 403  access denied to requested subscription
6 username+group+subscription 동시                       HTTP 403  access denied to requested subscription

== 구독 SA (maas-spoof-good) ==
7 대조군 (헤더 없음)                                HTTP 200  {"id":"chatcmpl-3e2f7fa4-c180-4a9b-8c59-4f77840b4cf7","objec
8 정상 주체 + x-maas-group 주입                      HTTP 403  Access denied
9 정상 주체 + x-maas-username 주입                   HTTP 403  Access denied
10 정상 주체 + 자기 구독 x-maas-subscription       HTTP 200  {"id":"chatcmpl-d92fb0c2-5cb7-4453-9aef-d3ce2fc1e042","objec

== Assertions ==
PASS  1 대조군 (헤더 없음) -> 403
PASS  2 x-maas-username: 구독 SA 사칭 -> 403
PASS  3 x-maas-group: maas-premium -> 403
PASS  4 X-MaaS-Group (대소문자 변형) -> 403
PASS  5 x-maas-subscription: 타인 구독 지정 -> 403
PASS  6 username+group+subscription 동시 -> 403
PASS  7 대조군 (헤더 없음) -> 200
PASS  8 정상 주체 + x-maas-group 주입 -> 403
PASS  9 정상 주체 + x-maas-username 주입 -> 403
PASS  10 정상 주체 + 자기 구독 x-maas-subscription -> 200

RESULT: ALL PASS
```

| 관찰 | 내용 |
|---|---|
| 헤더 기반 사칭 | 모든 조합이 거부됨. 주체·Group은 token 검증 결과로만 결정된다 |
| 거부 사유 | 구독 없는 주체는 구독 검사(`no matching subscription`)에서, 정상 주체는 `deny-client-identity-headers`(`Access denied`)에서 거부 |
| `x-maas-subscription` | client 입력이 허용되는 유일한 헤더. 자기 구독 지정은 200, 타인 구독 지정은 `access denied to requested subscription` |
| 대소문자 | HTTP 헤더 이름은 대소문자 무관하게 처리됨 (4) |
