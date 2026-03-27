$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function ConvertTo-MyTunnelSafeComponent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  $builder = New-Object System.Text.StringBuilder
  foreach ($ch in $Value.ToCharArray()) {
    if (
      (($ch -ge 'a') -and ($ch -le 'z')) -or
      (($ch -ge 'A') -and ($ch -le 'Z')) -or
      (($ch -ge '0') -and ($ch -le '9')) -or
      ($ch -eq '-') -or
      ($ch -eq '_')
    ) {
      [void]$builder.Append($ch)
    } else {
      [void]$builder.Append('-')
    }
  }

  $builder.ToString()
}

function ConvertTo-MyTunnelCompactText {
  param(
    [AllowNull()]
    [string]$Value,
    [int]$MaxLength = 240
  )

  if ([string]::IsNullOrEmpty($Value)) {
    return $null
  }

  $compact = [regex]::Replace($Value, '\x1b\[[0-9;]*[A-Za-z]', '')
  $compact = $compact -replace '\s+', ' '
  $compact = $compact.Trim()
  if ([string]::IsNullOrEmpty($compact)) {
    return $null
  }
  if ($compact.Length -le $MaxLength) {
    return $compact
  }

  return $compact.Substring(0, [Math]::Max($MaxLength - 3, 0)) + '...'
}

function ConvertTo-MyTunnelBase64UrlString {
  param(
    [Parameter(Mandatory = $true)]
    [byte[]]$Bytes
  )

  [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-MyTunnelBase64UrlString {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  $normalized = $Value.Replace('-', '+').Replace('_', '/')
  switch ($normalized.Length % 4) {
    0 { break }
    2 { $normalized += '=='; break }
    3 { $normalized += '='; break }
    default { throw "invalid base64url length: $($Value.Length)" }
  }

  [Convert]::FromBase64String($normalized)
}

function Resolve-MyTunnelMsiPath {
  param(
    [string]$PreferredPath = ""
  )

  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
    $candidates += $PreferredPath
  }
  $candidates += @(
    "$env:USERPROFILE\MyTunnelApp.msi",
    'C:\Users\Public\MyTunnelApp.msi'
  )

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  throw "MSI not found in expected paths: $($candidates -join ', ')"
}

function Get-MyTunnelBundledHelperPath {
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='MyTunnelService'" -ErrorAction SilentlyContinue
  if ($null -eq $service) {
    throw 'MyTunnelService is not installed; cannot locate bundled helper'
  }

  $servicePathName = [string]$service.PathName
  if ([string]::IsNullOrWhiteSpace($servicePathName)) {
    throw 'MyTunnelService does not report an executable path'
  }

  $serviceExePath = $null
  if ($servicePathName.StartsWith('"')) {
    $closingQuote = $servicePathName.IndexOf('"', 1)
    if ($closingQuote -lt 1) {
      throw "MyTunnelService PathName is malformed: $servicePathName"
    }
    $serviceExePath = $servicePathName.Substring(1, $closingQuote - 1)
  } else {
    $serviceExePath = ($servicePathName -split '\s+', 2)[0]
  }

  if ([string]::IsNullOrWhiteSpace($serviceExePath)) {
    throw "Unable to resolve MyTunnelService executable path from PathName: $servicePathName"
  }

  $helperPath = Join-Path (Split-Path -Parent $serviceExePath) 'scepclient.exe'
  if (-not (Test-Path -LiteralPath $helperPath)) {
    throw "Bundled scepclient.exe was not found at $helperPath"
  }

  $helperPath
}

function Resolve-MyTunnelDeviceIdProbePath {
  param(
    [string]$PreferredPath = ""
  )

  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
    $candidates.Add($PreferredPath)
  }
  try {
    $candidates.Add((Get-MyTunnelBundledHelperPath -replace 'scepclient\.exe$', 'device-id-probe.exe'))
  } catch {
  }
  $candidates.Add('C:\Users\Public\device-id-probe.exe')
  $candidates.Add('C:\Program Files\MyTunnelApp\device-id-probe.exe')

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  throw "device-id-probe.exe was not found in expected paths: $($candidates -join ', ')"
}

function Invoke-MyTunnelDeviceIdProbe {
  param(
    [string]$ProbePath = ""
  )

  $resolvedProbePath = Resolve-MyTunnelDeviceIdProbePath -PreferredPath $ProbePath
  $probeResult = Invoke-MyTunnelCapturedProcess -FilePath $resolvedProbePath -ArgumentList @('-json')
  if ($probeResult.exit_code -ne 0) {
    $failureText = $probeResult.stderr
    if ([string]::IsNullOrWhiteSpace($failureText)) {
      $failureText = $probeResult.stdout
    }
    throw "device-id-probe.exe failed with exit code $($probeResult.exit_code): $(ConvertTo-MyTunnelCompactText -Value $failureText)"
  }

  $jsonText = [string]$probeResult.stdout
  $jsonText = $jsonText.Trim()
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    throw 'device-id-probe.exe did not return a JSON payload'
  }

  try {
    $probe = $jsonText | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "device-id-probe.exe returned invalid JSON: $(ConvertTo-MyTunnelCompactText -Value $jsonText)"
  }

  $resolvedDeviceId = [string]$probe.device_id
  $resolvedExpectedDeviceId = [string]$probe.expected_device_id
  if ([string]::IsNullOrWhiteSpace($resolvedExpectedDeviceId)) {
    $resolvedExpectedDeviceId = $resolvedDeviceId
  }
  if ([string]::IsNullOrWhiteSpace($resolvedDeviceId)) {
    $resolvedDeviceId = $resolvedExpectedDeviceId
  }
  if ([string]::IsNullOrWhiteSpace($resolvedDeviceId) -or [string]::IsNullOrWhiteSpace($resolvedExpectedDeviceId)) {
    throw 'device-id-probe.exe did not return device_id / expected_device_id'
  }
  if ($resolvedDeviceId -ne $resolvedExpectedDeviceId) {
    throw "device-id-probe.exe returned mismatched device_id=$resolvedDeviceId and expected_device_id=$resolvedExpectedDeviceId"
  }

  $ekPublicB64 = [string]$probe.ek_public_b64
  if ([string]::IsNullOrWhiteSpace($ekPublicB64)) {
    throw 'device-id-probe.exe did not return ek_public_b64'
  }

  [ordered]@{
    probe_path          = $resolvedProbePath
    device_id           = $resolvedDeviceId
    expected_device_id  = $resolvedExpectedDeviceId
    ek_public_b64       = $ekPublicB64
  }
}

