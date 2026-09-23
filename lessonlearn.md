# Lessons Learned — myocp / sandbox harness 운영 기록

`myocp` 클러스터를 대상으로 `openshift-aws-harness` harness를 운영하며 발견한 버그와 이슈들.
비밀정보는 없음 — 이 파일은 git으로 추적됨. 실시간 접속 정보와 현재 상태는 `AGENT.md`
(gitignored)에 있음.

## 2026-09-23 — G/VT vCPU 쿼터, 예전 기록(4)과 다름 (실측 16)

이전 기록엔 "쿼터=4, g4dn.xlarge 1대가 한계"라고 돼 있었지만, `aws service-quotas
get-service-quota --service-code ec2 --quota-code L-DB2E81BA`로 재확인하니 16이었다.
sandbox 계정이 회전되면서 쿼터도 바뀐 것. 두 번째 g4dn.xlarge를 문제없이 추가함.
**교훈**: 계정 종속 쿼터는 캐시된 기록 대신 매번 재확인.

## 2026-09-23 — 공식 vLLM 커뮤니티 CPU 이미지, 실제 채팅 요청에서 무한 루프 (미해결, 포기)

RHOAI 3.5 프리셋엔 CPU 전용 vLLM 이미지가 없어서 `public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:latest`를
시도. 컨테이너 시작/헬스체크/워밍업은 정상인데, 실제 `/v1/chat/completions` 요청만 오면
`EngineCore` 프로세스가 CPU 90%+로 무한정 돎(응답 없음, `shm_broadcast` 경고 반복).
`VLLM_ENABLE_V1_MULTIPROCESSING=0`도 효과 없음. Gateway/Authorino 없이 vLLM Service를
클러스터 내부에서 직접 호출해도 동일 — 100% 이미지/엔진 자체 버그로 결론, 조사 중단.
GPU 워커를 하나 더 추가해 두 번째 모델도 GPU로 전환(위 쿼터 항목). **교훈**: RHOAI가
지원 안 하는 하드웨어 조합은 헬스체크 통과와 실제 추론 처리를 별개로 검증할 것.

## 2026-09-22 — 모델 배포 시 `odh-model-controller`가 MaaS AuthPolicy를 가로챔 (해결, 자동화됨)

모델이 `maas-default-gateway`에 붙는 순간 `odh-model-controller`가 자기 AuthPolicy(`kubernetesTokenReview`만 지원)를
만들고, Kuadrant가 이걸 `Enforced`로, MaaS AuthPolicy를 `Overridden`으로 표시 —
Keycloak 연동이 spec엔 남아있지만 비활성화됨.

**조치**:
```sh
oc annotate gateway maas-default-gateway -n openshift-ingress \
  opendatahub.io/managed="false" \
  security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
```
`monitoring-llmd-rhoai/harness/remote/maas.sh` Step 7에 자동화됨(모델 배포 전에 미리 적용).
**교훈**: `maas-*` AuthPolicy가 갑자기 죽으면 `Overridden` 여부부터 확인 — 자기 설정이
깨진 게 아니라 경쟁 정책이 이긴 것일 수 있음.

## 2026-09-23 — Authorino→`maas-api` mTLS 403 (해결, 자동화됨)

`GET /v1/models`는 200인데 `POST .../v1/chat/completions`만 403. 원인: AuthPolicy의
`subscription-valid` 규칙에서 Authorino가 직접 `maas-api`로 mTLS 호출을 거는데, `maas-api`
서빙 인증서가 OpenShift 내부 `openshift-service-serving-signer` CA로 서명돼 있고 이 CA가
Authorino의 신뢰 번들(`authorino-extra-ca` ConfigMap, `kuadrant-system`)에 없어서 서버
인증서를 못 믿고 `bad_certificate` 발생. (Keycloak 라우터 CA 때와 같은 유형의 문제.)

확인: `openssl x509 -noout -issuer`로 서명 CA 확인 → `authorino-extra-ca`에 있는지
`openssl crl2pkcs7 -nocrl -certfile <bundle> | openssl pkcs7 -print_certs -noout`으로
대조(PEM은 base64라 `grep "CN=..."` 직접 걸면 항상 실패함 — 자동화 스크립트 초안에서
이 실수로 CA가 중복 추가되는 버그가 났었음).

