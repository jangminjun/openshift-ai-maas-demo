# 시나리오 29: 테넌트 간 Gateway 격리

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5)
**관련 컴포넌트:** AITenant, MaaS Gateway, AuthPolicy `maas-gateway-auth`(`tenant-gateway-isolation`)

## 목적

복수의 `AITenant`가 각자 Gateway를 보유할 때, 한 테넌트에서 발급된 API key로 다른 테넌트의 Gateway를
호출할 수 없는지 검증한다.

현재 AuthPolicy의 `tenant-gateway-isolation` 규칙은 다음과 같은 stub이다.

```rego
# Tenant hostname isolation stub.
# Replace with a real maas-api call to validate that the API key's tenant
# matches the gateway hostname (prevents Coke key on Pepsi gateway).
allow { true }
```

본 시나리오는 이 stub에도 불구하고 실제 격리가 성립하는지를 교차 호출로 확인한다. 실측 결과 격리는 key 검증·route·구독 reconcile 단계에서 성립하였다.

## 구성

| 리소스 | 테넌트 A | 테넌트 B |
|---|---|---|
| AITenant | `ai-tenants/models-as-a-service` (기존) | `ai-tenants/tenant-b` (신규) |
| Gateway host | `maas.apps.<domain>` | `maas-b.apps.<domain>` |
| API key | key-A | key-B |

```sh
oc get aitenant -A
oc get gateway -n openshift-ingress
oc get authpolicy -n openshift-ingress -o yaml | grep -B2 -A6 'tenant-gateway-isolation'
```

## 절차

1. 테넌트 B를 생성한다 (생성 절차 자체가 지원되는지 함께 기록).
2. 각 테넌트에서 API key를 발급한다.
3. key-A로 Gateway B를, key-B로 Gateway A를 호출한다.
4. ServiceAccount token(시나리오 21)으로 양쪽 Gateway를 호출한다.

## 판정 기준

| 케이스 | 기대 | 실측 |
|---|---|---|
| key-A → Gateway A | 200 | 200 |
| key-A → Gateway B | 403 | 403 |
| key-B → Gateway A | 403 | 403 |
| tenant B 구독이 tenant A 모델 참조 | 거부 | `Failed` |

## 자동화

```sh
bash harness/remote/scenario29-tenant-isolation.sh                 # 종료 시 tenant B 삭제
KEEP_TENANT=1 bash harness/remote/scenario29-tenant-isolation.sh   # tenant B 유지
```

tenant B의 Gateway는 별도 AWS ELB를 생성하며 DNS 레코드가 없으므로 `curl --connect-to <ELB>`로 접근한다.
ELB는 Gateway `Programmed` 이후 약 40초~수 분 뒤 응답을 시작한다. AITenant 삭제 시 tenant namespace(`ai-tenant-tenant-b`)는 남는다.

## AITenant 생성 시 자동 생성 리소스 (실측)

| 리소스 | 이름 |
|---|---|
| tenant namespace | `ai-tenant-tenant-b` (`MaaSTenantConfig default-tenant` 포함) |
| AuthPolicy | `openshift-ingress/maas-tenant-b-gateway-maas-auth` |
| TokenRateLimitPolicy | `openshift-ingress/gateway-default-deny-tenant-b` |
| HTTPRoute | `redhat-ai-gateway-infra/maas-api-route-tenant-b` → Service `maas-api-tenant-b` (maas-api Deployment은 공유) |

## 실측 결과 (2026-10-07, sandbox49)

