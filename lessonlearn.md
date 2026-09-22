# Lessons Learned — myocp / sandbox harness operations

Bugs and incidents found while operating the `openshift-aws-harness` harness against
the `myocp` cluster. No secrets here — this is git-tracked. Live connection info and
current state live in `AGENT.md` (gitignored) instead.

## 2026-09-22 — Deploying any real model makes `odh-model-controller` silently steal the MaaS gateway's AuthPolicy; a Gateway annotation stops it (fixed, now automated)

**Symptom**: scenario 17's Keycloak wiring (see the two entries below) worked and was verified
end-to-end (HTTP 200) — then, purely from deploying an unrelated `LLMInferenceService` on the same
Gateway, it broke again with `401 UNAUTHENTICATED`, even though `oc get authpolicy maas-gateway-auth
-n openshift-ingress` showed the Keycloak identity source patch still present in `spec`.

**Root cause**: the moment a model with a route gets attached to `maas-default-gateway`, KServe's
`odh-model-controller` (its `gateway-auth-bootstrap` sub-controller) creates its **own** AuthPolicy
(`<gateway>-authn`) targeting the same Gateway — pure `kubernetesTokenReview` auth, no external OIDC,
no API keys. Kuadrant's policy conflict resolution then marks that one `Enforced` and the
MaaS-managed one `Overridden` (not deleted — just not applied), so the Keycloak patch was still
*present* in spec but no longer *active*.

**Fix**: annotate the Gateway so `odh-model-controller` leaves its policies alone —
```sh
oc annotate gateway maas-default-gateway -n openshift-ingress \
  opendatahub.io/managed="false" \
  security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
```
Confirmed via the controller's own logs that it then *deletes* its own competing AuthPolicy
(`INFO Deleting AuthPolicy {..., "name": "maas-default-gateway-authn"}`) rather than leaving it
around unenforced. Full trace incl. the controller log lines:
`openshift-ai-maas-demo/docs/scenarios/17-maas-external-oidc-auth.md` section 7.

**Now automated**: `monitoring-llmd-rhoai/harness/remote/maas.sh` Step 7 applies this annotation
right after creating the Gateway, so a fresh install never hits this — the annotation is in place
*before* any model ever gets deployed, so `odh-model-controller` never gets a chance to create the
competing policy in the first place.

**How to apply going forward**: if a `maas-*` AuthPolicy that was working suddenly stops (especially
right after deploying/redeploying a model), check `oc get authpolicy -A -o custom-columns='NAME:
.metadata.name,TARGET:.spec.targetRef.name,ENFORCED:.status.conditions[-1].status,REASON:
.status.conditions[-1].reason'` for a second policy on the same target before assuming the first
policy's own config broke — `Overridden` means something else won, not that this one is misconfigured.

## 2026-09-22 — Authorino makes its own outbound mTLS call to `maas-api` during authorization (not something Envoy/Gateway does) — currently rejected ("bad certificate"), NOT YET FIXED

**Symptom**: with the above two issues fixed, `GET /v1/models` with a valid Keycloak token returns
200 (real model + subscription data), but an actual `POST .../v1/chat/completions` call — same
token, same user, group membership confirmed matching in the policy's own rego (`model_access`) —
still returns `403`.

**Root cause**: the AuthPolicy's `subscription-valid` authorization rule depends on a `metadata`
phase that has Authorino itself (not Envoy) make an HTTP call to `https://maas-api.redhat-ai-gateway-
infra.svc.cluster.local:8443/internal/v1/subscriptions/select`. That call fails at the TLS layer:
`maas-api`'s own logs show `http: TLS handshake error from <IP>: remote error: tls: bad certificate`
at the exact moment of the request. Confirmed the `<IP>` is Authorino's pod IP, not any Gateway/Envoy
pod IP (checked both side by side) — so this is unambiguously Authorino's own outbound client
certificate being rejected by `maas-api`, a completely different hop from the two issues above.

