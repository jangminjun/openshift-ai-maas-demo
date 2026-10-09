# 원격 데이터센터 External Redis를 RHCL Limitador 저장소로 사용하는 구성 지침

**대상:** RHOAI MaaS + Red Hat Connectivity Link(RHCL)
**관련 컴포넌트:** Limitador(`kuadrant-system/limitador`), TokenRateLimitPolicy, External Redis
**전제:** OpenShift 클러스터와 Redis가 서로 다른 데이터센터에 있으며, 두 데이터센터는 10 Gbps로 연결된다

## 1. 요지

| 항목 | 결론 |
|---|---|
| 병목 | 대역폭이 아니라 **RTT(왕복 지연)**와 **회선 가용성**이다. 카운터 갱신은 요청당 수백 byte 수준이므로 10 Gbps는 사실상 무관하다 |
| 저장소 방식 | RTT가 약 1 ms 미만이면 `redis`, 그 이상이거나 회선 장애 가능성이 있으면 **`redis-cached`를 권장**한다 |
| 정확도 | `redis-cached`는 지연과 장애 내성을 얻는 대신 쿼터를 `flush-period` 동안 초과 허용할 수 있다 |
| 보안 | 데이터센터 간 구간이므로 `rediss://`(TLS)와 Redis ACL 사용자 인증을 필수로 한다 |

## 2. 요청 경로와 지연

MaaS 요청은 Gateway(Envoy) → Kuadrant wasm-shim → Limitador → Redis 순서로 쿼터를 판정한다.
TokenRateLimitPolicy는 요청 수신 시 한도를 판정하고, 응답 수신 후 `usage.total_tokens`를 반영한다.
따라서 요청 1건당 Limitador 호출은 최대 2회이며, 각 호출은 저장소 방식에 따라 다음과 같이 지연된다.

| 저장소 | 판정 시 Redis 접근 | 요청당 추가 지연 | Redis 단절 시 |
|---|---|---|---|
| `redis` | 매 호출 동기 | 약 RTT × 2 | Limitador 오류 → Gateway 응답 실패 가능 (실측 필요, §6) |
| `redis-cached` | 로컬 캐시 판정, 주기적 비동기 flush | 거의 없음 | 로컬 캐시로 계속 판정, 복구 후 누적분 동기화 |

`redis-cached`는 일시적(transient) 오류 시 `datastore_partitioned=1`로 전환하고 미반영 증가분을 캐시에 보존한다.
인증 실패 등 비일시적 오류에서는 Limitador 프로세스가 종료되므로 URL·자격 증명은 사전에 검증한다.

추론 응답 시간(수백 ms~수 초) 대비 RTT 수 ms는 작지만, `redis` 방식에서는 Redis 장애가 곧 MaaS 장애로 이어진다는 점이 더 중요하다.

## 3. Redis 요구 사항

| 항목 | 지침 |
|---|---|
| 연결 형태 | Limitador는 단일 URL만 받는다. Redis Cluster 모드와 Sentinel에 대한 지원 근거는 없으므로, 장애 조치는 제공자의 단일 endpoint(VIP, Redis Enterprise DB endpoint, 관리형 서비스 등)로 해결한다 |
| 가용성 | 복제본 + 자동 장애 조치. 장애 조치 시간이 `redis` 방식의 MaaS 중단 시간이 된다 |
| 영속성 | 카운터는 window 종료 시 TTL로 만료된다. 긴 window(1h 이상, 일/월 쿼터)를 쓰면 Redis 재시작 시 쿼터가 초기화되므로 AOF(`appendfsync everysec`)를 권장한다 |
| 메모리 정책 | key eviction은 쿼터 초기화와 같다. `maxmemory-policy noeviction`으로 두고 사용량을 모니터링한다 |
| 용량 | key 수 ≈ 구독 × 주체 × 모델 × limit 수. 일반적으로 수십 MB 이내 |
| 공유 | 여러 클러스터가 같은 Redis를 쓰면 클러스터 간 쿼터가 통합된다. 분리하려면 클러스터별 DB 번호 또는 인스턴스를 사용한다 |

## 4. 네트워크 및 보안

| 항목 | 지침 |
|---|---|
| 방화벽 | `kuadrant-system` Limitador Pod → Redis TLS 포트 허용 |
| 출발지 IP 고정 | Redis 측에서 IP 허용 목록을 쓴다면 `kuadrant-system` namespace에 EgressIP를 지정한다 |
| Egress 정책 | EgressFirewall 또는 egress NetworkPolicy가 있다면 Redis 대상으로 예외를 둔다 |
| TLS | `rediss://` 사용. `#insecure`(인증서 미검증)는 운영 환경에서 사용하지 않는다. 사설 CA 서명 인증서를 Limitador가 신뢰하는지는 사전에 시험한다 |
| 인증 | 전용 ACL 사용자를 만든다. 사용자명이 없으면 `default` 사용자로 접속한다 |

