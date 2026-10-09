# 시나리오 31·31-B 시험 중 발견 사항

[시나리오 31-B](31b-maas-remote-redis-high-load.md)의 결론 도출 과정에서 확인한 제약, 장애 원인, 측정상 유의점을 기록한다.

## 1. MaaS 실경로의 고부하 한계: 인증 단계

### 1.1 부하 단계별 결과 (원격 Redis + `redis-cached`, 모델 replica 5, `max_tokens: 1`)

서버가 받은 부하(전체 req/s)를 기준으로 본다. client는 multi-process 수로 부하를 조절하였다.

| Authorino | client (multi-process) | 수신 부하 (전체 req/s) | 처리 부하 (성공 req/s) | 성공률 | p50 / p95 / p99 ms | Redis 명령/s | 명령/성공 요청 | Mbps | 부하 중 RTT 평균 (최대) ms |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 32 | 224.3 | 223 | 99.5% | 124 / 175 / 213 | 625 | 3.00 | 2.33 | 12.5 (16) |
| 1 | 64 | 250.7 | 105 | 41.8% | 236 / 302 / 322 | 298 | 3.00 | 1.11 | 12.6 (19) |
| 3 | 32 | 210.9 | 210 | 99.6% | 130 / 179 / 212 | 589 | 3.00 | 2.20 | 12.6 (15) |
| 3 | 64 | 307.9 | 285 | 92.4% | 175 / 276 / 306 | 793 | 3.00 | 2.97 | 15.1 (37) |
| 3 | 128 | 420.8 | 156 | 37.1% | 296 / 371 / 411 | 439 | 3.00 | 1.64 | 17.1 (53) |
| 3 | 256 | 523.5 | 73 | 13.9% | 438 / 655 / 803 | 206 | 3.00 | 0.77 | 20.4 (148) |
| 6 | 64 | 266.1 | — | 86.4% | 191 / 309 / 374 | 712 | — | — | 13.1 (18) |
| 6 | 128 | 409.8 | — | 38.9% | 287 / 388 / 456 | 399 | — | — | 15.4 (45) |

원본: `harness/results/scenario31b/2026-10-09-steps-authorino1.log`, `2026-10-09-steps.log`, `2026-10-09-auth6-check.log`

### 1.2 원인

| 관찰 | 내용 |
|---|---|
| 오류 형태 | HTTP 500, upstream 없음, 약 200 ms, 본문 23 byte. Gateway 로그 `kuadrant_wasm_shim: gRPC status code is not OK` |
| 원인 | Kuadrant wasm-shim의 `auth-service`(Authorino) timeout 200 ms 초과 → `failureMode: deny` |
| Redis와의 관계 | 없음. 실패 요청은 Limitador 호출 전에 차단되어 Redis 명령이 발생하지 않음 |

```sh
oc get envoyfilter kuadrant-maas-default-gateway -n openshift-ingress -o yaml   # services: timeout, failureMode
```

| 서비스 | timeout | failureMode | 초과 시 |
|---|---|---|---|
| `auth-service` (Authorino) | 200 ms | `deny` | HTTP 500 |
| `ratelimit-check/report-service` (Limitador) | 100 ms | `allow` | **쿼터 검사 없이 통과** |

### 1.3 자원 확장 시도

| 대상 | 조치 | 결과 |
|---|---|---|
| Authorino | `oc patch authorino authorino -n kuadrant-system` replicas 1 → 3 → 6 | 유지됨. 1 → 3에서 c64 성공률 41.8% → 92.4%, 3 → 6은 효과 없음 |
| maas-api | `oc patch deploy maas-api` replicas 3, CPU limit 2 | **operator가 원복** (`Config/default` 소유, replica 1, limit 500m) |
| Gateway HPA | `oc patch hpa maas-default-gateway-maas-gateway-class` max 20 | **operator가 원복** (Gateway 소유, max 10) |

부하 중 CPU (c128, Authorino 3): Authorino 약 4.5 core, Gateway 10 Pod 3.75 core, maas-api 495m(limit 500m), vLLM Pod당 약 0.47 core, Limitador 105m.
병목 컴포넌트는 인증 경로로 판단되나 단일 원인은 특정하지 못하였다.

## 2. Limitador timeout과 원격 Redis

- Limitador 호출 timeout은 100 ms, `failureMode: allow`이다. Limitador가 100 ms 안에 응답하지 못하면 요청은 **오류 없이 쿼터 검사를 건너뛴다.**
- 요청당 Redis 왕복이 2회이므로 RTT가 수십 ms를 넘으면 위험 구간이다.
- 과부하 구간에서 측정용 Pod의 RTT가 최대 148 ms(MaaS 실경로 c256), 263 ms(시험 B 1,600 연결)까지 증가하였다. 측정 Pod 자체의 CPU 경합 영향인지 회선 경합인지는 구분하지 못하였다.

## 3. `redis-cached`의 효과

- 설계상 `redis-cached`는 Limitador 메모리로 판정하고 Redis에 비동기 반영하지만, 본 구성(TokenRateLimitPolicy)에서는 `redis`와 응답 시간·요청당 Redis 명령 수(3개)가 동일하였다.
- 원격 Redis의 지연(약 RTT × 2)은 두 방식 모두에서 요청 경로에 나타났다.

## 4. ServiceAccount token client의 인증 병목

