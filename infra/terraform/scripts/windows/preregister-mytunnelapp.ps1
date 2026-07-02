[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ServerBaseUrl,

  [Parameter(Mandatory = $true)]
  [string]$ServerUrl,

  [Parameter(Mandatory = $true)]
  [string]$ClientUid,

  [Parameter(Mandatory = $true)]
  [string]$EnrollmentSecret,

  [string]$ManagedClientType = "windows-msi",
  [string]$AvailablePeriod = "168h",
  [string]$PendingPeriod = "0s",
  [string]$ProbePath = "",
  [int]$SecretRefreshLeadMinutes = 15,
  [switch]$RefreshEnrollmentSecret
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-MyTunnelNormalizedLowerText {
  param(
    [AllowNull()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ""
  }

  return $Value.Trim().ToLowerInvariant()
}

function ConvertTo-MyTunnelHashtable {
  param(
    [AllowNull()]
    [object]$Value
  )

  $table = @{}
  if ($null -eq $Value) {
    return $table
  }
  if ($Value -is [hashtable]) {
    foreach ($key in $Value.Keys) {
      $table[[string]$key] = $Value[$key]
    }
    return $table
  }
  foreach ($property in $Value.PSObject.Properties) {
    $table[[string]$property.Name] = $property.Value
  }
  return $table
}

function ConvertFrom-MyTunnelJsonOrNull {
  param(
    [AllowNull()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  $trimmed = $Value.Trim()
  if ($trimmed -eq "null") {
    return $null
  }

  return $trimmed | ConvertFrom-Json -ErrorAction Stop
}

function Read-MyTunnelErrorResponseBody {
  param(
    [AllowNull()]
    [object]$Response
  )

  if ($null -eq $Response) {
    return ""
  }

  $stream = $null
  $reader = $null
  try {
    $stream = $Response.GetResponseStream()
    if ($null -eq $stream) {
      return ""
    }
    $reader = New-Object System.IO.StreamReader($stream)
    return $reader.ReadToEnd()
  } catch {
    return ""
  } finally {
    if ($null -ne $reader) {
      $reader.Dispose()
    }
    if ($null -ne $stream) {
      $stream.Dispose()
    }
  }
}

function Invoke-MyTunnelHttpJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Method,

    [Parameter(Mandatory = $true)]
    [string]$Url,

    [AllowNull()]
    [object]$Payload = $null
  )

  $request = @{
    Method          = $Method
    Uri             = $Url
    UseBasicParsing = $true
    ErrorAction     = "Stop"
    Headers         = @{
      "Content-Type" = "application/json"
    }
  }
  if ($null -ne $Payload) {
    $request.Body = ($Payload | ConvertTo-Json -Compress -Depth 10)
  }

  try {
    $response = Invoke-WebRequest @request
    return [PSCustomObject]@{
      status = [int]$response.StatusCode
      body   = [string]$response.Content
      error  = $null
    }
  } catch {
    $status = 0
    $body = ""
    if ($null -ne $_.Exception.Response) {
      try {
        $status = [int]$_.Exception.Response.StatusCode
      } catch {
        $status = 0
      }
      $body = Read-MyTunnelErrorResponseBody -Response $_.Exception.Response
    }
    return [PSCustomObject]@{
      status = $status
      body   = [string]$body
      error  = [string]$_.Exception.Message
    }
  }
}

function Assert-MyTunnelHttpStatus {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Response,

    [Parameter(Mandatory = $true)]
    [int[]]$ExpectedStatus,

    [Parameter(Mandatory = $true)]
    [string]$Context
  )

  if ($ExpectedStatus -contains [int]$Response.status) {
    return
  }

  $message = [string]$Response.body
  if ([string]::IsNullOrWhiteSpace($message)) {
    $message = [string]$Response.error
  }
  throw "$Context failed with HTTP $($Response.status): $message"
}

function Resolve-MyTunnelProbePath {
  param(
    [string]$PreferredPath = ""
  )

  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
    $candidates.Add($PreferredPath) | Out-Null
  }
  $candidates.Add((Join-Path $PSScriptRoot "device-id-probe.exe")) | Out-Null
  $candidates.Add("C:\Program Files\MyTunnelApp\device-id-probe.exe") | Out-Null

  try {
    $command = Get-Command "device-id-probe.exe" -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
      $candidates.Add([string]$command.Source) | Out-Null
    }
  } catch {
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  return $null
}

