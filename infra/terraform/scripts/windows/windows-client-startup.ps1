$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$clientRoot = "C:\scep-client"
$binDir = Join-Path $clientRoot "bin"
$configDir = Join-Path $clientRoot "config"
$runtimeDir = Join-Path $clientRoot "runtime"
$stateDir = Join-Path $clientRoot "state"
$attestationDir = Join-Path $stateDir "attestation"
$logDir = Join-Path $clientRoot "logs"

$paths = @($clientRoot, $binDir, $configDir, $runtimeDir, $stateDir, $attestationDir, $logDir)
foreach ($path in $paths) {
  New-Item -Path $path -ItemType Directory -Force | Out-Null
}

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
  Write-Warning "Unable to force TLS 1.2: $($_.Exception.Message)"
}

$requiredTools = @("powershell.exe", "curl.exe", "certutil.exe")
$missingTools = @()
foreach ($tool in $requiredTools) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    $missingTools += $tool
  }
}

if ($missingTools.Count -gt 0) {
  Write-Warning ("Missing expected tools: {0}" -f ($missingTools -join ", "))
}

$binaryPlaceholders = @(
  @{
    path = Join-Path $binDir "scep-service.exe.placeholder"
    text = "TODO: replace with provisioned service binary."
  },
  @{
    path = Join-Path $binDir "scep-agent.exe.placeholder"
    text = "TODO: replace with provisioned attestation agent binary."
  }
)

foreach ($placeholder in $binaryPlaceholders) {
  Set-Content -Path $placeholder.path -Encoding UTF8 -Value $placeholder.text
}

$artifactAcquisitionTodo = @'
# TODO: Acquire signed artifacts from your release channel and place them in C:\scep-client\bin.
# Invoke-WebRequest -Uri "<service-binary-url>" -OutFile "C:\scep-client\bin\scep-service.exe"
# Invoke-WebRequest -Uri "<agent-binary-url>" -OutFile "C:\scep-client\bin\scep-agent.exe"
# TODO: Validate checksums/signatures before removing *.placeholder files.
'@
Set-Content -Path (Join-Path $runtimeDir "artifact-acquisition.todo.ps1") -Encoding UTF8 -Value $artifactAcquisitionTodo

$invocationTodo = @'
# TODO: Replace with production invocation commands once binaries/config are available.
# & "C:\scep-client\bin\scep-service.exe" --config "C:\scep-client\config\service.yaml"
# & "C:\scep-client\bin\scep-agent.exe" --attestation "C:\scep-client\state\attestation\attestation-payload.json"
'@
Set-Content -Path (Join-Path $runtimeDir "invoke-client.todo.ps1") -Encoding UTF8 -Value $invocationTodo

$tpmInfo = [ordered]@{
  present              = $false
  ready                = $false
  enabled              = $false
  activated            = $false
  owned                = $false
  manufacturer_id      = $null
  manufacturer_version = $null
  note                 = $null
}

if (Get-Command Get-Tpm -ErrorAction SilentlyContinue) {
  try {
    $tpm = Get-Tpm
    $tpmInfo.present = [bool]$tpm.TpmPresent
    $tpmInfo.ready = [bool]$tpm.TpmReady
    $tpmInfo.enabled = [bool]$tpm.TpmEnabled
    $tpmInfo.activated = [bool]$tpm.TpmActivated
    $tpmInfo.owned = [bool]$tpm.TpmOwned
    $tpmInfo.manufacturer_id = $tpm.ManufacturerId
    $tpmInfo.manufacturer_version = $tpm.ManufacturerVersion
  } catch {
    $tpmInfo.note = "Get-Tpm failed: $($_.Exception.Message)"
  }
} else {
  $tpmInfo.note = "Get-Tpm command not available."
}

$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
$serial = "unknownserial"
if ($bios -and $bios.SerialNumber) {
  $serial = ($bios.SerialNumber -replace "\s+", "").ToLowerInvariant()
}

$computerName = $env:COMPUTERNAME
if (-not $computerName) {
  $computerName = "unknownhost"
}

$deviceId = ("{0}-{1}" -f $computerName.ToLowerInvariant(), $serial).Trim("-")

$payload = [ordered]@{
  device_id        = $deviceId
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  tpm_info         = $tpmInfo
  attestation      = [ordered]@{
    nonce           = "TODO_NONCE"
    aik_public      = "TODO_AIK_PUBLIC"
    quote           = "TODO_TPM_QUOTE"
    quote_signature = "TODO_TPM_QUOTE_SIGNATURE"
    pcr_selection   = @()
  }
  execution        = [ordered]@{
    service_binary_path = "C:\scep-client\bin\scep-service.exe"
    agent_binary_path   = "C:\scep-client\bin\scep-agent.exe"
    invoke_todo_script  = "C:\scep-client\runtime\invoke-client.todo.ps1"
  }
}

$payloadPath = Join-Path $attestationDir "attestation-payload.json"
$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $payloadPath -Encoding UTF8

Set-Content -Path (Join-Path $logDir "startup-status.txt") -Encoding UTF8 -Value "Windows client provisioning assets prepared."
