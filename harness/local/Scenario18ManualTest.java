// Run this DIRECTLY from your own laptop (no SSH/bastion needed). Java 21,
// no external dependencies (java.net.http only): java Scenario18ManualTest.java
//
// Windows PowerShell 5.1 console note: Korean text can render as mojibake
// even after `chcp 65001` (that alone doesn't update .NET's console output
// encoding). Fix: run this once per session before `java ...`:
//   [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
// (Git Bash doesn't need this -- it's UTF-8 by default.)
//
// Tests scenario 18 (docs/scenarios/18-maas-openai-body-routing.md): fixed
// /v1/chat/completions endpoint, model selected purely via the request
// body's "model" field. Requires harness/state/keycloak-users.env (run
// ./harness.sh scenario17-keycloak-realm first if missing).
import java.io.IOException;
import java.io.PrintStream;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

public class Scenario18ManualTest {

    record Config(String maasUrl, String modelA, String modelB, HttpClient client,
                   String kc, String realm, String clientId) {}

    public static void main(String[] args) throws Exception {
        System.setOut(new PrintStream(System.out, true, StandardCharsets.UTF_8));
        System.setErr(new PrintStream(System.err, true, StandardCharsets.UTF_8));

        var client = trustingHttpClient();
        var domain = envOr("CLUSTER_DOMAIN", () -> oc("get", "ingresses.config.openshift.io",
                "cluster", "-o", "jsonpath={.spec.domain}"));
        var kc = envOr("MAAS_KEYCLOAK_URL", () -> {
            var namespace = System.getenv().getOrDefault("KEYCLOAK_NAMESPACE", "maas-keycloak");
            var host = oc("get", "route", "-n", namespace, "-o", "jsonpath={.items[0].spec.host}");
            if (host.isBlank()) throw new RuntimeException("no Route found in " + namespace);
            return "https://" + host;
        });
        var cfg = new Config(
                System.getenv().getOrDefault("MAAS_URL", "https://maas." + domain + "/v1/chat/completions"),
                // MUST be the full "id" from GET /v1/models (publishers/<ns>/models/<name>) --
                // a short name (just <name>) does NOT route, it 404s.
                System.getenv().getOrDefault("MAAS_TEST_MODEL",
                        "publishers/maas-demo/models/Qwen2.5-1.5B-Instruct"),
                System.getenv().getOrDefault("MAAS_TEST_MODEL_B",
                        "publishers/maas-demo/models/DeepSeek-R1-Distill-Qwen-1.5B"),
                client, kc,
                System.getenv().getOrDefault("KEYCLOAK_REALM", "maas-demo"),
                System.getenv().getOrDefault("KEYCLOAK_CLIENT_ID", "maas-test-client"));

        var stateFile = Path.of(System.getProperty("user.dir")).resolve("../state/keycloak-users.env");
        var stateEnv = loadEnv(stateFile);
        var clientSecret = stateEnv.get("KEYCLOAK_CLIENT_SECRET");
        var basicPassword = stateEnv.get("KEYCLOAK_USER_BASIC_PASSWORD");
        if (clientSecret == null || basicPassword == null) {
            System.err.println("Missing KEYCLOAK_CLIENT_SECRET / KEYCLOAK_USER_BASIC_PASSWORD in " + stateFile);
            System.exit(1);
        }

        var token = getToken(cfg, "basic-user", basicPassword, clientSecret);

        System.out.println("== 고정 엔드포인트: " + cfg.maasUrl() + " (아래 내내 안 바뀜) ==\n");

        System.out.println("== 1) model=" + cfg.modelA() + " -- HTTP 200 기대 ==");
        showResult(cfg.modelA(), callModel(cfg, token, cfg.modelA()));
        System.out.println("(403이면 Authorino가 maas-api TLS 인증서를 다시 못 믿는 상태로 되돌아간 것 --");
        System.out.println(" ./harness.sh scenario17-authorino-trust-ca 재실행)\n");

        System.out.println("== 2) model=" + cfg.modelB() + " (같은 URL, body만 바뀜!) -- HTTP 200 기대 ==");
        showResult(cfg.modelB(), callModel(cfg, token, cfg.modelB()));

        System.out.println("\n== 3) 대조군: 존재하지 않는 모델명 -- HTTP 404 기대 (조용히 다른 모델로 안 새는지 확인) ==");
        var fakeModel = "definitely-not-a-registered-model-" + System.currentTimeMillis() / 1000;
        var negative = callModel(cfg, token, fakeModel);
        System.out.println("<< RESPONSE:");
        System.out.println(prettyJson(negative.body()));
        System.out.println("HTTP " + negative.statusCode());
    }

