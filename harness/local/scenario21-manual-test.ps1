<#
.SYNOPSIS
  Scenario 21 manual test for Windows PowerShell (5.1+): an in-cluster Pod
  calls the model through the MaaS Gateway with its ServiceAccount token.

.DESCRIPTION
  Run directly from your own PC (no SSH/bastion). Starts one client Pod per
  ServiceAccount, runs curl inside it via `oc exec`, prints each response,
  then deletes the Pods. See docs/scenarios/21-maas-in-cluster-pod-client.md.

  Requires: oc.exe on PATH, an admin `oc login` session, and the
  namespace/SAs/subscription created by `./harness.sh scenario21-pod-client`.

  The request body is passed into the Pod as base64 -- PowerShell 5.1 does
  not escape double quotes and re-encodes non-ASCII text when passing
  arguments to native executables, so a raw JSON body would arrive broken.

.EXAMPLE
  .\scenario21-manual-test.ps1
.EXAMPLE
  .\scenario21-manual-test.ps1 -Prompt '쿠버네티스를 한 문장으로 설명해줘'
.EXAMPLE
  .\scenario21-manual-test.ps1 -PathMode external
#>
param(
  [string]$Prompt = 'Say hello in one word.',
  [int]$MaxTokens = 64,
  [ValidateSet('internal', 'external')][string]$PathMode = 'internal',
  [string]$ClientNamespace = 'maas-pod-client',
  [string]$ClientSA = 'maas-client',
  [string]$DeniedSA = 'maas-client-nosub',
  [string]$ModelNamespace = 'maas-demo',
  [string]$ModelName = 'maas-demo-model',
  [string]$ClientImage = 'registry.access.redhat.com/ubi9/ubi-minimal:latest'
)
$ErrorActionPreference = 'Stop'
# UTF-8 for text piped into oc.exe and for Korean text coming back from it.
$utf8 = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8
[Console]::OutputEncoding = $utf8

function Invoke-Oc {
  # Runs oc.exe; throws on non-zero exit so failures are not silently ignored.
  $out = & oc @args
  if ($LASTEXITCODE -ne 0) { throw "oc $($args -join ' ') failed (exit $LASTEXITCODE)" }
  $out
}

function Section([string]$Text) { Write-Host ''; Write-Host "== $Text ==" -ForegroundColor Cyan }

# --- Preconditions ---------------------------------------------------------
& oc whoami *> $null
if ($LASTEXITCODE -ne 0) { throw 'oc login 먼저 필요.' }
& oc get sa $ClientSA $DeniedSA -n $ClientNamespace *> $null
if ($LASTEXITCODE -ne 0) { throw "$ClientNamespace 의 SA 없음 -- ./harness.sh scenario21-pod-client 먼저 실행." }

# --- Derived values --------------------------------------------------------
$domain     = Invoke-Oc get ingresses.config.openshift.io cluster -o 'jsonpath={.spec.domain}'
$maasHost   = "maas.$domain"
$gwSvc      = Invoke-Oc get svc -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=maas-default-gateway -o 'jsonpath={.items[0].metadata.name}'
$servedName = Invoke-Oc get llminferenceservice $ModelName -n $ModelNamespace -o 'jsonpath={.spec.model.name}'
$modelId    = "publishers/$ModelNamespace/models/$servedName"
$workload   = "$ModelName-kserve-workload-svc.$ModelNamespace.svc.cluster.local"
$connectTo  = if ($PathMode -eq 'internal') { "--connect-to ${maasHost}:443:${gwSvc}.openshift-ingress.svc.cluster.local:443" } else { '' }

function New-BodyB64([string]$Model) {
  $json = @{ model = $Model; messages = @(@{ role = 'user'; content = $Prompt }); max_tokens = $MaxTokens } |
    ConvertTo-Json -Depth 5 -Compress
  [Convert]::ToBase64String($utf8.GetBytes($json))
}

# --- In-Pod helper script (ConfigMap) --------------------------------------
# call.sh <url> [body-base64] : curl with the Pod's own SA token.
$callSh = @'
#!/bin/bash
T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
args=(-sk $CONNECT_TO --max-time 120 -w '\nHTTP %{http_code}\n' -H "Authorization: Bearer $T")
if [ -n "${2:-}" ]; then
  echo "$2" | base64 -d > /tmp/body
  curl "${args[@]}" -H 'Content-Type: application/json' --data-binary @/tmp/body "$1"
else
  curl "${args[@]}" "$1"
fi
'@
$cmFile = Join-Path $env:TEMP 'scenario21-call.sh'
[IO.File]::WriteAllText($cmFile, ($callSh -replace "`r`n", "`n"), $utf8)
Invoke-Oc create configmap maas-client-manual-script -n $ClientNamespace "--from-file=call.sh=$cmFile" --dry-run=client -o yaml |
  & oc apply -f - | Out-Null
Remove-Item $cmFile -Force

# --- Client Pods -----------------------------------------------------------
$podOk = "maas-client-manual-$ClientSA"
$podNo = "maas-client-manual-$DeniedSA"

function Start-ClientPod([string]$Pod, [string]$SA) {
  & oc delete pod $Pod -n $ClientNamespace --ignore-not-found *> $null
  $yaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: $Pod
  namespace: $ClientNamespace
spec:
  serviceAccountName: $SA
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: client
    image: $ClientImage
    command: [sleep, "600"]
    env: [{name: CONNECT_TO, value: "$connectTo"}]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    volumeMounts: [{name: scripts, mountPath: /scripts}]
  volumes: [{name: scripts, configMap: {name: maas-client-manual-script}}]
"@
  $yaml | & oc apply -f - | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Pod $Pod 생성 실패" }
}

function Invoke-PodCurl([string]$Pod, [string]$Url, [string]$BodyB64 = '') {
  if ($BodyB64) { & oc exec -n $ClientNamespace $Pod -- bash /scripts/call.sh $Url $BodyB64 }
  else          { & oc exec -n $ClientNamespace $Pod -- bash /scripts/call.sh $Url }
}

try {
  Section "0) client Pod 기동 ($ClientNamespace : SA $ClientSA, $DeniedSA)"
  Start-ClientPod $podOk $ClientSA
  Start-ClientPod $podNo $DeniedSA
  Invoke-Oc wait "pod/$podOk" "pod/$podNo" -n $ClientNamespace --for=condition=Ready --timeout=180s | Out-Null
  Write-Host "경로: $PathMode | host: $maasHost | model: $modelId"

  Section "1) [$ClientSA] GET /v1/models -- HTTP 200, 모델 1개 기대"
  Invoke-PodCurl $podOk "https://$maasHost/v1/models"

  Section "2) [$ClientSA] POST /v1/chat/completions -- HTTP 200 기대"
  Write-Host "질문: $Prompt"
  Invoke-PodCurl $podOk "https://$maasHost/v1/chat/completions" (New-BodyB64 $modelId)

  Section "3) [$DeniedSA] POST /v1/chat/completions -- HTTP 403 기대 (구독 없음)"
  Invoke-PodCurl $podNo "https://$maasHost/v1/chat/completions" (New-BodyB64 $modelId)

  Section "4) [$DeniedSA] vLLM Service 직접 호출 (Gateway 우회) -- NetworkPolicy 없으면 200"
  Invoke-PodCurl $podNo "https://${workload}:8000/v1/chat/completions" (New-BodyB64 $servedName)
}
finally {
  & oc delete pod $podOk $podNo -n $ClientNamespace --ignore-not-found --wait=false *> $null
}
