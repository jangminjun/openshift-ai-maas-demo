# 시나리오 32: 원격 region Redis 장애 시 MaaS 동작

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5, RHCL 1.4)
**관련 컴포넌트:** Limitador(`spec.storage`), External Redis, NetworkPolicy
**선행:** [시나리오 31](31-maas-remote-redis-latency.md)의 원격 Redis 구성

## 목적

원격 Redis와의 회선 단절, Redis 재시작 등 장애 상황에서 MaaS 요청 처리와 쿼터 집행이 어떻게 되는지 확인한다.
고객에게 "회선 장애가 서비스 장애로 이어지는가"에 대한 답을 실측으로 제시하는 것이 목적이다.

## 구성

시나리오 31과 동일하다. 회선 단절은 MaaS 클러스터에서 Limitador Pod의 egress를 NetworkPolicy로 차단하여 재현한다.
즉시 적용되고 해제도 즉시 되므로 단절 시간을 정확히 통제할 수 있다.

```sh
oc apply -n kuadrant-system -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: limitador-redis-cut
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
oc delete networkpolicy limitador-redis-cut -n kuadrant-system     # 복구
```

## 시험 항목

| # | 상황 | 방법 | 확인 |
|---|---|---|---|
| F1 | 회선 단절 60초 (`redis-cached`) | 부하 중 NetworkPolicy 적용 → 60초 후 삭제 | HTTP 코드, `datastore_partitioned`, 복구 후 Redis 카운터 반영 |
| F2 | 회선 단절 중 쿼터 집행 | 낮은 한도 구독(시나리오 22)으로 단절 중 요청 | 단절 중에도 429가 집행되는지 |
| F3 | 회선 단절 중 Limitador 재시작 | 단절 상태에서 `oc rollout restart deploy/limitador-limitador` | Pod Ready 여부, MaaS 요청 처리 |
| F4 | 회선 단절 (`redis`, 대조군) | 저장소 방식을 `redis`로 바꾸고 F1 반복 | client가 받는 HTTP 코드 |
| F5 | 원격 Redis 재시작 | 원격 클러스터에서 `oc rollout restart deploy/redis -n remote-redis` | 재시작 중 MaaS 응답, 재시작 후 카운터 유지(AOF + PVC) |

## 판정 기준

| # | 기대 결과 | 고객 전달 의미 |
|---|---|---|
| F1 | 단절 중 200 유지, `datastore_partitioned` 1 → 0, 복구 후 카운터 반영 | 회선 장애가 서비스 장애로 이어지지 않음 |
| F2 | 단절 중에도 Limitador 1개 기준으로는 쿼터 집행 | 단절 중 쿼터는 Limitador별로 느슨해질 뿐 해제되지 않음 |
| F3 | 결과 기록 (사전 기대값 없음) | 운영 절차(장애 중 재시작 금지 여부)에 반영 |
| F4 | 결과 기록 | `redis-cached`를 권장하는 근거 |
| F5 | 재시작 후 카운터 유지 | Redis에 AOF + PVC가 필요한 근거 |

## 자동화

미작성. 시나리오 31 스크립트(`scenario31-limitador-redis-switch.sh`, `scenario31-remote-redis-load.sh`)를 재사용한다.

## 실측 결과

(시나리오 31 완료 후 수행)
