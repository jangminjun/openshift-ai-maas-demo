# 시나리오 19: 통합 MaaS Governance 관리 페이지

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5)
**관련 컴포넌트:** RHOAI(ODS) Dashboard (rhods-dashboard) — Settings

## 목적

RHOAI 3.4까지는 MaaS 관련 설정(누가 어떤 모델을 구독할 수 있는지, 인가 정책)이 여러 화면/CR에 흩어져
있었다. 3.5는 이걸 **Settings 안의 "MaaS Governance" 단일 탭**으로 통합해서, 관리자가 한 화면에서
**Subscriptions**(그룹별 구독 모델·토큰 제한)와 **Authorization Policies**(인가 규칙)를 같이 보고
고칠 수 있게 한다. 이 시나리오는 기능 자체보다 **관리자 UX가 실제로 통합되어 있는지, 여기서 만든 설정이
실제 MaaS Gateway 동작(시나리오 17/18)에 반영되는지**를 확인하는 데 초점을 둔다.

## 시사점 — 이게 되면 뭐가 좋아지나

- **MaaS 운영이 "CR을 직접 만질 줄 아는 사람"에게 묶여 있지 않게 된다.** 3.4까지는 구독/인가 정책을
  바꾸려면 결국 `oc apply`로 `AuthPolicy`/`RateLimitPolicy` 같은 CR을 직접 만져야 했다 — 즉 플랫폼팀
  엔지니어만 운영할 수 있었다. 단일 UI 탭으로 통합되면 **비즈니스/운영 담당자에게 일상적인 구독 관리
  업무를 위임**할 수 있다 (플랫폼팀은 예외적인/구조적인 변경만 담당).
- **여러 화면·CR을 오가며 상태를 맞춰보지 않아도 된다.** Subscriptions와 Authorization Policies가 따로
  있으면 "이 그룹이 왜 이 모델을 못 쓰지?"를 답하려면 구독 목록과 인가 규칙을 각각 따로 뒤져서 머릿속
  에서 조합해야 한다. 한 탭에 있으면 원인 파악(트러블슈팅) 자체가 빨라진다.
- **변경 이력/실수 위험이 준다.** YAML을 직접 고치는 것보다 UI 폼이 실수(오타, 잘못된 네임스페이스 등)
  여지가 적다 — 운영 안정성 측면의 이득.

## 사전 조건 — 이 화면이 뜨려면 뭐가 설치/활성화돼 있어야 하나

이건 화면에 나타나는 **결과**라서, 그 결과가 뜨려면 아래가 전부 맞아떨어져야 한다. 대부분
이 저장소의 `harness/remote/maas-up.sh`가 이미 자동화해 둔 단계들이라, 그 스크립트의 각
Step과 1:1로 대응시켜 놨다 — 페이지가 안 보이면 이 중 어느 단계가 빠졌는지부터 의심할 것.

1. **RHOAI 3.5 오퍼레이터 + `DataScienceCluster` Ready** — `openshift-aws-harness/harness/harness.sh rhoai`
   (`channel: stable-3.5`로 이미 맞춰둠). 대시보드 자체(`rhods-dashboard`)가 이걸로 뜸.
2. **RHCL(Kuadrant: Authorino + Limitador) 오퍼레이터** — `maas-up.sh` Step 1. Governance 페이지가
   보여주고 고치는 `AuthPolicy`/`RateLimitPolicy` CR들의 컨트롤러가 이 오퍼레이터에서 나온다 — 이게
   없으면 페이지가 뜨더라도 "관리할 대상"(백엔드 CR) 자체가 없다.
3. **`DataScienceCluster`의 `spec.components.aigateway.modelsAsAService.managementState: Managed`** —
   `maas-up.sh` Step 3 (RHOAI 3.4까지는 `kserve.modelsAsService`였음, 3.5에서 개명 —
   `lessonlearn.md` 참고). MaaS 기능 자체의 온/오프 스위치.
4. **`odhdashboardconfig`의 대시보드 기능 플래그** — `maas-up.sh` Step 7,
   `redhat-ods-applications` 네임스페이스의 `odh-dashboard-config`:
   `genAiStudio: true`, `modelAsService: true` (+ `disableModelRegistry: false`,
   `disableModelCatalog: false`, `disableKServeMetrics: false`, `disableLMEval: false`).
   **이게 핵심 스위치다 — 이 두 플래그가 꺼져 있으면 오퍼레이터/CR이 다 정상이어도 Settings 메뉴에
   "MaaS Governance" 항목 자체가 안 보일 가능성이 높다.** 확인: `oc get odhdashboardconfig
   odh-dashboard-config -n redhat-ods-applications -o jsonpath='{.spec.dashboardConfig}'`
