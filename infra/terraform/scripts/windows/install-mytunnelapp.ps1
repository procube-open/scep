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
    [string]$DeviceIdOverride
  )

  $registryPath = 'HKLM:\SOFTWARE\MyTunnelApp'
  $managedDir = Join-Path 'C:\ProgramData\MyTunnelApp\managed' ("{0}-{1}" -f (ConvertTo-MyTunnelSafeComponent -Value $ClientUid), (ConvertTo-MyTunnelSafeComponent -Value $DeviceIdOverride))
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
      device_id                         = if ($null -ne $registry) { $registry.DeviceId } else { $null }
      device_id_override                = if ($null -ne $registry) { $registry.DeviceIdOverride } else { $null }
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
    [string]$DeviceIdOverride,

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
  if ($registry.device_id -ne $DeviceIdOverride) {
    $mismatches.Add('device_id')
  }
  if ($registry.device_id_override -ne $DeviceIdOverride) {
    $mismatches.Add('device_id_override')
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
    [bool]$ReinstallRequested,

    [Parameter(Mandatory = $true)]
    [int]$MsiexecExitCode,

    [Parameter(Mandatory = $true)]
    [object]$PreInstallSummary,

    [Parameter(Mandatory = $true)]
    [bool]$RequireManagedThumbprintChange,

    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$DeviceIdOverride,

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
  $Summary['reinstall_requested'] = $ReinstallRequested
  $Summary['msiexec_exit_code'] = $MsiexecExitCode
  $Summary['reboot_required'] = $MsiexecExitCode -in @(1641, 3010)
  $Summary['pre_install_summary'] = $PreInstallSummary
  $Summary['managed_thumbprint_before'] = $PreInstallSummary.managed.managed_thumbprint
  $Summary['managed_thumbprint_after'] = $Summary.managed.managed_thumbprint
  $Summary['managed_thumbprint_changed'] = (
    $null -ne $PreInstallSummary.managed.managed_thumbprint -and
    $null -ne $Summary.managed.managed_thumbprint -and
    $PreInstallSummary.managed.managed_thumbprint -ne $Summary.managed.managed_thumbprint
  )
  $Summary['require_managed_thumbprint_change'] = $RequireManagedThumbprintChange
  $Summary['requested_config'] = [ordered]@{
    server_url         = $ServerUrl
    client_uid         = $ClientUid
    device_id_override = $DeviceIdOverride
    poll_interval      = $PollInterval
    renew_before       = $RenewBefore
    log_level          = $LogLevel
  }
  $Summary
}

function ConvertTo-MyTunnelMarkerSummary {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Summary
  )

  [ordered]@{
    observed_at_utc                 = $Summary.observed_at_utc
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
  }
}

function Wait-MyTunnelInstallObservation {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$DeviceIdOverride,

    [object]$BaselineSummary = $null,
    [switch]$RequireManagedThumbprintChange,
    [int]$WaitSeconds = 90
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max($WaitSeconds, 0))
  $summary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -DeviceIdOverride $DeviceIdOverride

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
    $summary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -DeviceIdOverride $DeviceIdOverride
  }

  $summary
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
    [string]$DeviceIdOverride,

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
    DeviceId         = $DeviceIdOverride
    DeviceIdOverride = $DeviceIdOverride
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

  $service = Get-Service -Name 'MyTunnelService' -ErrorAction SilentlyContinue
  if ($null -ne $service) {
    if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::StartPending) {
      $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(60))
    }

    $service.Refresh()
    if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
      Stop-Service -Name 'MyTunnelService' -Force -ErrorAction Stop
      $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(60))
    } elseif ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::StopPending) {
      $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(60))
    }

    $service.Refresh()
    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
      Start-Service -Name 'MyTunnelService' -ErrorAction Stop
      $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(60))
    }

    Start-Sleep -Seconds 5
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
    [string]$DeviceIdOverride,

    [string]$MsiPath = "",
    [string]$PollInterval = '1h',
    [string]$RenewBefore = '14d',
    [ValidateSet('trace', 'debug', 'info', 'warn', 'error')]
    [string]$LogLevel = 'info',
    [switch]$ForceFreshInstall,
    [switch]$ApplyRegistryOverrides,
    [switch]$RequireManagedThumbprintChange,
    [int]$WaitSeconds = 90
  )

  $resolvedMsiPath = Resolve-MyTunnelMsiPath -PreferredPath $MsiPath
  New-Item -ItemType Directory -Path 'C:\ProgramData\MyTunnelApp' -Force | Out-Null
  $removedProducts = @()
  $preInstallSummary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -DeviceIdOverride $DeviceIdOverride
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
    "DEVICE_ID_OVERRIDE=$DeviceIdOverride"
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

  if ($ApplyRegistryOverrides) {
    Apply-MyTunnelRegistryOverrides -ServerUrl $ServerUrl -ClientUid $ClientUid -EnrollmentSecret $EnrollmentSecret -DeviceIdOverride $DeviceIdOverride -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel
  }

  $summary = Wait-MyTunnelInstallObservation -ClientUid $ClientUid -DeviceIdOverride $DeviceIdOverride -BaselineSummary $preInstallSummary -RequireManagedThumbprintChange:$RequireManagedThumbprintChange -WaitSeconds $WaitSeconds
  $summary = Add-MyTunnelInstallMetadata -Summary $summary -ResolvedMsiPath $resolvedMsiPath -ForceFreshInstall ([bool]$ForceFreshInstall) -RemovedProducts $removedProducts -ApplyRegistryOverrides ([bool]$ApplyRegistryOverrides) -ReinstallRequested ($existingProductCodes.Count -gt 0) -MsiexecExitCode $process.ExitCode -PreInstallSummary $preInstallSummary -RequireManagedThumbprintChange ([bool]$RequireManagedThumbprintChange) -ServerUrl $ServerUrl -ClientUid $ClientUid -DeviceIdOverride $DeviceIdOverride -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel

  if ((-not $ForceFreshInstall) -and (-not $ApplyRegistryOverrides) -and $existingProductCodes.Count -gt 0) {
    $mismatchList = @(Get-MyTunnelConfigMismatchList -Summary $summary -ServerUrl $ServerUrl -ClientUid $ClientUid -DeviceIdOverride $DeviceIdOverride -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel)
    if ($mismatchList.Count -gt 0) {
      $fallbackSummary = Invoke-MyTunnelAppSilentInstall -ServerUrl $ServerUrl -ClientUid $ClientUid -EnrollmentSecret $EnrollmentSecret -DeviceIdOverride $DeviceIdOverride -MsiPath $resolvedMsiPath -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel -ForceFreshInstall -RequireManagedThumbprintChange:$RequireManagedThumbprintChange -WaitSeconds $WaitSeconds
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