function ConvertTo-MyTunnelProcessArgument {
  param(
    [AllowNull()]
    [string]$Value
  )

  if ($null -eq $Value -or $Value.Length -eq 0) {
    return '""'
  }
  if ($Value -notmatch '[\s"]') {
    return $Value
  }

  $builder = New-Object System.Text.StringBuilder
  [void]$builder.Append('"')
  $backslashCount = 0

  foreach ($ch in $Value.ToCharArray()) {
    if ($ch -eq '\') {
      $backslashCount += 1
      continue
    }

    if ($ch -eq '"') {
      [void]$builder.Append((''.PadLeft(($backslashCount * 2) + 1, '\')))
      [void]$builder.Append('"')
      $backslashCount = 0
      continue
    }

    if ($backslashCount -gt 0) {
      [void]$builder.Append((''.PadLeft($backslashCount, '\')))
      $backslashCount = 0
    }

    [void]$builder.Append($ch)
  }

  if ($backslashCount -gt 0) {
    [void]$builder.Append((''.PadLeft($backslashCount * 2, '\')))
  }
  [void]$builder.Append('"')

  $builder.ToString()
}

function Invoke-MyTunnelCapturedProcess {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [string[]]$ArgumentList = @()
  )

  $argumentString = (
    $ArgumentList |
      ForEach-Object { ConvertTo-MyTunnelProcessArgument -Value ([string]$_) }
  ) -join ' '
  $captureId = [guid]::NewGuid().ToString('N')
  $stdoutPath = Join-Path $env:TEMP ("mytunnel-helper-stdout-{0}.log" -f $captureId)
  $stderrPath = Join-Path $env:TEMP ("mytunnel-helper-stderr-{0}.log" -f $captureId)

  $process = $null
  $exitCode = $null
  $stdout = ''
  $stderr = ''

  try {
    $process = Start-Process `
      -FilePath $FilePath `
      -ArgumentList $argumentString `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -Wait `
      -PassThru

    $stdout = if (Test-Path -LiteralPath $stdoutPath) {
      [System.IO.File]::ReadAllText($stdoutPath)
    } else {
      ''
    }
    $stderr = if (Test-Path -LiteralPath $stderrPath) {
      [System.IO.File]::ReadAllText($stderrPath)
    } else {
      ''
    }
    $exitCode = [int]$process.ExitCode
  } finally {
    if ($null -ne $process) {
      $process.Dispose()
    }
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }

  [ordered]@{
    exit_code = $exitCode
    stdout    = $stdout
    stderr    = $stderr
  }
}

function Get-MyTunnelInstalledProductCodes {
  $uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  )

  $productCodes = New-Object System.Collections.Generic.List[string]
  foreach ($root in $uninstallRoots) {
    if (-not (Test-Path -LiteralPath $root)) {
      continue
    }

    foreach ($entry in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
      $props = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue
      if ($null -eq $props) {
        continue
      }

      $displayNameProperty = $props.PSObject.Properties['DisplayName']
      if ($null -eq $displayNameProperty -or $displayNameProperty.Value -ne 'MyTunnelApp') {
        continue
      }

      if ($entry.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
        $productCodes.Add($entry.PSChildName)
      }
    }
  }

  @($productCodes | Select-Object -Unique)
}

function ConvertFrom-MyTunnelPem {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $pemText = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
  $match = [regex]::Match(
    $pemText,
    '-----BEGIN CERTIFICATE-----\s*(?<body>[A-Za-z0-9+/=\r\n]+?)\s*-----END CERTIFICATE-----'
  )
  if (-not $match.Success) {
    throw "PEM file does not contain a certificate body: $Path"
  }

  $pemBody = (
    $match.Groups['body'].Value -split "`r?`n" |
      Where-Object { $_ }
  ) -join ''

  if ([string]::IsNullOrWhiteSpace($pemBody)) {
    throw "PEM file does not contain a certificate body: $Path"
  }

  $bytes = [Convert]::FromBase64String($pemBody)
  New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $bytes)
}

function Get-MyTunnelInstallSummary {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId
  )

  $registryPath = 'HKLM:\SOFTWARE\MyTunnelApp'
  $managedDir = Join-Path 'C:\ProgramData\MyTunnelApp\managed' ("{0}-{1}" -f (ConvertTo-MyTunnelSafeComponent -Value $ClientUid), (ConvertTo-MyTunnelSafeComponent -Value $ExpectedDeviceId))
  $managedCertPath = Join-Path $managedDir 'cert.pem'
  $managedKeyPath = Join-Path $managedDir 'key.pem'
  $fallbackConfigPath = 'C:\ProgramData\MyTunnelApp\config.json'
  $logDir = 'C:\ProgramData\MyTunnelApp\logs'

  $registry = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='MyTunnelService'" -ErrorAction SilentlyContinue
  $logFiles = @(Get-ChildItem -Path $logDir -Filter 'service.log*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)

  $latestLogPath = $null
  $latestLogLastWriteUtc = $null
  $logContainsPlatformProvider = $false
  $logContainsManagedFileFallback = $false
  $recentLogLines = @()
  if ($logFiles.Count -gt 0) {
    $latestLogPath = $logFiles[0].FullName
    $latestLogLastWriteUtc = $logFiles[0].LastWriteTimeUtc.ToString('o')
    $recentLogLines = @(Get-Content -LiteralPath $latestLogPath -Tail 80 -ErrorAction SilentlyContinue)
    $recentLogText = $recentLogLines -join "`n"
    $logContainsPlatformProvider = $recentLogText -match 'Microsoft Platform Crypto Provider'
    $logContainsManagedFileFallback = $recentLogText -match 'Software RSA Key \(managed file\)|key\.pem'
  }

  $managedThumbprint = $null
  $presentInMachineStore = $false
  $managedCertLastWriteUtc = $null
  if (Test-Path -LiteralPath $managedCertPath) {
    try {
      $managedCertLastWriteUtc = (Get-Item -LiteralPath $managedCertPath).LastWriteTimeUtc.ToString('o')
    } catch {
      $managedCertLastWriteUtc = $null
    }
    try {
      $managedCert = ConvertFrom-MyTunnelPem -Path $managedCertPath
      $managedThumbprint = $managedCert.Thumbprint
      if ($managedThumbprint) {
        $storeMatch = Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
          Where-Object { $_.Thumbprint -eq $managedThumbprint } |
          Select-Object -First 1
        $presentInMachineStore = $null -ne $storeMatch
      }
    } catch {
      $managedThumbprint = "error:$($_.Exception.Message)"
    }
  }

  $registryPropertyNames = @()
  if ($null -ne $registry) {
    $registryPropertyNames = @($registry.PSObject.Properties.Name)
  }

  $fallbackConfigExists = Test-Path -LiteralPath $fallbackConfigPath
  $latestLogExcerpt = $null
  if ($recentLogLines.Count -gt 0) {
    $latestLogExcerpt = ConvertTo-MyTunnelCompactText -Value (($recentLogLines | Select-Object -Last 3) -join ' | ')
  }

  [ordered]@{
    observed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    registry        = [ordered]@{
      server_url                        = if ($null -ne $registry) { $registry.ServerUrl } else { $null }
      client_uid                        = if ($null -ne $registry) { $registry.ClientUid } else { $null }
      expected_device_id                = if ($null -ne $registry -and $registryPropertyNames -contains 'ExpectedDeviceId') { $registry.ExpectedDeviceId } elseif ($null -ne $registry) { $registry.DeviceId } else { $null }
      device_id                         = if ($null -ne $registry) { $registry.DeviceId } else { $null }
      poll_interval                     = if ($null -ne $registry) { $registry.PollInterval } else { $null }
      renew_before                      = if ($null -ne $registry) { $registry.RenewBefore } else { $null }
      log_level                         = if ($null -ne $registry) { $registry.LogLevel } else { $null }
      has_enrollment_secret             = $registryPropertyNames -contains 'EnrollmentSecret'
      has_enrollment_secret_protected   = $registryPropertyNames -contains 'EnrollmentSecretProtected'
    }
    config          = [ordered]@{
      path = $fallbackConfigPath
      exists = $fallbackConfigExists
    }
    service         = [ordered]@{
      exists      = $null -ne $service
      state       = if ($null -ne $service) { $service.State } else { $null }
      start_mode  = if ($null -ne $service) { $service.StartMode } else { $null }
      start_name  = if ($null -ne $service) { $service.StartName } else { $null }
    }
    managed         = [ordered]@{
      dir                     = $managedDir
      cert_path               = $managedCertPath
      cert_exists             = Test-Path -LiteralPath $managedCertPath
      cert_last_write_utc     = $managedCertLastWriteUtc
      key_path                = $managedKeyPath
      key_pem_exists          = Test-Path -LiteralPath $managedKeyPath
      managed_thumbprint      = $managedThumbprint
      present_in_machine_store = $presentInMachineStore
    }
    logs            = [ordered]@{
      latest_log_path                 = $latestLogPath
      latest_log_last_write_utc       = $latestLogLastWriteUtc
      contains_platform_provider      = $logContainsPlatformProvider
      contains_managed_file_fallback  = $logContainsManagedFileFallback
      latest_log_excerpt              = $latestLogExcerpt
    }
  }
}

function Get-MyTunnelConfigMismatchList {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Summary,

    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,

    [Parameter(Mandatory = $true)]
    [string]$PollInterval,

    [Parameter(Mandatory = $true)]
    [string]$RenewBefore,

    [Parameter(Mandatory = $true)]
    [string]$LogLevel
  )

  $mismatches = New-Object System.Collections.Generic.List[string]
  $registry = $Summary.registry

  if ($registry.server_url -ne $ServerUrl) {
    $mismatches.Add('server_url')
  }
  if ($registry.client_uid -ne $ClientUid) {
    $mismatches.Add('client_uid')
  }
  if ($registry.expected_device_id -ne $ExpectedDeviceId) {
    $mismatches.Add('expected_device_id')
  }
  if ($registry.device_id -ne $ExpectedDeviceId) {
    $mismatches.Add('device_id')
  }
  if ($registry.poll_interval -ne $PollInterval) {
    $mismatches.Add('poll_interval')
  }
  if ($registry.renew_before -ne $RenewBefore) {
    $mismatches.Add('renew_before')
  }
  if ($registry.log_level -ne $LogLevel) {
    $mismatches.Add('log_level')
  }

  @($mismatches)
}

function Add-MyTunnelInstallMetadata {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Summary,

    [Parameter(Mandatory = $true)]
    [string]$ResolvedMsiPath,

    [Parameter(Mandatory = $true)]
    [bool]$ForceFreshInstall,

    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [array]$RemovedProducts,

    [Parameter(Mandatory = $true)]
    [bool]$ApplyRegistryOverrides,

    [Parameter(Mandatory = $true)]
    [bool]$ConvergeToLocalService,

    [Parameter(Mandatory = $true)]
    [bool]$ReinstallRequested,

    [Parameter(Mandatory = $true)]
    [int]$MsiexecExitCode,

    [Parameter(Mandatory = $true)]
    [object]$PreInstallSummary,

    [Parameter(Mandatory = $true)]
    [bool]$RequireManagedThumbprintChange,

    [Parameter(Mandatory = $true)]
    [object]$PreregCheck,

    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,

    [Parameter(Mandatory = $true)]
    [string]$PollInterval,

    [Parameter(Mandatory = $true)]
    [string]$RenewBefore,

    [Parameter(Mandatory = $true)]
    [string]$LogLevel
  )

  $Summary['msi_path'] = $ResolvedMsiPath
  $Summary['fresh_install_requested'] = $ForceFreshInstall
  $Summary['fresh_install_removed_products'] = @($RemovedProducts)
  $Summary['apply_registry_overrides_requested'] = $ApplyRegistryOverrides
  $Summary['converge_to_local_service_requested'] = $ConvergeToLocalService
  $Summary['reinstall_requested'] = $ReinstallRequested
  $Summary['msiexec_exit_code'] = $MsiexecExitCode
  $Summary['reboot_required'] = $MsiexecExitCode -in @(1641, 3010)
  $Summary['pre_install_summary'] = $PreInstallSummary
  $Summary['prereg_check'] = $PreregCheck
  $Summary['managed_thumbprint_before'] = $PreInstallSummary.managed.managed_thumbprint
  $Summary['managed_thumbprint_after'] = $Summary.managed.managed_thumbprint
  $Summary['managed_thumbprint_changed'] = (
    $null -ne $PreInstallSummary.managed.managed_thumbprint -and
    $null -ne $Summary.managed.managed_thumbprint -and
    $PreInstallSummary.managed.managed_thumbprint -ne $Summary.managed.managed_thumbprint
  )
  $Summary['require_managed_thumbprint_change'] = $RequireManagedThumbprintChange
  $Summary['requested_config'] = [ordered]@{
    server_url          = $ServerUrl
    client_uid          = $ClientUid
    expected_device_id  = $ExpectedDeviceId
    poll_interval       = $PollInterval
    renew_before        = $RenewBefore
    log_level           = $LogLevel
  }
  $Summary
}

function ConvertTo-MyTunnelMarkerSummary {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Summary
  )

  $activationNegative = $null
  if ($Summary.PSObject.Properties.Match('activation_negative').Count -gt 0) {
    $activationNegative = $Summary.activation_negative
  }

  [ordered]@{
    observed_at_utc                 = $Summary.observed_at_utc
    prereg_check                    = $Summary.prereg_check
    registry                        = $Summary.registry
    config                          = $Summary.config
    service                         = $Summary.service
    managed                         = $Summary.managed
    logs                            = [ordered]@{
      latest_log_path                = $Summary.logs.latest_log_path
      latest_log_last_write_utc      = $Summary.logs.latest_log_last_write_utc
      contains_platform_provider     = $Summary.logs.contains_platform_provider
      contains_managed_file_fallback = $Summary.logs.contains_managed_file_fallback
      latest_log_excerpt             = $Summary.logs.latest_log_excerpt
    }
    msi_path                        = $Summary.msi_path
    fresh_install_requested         = $Summary.fresh_install_requested
    fresh_install_removed_products  = $Summary.fresh_install_removed_products
    apply_registry_overrides_requested = $Summary.apply_registry_overrides_requested
    converge_to_local_service_requested = $Summary.converge_to_local_service_requested
    reinstall_requested             = $Summary.reinstall_requested
    msiexec_exit_code               = $Summary.msiexec_exit_code
    reboot_required                 = $Summary.reboot_required
    managed_thumbprint_before       = $Summary.managed_thumbprint_before
    managed_thumbprint_after        = $Summary.managed_thumbprint_after
    managed_thumbprint_changed      = $Summary.managed_thumbprint_changed
    require_managed_thumbprint_change = $Summary.require_managed_thumbprint_change
    requested_config                = $Summary.requested_config
    reconfigure_fallback_used       = $Summary.reconfigure_fallback_used
    reconfigure_fallback_reason     = $Summary.reconfigure_fallback_reason
    initial_reinstall_registry      = if ($null -ne $Summary.initial_reinstall_summary) { $Summary.initial_reinstall_summary.registry } else { $null }
    activation_negative             = $activationNegative
  }
}

function Wait-MyTunnelInstallObservation {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,

    [object]$BaselineSummary = $null,
    [switch]$RequireManagedThumbprintChange,
    [int]$WaitSeconds = 90
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max($WaitSeconds, 0))
  $summary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId

  while ((Get-Date) -lt $deadline) {
    if ($null -eq $BaselineSummary) {
      if (
        $summary.registry.has_enrollment_secret_protected -or
        $summary.managed.cert_exists -or
        $summary.logs.latest_log_path
      ) {
        return $summary
      }
    } else {
      $managedThumbprintChanged = (
        $null -ne $summary.managed.managed_thumbprint -and
        $null -ne $BaselineSummary.managed.managed_thumbprint -and
        $summary.managed.managed_thumbprint -ne $BaselineSummary.managed.managed_thumbprint
      )
      $managedCertAppeared = (
        $summary.managed.cert_exists -and
        (-not $BaselineSummary.managed.cert_exists)
      )
      $managedCertUpdated = (
        $null -ne $summary.managed.cert_last_write_utc -and
        $summary.managed.cert_last_write_utc -ne $BaselineSummary.managed.cert_last_write_utc
      )
      $protectedSecretAppeared = (
        $summary.registry.has_enrollment_secret_protected -and
        (-not $BaselineSummary.registry.has_enrollment_secret_protected)
      )
      $logAdvanced = (
        $null -ne $summary.logs.latest_log_last_write_utc -and
        $summary.logs.latest_log_last_write_utc -ne $BaselineSummary.logs.latest_log_last_write_utc
      )

      if ($RequireManagedThumbprintChange) {
        if ($managedThumbprintChanged) {
          return $summary
        }

        if (
          $null -eq $BaselineSummary.managed.managed_thumbprint -and
          $summary.managed.cert_exists -and
          $summary.managed.present_in_machine_store
        ) {
          return $summary
        }
      } elseif (
        $managedThumbprintChanged -or
        $managedCertAppeared -or
        $managedCertUpdated -or
        $protectedSecretAppeared -or
        $logAdvanced
      ) {
        return $summary
      }
    }

    Start-Sleep -Seconds 5
    $summary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId
  }

  $summary
}

function Restart-MyTunnelService {
  $service = Get-Service -Name 'MyTunnelService' -ErrorAction SilentlyContinue
  if ($null -eq $service) {
    return
  }

  if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::StartPending) {
    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(60))
  }

  $service.Refresh()
  if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
    $stopped = $false
    for ($attempt = 1; $attempt -le 5; $attempt += 1) {
      try {
        Stop-Service -Name 'MyTunnelService' -Force -ErrorAction Stop
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(60))
        $stopped = $true
        break
      } catch {
        if ($attempt -ge 5) {
          $serviceCim = Get-CimInstance -ClassName Win32_Service -Filter "Name='MyTunnelService'" -ErrorAction SilentlyContinue
          $scQuery = Invoke-MyTunnelCapturedProcess -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList @(
            'queryex'
            'MyTunnelService'
          )
          $diagParts = @("stop_attempts=$attempt")
          if ($null -ne $serviceCim) {
            $diagParts += "start_name=$($serviceCim.StartName)"
            $diagParts += "state=$($serviceCim.State)"
            $diagParts += "exit_code=$($serviceCim.ExitCode)"
            $diagParts += "service_exit_code=$($serviceCim.ServiceSpecificExitCode)"
          }
          $scText = $scQuery.stderr
          if ([string]::IsNullOrWhiteSpace($scText)) {
            $scText = $scQuery.stdout
          }
          if (-not [string]::IsNullOrWhiteSpace($scText)) {
            $diagParts += "sc_queryex=$(ConvertTo-MyTunnelCompactText -Value $scText -MaxLength 500)"
          }
          throw "failed to stop MyTunnelService for restart: $($_.Exception.Message); $($diagParts -join '; ')"
        }

        Start-Sleep -Seconds 5
        $service.Refresh()
      }
    }
    if (-not $stopped) {
      throw 'MyTunnelService stop retry loop exhausted without success'
    }
  } elseif ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::StopPending) {
    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(60))
  }

  $service.Refresh()
  if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
    try {
      Start-Service -Name 'MyTunnelService' -ErrorAction Stop
      $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(60))
    } catch {
      $serviceCim = Get-CimInstance -ClassName Win32_Service -Filter "Name='MyTunnelService'" -ErrorAction SilentlyContinue
      $scQuery = Invoke-MyTunnelCapturedProcess -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList @(
        'queryex'
        'MyTunnelService'
      )
      $eventText = $null
      try {
        $recentEvents = Get-WinEvent -FilterHashtable @{
          LogName      = 'System'
          ProviderName = 'Service Control Manager'
          StartTime    = (Get-Date).AddMinutes(-15)
        } -MaxEvents 5
        if ($recentEvents) {
          $eventText = ($recentEvents |
            ForEach-Object {
              "[{0}] id={1} {2}" -f $_.TimeCreated.ToUniversalTime().ToString('o'), $_.Id, (ConvertTo-MyTunnelCompactText -Value $_.Message -MaxLength 400)
            }) -join ' | '
        }
      } catch {
        $eventText = "Get-WinEvent failed: $($_.Exception.Message)"
      }

      $diagParts = @()
      if ($null -ne $serviceCim) {
        $diagParts += "start_name=$($serviceCim.StartName)"
        $diagParts += "state=$($serviceCim.State)"
        $diagParts += "exit_code=$($serviceCim.ExitCode)"
        $diagParts += "service_exit_code=$($serviceCim.ServiceSpecificExitCode)"
      }
      $scText = $scQuery.stderr
      if ([string]::IsNullOrWhiteSpace($scText)) {
        $scText = $scQuery.stdout
      }
      if (-not [string]::IsNullOrWhiteSpace($scText)) {
        $diagParts += "sc_queryex=$(ConvertTo-MyTunnelCompactText -Value $scText -MaxLength 500)"
      }
      if (-not [string]::IsNullOrWhiteSpace($eventText)) {
        $diagParts += "events=$eventText"
      }

      throw "failed to start MyTunnelService after reconfiguration: $($_.Exception.Message); $($diagParts -join '; ')"
    }
  }

  Start-Sleep -Seconds 5
}