5. **대시보드/모델 컨트롤러 재기동** — `maas-up.sh` Step 8 (`odh-model-controller`,
   `kserve-controller-manager` pod 재시작). 위 설정 변경을 컨트롤러가 즉시 못 읽는 경우가 있어 필요.
6. **`system:admin`(cluster-admin) 계정으로 로그인** — Settings 메뉴 자체가 관리자 전용일 가능성이 높음
   (일반 사용자로 접근 시 막히는지는 "리스크" 항목 참고).
7. **(내용이 있으려면) 구독 대상이 될 모델/네임스페이스가 최소 1개 이상 배포되어 있을 것** — 예:
   `./harness.sh scenario18-deploy-model`로 배포한 모델, 또는 시나리오 17에서 만든 그룹
   (`maas-basic`/`maas-premium`)에 매핑될 모델. 없으면 페이지는 뜨지만 Subscriptions 탭이 빈 화면일
   수 있다.

전부 완료됐는지 한 번에 확인: `cd openshift-ai-maas-demo/harness && ./harness.sh scenario19-governance-snapshot`
결과에서 `modelsAsService`가 `Managed`인지, `odhdashboardconfig`에 위 플래그들이 켜져 있는지, AuthPolicy/
RateLimitPolicy가 하나 이상 존재하는지를 먼저 확인한다.

## 절차

```
1) https://data-science-gateway.apps.myocp.sandbox1314.opentlc.com 접속
   (system:admin, OpenShift OAuth 연동 — AGENT.md 참고)
2) (선택, 강력 권장) UI 조작 전 스냅샷: cd openshift-ai-maas-demo/harness && ./harness.sh scenario19-governance-snapshot
3) 좌측 메뉴 Settings → MaaS Governance 진입
4) 통합 탭에서 확인:
   - Subscriptions 탭: 그룹(예: maas-basic, maas-premium)별로 어떤 모델이 할당돼 있고
     토큰 Rate Limit이 얼마인지 조회
   - Authorization Policies 탭: 현재 걸려 있는 인가 규칙 목록 확인
5) 간단한 정책 변경 시연 — 예를 들어 특정 그룹의 토큰 한도를 낮춰서 저장
6) UI 조작 후 스냅샷 다시: ./harness.sh scenario19-governance-snapshot, 두 스냅샷을 diff해서
   실제로 어떤 CR이 바뀌었는지 확인 (이 프로젝트 harness의 자동화 범위 — UI 클릭 자체는 수동)
7) 시나리오 17(외부 OIDC 그룹 매핑)이나 18(모델 라우팅)에서 쓰던 계정으로 다시 요청을 보내,
   방금 UI에서 바꾼 값이 실제로 Gateway 동작(쿼터 초과 시점 등)에 반영됐는지 확인
```

## 예상 결과

- Settings 안에서 별도 페이지 이동 없이 Subscriptions/Authorization Policies를 한 탭에서 전환하며 볼 수
  있다.
- UI에서 바꾼 구독/정책 값이 (시나리오 17/18 재실행 시) 실제 API 동작에 반영된다 — UI가 그냥 읽기 전용
  뷰가 아니라 실제 CR을 쓰고 있어야 함.

## 리스크 / 확인 필요

- 이 페이지가 내부적으로 건드리는 CR이 무엇인지(Authorino `AuthPolicy`/`AuthConfig`, Limitador
  `RateLimitPolicy`, 또는 RHOAI 자체 CRD인지) — UI 조작 전후로 `oc get authpolicy,ratelimitpolicy -A -o yaml`
  등을 diff해서 확인하면 "겪은 이슈"에 기록할 만한 실측 포인트가 나올 가능성 높음.
- 관리자 권한(`system:admin`)이 아닌 일반 사용자가 이 탭에 접근을 시도했을 때 제대로 막히는지(RBAC)도
  가벼운 확인 대상.

## 실측 결과

_(미착수 — `myocp` 클러스터 설치 및 RHOAI 3.5/MaaS 배포 완료 후 진행 예정)_
