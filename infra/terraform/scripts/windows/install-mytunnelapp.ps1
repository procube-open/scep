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
  $logDir = 'C:\ProgramData\MyTunnelApp\logs'

  $registry = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='MyTunnelService'" -ErrorAction SilentlyContinue
  $logFiles = @(Get-ChildItem -Path $logDir -Filter 'service.log*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)

  $latestLogPath = $null
  $logContainsPlatformProvider = $false
  $logContainsManagedFileFallback = $false
  if ($logFiles.Count -gt 0) {
    $latestLogPath = $logFiles[0].FullName
    $recentLogText = (Get-Content -LiteralPath $latestLogPath -Tail 200 -ErrorAction SilentlyContinue) -join "`n"
    $logContainsPlatformProvider = $recentLogText -match 'Microsoft Platform Crypto Provider'
    $logContainsManagedFileFallback = $recentLogText -match 'Software RSA Key \(managed file\)|key\.pem'
  }

  $managedThumbprint = $null
  $presentInMachineStore = $false
  if (Test-Path -LiteralPath $managedCertPath) {
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

  [ordered]@{
    observed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    registry        = [ordered]@{
      server_url                        = if ($null -ne $registry) { $registry.ServerUrl } else { $null }
      client_uid                        = if ($null -ne $registry) { $registry.ClientUid } else { $null }
      device_id                         = if ($null -ne $registry) { $registry.DeviceId } else { $null }
      device_id_override                = if ($null -ne $registry) { $registry.DeviceIdOverride } else { $null }
      has_enrollment_secret             = $registryPropertyNames -contains 'EnrollmentSecret'
      has_enrollment_secret_protected   = $registryPropertyNames -contains 'EnrollmentSecretProtected'
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
      key_path                = $managedKeyPath
      key_pem_exists          = Test-Path -LiteralPath $managedKeyPath
      managed_thumbprint      = $managedThumbprint
      present_in_machine_store = $presentInMachineStore
    }
    logs            = [ordered]@{
      latest_log_path                 = $latestLogPath
      contains_platform_provider      = $logContainsPlatformProvider
      contains_managed_file_fallback  = $logContainsManagedFileFallback
    }
  }
}

function Wait-MyTunnelInstallObservation {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$DeviceIdOverride,

    [int]$WaitSeconds = 90
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max($WaitSeconds, 0))
  $summary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -DeviceIdOverride $DeviceIdOverride

  while ((Get-Date) -lt $deadline) {
    if (
      $summary.registry.has_enrollment_secret_protected -or
      $summary.managed.cert_exists -or
      $summary.logs.latest_log_path
    ) {
      return $summary
    }

    Start-Sleep -Seconds 5
    $summary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -DeviceIdOverride $DeviceIdOverride
  }

  $summary
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
    [int]$WaitSeconds = 90
  )

  $resolvedMsiPath = Resolve-MyTunnelMsiPath -PreferredPath $MsiPath
  New-Item -ItemType Directory -Path 'C:\ProgramData\MyTunnelApp' -Force | Out-Null
  $removedProducts = @()

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

  $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -PassThru -Wait -NoNewWindow
  if ($process.ExitCode -notin @(0, 1641, 3010)) {
    throw "msiexec.exe failed with exit code $($process.ExitCode)"
  }

  $summary = Wait-MyTunnelInstallObservation -ClientUid $ClientUid -DeviceIdOverride $DeviceIdOverride -WaitSeconds $WaitSeconds
  $summary['msi_path'] = $resolvedMsiPath
  $summary['fresh_install_requested'] = [bool]$ForceFreshInstall
  $summary['fresh_install_removed_products'] = @($removedProducts)
  $summary['msiexec_exit_code'] = $process.ExitCode
  $summary['reboot_required'] = $process.ExitCode -in @(1641, 3010)
  $summary
}