function Enable-MyTunnelLocalServiceConvergence {
  $programDataPath = 'C:\ProgramData\MyTunnelApp'
  New-Item -ItemType Directory -Path $programDataPath -Force | Out-Null

  $icaclsResult = Invoke-MyTunnelCapturedProcess -FilePath "$env:SystemRoot\System32\icacls.exe" -ArgumentList @(
    $programDataPath
    '/grant'
    'NT AUTHORITY\LOCAL SERVICE:(OI)(CI)(M)'
    '/T'
    '/C'
  )
  if ($icaclsResult.exit_code -ne 0) {
    $failureText = $icaclsResult.stderr
    if ([string]::IsNullOrWhiteSpace($failureText)) {
      $failureText = $icaclsResult.stdout
    }
    throw "icacls.exe grant for $programDataPath failed with exit code $($icaclsResult.exit_code): $(ConvertTo-MyTunnelCompactText -Value $failureText)"
  }

  $registryKeyPath = 'SOFTWARE\MyTunnelApp'
  $registryRights = (
    [System.Security.AccessControl.RegistryRights]::ReadKey -bor
    [System.Security.AccessControl.RegistryRights]::WriteKey -bor
    [System.Security.AccessControl.RegistryRights]::CreateSubKey -bor
    [System.Security.AccessControl.RegistryRights]::EnumerateSubKeys -bor
    [System.Security.AccessControl.RegistryRights]::Delete
  )
  $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::LocalMachine,
    [Microsoft.Win32.RegistryView]::Registry64
  )
  try {
    $registryKey = $baseKey.CreateSubKey(
      $registryKeyPath,
      [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree
    )
    if ($null -eq $registryKey) {
      throw "failed to open or create HKLM:\\$registryKeyPath for LocalService convergence"
    }

    try {
      $registrySecurity = $registryKey.GetAccessControl()
      $registryRule = New-Object System.Security.AccessControl.RegistryAccessRule(
        'NT AUTHORITY\LocalService',
        $registryRights,
        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
      )
      $registrySecurity.SetAccessRule($registryRule)
      $registryKey.SetAccessControl($registrySecurity)
    } finally {
      $registryKey.Close()
    }
  } finally {
    $baseKey.Close()
  }

  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='MyTunnelService'" -ErrorAction SilentlyContinue
  if ($null -eq $service) {
    throw 'MyTunnelService is not installed; cannot converge to LocalService'
  }

  if ([string]$service.StartName -ne 'NT AUTHORITY\LocalService') {
    $scResult = Invoke-MyTunnelCapturedProcess -FilePath "$env:SystemRoot\System32\sc.exe" -ArgumentList @(
      'config'
      'MyTunnelService'
      'obj='
      'NT AUTHORITY\LocalService'
      'password='
      ''
    )
    if ($scResult.exit_code -ne 0) {
      $failureText = $scResult.stderr
      if ([string]::IsNullOrWhiteSpace($failureText)) {
        $failureText = $scResult.stdout
      }
      throw "sc.exe config MyTunnelService failed with exit code $($scResult.exit_code): $(ConvertTo-MyTunnelCompactText -Value $failureText)"
    }
  }
}