function Get-MyTunnelDeviceIdViaProbe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResolvedProbePath
  )

  $output = & $ResolvedProbePath -json 2>&1
  $exitCode = $LASTEXITCODE
  $text = ($output | Out-String).Trim()
  if ($exitCode -ne 0) {
    throw "device-id-probe.exe failed with exit code $exitCode: $text"
  }
  if ([string]::IsNullOrWhiteSpace($text)) {
    throw "device-id-probe.exe returned an empty JSON payload"
  }

  $decoded = $text | ConvertFrom-Json -ErrorAction Stop
  $deviceId = [string]$decoded.expected_device_id
  if ([string]::IsNullOrWhiteSpace($deviceId)) {
    $deviceId = [string]$decoded.device_id
  }
  $deviceId = Get-MyTunnelNormalizedLowerText -Value $deviceId
  if ([string]::IsNullOrWhiteSpace($deviceId)) {
    throw "device-id-probe.exe JSON did not contain expected_device_id or device_id"
  }

  return $deviceId
}

function Get-MyTunnelDeviceIdViaEndorsementKey {
  if (-not (Get-Command Get-TpmEndorsementKeyInfo -ErrorAction SilentlyContinue)) {
    throw "Get-TpmEndorsementKeyInfo is unavailable and device-id-probe.exe was not found"
  }

  $ekInfo = Get-TpmEndorsementKeyInfo -HashAlgorithm Sha256
  if ($null -eq $ekInfo -or $null -eq $ekInfo.PublicKey -or $null -eq $ekInfo.PublicKey.RawData -or $ekInfo.PublicKey.RawData.Length -eq 0) {
    throw "TPM endorsement key public key is unavailable"
  }

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($ekInfo.PublicKey.RawData)
  } finally {
    $sha.Dispose()
  }

  return (-join ($hash | ForEach-Object { $_.ToString("x2") }))
}

function Resolve-MyTunnelDeviceId {
  param(
    [string]$PreferredProbePath = ""
  )

  $resolvedProbePath = Resolve-MyTunnelProbePath -PreferredPath $PreferredProbePath
  if (-not [string]::IsNullOrWhiteSpace($resolvedProbePath)) {
    return [PSCustomObject]@{
      device_id  = (Get-MyTunnelDeviceIdViaProbe -ResolvedProbePath $resolvedProbePath)
      probe_path = $resolvedProbePath
      probe_mode = "helper"
    }
  }

  return [PSCustomObject]@{
    device_id  = (Get-MyTunnelDeviceIdViaEndorsementKey)
    probe_path = $null
    probe_mode = "powershell"
  }
}

function Get-MyTunnelClient {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResolvedServerBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedClientUid
  )

  $url = "{0}/api/client/{1}" -f $ResolvedServerBaseUrl, ([Uri]::EscapeDataString($ResolvedClientUid))
  $response = Invoke-MyTunnelHttpJson -Method "GET" -Url $url
  Assert-MyTunnelHttpStatus -Response $response -ExpectedStatus @(200) -Context "GET /api/client"
  return ConvertFrom-MyTunnelJsonOrNull -Value $response.body
}

function Add-MyTunnelClient {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResolvedServerBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedClientUid,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedDeviceId,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedManagedClientType
  )

  $url = "{0}/admin/api/client/add" -f $ResolvedServerBaseUrl
  $payload = @{
    uid        = $ResolvedClientUid
    attributes = @{
      device_id           = $ResolvedDeviceId
      managed_client_type = $ResolvedManagedClientType
    }
  }
  $response = Invoke-MyTunnelHttpJson -Method "POST" -Url $url -Payload $payload
  Assert-MyTunnelHttpStatus -Response $response -ExpectedStatus @(200) -Context "POST /admin/api/client/add"
}

function Update-MyTunnelClient {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResolvedServerBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedClientUid,

    [Parameter(Mandatory = $true)]
    [hashtable]$Attributes
  )

  $url = "{0}/admin/api/client/update" -f $ResolvedServerBaseUrl
  $payload = @{
    uid        = $ResolvedClientUid
    attributes = $Attributes
  }
  $response = Invoke-MyTunnelHttpJson -Method "PUT" -Url $url -Payload $payload
  Assert-MyTunnelHttpStatus -Response $response -ExpectedStatus @(200) -Context "PUT /admin/api/client/update"
}

function Revoke-MyTunnelClient {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResolvedServerBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedClientUid
  )

  $url = "{0}/admin/api/client/revoke" -f $ResolvedServerBaseUrl
  $payload = @{
    uid        = $ResolvedClientUid
    attributes = @{}
  }
  $response = Invoke-MyTunnelHttpJson -Method "POST" -Url $url -Payload $payload
  Assert-MyTunnelHttpStatus -Response $response -ExpectedStatus @(200) -Context "POST /admin/api/client/revoke"
}

