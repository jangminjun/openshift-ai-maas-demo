#!/usr/bin/env python3
"""Run this DIRECTLY from your own laptop (no SSH/bastion needed), stdlib only.
Tests scenario 18 (docs/scenarios/18-maas-openai-body-routing.md): fixed
/v1/chat/completions endpoint, model selected purely via the request body's
"model" field. Requires harness/state/keycloak-users.env (run
./harness.sh scenario17-keycloak-realm first if missing).
"""
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(SCRIPT_DIR, "..", "state", "keycloak-users.env")


def cluster_domain():
    """CLUSTER_DOMAIN env var wins; otherwise ask the currently oc-logged-in cluster."""
    if os.environ.get("CLUSTER_DOMAIN"):
        return os.environ["CLUSTER_DOMAIN"]
    try:
        out = subprocess.run(
            ["oc", "get", "ingresses.config.openshift.io", "cluster",
             "-o", "jsonpath={.spec.domain}"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except (FileNotFoundError, subprocess.CalledProcessError) as e:
        sys.exit(
            "Couldn't get cluster domain via 'oc' (not logged in / oc missing) "
            f"and CLUSTER_DOMAIN isn't set: {e}"
        )


def keycloak_url():
    """MAAS_KEYCLOAK_URL env var wins; otherwise look up the actual Route in
    KEYCLOAK_NAMESPACE -- the Route's own name is hardcoded ("maas-keycloak")
    inside harness/remote/scenario17-keycloak-up.sh, not something this
    script should assume, so read the live object instead of guessing it."""
    if os.environ.get("MAAS_KEYCLOAK_URL"):
        return os.environ["MAAS_KEYCLOAK_URL"]
    namespace = os.environ.get("KEYCLOAK_NAMESPACE", "maas-keycloak")
    try:
        out = subprocess.run(
            ["oc", "get", "route", "-n", namespace, "-o", "jsonpath={.items[0].spec.host}"],
            capture_output=True, text=True, check=True,
        )
        host = out.stdout.strip()
        if not host:
            raise ValueError("no Route found")
        return f"https://{host}"
    except (FileNotFoundError, subprocess.CalledProcessError, ValueError) as e:
        sys.exit(
            f"Couldn't find the Keycloak Route in namespace '{namespace}' "
            f"and MAAS_KEYCLOAK_URL isn't set: {e}"
        )


DOMAIN = cluster_domain()
KC = keycloak_url()
REALM = os.environ.get("KEYCLOAK_REALM", "maas-demo")
CLIENT_ID = os.environ.get("KEYCLOAK_CLIENT_ID", "maas-test-client")
MAAS_URL = os.environ.get("MAAS_URL", f"https://maas.{DOMAIN}/v1/chat/completions")
# MUST be the full "id" from GET /v1/models (publishers/<ns>/models/<name>) --
# a short name (just <name>) does NOT route, it 404s.
MODEL_A = os.environ.get("MAAS_TEST_MODEL", "publishers/maas-demo/models/Qwen2.5-1.5B-Instruct")
MODEL_B = os.environ.get("MAAS_TEST_MODEL_B", "publishers/maas-demo/models/DeepSeek-R1-Distill-Qwen-1.5B")

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def load_env(path):
    env = {}
    if not os.path.isfile(path):
        sys.exit(f"Missing {path} -- run ./harness.sh scenario17-keycloak-realm first.")
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k] = v
    return env


def post(url, data, headers, expect_json=True):
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, context=CTX) as resp:
            body = resp.read().decode()
            return resp.status, body
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def get_token(username, password, client_secret):
    body = urllib.parse.urlencode({
        "grant_type": "password",
        "client_id": CLIENT_ID,
        "client_secret": client_secret,
        "username": username,
        "password": password,
    }).encode()
    status, body_text = post(
        f"{KC}/realms/{REALM}/protocol/openid-connect/token",
        body,
        {"Content-Type": "application/x-www-form-urlencoded"},
    )
    if status != 200:
        sys.exit(f"FAILED to get token: HTTP {status} {body_text}")
    return json.loads(body_text)["access_token"]


def print_body(body):
    try:
        print(json.dumps(json.loads(body), indent=2, ensure_ascii=False))
    except json.JSONDecodeError:
        print(body)


def call_model(token, model_name):
    payload_dict = {
        "model": model_name,
        "messages": [{"role": "user", "content": "1+1?"}],
        "max_tokens": 30,
    }
    print(f">> REQUEST: POST {MAAS_URL}")
    print(json.dumps(payload_dict, indent=2, ensure_ascii=False))
    payload = json.dumps(payload_dict).encode()
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    return post(MAAS_URL, payload, headers)


def show_result(requested_model, status, body):
    """Prints the full response, then a one-line verdict naming which model
    actually answered (from the response's own "model" field) -- this is the
    proof that body-based routing, not the fixed URL, decided the backend."""
    print("<< RESPONSE:")
    print_body(body)
    print(f"HTTP {status}")
    try:
        answered_by = json.loads(body).get("model")
    except json.JSONDecodeError:
        answered_by = None
    if answered_by:
        match = "✅ 일치" if answered_by in requested_model else "⚠️ 불일치"
        print(f">>> 요청한 model={requested_model}")
        print(f">>> 실제 응답한 모델={answered_by} ({match})")


def main():
    env = load_env(STATE_FILE)
    client_secret = env.get("KEYCLOAK_CLIENT_SECRET")
    basic_password = env.get("KEYCLOAK_USER_BASIC_PASSWORD")
    if not client_secret or not basic_password:
        sys.exit(f"Missing KEYCLOAK_CLIENT_SECRET / KEYCLOAK_USER_BASIC_PASSWORD in {STATE_FILE}")

    token = get_token("basic-user", basic_password, client_secret)

    print(f"== 고정 엔드포인트: {MAAS_URL} (아래 내내 안 바뀜) ==")

    print()
    print(f"== 1) model={MODEL_A} -- HTTP 200 기대 ==")
    status, body = call_model(token, MODEL_A)
    show_result(MODEL_A, status, body)
    print("(403이면 Authorino가 maas-api TLS 인증서를 다시 못 믿는 상태로 되돌아간 것 --")
    print(" ./harness.sh scenario17-authorino-trust-ca 재실행)")

    print()
    print(f"== 2) model={MODEL_B} (같은 URL, body만 바뀜!) -- HTTP 200 기대 ==")
    status, body = call_model(token, MODEL_B)
    show_result(MODEL_B, status, body)

    print()
    print("== 3) 대조군: 존재하지 않는 모델명 -- HTTP 404 기대 (조용히 다른 모델로 안 새는지 확인) ==")
    fake_model = f"definitely-not-a-registered-model-{int(time.time())}"
    status, body = call_model(token, fake_model)
    print("<< RESPONSE:")
    print_body(body)
    print(f"HTTP {status}")


if __name__ == "__main__":
    main()