function Apply-MyTunnelRegistryOverrides {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$EnrollmentSecret,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,

    [Parameter(Mandatory = $true)]
    [string]$PollInterval,

    [Parameter(Mandatory = $true)]
    [string]$RenewBefore,

    [Parameter(Mandatory = $true)]
    [string]$LogLevel
  )

  $registryPath = 'HKLM:\SOFTWARE\MyTunnelApp'
  if (-not (Test-Path -LiteralPath $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
  }

  $overrides = [ordered]@{
    ConfigURL        = $ServerUrl
    ServerUrl        = $ServerUrl
    ClientUid        = $ClientUid
    ExpectedDeviceId = $ExpectedDeviceId
    DeviceId         = $ExpectedDeviceId
    PollInterval     = $PollInterval
    RenewBefore      = $RenewBefore
    LogLevel         = $LogLevel
  }

  foreach ($entry in $overrides.GetEnumerator()) {
    Set-ItemProperty -LiteralPath $registryPath -Name $entry.Key -Value $entry.Value -Type String
  }

  if (-not [string]::IsNullOrWhiteSpace($EnrollmentSecret)) {
    Set-ItemProperty -LiteralPath $registryPath -Name 'EnrollmentSecret' -Value $EnrollmentSecret -Type String
  }

  Restart-MyTunnelService
}