```sh
oc get pods -n kuadrant-system -l app=limitador -o wide
oc get egressip
oc get egressfirewall,networkpolicy -n kuadrant-system
```

## 5. 구성

```sh
oc create secret generic redis-config -n kuadrant-system \
  --from-literal=URL='rediss://<user>:<password>@<redis-host>:<port>/<db>'
```

권장 구성(`redis-cached`):

```sh
oc patch limitador limitador -n kuadrant-system --type=merge -p '
spec:
  replicas: 2
  storage:
    redis-cached:
      configSecretRef:
        name: redis-config
      options:
        flush-period: 1000      # ms. 짧을수록 정확, Redis 부하 증가
        response-timeout: 350   # ms. RTT의 수 배 이상으로 설정
        batch-size: 100
        max-cached: 10000
'
```

RTT가 1 ms 미만이고 쿼터 정확도가 최우선이면 `storage.redis.configSecretRef.name: redis-config`를 사용한다.

```sh
oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.storage}{"\n"}'
oc get limitador limitador -n kuadrant-system -o jsonpath='{.status.conditions}{"\n"}'
oc logs -n kuadrant-system -l app=limitador --tail=50
```

### 파라미터 선정

| 파라미터 | 기본값 | 고려 사항 |
|---|---|---|
| `flush-period` | 1000 ms | 초과 허용량 ≈ 전체 replica·클러스터의 초당 토큰 처리량 × (`flush-period` + RTT) |
| `response-timeout` | 350 ms | RTT × 5 이상. 너무 짧으면 순간 지연에도 partition으로 판정된다 |
| `max-cached` | 10000 | 활성 카운터 수(구독 × 주체 × 모델)보다 크게 둔다 |

window가 짧고 한도가 작은 구독(예: 200 tok/2m)일수록 초과 비율이 커지고, 1h 이상 window에서는 무시할 수준이다.

## 6. 인수 시험

| 시험 | 방법 | 기대 결과 |
|---|---|---|
| 연결 | 구성 후 MaaS 추론 요청 | 200, Limitador 로그에 오류 없음 |
| 지연 | 구성 전후 p50/p99 응답 시간 비교 | 증가분 ≈ RTT × 2 이하(`redis`), 거의 없음(`redis-cached`) |
| 쿼터 집행 | 시나리오 22 절차(낮은 한도 구독) | 한도 초과 시 429, window 경과 후 200 |
| replica 간 공유 | Limitador `replicas: 2`에서 시나리오 22 반복 | 한도가 replica 수만큼 늘어나지 않음 |
| Redis 단절 | Limitador Pod egress 차단(아래) 후 요청 | `redis`: 응답 코드 기록, `redis-cached`: 200 유지 및 `datastore_partitioned=1` |
| 복구 | 차단 해제 | `datastore_partitioned=0`, 단절 중 사용량이 Redis에 반영 |
| Redis 장애 조치 | Redis primary 전환 | 중단 시간 기록 |

```sh
oc apply -n kuadrant-system -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-limitador-egress-test
spec:
  podSelector:
    matchLabels:
      app: limitador
  policyTypes: [Egress]
  egress:
  - ports:
    - {protocol: UDP, port: 53}
    - {protocol: TCP, port: 53}
    - {protocol: UDP, port: 5353}
    - {protocol: TCP, port: 5353}
EOF
oc delete networkpolicy deny-limitador-egress-test -n kuadrant-system   # 복구
```

## 7. 운영 감시

| 지표 | 의미 | 경보 기준(예) |
|---|---|---|
| `datastore_partitioned` | `redis-cached`의 Redis 단절 여부 | 1이 1분 이상 지속 |
| `datastore_latency` | Limitador → Redis 지연 | p99 > `response-timeout`의 50% |
| `limited_calls` / `authorized_calls` | 차단·허용 건수 | 차단 비율 급변 |
| Redis `used_memory`, `connected_clients` | Redis 측 용량 | `maxmemory`의 80% |

```sh
oc get servicemonitor,podmonitor -n kuadrant-system
oc exec -n kuadrant-system deploy/limitador-limitador -- curl -s localhost:8080/metrics | grep -E 'datastore_|_calls'
```

Deployment 이름과 metrics 포트는 설치 버전에 따라 다를 수 있으므로 `oc get deploy,svc -n kuadrant-system`으로 확인한다.

## 8. 참고

- [Red Hat Connectivity Link — Configuring Redis storage for rate limiting](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.0/html/installing_connectivity_link_on_openshift/configure-redis_connectivity-link)
- [limitador-operator storage](https://github.com/Kuadrant/limitador-operator/blob/main/doc/storage.md)
- [Limitador server configuration](https://github.com/Kuadrant/limitador/blob/main/doc/server/configuration.md)