```text
== 1) Tenant B: Gateway maas-tenant-b-gateway (maas-b.apps.myocp.sandbox49.opentlc.com) + AITenant tenant-b ==
gateway.gateway.networking.k8s.io/maas-tenant-b-gateway created
aitenant.maas.opendatahub.io/tenant-b created
NAME                  READY   TENANT NAMESPACE      GATEWAY                 AGE
models-as-a-service   True    models-as-a-service   maas-default-gateway    21h
tenant-b              True    ai-tenant-tenant-b    maas-tenant-b-gateway   28s
tenant B namespace=ai-tenant-tenant-b, ELB=ab30337cece6246af8a67a66fdf2281b-988800888.us-east-1.elb.amazonaws.com
ELB 응답 시작: 42s
생성된 정책: authpolicy.kuadrant.io/maas-tenant-b-gateway-maas-auth tokenratelimitpolicy.kuadrant.io/gateway-default-deny-tenant-b 

== 2) 구독: A(models-as-a-service), B(ai-tenant-tenant-b) — 둘 다 maas-demo/maas-demo-model 참조 ==
maas-tenant-b-sub phase=Failed: failed to reconcile TokenRateLimitPolicies: model maas-demo/maas-demo-model is not attached to tenant gateway for subscription ai-tenant-tenant-b/maas-tenant-b-sub: HTTPRoute maas-demo/maas-demo-model-kserve-route does not reference tenant Gateway openshift-ingress/maas-tenant-b-gateway

== 3) API key 발급 (B는 생성 직후 일시 500 가능 — 최대 6회 재시도) ==
key-A on A: 201 subscription=maas-tenant-a-sub
key-B on B (try 1): 201
key-B subscription=maas-tenant-b-sub

== 4) 교차 호출 ==
key-A → Gateway A chat                     HTTP 200  {"id":"chatcmpl-f213d9c6-d972-468d-ad96-fabb0767d8c9","object":"chat.c
key-A → Gateway B /v1/models               HTTP 403  
key-A → Gateway B chat                     HTTP 404  
key-B → Gateway A /v1/models               HTTP 403  
key-B → Gateway A chat                     HTTP 403  
key-B → Gateway B /v1/models               HTTP 500  {"error":{"message":"Failed to select subscription","type":"server_err
SA token A → Gateway B /v1/models          HTTP 200  {"data":[],"object":"list"}
SA token A → Gateway B chat                HTTP 404  
SA token B → Gateway A chat                HTTP 403  no matching subscription found for user

== Assertions ==
PASS  B 구독이 A 모델 참조 시 거부 (phase) -> Failed
PASS  key-A 발급 -> 201
PASS  key-B 발급 -> 201
PASS  key-A → A chat -> 200
PASS  key-A → B 거부 -> 403
PASS  key-A → B chat 거부 -> 404
PASS  key-B → A 거부 -> 403
PASS  key-B → A chat 거부 -> 403
PASS  SA token A → B chat (route 없음) -> 404
PASS  SA token B → A chat (구독 없음) -> 403
INFO  key-B → B /v1/models -> 500 (Failed 구독에 묶인 key)
INFO  SA token A → B /v1/models -> 200

RESULT: ALL PASS
KEEP_TENANT=1: tenant-b 유지
```

| 관찰 | 내용 |
|---|---|
| API key 격리 | key는 발급 tenant에 귀속된다. 타 tenant Gateway에서 양방향 403. AuthPolicy의 `tenant-gateway-isolation` stub(`allow { true }`)과 무관하게 key 검증 단계에서 격리된다 |
| 모델 격리 | 모델 HTTPRoute가 붙은 Gateway에서만 라우팅된다 (tenant B Gateway에서 404) |
| 구독 격리 | 타 tenant Gateway에 붙은 모델을 참조하는 `MaaSSubscription`은 `Failed`로 거부된다 |
| SA token | tenant 귀속이 없어 어느 Gateway에서도 인증은 통과한다(`/v1/models` 200, 빈 목록). 인가는 해당 tenant의 구독·route로 제한된다 |
| 결함 1 | `Failed` 구독으로도 API key가 발급되며, 그 key는 `/v1/models`에서 500 `Failed to select subscription`을 반환한다 |
| 결함 2 | tenant 생성 직후 key 발급이 일시적으로 500을 반환한다 (wasm-shim `gRPC status code is not OK`, 이후 정상) |