function Resolve-MyTunnelAttestationNonceEndpoint {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl
  )

  $trimmed = $ServerUrl.TrimEnd('/')
  if ($trimmed -match '/scep$') {
    return ($trimmed -replace '/scep$', '/api/attestation/nonce')
  }

  "$trimmed/api/attestation/nonce"
}

function Resolve-MyTunnelAttestationPreregCheckEndpoint {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl
  )

  $trimmed = $ServerUrl.TrimEnd('/')
  if ($trimmed -match '/scep$') {
    return ($trimmed -replace '/scep$', '/api/attestation/prereg-check')
  }

  "$trimmed/api/attestation/prereg-check"
}

function Invoke-MyTunnelAttestationPreregCheck {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,

    [string]$DeviceIdProbePath = ""
  )

  $endpoint = Resolve-MyTunnelAttestationPreregCheckEndpoint -ServerUrl $ServerUrl
  $probeIdentity = Invoke-MyTunnelDeviceIdProbe -ProbePath $DeviceIdProbePath
  if ($probeIdentity.expected_device_id -ne $ExpectedDeviceId) {
    throw "device-id-probe.exe returned expected_device_id=$($probeIdentity.expected_device_id) instead of preregistered expected_device_id=$ExpectedDeviceId"
  }

  $requestBody = @{
    client_uid = $ClientUid
    device_id  = $probeIdentity.device_id
  } | ConvertTo-Json -Compress

  $response = Invoke-RestMethod -Method Post -Uri $endpoint -ContentType 'application/json' -Body $requestBody
  $result = [string]$response.result
  if ([string]::IsNullOrWhiteSpace($result)) {
    throw "attestation prereg-check response from $endpoint did not include a result"
  }

  $summary = [ordered]@{
    endpoint            = $endpoint
    result              = $result
    probe_path          = $probeIdentity.probe_path
    expected_device_id  = $probeIdentity.expected_device_id
    ek_public_b64       = $probeIdentity.ek_public_b64
  }

  switch ($result) {
    'ready' {
      return $summary
    }
    'client_not_found' {
      throw "attestation prereg-check reported client_not_found for client_uid=$ClientUid"
    }
    'device_id_mismatch' {
      throw "attestation prereg-check reported device_id_mismatch for client_uid=$ClientUid expected_device_id=$ExpectedDeviceId"
    }
    'not_issuable_yet' {
      throw "attestation prereg-check reported not_issuable_yet for client_uid=$ClientUid; issue the initial enrollment secret after preregistration and retry"
    }
    default {
      throw "attestation prereg-check returned unexpected result $result from $endpoint"
    }
  }
}