function Get-MyTunnelSecretInfo {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResolvedServerBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedClientUid
  )

  $url = "{0}/admin/api/secret/get/{1}" -f $ResolvedServerBaseUrl, ([Uri]::EscapeDataString($ResolvedClientUid))
  $response = Invoke-MyTunnelHttpJson -Method "GET" -Url $url
  if ([int]$response.status -eq 200) {
    return ConvertFrom-MyTunnelJsonOrNull -Value $response.body
  }

  $bodyText = [string]$response.body
  if (([int]$response.status -eq 404) -or ($bodyText -match "sql: no rows in result set")) {
    return $null
  }

  Assert-MyTunnelHttpStatus -Response $response -ExpectedStatus @(200) -Context "GET /admin/api/secret/get"
  return $null
}

function New-MyTunnelEnrollmentSecret {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResolvedServerBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedClientUid,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedEnrollmentSecret,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedAvailablePeriod,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedPendingPeriod
  )

  $url = "{0}/admin/api/secret/create" -f $ResolvedServerBaseUrl
  $payload = @{
    target           = $ResolvedClientUid
    secret           = $ResolvedEnrollmentSecret
    available_period = $ResolvedAvailablePeriod
    pending_period   = $ResolvedPendingPeriod
  }
  $response = Invoke-MyTunnelHttpJson -Method "POST" -Url $url -Payload $payload
  Assert-MyTunnelHttpStatus -Response $response -ExpectedStatus @(201) -Context "POST /admin/api/secret/create"
}

function Test-MyTunnelSecretNeedsRefresh {
  param(
    [AllowNull()]
    [object]$SecretInfo,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedEnrollmentSecret,

    [Parameter(Mandatory = $true)]
    [int]$LeadMinutes,

    [Parameter(Mandatory = $true)]
    [bool]$ForceRefresh
  )

  if ($ForceRefresh) {
    return $true
  }
  if ($null -eq $SecretInfo) {
    return $true
  }

  $storedSecret = [string]$SecretInfo.secret
  if ($storedSecret -ne $ResolvedEnrollmentSecret) {
    return $true
  }

  $deleteAtText = [string]$SecretInfo.delete_at
  if ([string]::IsNullOrWhiteSpace($deleteAtText)) {
    return $true
  }

  try {
    $deleteAt = [DateTimeOffset]::Parse($deleteAtText).ToUniversalTime()
  } catch {
    return $true
  }

  return $deleteAt -le [DateTimeOffset]::UtcNow.AddMinutes([Math]::Max($LeadMinutes, 0))
}

function Invoke-MyTunnelPreregCheck {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResolvedServerBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedClientUid,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedDeviceId
  )

  $url = "{0}/api/attestation/prereg-check" -f $ResolvedServerBaseUrl
  $payload = @{
    client_uid = $ResolvedClientUid
    device_id  = $ResolvedDeviceId
  }
  $response = Invoke-MyTunnelHttpJson -Method "POST" -Url $url -Payload $payload
  Assert-MyTunnelHttpStatus -Response $response -ExpectedStatus @(200) -Context "POST /api/attestation/prereg-check"
  $decoded = ConvertFrom-MyTunnelJsonOrNull -Value $response.body
  if ($null -eq $decoded -or [string]::IsNullOrWhiteSpace([string]$decoded.result)) {
    throw "prereg-check response did not contain a result field"
  }
  return ([string]$decoded.result).Trim().ToLowerInvariant()
}

$resolvedManagedClientType = Get-MyTunnelNormalizedLowerText -Value $ManagedClientType
if ($resolvedManagedClientType -ne "windows-msi") {
  throw "ManagedClientType must be windows-msi"
}

$resolvedServerBaseUrl = $ServerBaseUrl.Trim().TrimEnd("/")
if ([string]::IsNullOrWhiteSpace($resolvedServerBaseUrl)) {
  throw "ServerBaseUrl is required"
}

$resolvedServerUrl = $ServerUrl.Trim().TrimEnd("/")
if ([string]::IsNullOrWhiteSpace($resolvedServerUrl)) {
  throw "ServerUrl is required"
}
if (-not $resolvedServerUrl.EndsWith("/scep")) {
  throw "ServerUrl must point to the SCEP endpoint and end with /scep"
}

$resolvedClientUid = $ClientUid.Trim()
if ([string]::IsNullOrWhiteSpace($resolvedClientUid)) {
  throw "ClientUid is required"
}

$resolvedEnrollmentSecret = $EnrollmentSecret.Trim()
if ([string]::IsNullOrWhiteSpace($resolvedEnrollmentSecret)) {
  throw "EnrollmentSecret is required"
}

$deviceIdentity = Resolve-MyTunnelDeviceId -PreferredProbePath $ProbePath
$resolvedDeviceId = Get-MyTunnelNormalizedLowerText -Value ([string]$deviceIdentity.device_id)
if ([string]::IsNullOrWhiteSpace($resolvedDeviceId)) {
  throw "device_id probe returned an empty value"
}

