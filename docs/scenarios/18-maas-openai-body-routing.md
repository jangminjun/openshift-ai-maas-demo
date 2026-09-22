# 시나리오 18: OpenAI 호환 Body 기반 모델 라우팅

**모듈:** 서빙 및 추론 > MaaS
**지원 단계:** GA (RHOAI 3.5)
**관련 컴포넌트:** MaaS Gateway, 표준 OpenAI SDK

## 목적

지금까지(시나리오 13 등)는 모델마다 **URL 경로**(`/<namespace>/<model-name>/v1/chat/completions`)가
달라서, 모델을 바꾸려면 클라이언트 쪽 `base_url`을 매번 바꿔야 했다. 이 시나리오는 **URL은 고정**하고,
표준 OpenAI 클라이언트가 늘 보내는 요청 Body의 `model` 필드값만으로 MaaS Gateway가 실제 백엔드
모델/네임스페이스를 자동으로 찾아 라우팅하는지 검증한다. 부가로 그 라우팅 결과에 따라 구독 확인/비용
계산/인가 정책(시나리오 17의 쿼터 등)이 **모델별로** 올바르게 갈리는지도 함께 본다.

이게 되면 기존에 OpenAI API용으로 작성된 애플리케이션/SDK 코드를 **엔드포인트 URL 한 줄만** 바꿔서 그대로
MaaS에 붙일 수 있다는 뜻이라, llm-d 자체 시나리오(11~16)보다 사실 "붙이기 쉬움"이라는 실용적 가치가 큰
기능이다.

## 절차

### 0) 전/후 비교 — 왜 이게 "URL 안 바꿔도 된다"는 뜻인지 코드로 확인

**이전 (RHOAI 3.4까지, 경로 기반) — 모델을 바꾸려면 `base_url` 자체를 바꿔야 했다:**

```python
from openai import OpenAI

# 모델 A 호출 — base_url 안에 namespace/model 이름이 박혀 있음
client_a = OpenAI(
    base_url="https://maas.apps.myocp.sandbox1314.opentlc.com/llmd-scenario11/model-a",
    api_key="<MaaS API Key>",
)
resp_a = client_a.chat.completions.create(
    model="model-a",  # SDK가 요구하니 넣긴 하지만, 실제 라우팅은 base_url이 결정
    messages=[{"role": "user", "content": "ping from model A"}],
)

# 모델 B로 바꾸려면 client를 통째로 다시 만들어야 함 — base_url이 다르므로
client_b = OpenAI(
    base_url="https://maas.apps.myocp.sandbox1314.opentlc.com/llmd-scenario12/model-b",
    api_key="<MaaS API Key>",
)
resp_b = client_b.chat.completions.create(
    model="model-b",
    messages=[{"role": "user", "content": "ping from model B"}],
)
```

**이후 (RHOAI 3.5, Body 기반) — `client`는 한 번만 만들고, 이후로는 `model` 값만 바꾼다:**

```python
from openai import OpenAI

# client 하나 — base_url에 모델 정보가 전혀 없음, 이후 절대 안 바뀜
client = OpenAI(
    base_url="https://maas.apps.myocp.sandbox1314.opentlc.com/v1",
    api_key="<MaaS API Key>",
)

resp_a = client.chat.completions.create(
    model="model-a",  # 라우팅을 실제로 결정하는 건 이제 이 값
    messages=[{"role": "user", "content": "ping from model A"}],
)
resp_b = client.chat.completions.create(
    model="model-b",  # client 재생성 없이 모델만 교체
    messages=[{"role": "user", "content": "ping from model B"}],
)
```

**차이가 의미하는 것**: 이전 방식은 클라이언트 코드가 "어떤 모델을 쓸지"를 **연결 설정(`base_url`)** 으로
표현해야 했다 — 즉 모델 카탈로그가 바뀔 때마다 애플리케이션의 설정/코드를 건드려야 했음. 이후 방식은
그걸 **매 요청의 데이터(`model` 필드)** 로 옮겨서, 클라이언트는 한 번 설정한 뒤로 다시 안 건드리고
모델 선택을 런타임 값으로 다룰 수 있다 — 기존 OpenAI API 기반 앱을 그대로 얹을 수 있는 이유가 이것.

### 1) 실제 실행

```sh
pip install openai  # 이미 있으면 생략

python3 - <<'PY'
from openai import OpenAI

client = OpenAI(
    base_url="https://maas.apps.myocp.sandbox1314.opentlc.com/v1",  # 모델별 경로 없이 고정
    api_key="<MaaS API Key>",
)

# 모델 A 호출 — URL 그대로, model 필드만 바꿔서 전송
resp_a = client.chat.completions.create(
    model="<모델A 식별자>",
    messages=[{"role": "user", "content": "ping from model A"}],
)
print("A:", resp_a.choices[0].message.content)

# 모델 B 호출 — 코드상 base_url 변경 없음, model 필드만 교체
resp_b = client.chat.completions.create(
    model="<모델B 식별자>",
    messages=[{"role": "user", "content": "ping from model B"}],
)
print("B:", resp_b.choices[0].message.content)
PY
```

검증 포인트:
1. 위 두 호출이 `base_url`을 전혀 바꾸지 않고도 서로 다른 백엔드 모델에 도달하는지
   (응답 내용/모델 자체 정체성으로 구분, 또는 각 모델 pod 로그에서 요청 수신 확인)
2. `model` 필드에 **구독하지 않은/존재하지 않는** 모델명을 넣었을 때 명확한 에러(404 또는 인가 거부)로
   응답하는지 — 조용히 엉뚱한 모델로 라우팅되면 안 됨
3. 모델별로 서로 다른 쿼터/구독이 걸려 있다면(예: 모델A는 premium 전용), Body 기반 라우팅에서도 그
   정책이 그대로 적용되는지

## 예상 결과

- 클라이언트 코드는 `base_url` 한 번만 설정하고, 이후 모델 전환은 순수하게 요청 Body의 `model` 값만으로
  이루어진다.
- 존재하지 않거나 구독 안 된 모델명은 명확한 에러로 막힌다(자동으로 기본 모델로 폴백되거나 하지 않음).

## 리스크 / 확인 필요

- `model` 필드값과 실제 클러스터의 `namespace/name` 매핑 규칙 확인 필요 — 그대로 1:1 문자열 매칭인지,
  아니면 MaaS 쪽에 별도 alias/카탈로그 등록이 필요한지(예: Gen AI Studio에서 모델 등록 시 지정하는
  `model` alias).
- 기존 시나리오 13/17에서 쓰던 **경로 기반** 엔드포인트(`/<ns>/<model>/v1/chat/completions`)와 이번
  **Body 기반** 고정 엔드포인트(`/v1/chat/completions`)가 동시에 지원되는지, 아니면 3.5부터 후자가
  권장/대체 경로인지 — 문서화가 필요하면 이 프로젝트의 `AGENT.md`에 반영.

## 실측 결과

_(미착수 — `myocp` 클러스터 설치 및 RHOAI 3.5/MaaS 배포 완료 후 진행 예정)_