function Get-MyTunnelAttestationNonce {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,

    [string]$DeviceIdProbePath = ""
  )

  $endpoint = Resolve-MyTunnelAttestationNonceEndpoint -ServerUrl $ServerUrl
  $probeIdentity = Invoke-MyTunnelDeviceIdProbe -ProbePath $DeviceIdProbePath
  if ($probeIdentity.expected_device_id -ne $ExpectedDeviceId) {
    throw "device-id-probe.exe returned expected_device_id=$($probeIdentity.expected_device_id) instead of preregistered expected_device_id=$ExpectedDeviceId"
  }
  $requestBody = @{
    client_uid    = $ClientUid
    device_id     = $probeIdentity.device_id
    ek_public_b64 = $probeIdentity.ek_public_b64
  } | ConvertTo-Json -Compress

  $response = Invoke-RestMethod -Method Post -Uri $endpoint -ContentType 'application/json' -Body $requestBody
  $nonceValue = [string]$response.nonce
  if ([string]::IsNullOrWhiteSpace($nonceValue)) {
    throw "attestation nonce response from $endpoint did not include a nonce"
  }

  [ordered]@{
    endpoint            = $endpoint
    nonce               = $nonceValue
    probe_path          = $probeIdentity.probe_path
    expected_device_id  = $probeIdentity.expected_device_id
    ek_public_b64       = $probeIdentity.ek_public_b64
  }
}

