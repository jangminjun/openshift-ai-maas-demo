# 시나리오 24: MaaS API Key 수명주기

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5)
**관련 컴포넌트:** maas-api(`/maas-api/v1/api-keys`), Authorino(`api-keys` identity), maas-db

## 목적

MaaS가 발급하는 `sk-oai-` 형식 API key의 발급, 사용, 폐기 전 과정을 검증한다. API key는 OpenShift
계정이 없는 외부 애플리케이션의 주 자격 증명이므로, 폐기 즉시 무효화되는지와 key 자체로 key 관리 API에
접근할 수 없는지가 핵심이다.

## 구성

| 항목 | 내용 |
|---|---|
| 발급 주체 | `maas-pod-client/maas-apikey-owner` SA (구독 `maas-apikey-sub`) |
| 발급 경로 | Gen AI Studio > API Keys, 또는 `POST /maas-api/v1/api-keys` |
| 검증 규칙 | AuthPolicy `maas-gateway-auth`의 `api-keys`, `deny-api-key-management` |

```sh
oc get authpolicy maas-gateway-auth -n openshift-ingress -o yaml | grep -A6 'deny-api-key-management'
oc get cronjob -n redhat-ai-gateway-infra
```

## 절차

1. 사용자 OpenShift token으로 `POST /maas-api/v1/api-keys`를 호출하여 key를 발급한다.
2. 발급된 key로 `GET /v1/models`, `POST /v1/chat/completions`를 호출한다.
3. 발급된 key로 `GET /maas-api/v1/api-keys`를 호출한다 (자기 key로 key 관리 시도).
4. 사용자 token으로 key를 폐기(`DELETE /maas-api/v1/api-keys/<id>`)한다.
5. 폐기 직후, 그리고 60초 후(Authorino cache ttl) 동일 key로 chat을 호출한다.
6. 만료 기한을 지정한 key가 만료 후 거부되는지, `maas-api-key-cleanup` CronJob이 정리하는지 확인한다.

## 판정 기준

| 케이스 | 기대 |
|---|---|
| 발급 key로 chat | 200 |
| key로 key 관리 API 호출 | 403 |
| 폐기 직후 | 401/403 (cache로 최대 60초 지연 가능) |
| 폐기 60초 후 | 401/403 |
| 형식 위조 key (`sk-oai-xxxx`) | 401/403 |

## 확인 사항

- 폐기 반영 지연 시간 (Authorino `auth-valid` cache ttl 60s)
- key에 연결된 구독(`apiKeyValidation.subscription`)이 고정되는지, 사용자 Group 변경을 따라가는지

## API 형식 (실측)

| 동작 | 요청 | 응답 |
|---|---|---|
| 발급 | `POST /maas-api/v1/api-keys` `{"name":"k1","expiresIn":60}` | 201, `key`·`id`·`subscription`·`expiresAt` |
| 조회 | `POST /maas-api/v1/api-keys/search` `{}` | 200, `data[].status` (`active`/`revoked`) |
| 단건 | `GET /maas-api/v1/api-keys/{id}` | 200 |
| 폐기 | `DELETE /maas-api/v1/api-keys/{id}` | 200, `status: revoked` |

- `expiresIn`은 초(정수) 또는 duration 문자열(`"2m"`)을 받는다. 미지정 시 90일.
- 알 수 없는 필드(`expiration`, `ttl`)는 오류 없이 무시되어 90일 key가 발급된다.
- 발급 시 key는 발급 주체의 구독(`maas-apikey-sub`)에 고정된다.

## 자동화

```sh
bash harness/remote/scenario24-api-key-lifecycle.sh
```

발급 주체는 `maas-pod-client/maas-apikey-owner` SA이다 (OpenShift 사용자 token으로의 발급은 미검증).

## 실측 결과 (2026-10-07, sandbox49, key 일부 마스킹)

```text
== 0) 기존 active key 정리 ==
revoked fe722211-a198-4194-820e-8ad0200faacf (200)
revoked 64ee0942-5691-4cb8-a919-d81b000f6ed2 (200)
revoked e4381bd2-e6e3-48ac-9cab-df27181946e1 (200)
revoked e07eab18-896f-4c4e-8cb5-a9de8aa2a387 (200)

== 1) 발급: K1(기본 만료), K2(expiresIn=60s) ==
{"id":"60835ce1-a1e4-46f0-aa47-36b6016ed76d","keyPrefix":"sk-oai-FtWe39***...","subscription":"maas-apikey-sub","createdAt":"2026-10-06T21:04:27Z","expiresAt":"2027-01-04T21:04:27Z"}
{"id":"bbe3c651-0139-42f5-862f-8963cb1b5a72","keyPrefix":"sk-oai-1TByEH***...","subscription":"maas-apikey-sub","createdAt":"2026-10-06T21:04:29Z","expiresAt":"2026-10-06T21:05:29Z"}

== 2) K1 사용 ==
GET /v1/models -> 200
POST /v1/chat/completions -> 200

== 3) K1으로 key 관리 API 호출 (자기 관리 금지) ==
POST api-keys -> 403
POST api-keys/search -> 403
DELETE api-keys/{K1} -> 403

== 4) 형식만 맞춘 위조 key ==
-> 403

== 5) K1 폐기 후 반영 지연 측정 ==
DELETE (owner) -> 200 status=revoked
  +1s -> 403

== 6) K2 만료 (expiresAt=2026-10-06T21:05:29Z) ==
만료 전 -> 200
  만료 +7s -> 403

== Assertions ==
PASS  발급 (SA token) -> 201
PASS  K1 GET /v1/models -> 200
PASS  K1 chat -> 200
PASS  K1으로 key 발급 금지 -> 403
PASS  K1으로 key 조회 금지 -> 403
PASS  K1으로 key 폐기 금지 -> 403
PASS  위조 key -> 403
PASS  폐기 (owner) -> 200
PASS  폐기 후 거부 (1s 내) -> 403
PASS  K2 만료 전 -> 200
PASS  K2 만료 후 거부 -> 403

RESULT: ALL PASS
```

| 관찰 | 내용 |
|---|---|
| 자기 관리 금지 | key로 발급·조회·폐기 모두 403 (`deny-api-key-management`) |
| 폐기 반영 | 1초 이내. Authorino cache(60s)에도 불구하고 즉시 거부되었다 |
| 만료 반영 | `expiresAt` 경과 직후 첫 요청부터 거부 |
| 무효 key 응답 코드 | 위조·폐기·만료 모두 401이 아닌 403 |