$client = Get-MyTunnelClient -ResolvedServerBaseUrl $resolvedServerBaseUrl -ResolvedClientUid $resolvedClientUid
if ($null -eq $client) {
  Add-MyTunnelClient `
    -ResolvedServerBaseUrl $resolvedServerBaseUrl `
    -ResolvedClientUid $resolvedClientUid `
    -ResolvedDeviceId $resolvedDeviceId `
    -ResolvedManagedClientType $resolvedManagedClientType
  $client = Get-MyTunnelClient -ResolvedServerBaseUrl $resolvedServerBaseUrl -ResolvedClientUid $resolvedClientUid
}

$attributes = ConvertTo-MyTunnelHashtable -Value $client.attributes
$attributes["device_id"] = $resolvedDeviceId
$attributes["managed_client_type"] = $resolvedManagedClientType
Update-MyTunnelClient -ResolvedServerBaseUrl $resolvedServerBaseUrl -ResolvedClientUid $resolvedClientUid -Attributes $attributes
$client = Get-MyTunnelClient -ResolvedServerBaseUrl $resolvedServerBaseUrl -ResolvedClientUid $resolvedClientUid
$status = [string]$client.status
$allowedStatuses = @("INACTIVE", "ISSUABLE", "ISSUED")
if ($allowedStatuses -notcontains $status) {
  throw "ClientUid $resolvedClientUid is in unsupported status $status"
}
$secretInfo = Get-MyTunnelSecretInfo -ResolvedServerBaseUrl $resolvedServerBaseUrl -ResolvedClientUid $resolvedClientUid
$needsRefresh = Test-MyTunnelSecretNeedsRefresh `
  -SecretInfo $secretInfo `
  -ResolvedEnrollmentSecret $resolvedEnrollmentSecret `
  -LeadMinutes $SecretRefreshLeadMinutes `
  -ForceRefresh ([bool]$RefreshEnrollmentSecret)

if ($status -eq "ISSUED" -and $needsRefresh) {
  throw "ClientUid $resolvedClientUid is already ISSUED; refusing to refresh the initial enrollment secret automatically"
}

if ($status -eq "ISSUABLE" -and $needsRefresh) {
  Revoke-MyTunnelClient -ResolvedServerBaseUrl $resolvedServerBaseUrl -ResolvedClientUid $resolvedClientUid
  $status = "INACTIVE"
}

if ($status -eq "INACTIVE" -or $needsRefresh) {
  New-MyTunnelEnrollmentSecret `
    -ResolvedServerBaseUrl $resolvedServerBaseUrl `
    -ResolvedClientUid $resolvedClientUid `
    -ResolvedEnrollmentSecret $resolvedEnrollmentSecret `
    -ResolvedAvailablePeriod $AvailablePeriod `
    -ResolvedPendingPeriod $PendingPeriod
}

$client = Get-MyTunnelClient -ResolvedServerBaseUrl $resolvedServerBaseUrl -ResolvedClientUid $resolvedClientUid
$secretInfo = Get-MyTunnelSecretInfo -ResolvedServerBaseUrl $resolvedServerBaseUrl -ResolvedClientUid $resolvedClientUid
$preregResult = Invoke-MyTunnelPreregCheck `
  -ResolvedServerBaseUrl $resolvedServerBaseUrl `
  -ResolvedClientUid $resolvedClientUid `
  -ResolvedDeviceId $resolvedDeviceId

if ($preregResult -ne "ready") {
  throw "prereg-check returned $preregResult instead of ready"
}

$secretDeleteAt = $null
if ($null -ne $secretInfo -and -not [string]::IsNullOrWhiteSpace([string]$secretInfo.delete_at)) {
  try {
    $secretDeleteAt = ([DateTimeOffset]::Parse([string]$secretInfo.delete_at).ToUniversalTime().ToString("o"))
  } catch {
    $secretDeleteAt = [string]$secretInfo.delete_at
  }
}

[ordered]@{
  server_base_url     = $resolvedServerBaseUrl
  server_url          = $resolvedServerUrl
  client_uid          = $resolvedClientUid
  managed_client_type = $resolvedManagedClientType
  expected_device_id  = $resolvedDeviceId
  enrollment_secret   = $resolvedEnrollmentSecret
  client_status       = [string]$client.status
  prereg_result       = $preregResult
  secret_delete_at    = $secretDeleteAt
  probe_mode          = [string]$deviceIdentity.probe_mode
  probe_path          = [string]$deviceIdentity.probe_path
} | ConvertTo-Json -Depth 8