function Invoke-MyTunnelTamperedActivationRenewal {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId
  )

  $managedDir = Join-Path 'C:\ProgramData\MyTunnelApp\managed' ("{0}-{1}" -f (ConvertTo-MyTunnelSafeComponent -Value $ClientUid), (ConvertTo-MyTunnelSafeComponent -Value $ExpectedDeviceId))
  $managedCertPath = Join-Path $managedDir 'cert.pem'
  if (-not (Test-Path -LiteralPath $managedCertPath)) {
    throw "tampered activation renewal requires an existing managed certificate at $managedCertPath"
  }

  $baselineSummary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId
  $helperPath = Get-MyTunnelBundledHelperPath
  $keyName = "{0}-{1}" -f (ConvertTo-MyTunnelSafeComponent -Value $ClientUid), (ConvertTo-MyTunnelSafeComponent -Value $ExpectedDeviceId)
  $keyProvider = 'Microsoft Platform Crypto Provider'
  $nonceInfo = Get-MyTunnelAttestationNonce -ServerUrl $ServerUrl -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId

  $placeholderClaims = [ordered]@{
    device_id   = $ExpectedDeviceId
    attestation = [ordered]@{
      format = 'tpm2-windows-v1-placeholder-renewal'
      nonce  = $nonceInfo.nonce
    }
  }
  $placeholderJson = $placeholderClaims | ConvertTo-Json -Depth 6 -Compress
  $placeholderEncoded = ConvertTo-MyTunnelBase64UrlString -Bytes ([System.Text.Encoding]::UTF8.GetBytes($placeholderJson))

  $emitResult = Invoke-MyTunnelCapturedProcess -FilePath $helperPath -ArgumentList @(
    '-uid'
    $ClientUid
    '-server-url'
    $ServerUrl
    '-emit-attestation'
    '-attestation'
    $placeholderEncoded
    '-key-provider'
    $keyProvider
    '-key-name'
    $keyName
  )
  if ($emitResult.exit_code -ne 0) {
    $emitFailureText = $emitResult.stderr
    if ([string]::IsNullOrWhiteSpace($emitFailureText)) {
      $emitFailureText = $emitResult.stdout
    }
    throw "scepclient.exe -emit-attestation failed with exit code $($emitResult.exit_code): $(ConvertTo-MyTunnelCompactText -Value $emitFailureText)"
  }

  $encodedAttestation = [string]$emitResult.stdout
  $encodedAttestation = $encodedAttestation.Trim()
  if ([string]::IsNullOrWhiteSpace($encodedAttestation)) {
    throw 'scepclient.exe -emit-attestation did not return an attestation payload'
  }

  $attestationJson = [System.Text.Encoding]::UTF8.GetString((ConvertFrom-MyTunnelBase64UrlString -Value $encodedAttestation))
  $attestationClaims = $attestationJson | ConvertFrom-Json
  if ($null -eq $attestationClaims.attestation) {
    throw 'emitted attestation payload did not contain an attestation object'
  }
  if ([string]::IsNullOrWhiteSpace([string]$attestationClaims.attestation.activation_id)) {
    throw 'emitted attestation payload did not contain activation_id'
  }
  if ([string]::IsNullOrWhiteSpace([string]$attestationClaims.attestation.activation_proof_b64)) {
    throw 'emitted attestation payload did not contain activation_proof_b64'
  }

  $attestationClaims.attestation.activation_proof_b64 = ConvertTo-MyTunnelBase64UrlString -Bytes ([System.Text.Encoding]::UTF8.GetBytes('tampered-activation-proof'))
  $tamperedJson = $attestationClaims | ConvertTo-Json -Depth 10 -Compress
  $tamperedEncoded = ConvertTo-MyTunnelBase64UrlString -Bytes ([System.Text.Encoding]::UTF8.GetBytes($tamperedJson))

  $renewalResult = Invoke-MyTunnelCapturedProcess -FilePath $helperPath -ArgumentList @(
    '-out'
    $managedCertPath
    '-uid'
    $ClientUid
    '-server-url'
    $ServerUrl
    '-key-provider'
    $keyProvider
    '-key-name'
    $keyName
    '-attestation'
    $tamperedEncoded
  )

  $finalSummary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId
  $thumbprintBefore = $baselineSummary.managed.managed_thumbprint
  $thumbprintAfter = $finalSummary.managed.managed_thumbprint
  $thumbprintChanged = (
    $null -ne $thumbprintBefore -and
    $null -ne $thumbprintAfter -and
    $thumbprintBefore -ne $thumbprintAfter
  )

  if ($renewalResult.exit_code -eq 0) {
    throw 'tampered activation renewal unexpectedly succeeded'
  }
  if (-not $finalSummary.managed.cert_exists) {
    throw "tampered activation renewal removed the managed certificate at $managedCertPath"
  }
  if (-not $finalSummary.managed.present_in_machine_store) {
    throw 'tampered activation renewal left the managed certificate absent from LocalMachine\My'
  }
  if ($thumbprintChanged) {
    throw "tampered activation renewal unexpectedly rotated the managed thumbprint from $thumbprintBefore to $thumbprintAfter"
  }

  [ordered]@{
    observed_at_utc            = (Get-Date).ToUniversalTime().ToString('o')
    helper_path                = $helperPath
    key_name                   = $keyName
    nonce_endpoint             = $nonceInfo.endpoint
    emit_attestation_exit_code = $emitResult.exit_code
    renewal_exit_code          = $renewalResult.exit_code
    renewal_rejected           = $renewalResult.exit_code -ne 0
    managed_thumbprint_before  = $thumbprintBefore
    managed_thumbprint_after   = $thumbprintAfter
    managed_thumbprint_changed = $thumbprintChanged
    renewal_stdout_excerpt     = ConvertTo-MyTunnelCompactText -Value $renewalResult.stdout
    renewal_stderr_excerpt     = ConvertTo-MyTunnelCompactText -Value $renewalResult.stderr
  }
}

