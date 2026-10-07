# 시나리오 30: MaaS Gateway 경유 MCP 서버 호출

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** 확인 필요 (RHOAI 3.5)
**관련 컴포넌트:** MaaS Gateway(`mcp` listener), HTTPRoute `mcp-servers/mcp-searxng`, Authorino

## 목적

MaaS Gateway는 모델용 `https` listener 외에 `mcp.apps.<domain>` 호스트의 `mcp` listener를 갖는다.
MCP(Model Context Protocol) 서버 호출에도 모델과 동일한 인증·인가가 적용되는지, 에이전트 Pod가
모델과 도구를 단일 자격 증명으로 사용할 수 있는지 검증한다.

## 구성

| 리소스 | 이름 | 비고 |
|---|---|---|
| Gateway listener | `maas-default-gateway` / `mcp` | `mcp.apps.<domain>:443` |
| HTTPRoute | `mcp-servers/mcp-searxng` | SearXNG MCP 서버 |
| client | 시나리오 21의 `maas-client` SA | |

```sh
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.listeners[*].name}'
oc get httproute mcp-searxng -n mcp-servers -o yaml
oc get authpolicy -n mcp-servers
```

## 절차

1. token 없이 `POST https://mcp.apps.<domain>/mcp` (`initialize`)를 호출한다.
2. 구독 SA token으로 `initialize` → `tools/list` → `tools/call`(검색)을 호출한다.
3. 구독 없는 SA token으로 동일하게 호출한다.
4. MCP 호출에 토큰 쿼터 또는 요청 수 제한이 적용되는지 확인한다.
5. 에이전트 Pod가 같은 SA token으로 모델 호출과 MCP 호출을 연계하는 흐름을 구성한다.

## 판정 기준

| 케이스 | 기대 |
|---|---|
| token 없음 | 401 |
| 구독 SA | 200, `tools/list`에 검색 도구 포함 |
| 구독 없는 SA | 정책 존재 여부를 기록 (MCP 인가가 구독과 연계되는지) |
| 쿼터 | 적용 여부 기록 |

## 자동화

```sh
bash harness/remote/scenario30-mcp-gateway.sh
```

주체: `maas-pod-client/maas-mcp-client`(구독 `maas-mcp-sub`), `maas-pod-client/maas-mcp-nosub`(구독 없음), `maas-mcp-client`로 발급한 API key.
MCP streamable HTTP 흐름(`initialize` → `mcp-session-id` → `notifications/initialized` → `tools/list` → `tools/call`)을 따른다.

## 실측 결과 (2026-10-07, sandbox49)

```text
== 1) initialize — 자격 증명별 ==
none       HTTP 401  
sa-sub     HTTP 200  searxng-mcp 3.3.1
sa-nosub   HTTP 200  searxng-mcp 3.3.1
apikey     HTTP 200  searxng-mcp 3.3.1

== 2) MCP 흐름 (SA maas-mcp-client) ==
session=28769e27002e4384a21ddd26eef02a00
notifications/initialized -> 202
tools/list -> 200 [search-web,fetch-web]
tools/call search-web -> 200 isError=false Search results for 'OpenShift AI' (10 results):  1. Red Hat OpenShift AI [score: 2.0]    URL: https://www.redhat.com/en/products/ai/openshift-ai    Red Hat Open

== 3) 구독 없는 SA로 tools/call ==
tools/call (nosub) -> 200

== 4) 연속 20회 tools/list (요청 수 제한 여부) ==
200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 200 

== 5) 클러스터 내부 Pod에서 Service 직접 호출 (Gateway 우회) ==
direct mcp-searxng:8000/mcp -> 200

== Assertions ==
PASS  token 없음 거부 -> 401
PASS  구독 SA initialize -> 200
PASS  API key initialize -> 200
PASS  tools/list -> 200
PASS  tools/call -> 200
FAIL  구독 없는 SA 거부 (구독 연계 인가) -> 200 (expected 403)
FAIL  구독 없는 SA tools/call 거부 -> 200 (expected 403)
FAIL  Service 직접 호출 차단 -> 200 (expected 000)
INFO  연속 20회 중 429: 0건

RESULT: FAILURES
```

| 관찰 | 내용 |
|---|---|
| 인증 | Gateway 기본 AuthPolicy(`maas-gateway-auth`)가 `mcp` listener에도 적용되어 token 없는 요청은 401. SA token과 MaaS API key 모두 사용 가능 |
| 인가 | MCP는 MaaS 구독과 연계되지 않는다. 구독 없는 SA도 `tools/call`까지 수행한다. 즉 클러스터의 모든 ServiceAccount가 MCP 도구를 사용할 수 있다 |
| 정책 부재 | `mcp-servers` namespace에 AuthPolicy·RateLimitPolicy 없음. `MaaSAuthPolicy`/`MaaSSubscription`은 `MaaSModelRef`만 대상으로 한다 |
| 요청 제한 | 토큰 기반 TokenRateLimitPolicy는 MCP 응답에 `usage`가 없어 집계되지 않으며, 20회 연속 요청에 제한 없음 |
| 우회 | `mcp-searxng:8000`은 클러스터 내부에서 인증 없이 직접 호출된다 (시나리오 23과 동일한 문제) |

## 보완 방안 (미적용)

| 항목 | 방법 |
|---|---|
| 우회 차단 | `mcp-servers`에 `openshift-ingress`발 ingress만 허용하는 `NetworkPolicy` (시나리오 23과 동일 형태) |
| 인가 | HTTPRoute `mcp-searxng`에 대상 Group/SA를 제한하는 `AuthPolicy` 추가 |
| 요청 제한 | HTTPRoute `mcp-searxng`에 주체별 `RateLimitPolicy` 추가 |

```sh
oc get authpolicy,ratelimitpolicy,networkpolicy -n mcp-servers
```