**Status: unresolved.** Toggling `security.opendatahub.io/authorino-tls-bootstrap` and Authorino's
own `listener.tls.enabled` (server-side, unrelated to this outbound client-side call) had no effect
on this specific failure. As a result, the "official" governance path (`MaaSSubscription` +
`MaaSAuthPolicy`, scenario 17 section 7) cannot yet complete an actual model call end-to-end — a
real response was obtained once, but only via a temporary Kubernetes-RBAC bypass (`ClusterRole`/
`RoleBinding` granting the Keycloak groups direct `get` on the `LLMInferenceService`, scenario 17
section 8) while the *other*, now-disabled `odh-model-controller` AuthPolicy was still active — that
bypass doesn't apply now that the Gateway is protected via the annotation above.

**How to apply going forward**: next investigation step is `oc describe deploy/maas-api -n
redhat-ai-gateway-infra` for whatever CA/cert config it expects for inbound mTLS clients, and
checking whether Authorino's `metadata.*.http` config (in the AuthPolicy CRD) has any client-cert
field at all — full detail in `docs/scenarios/17-maas-external-oidc-auth.md` section 8.

## 2026-09-22 — Don't infer "auth succeeded" from a generic error code without checking the actual decision logs; MaaS's real blocker is a broken gRPC call from Envoy to Authorino/Limitador

**Symptom**: `curl .../v1/models` with a valid Keycloak token returned `HTTP 500`. I claimed this
meant authentication had succeeded and the failure was purely downstream (a `maas-api` backend TLS
issue) — reasoning that a 500 instead of 401 implied the AuthPolicy let the request through.

**This claim was wrong, and I hadn't actually verified it** — I inferred it from the *type* of
error rather than checking what actually happened. The user directly challenged it ("500 뜨는게 왜
성공?"), which was the right call: the same request with **no token at all** also returned the
identical 500, not 401 — direct evidence against "the 500 only happens after auth passes," which
I'd overlooked.

**Actual root cause (found by tailing the gateway pod's logs while firing a live test request,
correlating by timestamp)**: `error envoy wasm ... kuadrant-wasm-shim: gRPC status code is not OK`
— Envoy's Kuadrant wasm filter fails its own gRPC call to Authorino/Limitador *before* any identity
or quota decision is made. Confirmed by checking Authorino's and Limitador's logs for the exact same
timestamp: **zero log lines on either side** — the request never even arrives at the auth/rate-limit
services, so of course the outcome doesn't depend on the token. Tried one plausible fix first (an
Istio `DestinationRule` forcing `mode: SIMPLE, insecureSkipVerify: true` for the Authorino
authorization service on port 50051, mirroring the one that already exists for `maas-api`) — no
effect, which was itself a useful signal: `oc get envoyfilter -A` in `openshift-ingress` showed
`kuadrant-auth-maas-default-gateway` (owned by the `Gateway`, auto-generated by RHOAI's
aigateway-operator/maas-controller) directly `ADD`-patching a Envoy `CLUSTER` for
`authorino-authorino-authorization:50051` with **no `transport_socket` at all** — i.e. plaintext.
DestinationRules only affect Istio-mesh-discovered clusters, not clusters an EnvoyFilter injects
directly, which is why it had no effect. Meanwhile `maas.sh`'s "Step 2: Authorino TLS" (carried
over from an RHOAI 3.3/3.4-era setup guide) explicitly turns **on**
`Authorino.spec.listener.tls.enabled: true` with a cert-manager cert. Mismatch: Envoy connects
plaintext, Authorino only speaks TLS on that port — handshake fails before Authorino's app layer
ever sees the request, explaining the zero-logs symptom exactly.

**Fix**: `oc patch authorino authorino -n kuadrant-system --type=merge -p
'{"spec":{"listener":{"tls":{"enabled":false}}}}'` — turning Authorino's listener TLS back off to
match what RHOAI 3.5's generated EnvoyFilter actually expects. Verified end-to-end immediately
after: a Keycloak token for a user with no OpenShift account got `HTTP 200` with a real model-list
response from `https://maas.apps.myocp.sandbox1314.opentlc.com/v1/models`, and the pre-existing
`oc`-token path still worked too (no regression).

