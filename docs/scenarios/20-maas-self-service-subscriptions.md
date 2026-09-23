# 시나리오 20: Self-service MaaS 구독 확인 탭

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5)
**관련 컴포넌트:** RHOAI(ODS) Dashboard — Gen AI Studio > API Keys

## 목적

시나리오 19가 **관리자**용(Settings > MaaS Governance)이라면, 이 시나리오는 **일반 사용자**용이다.
Gen AI Studio의 API Keys 페이지에 새로 생긴 **Subscriptions 탭**에서, 로그인한 사용자 본인에게 어떤
모델이 할당되어 있고 토큰 Rate Limit이 얼마인지, 그리고 그게 어떤 API Key와 연결되어 있는지를
**관리자에게 묻지 않고 셀프서비스로** 조회할 수 있는지 확인한다. 시나리오 17의 Group Mapping, 19의
관리자 설정이 최종적으로 사용자 입장에서 올바르게 보이는지 확인하는, 파이프라인의 "마지막 검증 지점"에
해당한다.

## 시사점 — 이게 되면 뭐가 좋아지나

- **"내 쿼터 얼마예요?" 문의 티켓이 사라진다.** 이게 없으면 사용자가 자기 한도/구독 모델을 알 방법이
  관리자에게 물어보는 것뿐이다 — 조직이 커질수록 이런 단순 조회성 문의가 플랫폼팀 시간을 갉아먹는다.
  셀프서비스 조회는 이 반복 비용을 구조적으로 없앤다.
- **앱 개발자의 디버깅 루프가 짧아진다.** "이 API Key로 왜 이 모델이 안 되지?"를 애플리케이션 로그와
  대시보드 화면만으로 스스로 확인할 수 있으면, 관리자에게 물어보고 답 기다리는 왕복 시간이 없어진다 —
  통합 작업 자체의 속도가 빨라진다.
- **17/19의 약속을 사용자 눈으로 직접 검증하는 지점이라는 게 핵심 가치.** 관리자 화면(19)에서 맞게
  설정했다고 "믿는" 것과, 실제 사용자 화면(20)에 그대로 보이는 걸 "확인하는" 것은 다르다 — 이 시나리오가
  없으면 파이프라인 전체(IDP 그룹 → 구독 매핑 → UI 반영)가 진짜 끝까지 이어지는지 아무도 모른다.

## 절차

```
0) (사전 준비) 일반 사용자 계정이 없으면 먼저 생성 (htpasswd IDP에 추가 + OpenShift Group
   `maas-basic`/`maas-premium`에 가입까지 한 번에):
   cd openshift-ai-maas-demo/harness && ./harness.sh scenario20-selfservice-user
   (비밀번호는 harness/state/selfservice-user.env에 저장됨, gitignored)
   API로 바로 검증하려면 (브라우저 없이): bash ./local/scenario20-manual-test.sh
1) https://data-science-gateway.apps.myocp.sandbox1314.opentlc.com 접속
   (일반 사용자 계정 — 관리자 아님, 위에서 만든 계정 또는 시나리오 17의 테스트 계정 재사용 가능)
2) Gen AI Studio → API Keys 페이지 진입
3) Subscriptions 탭 이동
4) 확인 항목:
   - 본인 계정(소속 그룹 기준)에 할당된 모델 목록이 실제 구독 상태와 일치하는지
   - 표시되는 토큰 Rate Limit이 시나리오 19에서 관리자가 설정한 값과 일치하는지
   - 이 페이지에 보이는 API Key와, 실제로 시나리오 18에서 쓴 API Key가 같은 것으로 연결되는지
5) (선택) 관리자가 시나리오 19에서 이 사용자의 구독을 변경한 뒤, 별도 조작 없이 새로고침만으로
   이 탭에 최신 값이 반영되는 데 걸리는 시간 확인 (즉시 반영 vs 캐시/지연)
```

## 예상 결과

- 사용자가 관리자 화면에 접근하지 않고도 본인의 모델 구독/쿼터/API Key 연결 현황을 한 곳에서 확인할 수
  있다.
- 관리자가 19에서 바꾼 값과 사용자가 20에서 보는 값이 일치한다(같은 소스를 읽고 있음을 의미).

## 리스크 / 확인 필요

- 19/20이 같은 백엔드 데이터를 읽는지, 아니면 20이 캐시된/지연된 값을 보여줄 수 있는지 — 위 절차 5번의
  반영 지연 여부가 핵심 실측 포인트.

## 실측 결과 (2026-09-23)

`GET /v1/subscriptions`가 Subscriptions 탭이 읽는 것과 정확히 같은 데이터를 반환하는 것을
확인 — 일반 htpasswd 사용자를 OpenShift `Group`(`maas-basic`)에 넣고 그 사용자로 로그인해서
호출하면 관리자가 시나리오 17/19에서 설정한 구독/쿼터가 그대로 보임(HTTP 200). 즉 이 API
호출만으로 브라우저 없이 "관리자 설정 → 사용자 화면 반영"을 검증할 수 있다 —
`local/scenario20-manual-test.sh`가 이걸 자동화한다 (격리된 kubeconfig로 로그인해서 현재 `oc`
세션은 안 건드림).

중요한 발견: 시나리오 17의 Keycloak 그룹(`groups` JWT 클레임)과 이 시나리오의 OpenShift OAuth
그룹은 **서로 다른 메커니즘**이다. `AuthPolicy`의 `openshift-identities` 인증 경로는
`kubernetesTokenReview`가 반환하는 `user.groups`를 쓰는데, 이건 실제 OpenShift `Group` CR
멤버십에서 나온다 — htpasswd 사용자를 아무리 만들어도 `Group`에 넣지 않으면 `/v1/subscriptions`가
빈 배열을 반환한다. `scenario20-selfservice-user.sh`가 사용자 생성과 `Group` 가입을 함께
처리하도록 반영함.