**조치**: `openshift-config-managed/service-ca` ConfigMap의 CA를 `authorino-extra-ca`에
추가(기존 값 유지) → Authorino 재시작.

**자동화됨**: `./harness.sh scenario17-authorino-trust-ca`
(`harness/remote/scenario17-authorino-trust-ca.sh`) — 라우터 CA + service-ca CA를
멱등적으로 확인/추가하고 Authorino CR 마운트도 패치. 클러스터 재구축 시(CA 값이 매번
바뀜) 시나리오 17 절차에 포함해서 실행할 것.

## 2026-09-22 — 에러 코드만으로 "인증 성공"을 추론하면 안 됨; 진짜 원인은 Envoy→Authorino gRPC 실패

유효한 토큰으로 `/v1/models` 호출 시 `HTTP 500`을 보고 "인증은 통과했다"고 추론했으나
틀림 — 토큰 없이도 동일한 500이 나왔음(사용자가 지적: "500 뜨는게 왜 성공?"). 실제 원인은
`kuadrant-wasm-shim: gRPC status code is not OK` — Envoy의 Kuadrant wasm 필터가
Authorino/Limitador 호출 자체에서 실패(양쪽 로그 모두 요청 도달 흔적 없음). 근본 원인:
`kuadrant-auth-maas-default-gateway` EnvoyFilter가 Authorino authorization 클러스터를
평문(plaintext)으로 패치하는데, `maas.sh`의 옛 "Step 2: Authorino TLS"가
`Authorino.spec.listener.tls.enabled: true`를 켜놔서 불일치.

**조치**: `oc patch authorino authorino -n kuadrant-system --type=merge -p '{"spec":{"listener":{"tls":{"enabled":false}}}}'`

**교훈**: 에러 *코드*만으로 그럴듯한 추론을 하지 말고 실제 판정 로그(Authorino 등)를
직접 확인할 것. 서로 다른 입력(토큰 있음/틀림/없음)에서 증상이 동일하면 분기 로직 자체에
도달 못 한 것일 확률이 높음 — 다운스트림뿐 아니라 업스트림도 볼 것.

## 2026-09-22 — Authorino의 self-signed 라우트 CA 신뢰: CRD 전용 필드가 아니라 실제 CA 번들 파일을 교체해야 함; Keycloak도 `proxy.headers: xforwarded` 필요

Keycloak이 edge TLS Route 뒤에 있어 클러스터 라우터 CA로 서명된 인증서가 보이는데,
Authorino 컨테이너의 시스템 CA 풀엔 없음 (`x509: certificate signed by unknown authority`
반복). `AuthPolicy`/`Authorino` CRD엔 "extra CA 신뢰" 전용 필드가 없고
`spec.volumes`는 디렉터리 단위 마운트만 지원(단일 파일 mountPath는 `Not a directory`로
실패).

**조치**: Go가 실제로 읽는 심볼릭 링크 대상 디렉터리(`/etc/pki/ca-trust/extracted/pem`,
Authorino 자신의 서빙 인증서가 있는 `/etc/pki/tls/certs`가 아님)에 ConfigMap을 마운트 —
기존 번들 + 라우터 CA(`oc get secret router-ca -n openshift-ingress-operator`)를 합쳐서
추가.

이어서 issuer 스킴 불일치(`expected https got http`) 발생 — Keycloak이 평문 HTTP로
실행되고 edge에서만 TLS 종료되는데 그 사실을 모름. **조치**:
`oc patch keycloak maas-keycloak -n maas-keycloak --type=merge -p '{"spec":{"proxy":{"headers":"xforwarded"}}}'`

**교훈**: edge/reencrypt TLS 뒤의 모든 RHBK/Keycloak은 처음부터
`spec.proxy.headers: xforwarded` 필요. 내부 CA 신뢰 전용 필드가 없으면 Go가 실제로 읽는
파일을 찾아 그 파일만 교체(공유 디렉터리 전체를 갈아치우지 말 것).

## 2026-09-22 — RHOAI 3.5 MaaS: `maas.sh`가 안 해주는 3가지 (Gateway, TLS cert, Postgres)

`./harness.sh maas`가 exit 0이어도 MaaS가 실제로 안 됨. 컨트롤러 로그/상태 조건으로
확인한 3가지 원인:
1. `maas-default-gateway`(정확히 이 이름, `openshift-ingress`)가 자동 생성 안 됨 — 스크립트가
   만든 `openshift-ai-inference` Gateway와는 별개.