**How to apply going forward**: `maas.sh`'s Authorino-TLS step is a leftover from the pre-3.5 setup
guide it was ported from and is now actively wrong for RHOAI 3.5 — either make it conditional on
RHOAI version or drop it entirely for 3.5+ installs (not yet done — script still enables it as of
this writing; if re-running `maas.sh` on a fresh 3.5 cluster, disable Authorino listener TLS
afterward the same way). More generally: never present "X failed a specific way, therefore Y must
have succeeded" as a conclusion without directly checking the component that would prove it (here:
the actual authorization decision, via Authorino's own logs) — a plausible-sounding inference from
an error *code* alone is not verification. When a symptom is identical across supposedly-different
inputs (valid token / wrong token / no token all → same 500), that sameness itself is a strong
signal the differentiating logic was never reached — check upstream of the auth layer, not just
downstream, before drawing conclusions.

## 2026-09-22 — Getting Authorino to trust a self-signed-route OIDC issuer needs a CA-bundle-file swap, not a documented "extra CA" field; also Keycloak needs `proxy.headers: xforwarded` behind edge TLS termination or its issuer URL reports the wrong scheme

**Symptom (part 1)**: after adding Keycloak as a third `jwt` identity source in the MaaS
`AuthPolicy` (`kuadrant.io/v1`, field is `jwt.issuerUrl`/`jwt.jwksUrl` — there's no `oidc` field in
this CRD version despite that being the conceptually obvious name), the `AuthPolicy` still showed
`Accepted: True` but Authorino's own pod logs repeated every few seconds: `x509: certificate signed
by unknown authority` trying to fetch Keycloak's `/.well-known/openid-configuration`.

**Root cause (part 1)**: Keycloak was exposed via an OpenShift Route with edge TLS termination,
so external clients see a cert signed by the cluster's router CA — which is NOT in Authorino's
container image's system CA trust store (RHEL9 UBI, standard public-CA-only bundle). Neither the
`AuthPolicy` CRD nor the `Authorino` operator CR (`operator.authorino.kuadrant.io`) has a
dedicated "trust this extra CA" field — the closest thing, `authorino.spec.volumes`, only supports
directory-level ConfigMap/Secret mounts (confirmed by trying a single-file `mountPath` first: fails
with `mount ... Not a directory`, since Kubernetes volume mounts always shadow a whole directory,
never subPath a single file, through this CRD's exposed fields at least).

**Fix (part 1)**: rather than fighting that, replaced the *file* Go's `x509.SystemCertPool()`
actually reads on this image (`/etc/pki/tls/certs/ca-bundle.crt`, a symlink to
`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`) by mounting a ConfigMap **at the symlink's
target directory** (`/etc/pki/ca-trust/extracted/pem`, not `/etc/pki/tls/certs` — the latter also
holds Authorino's own serving cert `tls.crt`, which a directory-shadowing mount would have deleted
and broken Authorino's own TLS listener). ConfigMap content = the pod's existing bundle
(`oc exec ... cat /etc/pki/tls/certs/ca-bundle.crt`) with the router CA
(`oc get secret router-ca -n openshift-ingress-operator`) appended — additive, not a replacement,
so every other previously-trusted CA still works.

**Symptom (part 2)**: after the CA fix, the error changed to `oidc: issuer did not match the issuer
returned by provider, expected "https://maas-keycloak..." got "http://maas-keycloak..."`.

**Root cause (part 2)**: Keycloak itself runs plain HTTP (`spec.http.httpEnabled: true`, no
`tlsSecret`) — TLS only happens at the Route. Keycloak has no way to know that unless told, so its
self-reported OIDC `issuer` (and every other self-referencing URL) used `http://`, while Authorino's
`issuerUrl` (correctly, from the caller's real-world perspective) said `https://`. go-oidc's
`NewProvider` strictly requires the discovery document's `issuer` field to exactly match the URL
you configured — no leniency.

**Fix (part 2)**: `oc patch keycloak maas-keycloak -n maas-keycloak --type=merge -p
'{"spec":{"proxy":{"headers":"xforwarded"}}}'` — tells Keycloak to trust `X-Forwarded-Proto`
(and related) headers from the edge-terminating Route/router, after which its discovery document's
`issuer` correctly reports `https://`.

**How to apply going forward**: any RHBK/Keycloak instance sitting behind edge/reencrypt TLS
termination (i.e., not terminating TLS itself) needs `spec.proxy.headers: xforwarded` from the
start, or every self-referencing URL it issues (not just the OIDC issuer — also endpoints in
tokens, redirect URIs, etc.) will silently use the wrong scheme. Separately: when Authorino (or
anything using Go's default system cert pool in a minimal/UBI container) needs to trust one extra
internal CA and the surrounding CRD gives no dedicated field for it, look for the actual file Go
reads (`ls -la /etc/pki/tls/certs/` to find what `ca-bundle.crt` really points to) and replace
*that specific file's target*, not a shared directory something else also depends on.

## 2026-09-22 — RHOAI 3.5's MaaS stack needs 3 more manual pieces `maas.sh` didn't provide: a `maas-default-gateway`, a working Gateway TLS cert, and a Postgres DB for `maas-api`

**Symptom**: after fixing the `modelsAsAService` field rename (see entry below) and getting
`./harness.sh maas` to exit 0 cleanly, MaaS still didn't actually work — `oc get aigateway
default-aigateway` showed `ModelsAsAServiceReady: False`, and the `Gateway openshift-ai-inference`
that the script created looked "Programmed" at the top level but its listener was silently broken.

**Root causes (three separate, found in sequence by reading controller logs and `oc explain`/status
conditions rather than guessing):**

1. **`maas-default-gateway` isn't auto-created.** `maas-controller`'s logs said explicitly: *"the
   Gateway must be created by a network or cluster administrator before AITenant can be
   provisioned"* / *"the specified Gateway must exist before enabling MaaS platform reconcile"*.
   The script only ever created a Gateway named `openshift-ai-inference` — a real, separate object,
   not a stand-in. RHOAI 3.5's MaaS specifically needs one named `maas-default-gateway` in
   `openshift-ingress`, hostname `maas.<cluster-domain>`.
2. **The referenced TLS secret (`default-gateway-tls`) never existed.** Nothing in this harness or
   RHOAI creates it. The Gateway's top-level `status.conditions[Programmed]` said `True` (because
   the LB Service came up fine), which masked that the *listener*-level condition was
   `Programmed: False, reason: Invalid, message: "Bad TLS configuration"` — you have to check
   `status.listeners[].conditions`, not just `status.conditions`, to catch this. Fixed by pointing
   `certificateRefs` at `router-certs-default` (the cluster's own default ingress router cert,
   already present in `openshift-ingress` — no cert-manager `Certificate` needed for a `*.apps.<domain>`
   hostname).
3. **`maas-api` needs its own Postgres, provisioned by nobody.** Condition message: *"database
   Secret 'maas-db-config' not found in namespace 'redhat-ai-gateway-infra'. Create the Secret with
   key 'DB_CONNECTION_URL' ... MaaS API cannot start without a database connection."* Stood up an
   ephemeral single-pod Postgres in `redhat-ai-gateway-infra` (same disposable-demo-DB pattern as
   `scenario17-keycloak-up.sh`'s DB for Keycloak) and created the secret pointing at it.

**Fix applied**: all three fixed live via `oc apply`/`oc create secret`, then folded into
`monitoring-llmd-rhoai/harness/remote/maas.sh` (Step 4 now creates both Gateways with the correct
cert ref; new Step 4b provisions the DB + secret) so a fresh cluster doesn't hit any of this.
Verified end-to-end afterward: `oc get aitenant -A` → `models-as-a-service` `READY=True`,
`https://maas.apps.myocp.sandbox1314.opentlc.com/v1/models` reachable from the open internet (not
just from the bastion).

**How to apply going forward**: when a component reports "ready" at a coarse level (Deployment
available, top-level Gateway Programmed) but the actual feature doesn't work, check the specific
sub-resource's own status conditions (`status.listeners[]` on a Gateway, not just `status`;
`ModelsAsAServiceReady` on the `AIGateway` CR, not just `Ready`) and read the owning controller's
logs directly — the real blocker is almost always named explicitly there (as it was in all three
cases here), far faster than guessing from symptoms.