- SA token으로 수신 부하 약 177 req/s(client multi-process 16개) 시 31,896건 중 401이 28,256건 발생하였다.
- Authorino가 SA token을 요청마다 `kubernetesTokenReview`로 검증하며, 이 단계에는 cache가 없어 kube-apiserver 호출이 시간 초과(`context canceled`)로 실패한다.
- MaaS API key(`sk-oai-`)는 검증 결과가 60초 cache되어 같은 부하에서 정상 동작하였다. 고부하 client는 API key를 사용한다.

## 5. Redis 로그의 TLS 오류

```text
Error accepting a client connection: error:0A000126:SSL routines::unexpected eof while reading (addr= laddr=10.128.1.6:6379)
```

- 5초 간격으로 Redis 기동 시점부터 지속 발생한다. AWS NLB의 TCP health check가 TLS handshake 없이 연결을 닫기 때문이며, 실제 client와 무관하다.
- Service의 `externalTrafficPolicy: Local`로 health check를 별도 포트(kube-proxy)로 돌리면 사라진다.

```sh
oc patch svc redis -n remote-redis -p '{"spec":{"externalTrafficPolicy":"Local"}}'
```

## 6. 원격 Redis 연결 설정

| 항목 | 내용 |
|---|---|
| URL 사용자명 | `rediss://:<pw>@host`(빈 사용자명)는 인증 실패. `rediss://default:<pw>@host` 사용 |
| 인증서 | NLB hostname이 64자를 넘어 인증서 CN에 넣을 수 없음 → SAN에만 기재 |
| Secret 반영 | Limitador는 `limitador-redis-config`의 `URL`을 env(`secretKeyRef`)로 읽으므로 Secret 변경 후 `oc rollout restart deploy/limitador-limitador` 필요 |
| metric | Limitador는 `datastore_latency`를 노출하지 않으며, `batcher_flush_size`는 값이 0으로 사용 불가 |

## 7. 측정상 유의 사항

| 항목 | 내용 |
|---|---|
| CPU 스냅숏 | `*-steps*.log.top`은 부하 시작 전에 채취되어 무효. `2026-10-09-steps-live-top.log`, `*-controls-c32.log.top` 사용 |
| 처리량 계산 | 부하 Pod 생성 시점부터 종료 시점까지의 창으로 계산(소폭 과소 추정) |
| GPU 노드 | 모델 replica 증설 중 rolling update로 cluster autoscaler가 GPU 노드를 일시 추가 |
| `redis-benchmark` | Pod 안의 `timeout`이 `redis-benchmark`를 종료하지 못하는 경우가 있어 고정 명령 수(`-n`)로 실행 |
| Windows 실행 환경 | `oc create token` 출력의 CR·개행 누락, Git Bash 경로 변환(`/tmp/...`), YAML에서 env 이름 `OFF`가 boolean으로 해석되는 문제를 스크립트에서 처리 |

## 8. 원격 Redis의 자원 한계

### 8.1 CPU limit

| CPU limit | 포화 처리량 (MaaS 환산 req/s) | throttling | 관찰 |
|---|---|---|---|
| 1 core | 31,610 | 미측정 | 최초 시험의 상한. 시험용 사양에 의한 값 |
| 4 core, `io-threads 4` | 47,154 | 27–32% | 평균 3.1 core이나 순간 사용량이 limit에 도달 |
| 8 core, `io-threads 4` | 48,771 | 0% | main thread 0.95 core로 포화 |

- CPU limit은 100 ms 주기로 사용량을 제한하므로, 평균 사용률이 limit보다 낮아도 throttling이 발생한다.
- `io-threads`는 대기 중에도 busy-wait로 thread당 약 0.9 core를 점유한다. `oc adm top`의 Redis CPU는 실제 부하보다 크게 보인다.

```sh
oc exec -n remote-redis deploy/redis -- sh -c 'cat /sys/fs/cgroup/cpu.stat'   # nr_periods, nr_throttled
```

### 8.2 memory limit

- memory limit 512Mi, 3,200 연결 부하 중 Redis가 exit 137(SIGKILL)로 종료되고 재시작되었다(4·8 core 시험 모두 3,200 연결 단계 결과 없음).
- 종료 직전 AOF rewrite가 1초 간격으로 반복되었다(fork CoW 52–84 MB).
- 시험 후 Redis에는 벤치마크 key 155,491개(154 MB)가 남아 RSS 264 MB였다. 벤치마크 데이터, 연결별 TLS buffer, AOF rewrite의 fork가 겹쳐 limit을 초과한 것으로 판단한다.
- 실제 Limitador 데이터는 1.23 MB(시나리오 31)이므로 운영 환경과는 조건이 다르다. 벤치마크 후에는 데이터를 삭제한다(`redis-cli FLUSHALL`).
- 재시작 후 Limitador는 자동 재연결되었다(`Ready=True`).

```sh
oc get pod -n remote-redis -l app=redis -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated}'
```

### 8.3 시험 스크립트

- Git Bash에서 `oc exec ... -- cat /sys/...`는 경로가 Windows 경로로 변환된다. `sh -c "cat /sys/..."`로 실행한다.
- 한 단계의 `redis-benchmark`가 실패하면 `set -e`로 스크립트가 출력 없이 종료되어, 실패를 경고로 기록하도록 수정하였다.