2. TLS secret(`default-gateway-tls`)이 없음 — `status.conditions`가 아니라
   `status.listeners[].conditions`를 봐야 `Bad TLS configuration`이 보임. 클러스터 기본
   `router-certs-default`로 해결.
3. `maas-api`용 Postgres/secret(`maas-db-config`)이 없음 — 임시 단일 파드 Postgres로 해결.

세 가지 모두 `monitoring-llmd-rhoai/harness/remote/maas.sh`에 반영(Step 4/4b)돼 새
클러스터는 안 겪음. **교훈**: 상위 레벨 "Ready"만 보지 말고 하위 리소스 상태 조건과
컨트롤러 로그를 직접 확인할 것.

## 2026-09-22 — RHOAI 3.5: `kserve.modelsAsService` → `aigateway.modelsAsAService` 개명

`./harness.sh maas`가 `modelsAsService is deprecated; cannot re-enable once Removed`로
실패. RHOAI 3.3/3.4의 필드가 3.5에서 `spec.components.aigateway.modelsAsAService`로
이동(`oc explain`으로 확인, "AsA" 철자는 오타 아님). `default-dsc`를 새 경로로 패치하고
`maas.sh` Step 3을 업데이트. **교훈**: 컴포넌트가 마이너 버전 사이에서 이동하면 `oc
explain`이 가장 빠른 확인 방법 — 옛 문서로 추측하지 말 것.

## 2026-09-22 — `wait-cluster`의 SSH 실패는 연결 문제일 뿐, 설치 실패가 아닐 수 있음

`wait-cluster`가 exit 255로 실패 보고됐지만, 실제로는 SSH 세션이 끊기기 37분 *전에* 이미
`openshift-install`이 "Install complete!"를 출력한 상태였음(원인 불명의 일시적 네트워크
끊김). **교훈**: 장기 실행 원격 tail의 exit-255는 연결 실패이지 원격 프로세스 실패가
아닐 수 있음 — 다시 접속해서 실제 로그/상태를 확인하고 결론 낼 것.

---

## 2026-09-22 — `bastion-up`은 다른 머신에서 실행하면 불일치하는 SSH 키를 조용히 import함

SSH가 `Permission denied`로 실패. 원인: `cmd_bastion_up`이 AWS에 키페어가 이미 있으면
로컬 키와 일치하는지 검증 없이 그냥 재사용 가정 — 환경 A에서 처음 만든 키와 환경 B의
로컬 키가 다르면 B는 SSH 실패할 때까지 이 사실을 모름. (SHA256 지문 대조로 확인,
`describe-key-pairs --include-public-key`가 실제 비교엔 더 확실함.)

**조치**: `destroy-bastion --yes` 후 올바른 키를 가진 머신에서 `bastion-up` 재실행.
**가드 추가**: `cmd_bastion_up`이 이제 재사용 전 로컬 `.pub`과 AWS 등록 키를 비교해서
불일치하면 즉시 `err` (아직 미커밋, 로컬 트리에만 있음).

## 2026-09-22 — 머신별 `state/<cluster>.env`는 sandbox 교체 시 오래된 값으로 남음

`state/myocp.env`가 9월 8일자 죽은 sandbox의 리소스 ID를 갖고 있었는데, 다른 세션은 회전된
계정 위에 완전히 새 bastion을 만들어놓은 상태였음 — state 파일은 머신별/gitignore라 서로
조정되지 않음. **조치**: 실제 AWS 리소스와 대조 후 덮어씀(백업 후). **교훈**: sandbox
회전 후나 다른 세션이 시작한 작업을 이어받을 땐 `harness.sh status`로 먼저 검증할 것.

## 2026-09-22 — `create-cluster`가 network/LB/IAM까지만 만들고 인스턴스 0개로 멈출 수 있음

`harness.sh all` 시작 2시간 뒤에도 EC2 인스턴스가 0개, CloudTrail에 `RunInstances` 없음.
근본 원인 미확인(SSH 키가 깨져 있어 bastion 로그를 못 봄). **교훈**: 멈춘 것처럼 보이면
AWS 리소스 타임스탬프+CloudTrail부터 확인. 가능하면 무언가 정리하기 전에 bastion
접속(SSH/SSM)으로 실제 install 로그부터 확보할 것.