function Invoke-MyTunnelAppSilentInstall {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$EnrollmentSecret,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,

    [string]$MsiPath = "",
    [string]$PollInterval = '1h',
    [string]$RenewBefore = '14d',
    [ValidateSet('trace', 'debug', 'info', 'warn', 'error')]
    [string]$LogLevel = 'info',
    [switch]$ForceFreshInstall,
    [switch]$ApplyRegistryOverrides,
    [switch]$ConvergeToLocalService,
    [switch]$RequireManagedThumbprintChange,
    [int]$WaitSeconds = 90
  )

  $resolvedMsiPath = Resolve-MyTunnelMsiPath -PreferredPath $MsiPath
  New-Item -ItemType Directory -Path 'C:\ProgramData\MyTunnelApp' -Force | Out-Null
  $preregCheck = Invoke-MyTunnelAttestationPreregCheck -ServerUrl $ServerUrl -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId
  $removedProducts = @()
  $preInstallSummary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId
  $existingProductCodes = @()

  if ($ForceFreshInstall) {
    foreach ($productCode in Get-MyTunnelInstalledProductCodes) {
      $uninstallProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $productCode, '/qn', '/norestart') -PassThru -Wait -NoNewWindow
      if ($uninstallProcess.ExitCode -notin @(0, 1605, 1614, 1641, 3010)) {
        throw "msiexec.exe uninstall failed for $productCode with exit code $($uninstallProcess.ExitCode)"
      }

      $removedProducts += [ordered]@{
        product_code = $productCode
        exit_code    = $uninstallProcess.ExitCode
      }
    }

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\MyTunnelApp') {
      Remove-Item -LiteralPath 'HKLM:\SOFTWARE\MyTunnelApp' -Recurse -Force
    }
  } else {
    $existingProductCodes = @(Get-MyTunnelInstalledProductCodes)
  }

  $arguments = @(
    '/i'
    $resolvedMsiPath
    "SERVER_URL=$ServerUrl"
    "CLIENT_UID=$ClientUid"
    "ENROLLMENT_SECRET=$EnrollmentSecret"
    "EXPECTED_DEVICE_ID=$ExpectedDeviceId"
    "POLL_INTERVAL=$PollInterval"
    "RENEW_BEFORE=$RenewBefore"
    "LOG_LEVEL=$LogLevel"
    '/qn'
    '/norestart'
  )

  if ($existingProductCodes.Count -gt 0) {
    $arguments += @(
      'REINSTALL=ALL'
      'REINSTALLMODE=vomus'
    )
  }

  $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -PassThru -Wait -NoNewWindow
  if ($process.ExitCode -notin @(0, 1641, 3010)) {
    throw "msiexec.exe failed with exit code $($process.ExitCode)"
  }

  if ($ConvergeToLocalService) {
    Enable-MyTunnelLocalServiceConvergence
  }

  if ($ApplyRegistryOverrides) {
    Apply-MyTunnelRegistryOverrides -ServerUrl $ServerUrl -ClientUid $ClientUid -EnrollmentSecret $EnrollmentSecret -ExpectedDeviceId $ExpectedDeviceId -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel
  } elseif ($ConvergeToLocalService) {
    Restart-MyTunnelService
  }

  $summary = Wait-MyTunnelInstallObservation -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId -BaselineSummary $preInstallSummary -RequireManagedThumbprintChange:$RequireManagedThumbprintChange -WaitSeconds $WaitSeconds
  $summary = Add-MyTunnelInstallMetadata -Summary $summary -ResolvedMsiPath $resolvedMsiPath -ForceFreshInstall ([bool]$ForceFreshInstall) -RemovedProducts $removedProducts -ApplyRegistryOverrides ([bool]$ApplyRegistryOverrides) -ConvergeToLocalService ([bool]$ConvergeToLocalService) -ReinstallRequested ($existingProductCodes.Count -gt 0) -MsiexecExitCode $process.ExitCode -PreInstallSummary $preInstallSummary -RequireManagedThumbprintChange ([bool]$RequireManagedThumbprintChange) -PreregCheck $preregCheck -ServerUrl $ServerUrl -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel

  if ((-not $ForceFreshInstall) -and (-not $ApplyRegistryOverrides) -and $existingProductCodes.Count -gt 0) {
    $mismatchList = @(Get-MyTunnelConfigMismatchList -Summary $summary -ServerUrl $ServerUrl -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel)
    if ($mismatchList.Count -gt 0) {
      $fallbackSummary = Invoke-MyTunnelAppSilentInstall -ServerUrl $ServerUrl -ClientUid $ClientUid -EnrollmentSecret $EnrollmentSecret -ExpectedDeviceId $ExpectedDeviceId -MsiPath $resolvedMsiPath -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel -ForceFreshInstall -ConvergeToLocalService:$ConvergeToLocalService -RequireManagedThumbprintChange:$RequireManagedThumbprintChange -WaitSeconds $WaitSeconds
      $fallbackSummary['reconfigure_fallback_used'] = $true
      $fallbackSummary['reconfigure_fallback_reason'] = "same-version reinstall left stale config for: $($mismatchList -join ', ')"
      $fallbackSummary['initial_reinstall_summary'] = $summary
      return $fallbackSummary
    }
  }

  $summary['reconfigure_fallback_used'] = $false
  $summary['reconfigure_fallback_reason'] = $null
  $summary['initial_reinstall_summary'] = $null
  $summary
}