    static void showResult(String requestedModel, HttpResponse<String> resp) {
        System.out.println("<< RESPONSE:");
        System.out.println(prettyJson(resp.body()));
        System.out.println("HTTP " + resp.statusCode());
        var answeredBy = jsonStringField(resp.body(), "model");
        if (answeredBy != null) {
            var match = requestedModel.contains(answeredBy) ? "✅ 일치" : "⚠️ 불일치";
            System.out.println(">>> 요청한 model=" + requestedModel);
            System.out.println(">>> 실제 응답한 모델=" + answeredBy + " (" + match + ")");
        }
        System.out.println();
    }

    static HttpResponse<String> callModel(Config cfg, String token, String modelName) throws IOException, InterruptedException {
        var payload = """
                {"model":"%s","messages":[{"role":"user","content":"1+1?"}],"max_tokens":30}"""
                .formatted(jsonEscape(modelName));
        System.out.println(">> REQUEST: POST " + cfg.maasUrl());
        System.out.println(prettyJson(payload));
        var req = HttpRequest.newBuilder(URI.create(cfg.maasUrl()))
                .header("Authorization", "Bearer " + token)
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(payload, StandardCharsets.UTF_8))
                .build();
        return cfg.client().send(req, HttpResponse.BodyHandlers.ofString());
    }

    static String getToken(Config cfg, String username, String password, String clientSecret) throws IOException, InterruptedException {
        var form = "grant_type=password"
                + "&client_id=" + urlEncode(cfg.clientId())
                + "&client_secret=" + urlEncode(clientSecret)
                + "&username=" + urlEncode(username)
                + "&password=" + urlEncode(password);
        var req = HttpRequest.newBuilder(URI.create(cfg.kc() + "/realms/" + cfg.realm() + "/protocol/openid-connect/token"))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(form))
                .build();
        var resp = cfg.client().send(req, HttpResponse.BodyHandlers.ofString());
        if (resp.statusCode() != 200) {
            System.err.println("FAILED to get token: HTTP " + resp.statusCode() + " " + resp.body());
            System.exit(1);
        }
        var token = jsonStringField(resp.body(), "access_token");
        if (token == null) {
            System.err.println("No access_token in response: " + resp.body());
            System.exit(1);
        }
        return token;
    }

    // ---- tiny helpers (no external deps) ----

    static String envOr(String name, Supplier<String> ocFallback) {
        var v = System.getenv(name);
        if (v != null && !v.isBlank()) return v;
        try {
            return ocFallback.get();
        } catch (Exception e) {
            System.err.println("Couldn't resolve " + name + " via 'oc' and it isn't set: " + e.getMessage());
            System.exit(1);
            return null;
        }
    }

    static String oc(String... args) {
        try {
            List<String> cmd = new ArrayList<>();
            cmd.add("oc");
            cmd.addAll(List.of(args));
            var p = new ProcessBuilder(cmd).start();
            var out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8).trim();
            p.waitFor();
            if (p.exitValue() != 0) throw new RuntimeException("oc exited " + p.exitValue());
            return out;
        } catch (IOException | InterruptedException e) {
            throw new RuntimeException(e);
        }
    }

    static Map<String, String> loadEnv(Path path) throws IOException {
        Map<String, String> env = new HashMap<>();
        if (!Files.isRegularFile(path)) {
            System.err.println("Missing " + path + " -- run ./harness.sh scenario17-keycloak-realm first.");
            System.exit(1);
        }
        for (var line : Files.readAllLines(path)) {
            line = line.strip();
            if (line.isEmpty() || line.startsWith("#") || !line.contains("=")) continue;
            var i = line.indexOf('=');
            env.put(line.substring(0, i), line.substring(i + 1));
        }
        return env;
    }

    static String urlEncode(String s) {
        return URLEncoder.encode(s, StandardCharsets.UTF_8);
    }

    static String jsonEscape(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    /**
     * Minimal top-level "field":"value" extractor -- deliberately not regex.
     * A backtracking regex over a long unescaped value (e.g. a multi-hundred-char
     * JWT access_token) can blow the stack in Java's Pattern engine; a plain
     * indexOf/scan has no such failure mode and is all we need for one flat field.
     */
    static String jsonStringField(String json, String field) {
        var key = "\"" + field + "\"";
        var keyStart = json.indexOf(key);
        if (keyStart < 0) return null;
        var colon = json.indexOf(':', keyStart + key.length());
        if (colon < 0) return null;
        var i = colon + 1;
        while (i < json.length() && Character.isWhitespace(json.charAt(i))) i++;
        if (i >= json.length() || json.charAt(i) != '"') return null;
        i++;
        var sb = new StringBuilder();
        while (i < json.length() && json.charAt(i) != '"') {
            var c = json.charAt(i);
            if (c == '\\' && i + 1 < json.length()) {
                sb.append(json.charAt(i + 1));
                i += 2;
            } else {
                sb.append(c);
                i++;
            }
        }
        return sb.toString();
    }

    /**
     * Indents compact JSON for readability. Walks the raw text character by
     * character tracking string/escape state -- not a real parser, but that's
     * enough to indent valid JSON correctly without pulling in a library.
     */
    static String prettyJson(String json) {
        var sb = new StringBuilder();
        var indent = 0;
        var inString = false;
        var escaped = false;
        for (int i = 0; i < json.length(); i++) {
            var c = json.charAt(i);
            if (inString) {
                sb.append(c);
                if (escaped) {
                    escaped = false;
                } else if (c == '\\') {
                    escaped = true;
                } else if (c == '"') {
                    inString = false;
                }
                continue;
            }
            switch (c) {
                case '"' -> { inString = true; sb.append(c); }
                case '{', '[' -> {
                    sb.append(c);
                    var next = i + 1 < json.length() ? json.charAt(i + 1) : ' ';
                    if (next == '}' || next == ']') {
                        // empty object/array -- keep on one line
                    } else {
                        indent++;
                        sb.append('\n').append("  ".repeat(indent));
                    }
                }
                case '}', ']' -> {
                    var prev = sb.isEmpty() ? ' ' : sb.charAt(sb.length() - 1);
                    if (prev != '{' && prev != '[') {
                        indent--;
                        sb.append('\n').append("  ".repeat(indent));
                    }
                    sb.append(c);
                }
                case ',' -> sb.append(c).append('\n').append("  ".repeat(indent));
                case ':' -> sb.append(": ");
                default -> {
                    if (!Character.isWhitespace(c)) sb.append(c);
                }
            }
        }
        return sb.toString();
    }

    static HttpClient trustingHttpClient() throws Exception {
        var trustAll = new TrustManager[]{new X509TrustManager() {
            public void checkClientTrusted(X509Certificate[] chain, String authType) {}
            public void checkServerTrusted(X509Certificate[] chain, String authType) {}
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        }};
        var ctx = SSLContext.getInstance("TLS");
        ctx.init(null, trustAll, new SecureRandom());
        return HttpClient.newBuilder().sslContext(ctx).build();
    }
}