## 2026-09-22 — RHOAI 3.5 renamed `kserve.modelsAsService` to `aigateway.modelsAsAService`; `monitoring-llmd-rhoai/harness/remote/maas.sh` still targeted the old field and errored

**Symptom**: `./harness.sh maas` (from `monitoring-llmd-rhoai`) failed at "Step 3: Enable
modelsAsService in DataScienceCluster" with:
```
The DataScienceCluster "default-dsc" is invalid: spec.components.kserve.modelsAsService:
Invalid value: modelsAsService is deprecated; cannot re-enable once Removed. Use
spec.components.aigateway.modelsAsAService instead
```

**Root cause**: that script was written against RHOAI 3.3/3.4, where MaaS lived under
`spec.components.kserve.modelsAsService`. RHOAI 3.5 moved it to a new top-level `aigateway`
component: `spec.components.aigateway.modelsAsAService` (confirmed via `oc explain
datasciencecluster.spec.components.aigateway.modelsAsAService` — the CRD description
explicitly notes the "AsA" spelling is intentional, matching the ai-gateway-operator CRD's own
field name, not a typo). The old field path is now rejected outright once `kserve.modelsAsService`
has been `Removed`, not just deprecated-but-tolerated.

**Fix applied**: patched `default-dsc` directly with the new path
(`aigateway.managementState: Managed` + `aigateway.modelsAsAService.managementState: Managed`),
then updated `maas.sh` Step 3 to check/set the new field instead of the old one. Re-ran
`./harness.sh maas` afterward — idempotent, picked up from Step 4 onward.

**How to apply going forward**: this harness (and its docs) now assume RHOAI 3.5+ only for the
MaaS path — if a cluster ever gets pinned back to 3.3/3.4, this script needs the old field path
restored (or branched on version). More generally: when a component "moves" between RHOAI minor
versions, `oc explain` on the live CRD is the fast way to find the new path — don't guess from
old docs/scripts, and don't assume an error message's unusual spelling (`modelsAsAService`) is a
typo before checking the actual schema.

## 2026-09-22 — `wait-cluster`'s SSH session can die of a transient timeout well after the real install already finished successfully; don't trust "failed" at face value

**Symptom**: the backgrounded `./harness.sh wait-cluster` run was reported as failed (exit 255,
`"Timeout, server ... not responding"`) about 50 minutes after it started. Reading that alone
looks like the cluster build failed.

**Root cause**: it wasn't a cluster failure — `openshift-install` had already printed
`"Install complete!"` (console URL + kubeadmin password) **37 minutes before** the SSH session
timed out. The long-lived SSH connection `wait-cluster` was tailing over apparently dropped on
its own sometime after the remote process had already exited cleanly (likely a transient
network blip between this machine and the bastion, unrelated to `openshift-install` itself) —
`ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6` didn't save it here, which is odd but
not investigated further since the underlying install was already done and unaffected.

**How to apply going forward**: an exit-255 SSH failure on a long-running remote-tail command
(`wait-cluster`, or anything similar) is a **connection** failure, not necessarily a **remote
process** failure. Don't report or assume the underlying job failed from that alone — reconnect
and check the actual remote state/logs directly (here: `grep level=info
~/ocp-install/.openshift_install.log`, `oc get clusterversion`) before concluding anything broke.

---

## 2026-09-22 — `bastion-up` silently imports a mismatched SSH key when run from a different machine/session

**Symptom**: SSH to the bastion (`ssh -i ~/.ssh/myocp-bastion ec2-user@<ip>`) failed with
`Permission denied (publickey)` for every plausible username, even though `AGENT.md`
claimed the same local keypair was reused.

**Root cause**: `harness/harness.sh`'s `cmd_bastion_up` only generates/imports a new
keypair when `aws ec2 describe-key-pairs --key-names "${CLUSTER_NAME}-bastion-key"`
finds nothing. It never checks whether the *local* `${SSH_KEY_PATH}` matches whatever
key AWS already has on file under that name. If `bastion-up` runs once from environment
A (where `~/.ssh/myocp-bastion` doesn't exist yet, so the script freshly generates one
and imports it) and then anyone re-runs any other step from environment B (a different
machine/session, where `~/.ssh/myocp-bastion` already exists from an older/unrelated
sandbox), B's local key is never reconciled with what's actually registered in AWS —
B just silently has the wrong private key with no error until an SSH attempt fails.

Confirmed by recomputing the SHA256 fingerprint of the local pubkey by hand (raw
base64-decode → sha256 → base64-encode-with-padding, to match AWS's exact fingerprint
format for imported ED25519 keys) and comparing byte-for-byte against
`aws ec2 describe-key-pairs` output — they were genuinely different keys, not just a
formatting mismatch in the comparison.

**Fix applied**: `harness.sh destroy-bastion --yes` (tears down the bastion + its
keypair) then re-ran `bastion-up` from the machine that already holds the correct local
`~/.ssh/<cluster>-bastion` private key, so the import reuses that machine's key
consistently.

**How to apply going forward**: whichever machine/session runs `bastion-up` for a given
cluster name is now the source of truth for that cluster's SSH key. Don't assume "same
key material" across machines without checking — either always run `bastion-up` from
the same place, or explicitly `scp` the resulting private key to every place that needs
to SSH in afterward. If SSH ever fails right after a fresh bastion-up elsewhere, suspect
this before anything else — check the AWS-registered key pair's fingerprint against the
local pubkey (see method above) rather than assuming network/SG issues.

**Guard added 2026-09-22**: `cmd_bastion_up` in `openshift-aws-harness/harness/harness.sh`
now compares the AWS-registered key pair's public key against local `${SSH_KEY_PATH}.pub`
(via `describe-key-pairs --include-public-key`, exact string compare — no fingerprint math
needed) whenever it's about to reuse an existing key pair, and `err`s out immediately with
a clear message instead of silently proceeding. Turns this into a loud failure at
`bastion-up` time instead of a confusing SSH failure hours later. Not yet committed —
lives locally in the working tree.

## 2026-09-22 — Per-machine harness `state/<cluster>.env` goes stale across sandbox rotations and across machines/sessions

**Symptom**: `harness/state/myocp.env` on this machine held VPC/instance/IP values from
a Sept 8 sandbox that was already dead, while a different session had since built a
brand new bastion (different VPC, different instance ID, different IP) under the same
cluster name `myocp` on a rotated sandbox account. Running any harness subcommand from
this machine would have operated on stale/nonexistent resource IDs.

**Root cause**: `state/<cluster>.env` is per-machine and gitignored (by design — it's
runtime state, and these sandbox accounts rotate). Nothing reconciles it against the
other machine/session that actually ran `bastion-up`, so two environments' state files
for the same `CLUSTER_NAME` can point at two completely different AWS accounts/resources
with no warning.

**Fix applied**: before calling `destroy-bastion`, manually cross-checked the state file
against real AWS resources (`aws ec2 describe-instances`, `describe-internet-gateways`,
`describe-route-tables` filtered by the actual VPC/subnet) and overwrote the stale state
file with the real current IDs, backing up the old one as
`state/myocp.env.stale-sandbox2478.bak` first.

**How to apply going forward**: after any sandbox rotation, or whenever picking up a
harness-based build that another session/machine started, verify `state/<cluster>.env`
against live AWS state before running any subcommand that reads it — don't trust it by
default. `harness.sh status` is the quickest sanity check.

## 2026-09-22 — `create-cluster` can silently stall after network/LB/IAM with zero instances, and there's no local visibility into why

**Symptom**: ~2 hours after another session reported kicking off `harness.sh all`, AWS
showed the cluster VPC, load balancers, and master/worker IAM roles created, but zero
target groups, zero bootstrap/master/worker EC2 instances, and no api/console DNS
records — and no `RunInstances` CloudTrail events beyond the original bastion. Normal
progress reaches instance creation within minutes of the LB stage; ~1h40m with nothing
is not "still installing."

**Root cause**: not confirmed — never got bastion access before deciding to tear down
and restart (see the SSH key issue above), so the actual `openshift-install`/terraform
error log was never seen.

**How to apply going forward**: when a build looks stalled, check AWS resource
creation timestamps + CloudTrail `RunInstances` history first (fast, needs only AWS
creds) before assuming the install is still progressing. But that only tells you *that*
it stalled, not *why* — getting bastion access (SSH or SSM) to read the actual
`openshift-install`/terraform logs is the real next step, and should happen before
tearing anything down if at all possible, so the failure reason isn't lost. This time
the SSH key was already broken so that wasn't an option; if it happens again with
working SSH, pull the logs before destroying anything.
