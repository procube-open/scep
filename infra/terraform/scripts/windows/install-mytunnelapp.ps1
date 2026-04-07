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

function Write-MyTunnelProgress {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  Write-Host $Message
}

function ConvertTo-MyTunnelEncodedPowerShellCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command
  )

  $bytes = [System.Text.Encoding]::Unicode.GetBytes($Command)
  [Convert]::ToBase64String($bytes)
}

function Get-MyTunnelTpmLockoutInfo {
  $result = [ordered]@{
    locked_out    = $false
    wait_seconds  = 0
    lockout_count = $null
    lockout_max   = $null
    raw_heal_time = $null
    query_timed_out = $false
    query_error     = $null
  }

  if (-not (Get-Command Get-Tpm -ErrorAction SilentlyContinue)) {
    Write-MyTunnelProgress 'MYTUNNEL_INSTALL_PROGRESS phase=tpm-lockout-query-unavailable reason=Get-Tpm-command-not-available'
    return $result
  }

  $queryScript = @'
$ErrorActionPreference = 'Stop'
$tpm = Get-Tpm
if ($null -eq $tpm) {
  return
}

$lockedOut = $false
if ($tpm.PSObject.Properties.Match('LockedOut').Count -gt 0) {
  $lockedOut = [bool]$tpm.LockedOut
} elseif ($tpm.PSObject.Properties.Match('TpmLockedOut').Count -gt 0) {
  $lockedOut = [bool]$tpm.TpmLockedOut
}

$lockoutCount = $null
if ($tpm.PSObject.Properties.Match('LockoutCount').Count -gt 0) {
  $lockoutCount = $tpm.LockoutCount
}

$lockoutMax = $null
if ($tpm.PSObject.Properties.Match('LockoutMax').Count -gt 0) {
  $lockoutMax = $tpm.LockoutMax
}

$rawHealTime = $null
if ($tpm.PSObject.Properties.Match('LockoutHealTime').Count -gt 0) {
  $rawHealTime = [string]$tpm.LockoutHealTime
}

[ordered]@{
  locked_out    = $lockedOut
  lockout_count = $lockoutCount
  lockout_max   = $lockoutMax
  raw_heal_time = $rawHealTime
} | ConvertTo-Json -Compress -Depth 4
'@

  Write-MyTunnelProgress 'MYTUNNEL_INSTALL_PROGRESS phase=tpm-lockout-query-start timeout_seconds=30'
  $queryResult = Invoke-MyTunnelCapturedProcess -FilePath 'powershell.exe' -ArgumentList @(
    '-NoLogo'
    '-NoProfile'
    '-NonInteractive'
    '-EncodedCommand'
    (ConvertTo-MyTunnelEncodedPowerShellCommand -Command $queryScript)
  ) -TimeoutSeconds 30

  if ($queryResult.timed_out) {
    $result.query_timed_out = $true
    $result.query_error = 'Get-Tpm query timed out after 30 seconds'
    Write-MyTunnelProgress 'MYTUNNEL_INSTALL_PROGRESS phase=tpm-lockout-query-timeout timeout_seconds=30'
    return $result
  }
  if ($queryResult.exit_code -ne 0) {
    $failureText = $queryResult.stderr
    if ([string]::IsNullOrWhiteSpace($failureText)) {
      $failureText = $queryResult.stdout
    }
    $result.query_error = "Get-Tpm query failed with exit code $($queryResult.exit_code): $(ConvertTo-MyTunnelCompactText -Value $failureText -MaxLength 160)"
    Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=tpm-lockout-query-failed exit_code={0} message={1}" -f $queryResult.exit_code, (ConvertTo-MyTunnelCompactText -Value $result.query_error -MaxLength 160))
    return $result
  }

  $jsonText = ([string]$queryResult.stdout).Trim()
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    Write-MyTunnelProgress 'MYTUNNEL_INSTALL_PROGRESS phase=tpm-lockout-query-empty'
    return $result
  }

  try {
    $tpm = $jsonText | ConvertFrom-Json -ErrorAction Stop
  } catch {
    $result.query_error = "Get-Tpm query returned invalid JSON: $(ConvertTo-MyTunnelCompactText -Value $jsonText -MaxLength 160)"
    Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=tpm-lockout-query-invalid-json message={0}" -f (ConvertTo-MyTunnelCompactText -Value $result.query_error -MaxLength 160))
    return $result
  }

  $result.locked_out = [bool]$tpm.locked_out
  $result.lockout_count = $tpm.lockout_count
  $result.lockout_max = $tpm.lockout_max
  $healTime = $tpm.raw_heal_time
  if ($null -ne $healTime) {
    $result.raw_heal_time = [string]$healTime
  }

  $waitSeconds = 0
  if ($healTime -is [TimeSpan]) {
    $waitSeconds = [int][Math]::Ceiling($healTime.TotalSeconds)
  } elseif ($healTime -is [ValueType]) {
    try {
      $waitSeconds = [int][Math]::Ceiling([double]$healTime)
    } catch {
      $waitSeconds = 0
    }
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$healTime)) {
    $healText = [string]$healTime
    if ($healText -match '^\d+$') {
      $waitSeconds = [int]$healText
    } else {
      $total = 0
      $matches = [regex]::Matches($healText, '(\d+)\s*(day|days|hour|hours|minute|minutes|second|seconds)')
      foreach ($match in $matches) {
        $value = [int]$match.Groups[1].Value
        switch -Regex ($match.Groups[2].Value) {
          '^day' { $total += $value * 24 * 60 * 60 }
          '^hour' { $total += $value * 60 * 60 }
          '^minute' { $total += $value * 60 }
          '^second' { $total += $value }
        }
      }
      $waitSeconds = $total
    }
  }

  if ($waitSeconds -lt 0) {
    $waitSeconds = 0
  }
  $result.wait_seconds = $waitSeconds
  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=tpm-lockout-state locked_out={0} wait_seconds={1} lockout_count={2} lockout_max={3} raw_heal_time={4}" -f $result.locked_out, $result.wait_seconds, $result.lockout_count, $result.lockout_max, (ConvertTo-MyTunnelCompactText -Value ([string]$result.raw_heal_time) -MaxLength 80))
  $result
}

function Wait-MyTunnelTpmLockoutClear {
  param(
    [int]$ExtraSeconds = 30,
    [int]$MaxSleepSeconds = 1800
  )

  $lockout = Get-MyTunnelTpmLockoutInfo
  if (-not $lockout.locked_out) {
    return $lockout
  }

  $sleepSeconds = [Math]::Max($lockout.wait_seconds + [Math]::Max($ExtraSeconds, 0), [Math]::Max($ExtraSeconds, 0))
  if ($MaxSleepSeconds -gt 0) {
    $sleepSeconds = [Math]::Min($sleepSeconds, $MaxSleepSeconds)
  }

  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=tpm-lockout-wait locked_out=true wait_seconds={0} lockout_count={1} lockout_max={2} raw_heal_time={3}" -f $sleepSeconds, $lockout.lockout_count, $lockout.lockout_max, (ConvertTo-MyTunnelCompactText -Value ([string]$lockout.raw_heal_time) -MaxLength 80))
  if ($sleepSeconds -gt 0) {
    Start-Sleep -Seconds $sleepSeconds
  }

  $postLockout = Get-MyTunnelTpmLockoutInfo
  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=tpm-lockout-check locked_out={0} wait_seconds={1} lockout_count={2} lockout_max={3} raw_heal_time={4}" -f $postLockout.locked_out, $postLockout.wait_seconds, $postLockout.lockout_count, $postLockout.lockout_max, (ConvertTo-MyTunnelCompactText -Value ([string]$postLockout.raw_heal_time) -MaxLength 80))
  $postLockout
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

function Get-MyTunnelServiceExecutablePath {
  $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='MyTunnelService'" -ErrorAction SilentlyContinue
  if ($null -eq $service) {
    throw 'MyTunnelService is not installed; cannot locate the service executable'
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

  $serviceExePath
}

function Get-MyTunnelBundledHelperPath {
  $serviceExePath = Get-MyTunnelServiceExecutablePath
  $helperPath = Join-Path (Split-Path -Parent $serviceExePath) 'scepclient.exe'
  if (-not (Test-Path -LiteralPath $helperPath)) {
    throw "Bundled scepclient.exe was not found at $helperPath"
  }

  $helperPath
}

function Get-MyTunnelInstalledBinaryState {
  param(
    [string]$ExpectedServiceSha256 = "",
    [string]$ExpectedBundledHelperSha256 = ""
  )

  $state = [ordered]@{
    service_path                   = $null
    service_sha256                 = $null
    service_matches_expected       = $null
    bundled_helper_path            = $null
    bundled_helper_sha256          = $null
    bundled_helper_matches_expected = $null
    path_error                     = $null
    any_mismatch                   = $false
  }

  try {
    $serviceExePath = Get-MyTunnelServiceExecutablePath
    $state.service_path = $serviceExePath
    if (Test-Path -LiteralPath $serviceExePath) {
      $state.service_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $serviceExePath).Hash.ToLowerInvariant()
    }

    $helperPath = Join-Path (Split-Path -Parent $serviceExePath) 'scepclient.exe'
    $state.bundled_helper_path = $helperPath
    if (Test-Path -LiteralPath $helperPath) {
      $state.bundled_helper_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $helperPath).Hash.ToLowerInvariant()
    }
  } catch {
    $state.path_error = $_.Exception.Message
  }

  if (-not [string]::IsNullOrWhiteSpace($ExpectedServiceSha256)) {
    $state.service_matches_expected = (
      -not [string]::IsNullOrWhiteSpace([string]$state.service_sha256) -and
      [string]$state.service_sha256 -eq ([string]$ExpectedServiceSha256).ToLowerInvariant()
    )
  }

  if (-not [string]::IsNullOrWhiteSpace($ExpectedBundledHelperSha256)) {
    $state.bundled_helper_matches_expected = (
      -not [string]::IsNullOrWhiteSpace([string]$state.bundled_helper_sha256) -and
      [string]$state.bundled_helper_sha256 -eq ([string]$ExpectedBundledHelperSha256).ToLowerInvariant()
    )
  }

  $state.any_mismatch = (
    ($null -ne $state.service_matches_expected -and (-not [bool]$state.service_matches_expected)) -or
    ($null -ne $state.bundled_helper_matches_expected -and (-not [bool]$state.bundled_helper_matches_expected))
  )

  [PSCustomObject]$state
}

function Resolve-MyTunnelDeviceIdProbeInvocation {
  param(
    [string]$PreferredPath = ""
  )

  $candidates = New-Object System.Collections.Generic.List[object]

  $addCandidate = {
    param(
      [string]$Path,
      [string[]]$Arguments
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
      return
    }

    $resolvedArguments = @()
    if ($null -ne $Arguments) {
      $resolvedArguments = @($Arguments)
    }

    $candidates.Add([ordered]@{
      path      = $Path
      arguments = $resolvedArguments
    }) | Out-Null
  }

  if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
    $preferredBaseName = [System.IO.Path]::GetFileName($PreferredPath)
    if ($preferredBaseName -match '^(?i)scepclient(?:\.exe)?$') {
      & $addCandidate $PreferredPath @('-print-device-id', '-json')
    } else {
      & $addCandidate $PreferredPath @('-json')
    }
  }

  & $addCandidate 'C:\Users\Public\device-id-probe.exe' @('-json')
  & $addCandidate 'C:\Program Files\MyTunnelApp\device-id-probe.exe' @('-json')
  & $addCandidate 'C:\Program Files\MyTunnelApp\scepclient.exe' @('-print-device-id', '-json')

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    $candidatePath = [string]$candidate.path
    if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and (Test-Path -LiteralPath $candidatePath)) {
      return [ordered]@{
        path      = (Resolve-Path -LiteralPath $candidatePath).Path
        arguments = @($candidate.arguments)
      }
    }
  }

  try {
    $bundledHelperPath = Get-MyTunnelBundledHelperPath
    $bundledProbePath = $bundledHelperPath -replace '(?i)scepclient\.exe$', 'device-id-probe.exe'
    & $addCandidate $bundledProbePath @('-json')
    & $addCandidate $bundledHelperPath @('-print-device-id', '-json')
  } catch {
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    $candidatePath = [string]$candidate.path
    if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and (Test-Path -LiteralPath $candidatePath)) {
      return [ordered]@{
        path      = (Resolve-Path -LiteralPath $candidatePath).Path
        arguments = @($candidate.arguments)
      }
    }
  }

  $candidatePaths = @(
    $candidates |
      ForEach-Object { [string]$_.path } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
  )
  throw "device identity probe command was not found in expected paths: $($candidatePaths -join ', ')"
}

function Invoke-MyTunnelDeviceIdProbe {
  param(
    [string]$ProbePath = ""
  )

  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=device-id-probe-prepare preferred_probe_path={0}" -f (ConvertTo-MyTunnelCompactText -Value $ProbePath -MaxLength 160))
  $lockoutInfo = Wait-MyTunnelTpmLockoutClear
  $probeInvocation = Resolve-MyTunnelDeviceIdProbeInvocation -PreferredPath $ProbePath
  $resolvedProbePath = [string]$probeInvocation.path
  $probeArguments = @($probeInvocation.arguments)
  $attempt = 1

  while ($true) {
    Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=device-id-probe-start attempt={0} probe_path={1} probe_args={2} locked_out={3} lockout_wait_seconds={4}" -f $attempt, $resolvedProbePath, (($probeArguments | ForEach-Object { [string]$_ }) -join ','), $lockoutInfo.locked_out, $lockoutInfo.wait_seconds)
    $probeResult = Invoke-MyTunnelCapturedProcess -FilePath $resolvedProbePath -ArgumentList $probeArguments -TimeoutSeconds 300

    if (-not $probeResult.timed_out -and $probeResult.exit_code -eq 0) {
      break
    }

    $failureText = $probeResult.stderr
    if ([string]::IsNullOrWhiteSpace($failureText)) {
      $failureText = $probeResult.stdout
    }
    $failureSummary = ConvertTo-MyTunnelCompactText -Value $failureText -MaxLength 160
    $retryableFailure = $probeResult.timed_out -or [string]::IsNullOrWhiteSpace($failureSummary) -or ($failureSummary -match '(?i)\btpm\b|\blockout\b')
    $canRetry = $attempt -lt 2 -and ($retryableFailure -or $lockoutInfo.locked_out -or $lockoutInfo.query_timed_out)
    if (-not $canRetry) {
      if ($probeResult.timed_out) {
        throw "device-id-probe.exe timed out after 300 seconds at $resolvedProbePath"
      }
      throw "device-id-probe.exe failed with exit code $($probeResult.exit_code): $failureSummary"
    }

    $retryWaitSeconds = 180
    if ($lockoutInfo.wait_seconds -gt 0) {
      $retryWaitSeconds = [Math]::Min($lockoutInfo.wait_seconds + 30, 1800)
    } elseif ($lockoutInfo.query_timed_out) {
      $retryWaitSeconds = 1020
    }
    Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=device-id-probe-retry-wait attempt={0} wait_seconds={1} timed_out={2} failure={3}" -f $attempt, $retryWaitSeconds, $probeResult.timed_out, $failureSummary)
    Start-Sleep -Seconds $retryWaitSeconds
    $lockoutInfo = Get-MyTunnelTpmLockoutInfo
    $attempt += 1
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

  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=device-id-probe-done expected_device_id={0}" -f $resolvedExpectedDeviceId)

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

    [string[]]$ArgumentList = @(),
    [int]$TimeoutSeconds = 0
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
  $timedOut = $false

  try {
    $process = Start-Process `
      -FilePath $FilePath `
      -ArgumentList $argumentString `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -PassThru

    if ($TimeoutSeconds -gt 0) {
      if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        try {
          Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        } catch {
        }
        [void]$process.WaitForExit(5000)
      }
    } else {
      [void]$process.WaitForExit()
    }

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
    $exitCode = if ($timedOut) { -1 } else { [int]$process.ExitCode }
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
    timed_out = $timedOut
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
  ConvertFrom-MyTunnelPemText -PemText $pemText -Label $Path
}

function ConvertFrom-MyTunnelPemText {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PemText,

    [string]$Label = 'PEM text'
  )

  $match = [regex]::Match(
    $pemText,
    '-----BEGIN CERTIFICATE-----\s*(?<body>[A-Za-z0-9+/=\r\n]+?)\s*-----END CERTIFICATE-----'
  )
  if (-not $match.Success) {
    throw "PEM data does not contain a certificate body: $Label"
  }

  $pemBody = (
    $match.Groups['body'].Value -split "`r?`n" |
      Where-Object { $_ }
  ) -join ''

  if ([string]::IsNullOrWhiteSpace($pemBody)) {
    throw "PEM data does not contain a certificate body: $Label"
  }

  $bytes = [Convert]::FromBase64String($pemBody)
  New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $bytes)
}

function Sync-MyTunnelManagedCertificateFromStore {
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
  $managedThumbprint = $null

  if (Test-Path -LiteralPath $managedCertPath) {
    try {
      $managedThumbprint = (ConvertFrom-MyTunnelPem -Path $managedCertPath).Thumbprint
    } catch {
      $managedThumbprint = $null
    }
  }

  $serverState = Get-MyTunnelServerCertificateState -ServerUrl $ServerUrl -ClientUid $ClientUid
  $serverActiveThumbprint = $null
  if ($null -ne $serverState -and -not [string]::IsNullOrWhiteSpace([string]$serverState.active_thumbprint)) {
    $serverActiveThumbprint = [string]$serverState.active_thumbprint
  }

  $storeCert = $null
  $selectionSource = $null
  if (-not [string]::IsNullOrWhiteSpace($serverActiveThumbprint)) {
    if ($managedThumbprint -eq $serverActiveThumbprint) {
      Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=managed-cert-sync skipped=already-current source=server-active thumbprint={0}" -f $serverActiveThumbprint)
      return
    }

    $storeCert = Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
      Where-Object { $_.Thumbprint -eq $serverActiveThumbprint } |
      Sort-Object NotAfter -Descending |
      Select-Object -First 1
    if ($null -eq $storeCert) {
      Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=managed-cert-sync skipped=server-active-cert-missing-in-store server_thumbprint={0}" -f $serverActiveThumbprint)
      return
    }
    $selectionSource = 'server-active'
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$serverState.fetch_error)) {
    Write-MyTunnelProgress (
      "MYTUNNEL_INSTALL_PROGRESS phase=managed-cert-sync mode=fallback reason=server-fetch-error message={0}" -f
        (ConvertTo-MyTunnelCompactText -Value ([string]$serverState.fetch_error) -MaxLength 600)
    )
  } else {
    Write-MyTunnelProgress 'MYTUNNEL_INSTALL_PROGRESS phase=managed-cert-sync mode=fallback reason=no-server-active-cert'
  }

  if (
    $null -eq $storeCert -and
    -not [string]::IsNullOrWhiteSpace($managedThumbprint)
  ) {
    $storeCert = Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
      Where-Object { $_.Thumbprint -eq $managedThumbprint } |
      Sort-Object NotAfter -Descending |
      Select-Object -First 1
    if ($null -ne $storeCert) {
      $selectionSource = 'managed-thumbprint'
    }
  }

  if ($null -eq $storeCert) {
    $storeCert = Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
      Where-Object {
        $_.GetNameInfo(
          [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
          $false
        ) -eq $ClientUid
      } |
      Sort-Object NotAfter -Descending |
      Select-Object -First 1
    if ($null -ne $storeCert) {
      $selectionSource = 'simple-name-fallback'
    }
  }

  if ($null -eq $storeCert) {
    Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=managed-cert-sync skipped=no-store-cert client_uid={0}" -f $ClientUid)
    return
  }

  if ($managedThumbprint -eq $storeCert.Thumbprint) {
    Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=managed-cert-sync skipped=already-current source={0} thumbprint={1}" -f $selectionSource, $storeCert.Thumbprint)
    return
  }

  New-Item -ItemType Directory -Path $managedDir -Force | Out-Null
  $pemBody = [Convert]::ToBase64String(
    $storeCert.RawData,
    [System.Base64FormattingOptions]::InsertLineBreaks
  )
  $pemText = "-----BEGIN CERTIFICATE-----`r`n$($pemBody)`r`n-----END CERTIFICATE-----`r`n"
  [System.IO.File]::WriteAllText($managedCertPath, $pemText, [System.Text.Encoding]::ASCII)
  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=managed-cert-sync updated=true source={0} thumbprint={1}" -f $selectionSource, $storeCert.Thumbprint)
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
  $latestErrorBackoffLine = $null
  $latestGeneratingKeyFailureLine = $null
  if ($logFiles.Count -gt 0) {
    $latestLogPath = $logFiles[0].FullName
    $latestLogLastWriteUtc = $logFiles[0].LastWriteTimeUtc.ToString('o')
    $recentLogLines = @(Get-Content -LiteralPath $latestLogPath -Tail 80 -ErrorAction SilentlyContinue)
    $recentLogText = $recentLogLines -join "`n"
    $logContainsPlatformProvider = $recentLogText -match 'Microsoft Platform Crypto Provider'
    $logContainsManagedFileFallback = $recentLogText -match 'Software RSA Key \(managed file\)|key\.pem'
    $errorBackoffLines = @($recentLogLines | Where-Object { $_ -match 'service state backoff' })
    if ($errorBackoffLines.Count -gt 0) {
      $latestErrorBackoffLine = ConvertTo-MyTunnelCompactText -Value ($errorBackoffLines[-1]) -MaxLength 1000
    }
    $generatingKeyFailureLines = @($recentLogLines | Where-Object { $_ -match 'key-management failed while in GeneratingKey' })
    if ($generatingKeyFailureLines.Count -gt 0) {
      $latestGeneratingKeyFailureLine = ConvertTo-MyTunnelCompactText -Value ($generatingKeyFailureLines[-1]) -MaxLength 1000
    }
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
      expected_device_id                = if ($null -ne $registry) { $registry.ExpectedDeviceId } else { $null }
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
      latest_error_backoff_line       = $latestErrorBackoffLine
      latest_generating_key_failure   = $latestGeneratingKeyFailureLine
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
    [object]$PreInstallServerState,

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
    [string]$LogLevel,
    [string]$ExpectedServiceSha256 = "",
    [string]$ExpectedBundledHelperSha256 = ""
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
  $Summary['pre_install_server'] = $PreInstallServerState
  $Summary['prereg_check'] = $PreregCheck
  $Summary['managed_thumbprint_before'] = $PreInstallSummary.managed.managed_thumbprint
  $Summary['managed_thumbprint_after'] = $Summary.managed.managed_thumbprint
  $Summary['managed_thumbprint_changed'] = (
    $null -ne $PreInstallSummary.managed.managed_thumbprint -and
    $null -ne $Summary.managed.managed_thumbprint -and
    $PreInstallSummary.managed.managed_thumbprint -ne $Summary.managed.managed_thumbprint
  )
  $serverState = Get-MyTunnelServerCertificateState -ServerUrl $ServerUrl -ClientUid $ClientUid
  $Summary['server'] = $serverState
  $Summary['server_active_thumbprint_before'] = $PreInstallServerState.active_thumbprint
  $Summary['server_active_thumbprint_after'] = $serverState.active_thumbprint
  $Summary['server_active_thumbprint_changed'] = (
    -not [string]::IsNullOrWhiteSpace([string]$PreInstallServerState.active_thumbprint) -and
    -not [string]::IsNullOrWhiteSpace([string]$serverState.active_thumbprint) -and
    [string]$PreInstallServerState.active_thumbprint -ne [string]$serverState.active_thumbprint
  )
  $Summary['server_active_serial_before'] = $PreInstallServerState.active_serial
  $Summary['server_active_serial_after'] = $serverState.active_serial
  $Summary['server_active_serial_changed'] = (
    -not [string]::IsNullOrWhiteSpace([string]$PreInstallServerState.active_serial) -and
    -not [string]::IsNullOrWhiteSpace([string]$serverState.active_serial) -and
    [string]$PreInstallServerState.active_serial -ne [string]$serverState.active_serial
  )
  $programFiles = Get-MyTunnelInstalledBinaryState -ExpectedServiceSha256 $ExpectedServiceSha256 -ExpectedBundledHelperSha256 $ExpectedBundledHelperSha256
  $expectedServiceSha256Normalized = $null
  if (-not [string]::IsNullOrWhiteSpace($ExpectedServiceSha256)) {
    $expectedServiceSha256Normalized = $ExpectedServiceSha256.ToLowerInvariant()
  }
  $expectedBundledHelperSha256Normalized = $null
  if (-not [string]::IsNullOrWhiteSpace($ExpectedBundledHelperSha256)) {
    $expectedBundledHelperSha256Normalized = $ExpectedBundledHelperSha256.ToLowerInvariant()
  }
  $Summary['program_files'] = $programFiles
  $Summary['expected_binaries'] = [ordered]@{
    service_sha256        = $expectedServiceSha256Normalized
    bundled_helper_sha256 = $expectedBundledHelperSha256Normalized
  }
  $Summary['program_files_match_expected'] = -not [bool]$programFiles.any_mismatch
  $Summary['managed_matches_server_active'] = (
    -not [string]::IsNullOrWhiteSpace([string]$Summary.managed.managed_thumbprint) -and
    -not [string]::IsNullOrWhiteSpace([string]$serverState.active_thumbprint) -and
    [string]$Summary.managed.managed_thumbprint -eq [string]$serverState.active_thumbprint
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
  if ($Summary -is [System.Collections.IDictionary]) {
    if ($Summary.Contains('activation_negative')) {
      $activationNegative = $Summary['activation_negative']
    }
  } elseif ($Summary.PSObject.Properties.Match('activation_negative').Count -gt 0) {
    $activationNegative = $Summary.activation_negative
  }

  [ordered]@{
    observed_at_utc                 = $Summary.observed_at_utc
    prereg_check                    = $Summary.prereg_check
    registry                        = $Summary.registry
    config                          = $Summary.config
    service                         = $Summary.service
    managed                         = $Summary.managed
    pre_install_server              = $Summary.pre_install_server
    server                          = $Summary.server
    program_files                   = $Summary.program_files
    expected_binaries               = $Summary.expected_binaries
    logs                            = [ordered]@{
      latest_log_path                = $Summary.logs.latest_log_path
      latest_log_last_write_utc      = $Summary.logs.latest_log_last_write_utc
      contains_platform_provider     = $Summary.logs.contains_platform_provider
      contains_managed_file_fallback = $Summary.logs.contains_managed_file_fallback
      latest_log_excerpt             = $Summary.logs.latest_log_excerpt
      latest_error_backoff_line      = $Summary.logs.latest_error_backoff_line
      latest_generating_key_failure  = $Summary.logs.latest_generating_key_failure
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
    server_active_thumbprint_before = $Summary.server_active_thumbprint_before
    server_active_thumbprint_after  = $Summary.server_active_thumbprint_after
    server_active_thumbprint_changed = $Summary.server_active_thumbprint_changed
    server_active_serial_before     = $Summary.server_active_serial_before
    server_active_serial_after      = $Summary.server_active_serial_after
    server_active_serial_changed    = $Summary.server_active_serial_changed
    program_files_match_expected    = $Summary.program_files_match_expected
    managed_matches_server_active   = $Summary.managed_matches_server_active
    require_managed_thumbprint_change = $Summary.require_managed_thumbprint_change
    requested_config                = $Summary.requested_config
    binary_refresh_fallback_used    = $Summary.binary_refresh_fallback_used
    binary_refresh_fallback_reason  = $Summary.binary_refresh_fallback_reason
    initial_reinstall_binary_state  = $Summary.initial_reinstall_binary_state
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
        if (
          $managedThumbprintChanged -and
          $summary.managed.present_in_machine_store
        ) {
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

function Seed-MyTunnelExistingConfigRegistry {
  param(
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

  $registryPath = 'HKLM:\SOFTWARE\MyTunnelApp'
  if (-not (Test-Path -LiteralPath $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
  }

  $overrides = [ordered]@{
    ServerUrl        = $ServerUrl
    ClientUid        = $ClientUid
    ExpectedDeviceId = $ExpectedDeviceId
    PollInterval     = $PollInterval
    RenewBefore      = $RenewBefore
    LogLevel         = $LogLevel
  }

  foreach ($entry in $overrides.GetEnumerator()) {
    Set-ItemProperty -LiteralPath $registryPath -Name $entry.Key -Value $entry.Value -Type String
  }

  Remove-ItemProperty -LiteralPath $registryPath -Name 'EnrollmentSecret' -ErrorAction SilentlyContinue
  Remove-ItemProperty -LiteralPath $registryPath -Name 'EnrollmentSecretProtected' -ErrorAction SilentlyContinue
}

function Apply-MyTunnelRegistryOverrides {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

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
    ServerUrl        = $ServerUrl
    ClientUid        = $ClientUid
    ExpectedDeviceId = $ExpectedDeviceId
    PollInterval     = $PollInterval
    RenewBefore      = $RenewBefore
    LogLevel         = $LogLevel
  }

  foreach ($entry in $overrides.GetEnumerator()) {
    Set-ItemProperty -LiteralPath $registryPath -Name $entry.Key -Value $entry.Value -Type String
  }

  if (-not [string]::IsNullOrWhiteSpace($EnrollmentSecret)) {
    Set-ItemProperty -LiteralPath $registryPath -Name 'EnrollmentSecret' -Value $EnrollmentSecret -Type String
  } elseif (Get-ItemProperty -LiteralPath $registryPath -Name 'EnrollmentSecret' -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -LiteralPath $registryPath -Name 'EnrollmentSecret' -ErrorAction SilentlyContinue
  }

  Sync-MyTunnelManagedCertificateFromStore -ServerUrl $ServerUrl -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId
  Restart-MyTunnelService
}

function Resolve-MyTunnelServerApiBaseUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl
  )

  $trimmed = $ServerUrl.TrimEnd('/')
  if ($trimmed -match '/scep$') {
    return ($trimmed -replace '/scep$', '')
  }

  $trimmed
}

function Resolve-MyTunnelAttestationNonceEndpoint {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl
  )

  $base = Resolve-MyTunnelServerApiBaseUrl -ServerUrl $ServerUrl
  "$base/api/attestation/nonce"
}

function Resolve-MyTunnelAttestationPreregCheckEndpoint {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl
  )

  $base = Resolve-MyTunnelServerApiBaseUrl -ServerUrl $ServerUrl
  "$base/api/attestation/prereg-check"
}

function Resolve-MyTunnelClientInfoEndpoint {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid
  )

  $base = Resolve-MyTunnelServerApiBaseUrl -ServerUrl $ServerUrl
  "{0}/api/client/{1}" -f $base, [System.Uri]::EscapeDataString($ClientUid)
}

function Resolve-MyTunnelCertListEndpoint {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid
  )

  $base = Resolve-MyTunnelServerApiBaseUrl -ServerUrl $ServerUrl
  "{0}/api/cert/list/{1}" -f $base, [System.Uri]::EscapeDataString($ClientUid)
}

function Get-MyTunnelServerCertificateState {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid
  )

  $state = [ordered]@{
    client_status      = $null
    active_thumbprint  = $null
    active_thumbprints = @()
    active_serial      = $null
    cert_count         = 0
    active_cert_count  = 0
    fetch_error        = $null
  }

  try {
    $clientResponse = Invoke-RestMethod -Method Get -Uri (Resolve-MyTunnelClientInfoEndpoint -ServerUrl $ServerUrl -ClientUid $ClientUid)
    if ($null -ne $clientResponse -and $clientResponse.PSObject.Properties.Match('status').Count -gt 0) {
      $state.client_status = [string]$clientResponse.status
    }
  } catch {
    $state.fetch_error = "client info fetch failed: $(ConvertTo-MyTunnelCompactText -Value $_.Exception.Message -MaxLength 600)"
    return [PSCustomObject]$state
  }

  try {
    $certResponse = Invoke-RestMethod -Method Get -Uri (Resolve-MyTunnelCertListEndpoint -ServerUrl $ServerUrl -ClientUid $ClientUid)
  } catch {
    $state.fetch_error = "cert list fetch failed: $(ConvertTo-MyTunnelCompactText -Value $_.Exception.Message -MaxLength 600)"
    return [PSCustomObject]$state
  }

  $certs = @($certResponse | Where-Object { $null -ne $_ })
  $state.cert_count = $certs.Count

  $activeCerts = @()
  foreach ($cert in $certs) {
    $thumbprint = $null
    if (
      $cert.PSObject.Properties.Match('cert_data').Count -gt 0 -and
      -not [string]::IsNullOrWhiteSpace([string]$cert.cert_data)
    ) {
      try {
        $thumbprint = (ConvertFrom-MyTunnelPemText -PemText ([string]$cert.cert_data) -Label 'server cert list entry').Thumbprint
      } catch {
        $thumbprint = $null
      }
    }

    if ($cert.PSObject.Properties.Match('status').Count -gt 0 -and [string]$cert.status -eq 'V') {
      $activeCerts += [PSCustomObject]@{
        Thumbprint = $thumbprint
        Serial     = [string]$cert.serial
        ValidTill  = [string]$cert.valid_till
      }
    }
  }

  $state.active_cert_count = $activeCerts.Count
  $state.active_thumbprints = @(
    $activeCerts |
      ForEach-Object { $_.Thumbprint } |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
  )

  if ($activeCerts.Count -gt 0) {
    $activeCert = @(
      $activeCerts |
        Sort-Object -Property @(
          @{
            Expression = {
              if ([string]::IsNullOrWhiteSpace([string]$_.ValidTill)) {
                [DateTime]::MinValue
              } else {
                try {
                  [DateTime]::Parse([string]$_.ValidTill).ToUniversalTime()
                } catch {
                  [DateTime]::MinValue
                }
              }
            }
          },
          @{
            Expression = {
              try {
                [bigint]([string]$_.Serial)
              } catch {
                [bigint]0
              }
            }
          }
        ) -Descending |
        Select-Object -First 1
    )
    if ($activeCert.Count -gt 0) {
      $state.active_thumbprint = $activeCert[0].Thumbprint
      $state.active_serial = $activeCert[0].Serial
    }
  }

  [PSCustomObject]$state
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

  $renewalStdoutExcerpt = ConvertTo-MyTunnelCompactText -Value $renewalResult.stdout -MaxLength 1000
  $renewalStderrExcerpt = ConvertTo-MyTunnelCompactText -Value $renewalResult.stderr -MaxLength 1000
  $renewalClassifierText = @($renewalStdoutExcerpt, $renewalStderrExcerpt) -ne ''
  $renewalClassifierText = ($renewalClassifierText -join ' ')
  $renewalFailureExcerpt = $renewalStdoutExcerpt
  if ([string]::IsNullOrWhiteSpace([string]$renewalFailureExcerpt)) {
    $renewalFailureExcerpt = $renewalStderrExcerpt
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$renewalStderrExcerpt)) {
    $renewalFailureExcerpt = ConvertTo-MyTunnelCompactText -Value ("stdout={0} stderr={1}" -f $renewalStdoutExcerpt, $renewalStderrExcerpt) -MaxLength 1000
  }
  Write-MyTunnelProgress (
    "MYTUNNEL_INSTALL_PROGRESS phase=activation-negative-renewal-result helper_path={0} exit_code={1} timed_out={2} stdout={3} stderr={4}" -f
      (ConvertTo-MyTunnelCompactText -Value $helperPath -MaxLength 200),
      $renewalResult.exit_code,
      [bool]$renewalResult.timed_out,
      $renewalStdoutExcerpt,
      $renewalStderrExcerpt
  )
  $renewalRejected = $renewalResult.exit_code -ne 0
  if (
    (-not $renewalRejected) -and
    (-not [string]::IsNullOrWhiteSpace([string]$renewalClassifierText)) -and
    (
      $renewalClassifierText -match '(?i)request failed, failInfo' -or
      $renewalClassifierText -match '(?i)invalid attestation' -or
      $renewalClassifierText -match '(?i)invalid renewal signer' -or
      $renewalClassifierText -match '(?i)PKIOperation for RenewalReq' -or
      $renewalClassifierText -match '(?i)parsing pkiMessage response RenewalReq' -or
      $renewalClassifierText -match '(?i)decrypt pkiEnvelope, msgType:\s*RenewalReq'
    )
  ) {
    $renewalRejected = $true
  }
  Write-MyTunnelProgress (
    "MYTUNNEL_INSTALL_PROGRESS phase=activation-negative-renewal-classified renewal_rejected={0} failure_excerpt={1}" -f
      [bool]$renewalRejected,
      $renewalFailureExcerpt
  )

  $finalSummary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId
  $thumbprintBefore = $baselineSummary.managed.managed_thumbprint
  $thumbprintAfter = $finalSummary.managed.managed_thumbprint
  $thumbprintChanged = (
    $null -ne $thumbprintBefore -and
    $null -ne $thumbprintAfter -and
    $thumbprintBefore -ne $thumbprintAfter
  )

  if (-not $renewalRejected) {
    throw (
      "tampered activation renewal unexpectedly succeeded exit_code={0} stdout={1} stderr={2} failure={3}" -f
        $renewalResult.exit_code,
        $renewalStdoutExcerpt,
        $renewalStderrExcerpt,
        $renewalFailureExcerpt
    )
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
    renewal_rejected           = $renewalRejected
    managed_thumbprint_before  = $thumbprintBefore
    managed_thumbprint_after   = $thumbprintAfter
    managed_thumbprint_changed = $thumbprintChanged
    renewal_stdout_excerpt     = $renewalStdoutExcerpt
    renewal_stderr_excerpt     = $renewalStderrExcerpt
    renewal_failure_excerpt    = $renewalFailureExcerpt
  }
}

function Invoke-MyTunnelAppSilentInstall {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [string]$EnrollmentSecret,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,

    [string]$MsiPath = "",
    [string]$PollInterval = '1h',
    [string]$RenewBefore = '14d',
    [ValidateSet('trace', 'debug', 'info', 'warn', 'error')]
    [string]$LogLevel = 'info',
    [string]$ExpectedServiceSha256 = "",
    [string]$ExpectedBundledHelperSha256 = "",
    [switch]$ForceFreshInstall,
    [switch]$AllowExistingCertificateReuse,
    [switch]$ApplyRegistryOverrides,
    [switch]$ConvergeToLocalService,
    [switch]$RequireManagedThumbprintChange,
    [int]$WaitSeconds = 90
  )

  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=silent-install-enter requested_msi_path={0} client_uid={1}" -f (ConvertTo-MyTunnelCompactText -Value $MsiPath -MaxLength 160), $ClientUid)
  $resolvedMsiPath = Resolve-MyTunnelMsiPath -PreferredPath $MsiPath
  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=silent-install-path-resolved msi_path={0}" -f $resolvedMsiPath)
  New-Item -ItemType Directory -Path 'C:\ProgramData\MyTunnelApp' -Force | Out-Null
  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=prereg-check-start client_uid={0}" -f $ClientUid)
  $preregCheck = Invoke-MyTunnelAttestationPreregCheck -ServerUrl $ServerUrl -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId
  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=prereg-check-done result={0} endpoint={1}" -f $preregCheck.result, $preregCheck.endpoint)
  $removedProducts = @()
  $preInstallSummary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId
  $preInstallServerState = Get-MyTunnelServerCertificateState -ServerUrl $ServerUrl -ClientUid $ClientUid
  $canReuseExistingCertificate = [bool]$preInstallSummary.managed.cert_exists
  $existingProductCodes = @()

  if ($ForceFreshInstall) {
    if ([string]::IsNullOrWhiteSpace($EnrollmentSecret) -and ((-not $AllowExistingCertificateReuse) -or (-not $canReuseExistingCertificate))) {
      throw 'EnrollmentSecret is required for force-fresh-install unless an existing managed certificate is being reused'
    }
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
    if ([string]::IsNullOrWhiteSpace($EnrollmentSecret) -and $AllowExistingCertificateReuse -and $canReuseExistingCertificate) {
      Seed-MyTunnelExistingConfigRegistry -ServerUrl $ServerUrl -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel
      Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=force-fresh-registry-seed client_uid={0} expected_device_id={1}" -f $ClientUid, $ExpectedDeviceId)
    }
  } else {
    $existingProductCodes = @(Get-MyTunnelInstalledProductCodes)
  }

  $arguments = @(
    '/i'
    $resolvedMsiPath
    "SERVER_URL=$ServerUrl"
    "CLIENT_UID=$ClientUid"
    "EXPECTED_DEVICE_ID=$ExpectedDeviceId"
    "POLL_INTERVAL=$PollInterval"
    "RENEW_BEFORE=$RenewBefore"
    "LOG_LEVEL=$LogLevel"
    '/qn'
    '/norestart'
  )
  if (-not [string]::IsNullOrWhiteSpace($EnrollmentSecret)) {
    $arguments += "ENROLLMENT_SECRET=$EnrollmentSecret"
  }

  if ($existingProductCodes.Count -gt 0) {
    $arguments += @(
      'REINSTALL=ALL'
      'REINSTALLMODE=vamus'
    )
  }

  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=msiexec-start resolved_msi_path={0} reinstall_requested={1} force_fresh_install={2}" -f $resolvedMsiPath, ($existingProductCodes.Count -gt 0), [bool]$ForceFreshInstall)
  $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -PassThru -Wait -NoNewWindow
  if ($process.ExitCode -notin @(0, 1641, 3010)) {
    throw "msiexec.exe failed with exit code $($process.ExitCode)"
  }
  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=msiexec-done exit_code={0}" -f $process.ExitCode)

  $postMsiexecBinaryState = Get-MyTunnelInstalledBinaryState -ExpectedServiceSha256 $ExpectedServiceSha256 -ExpectedBundledHelperSha256 $ExpectedBundledHelperSha256
  if ((-not $ForceFreshInstall) -and $existingProductCodes.Count -gt 0 -and [bool]$postMsiexecBinaryState.any_mismatch) {
    $binaryMismatchList = New-Object System.Collections.Generic.List[string]
    if ($null -ne $postMsiexecBinaryState.service_matches_expected -and (-not [bool]$postMsiexecBinaryState.service_matches_expected)) {
      $binaryMismatchList.Add('service.exe') | Out-Null
    }
    if ($null -ne $postMsiexecBinaryState.bundled_helper_matches_expected -and (-not [bool]$postMsiexecBinaryState.bundled_helper_matches_expected)) {
      $binaryMismatchList.Add('scepclient.exe') | Out-Null
    }

    $binaryFallbackReason = "same-version reinstall left stale Program Files binaries: $($binaryMismatchList -join ', ')"
    Write-MyTunnelProgress (
      "MYTUNNEL_INSTALL_PROGRESS phase=binary-refresh-fallback reason={0}" -f
        (ConvertTo-MyTunnelCompactText -Value $binaryFallbackReason -MaxLength 500)
    )

    $fallbackSummary = Invoke-MyTunnelAppSilentInstall -ServerUrl $ServerUrl -ClientUid $ClientUid -EnrollmentSecret $EnrollmentSecret -ExpectedDeviceId $ExpectedDeviceId -MsiPath $resolvedMsiPath -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel -ExpectedServiceSha256 $ExpectedServiceSha256 -ExpectedBundledHelperSha256 $ExpectedBundledHelperSha256 -ForceFreshInstall -AllowExistingCertificateReuse -ApplyRegistryOverrides:$ApplyRegistryOverrides -ConvergeToLocalService:$ConvergeToLocalService -RequireManagedThumbprintChange:$RequireManagedThumbprintChange -WaitSeconds $WaitSeconds
    $fallbackSummary['binary_refresh_fallback_used'] = $true
    $fallbackSummary['binary_refresh_fallback_reason'] = $binaryFallbackReason
    $fallbackSummary['initial_reinstall_binary_state'] = $postMsiexecBinaryState
    return $fallbackSummary
  }

  if ($ConvergeToLocalService) {
    Enable-MyTunnelLocalServiceConvergence
  }

  if ($ApplyRegistryOverrides) {
    Apply-MyTunnelRegistryOverrides -ServerUrl $ServerUrl -ClientUid $ClientUid -EnrollmentSecret $EnrollmentSecret -ExpectedDeviceId $ExpectedDeviceId -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel
  } elseif ($ConvergeToLocalService) {
    Restart-MyTunnelService
  }

  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=observation-start wait_seconds={0} require_thumbprint_change={1}" -f $WaitSeconds, [bool]$RequireManagedThumbprintChange)
  $summary = Wait-MyTunnelInstallObservation -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId -BaselineSummary $preInstallSummary -RequireManagedThumbprintChange:$RequireManagedThumbprintChange -WaitSeconds $WaitSeconds
  Write-MyTunnelProgress ("MYTUNNEL_INSTALL_PROGRESS phase=observation-done managed_thumbprint={0} service_state={1}" -f $summary.managed.managed_thumbprint, $summary.service.state)
  $summary = Add-MyTunnelInstallMetadata -Summary $summary -ResolvedMsiPath $resolvedMsiPath -ForceFreshInstall ([bool]$ForceFreshInstall) -RemovedProducts $removedProducts -ApplyRegistryOverrides ([bool]$ApplyRegistryOverrides) -ConvergeToLocalService ([bool]$ConvergeToLocalService) -ReinstallRequested ($existingProductCodes.Count -gt 0) -MsiexecExitCode $process.ExitCode -PreInstallSummary $preInstallSummary -PreInstallServerState $preInstallServerState -RequireManagedThumbprintChange ([bool]$RequireManagedThumbprintChange) -PreregCheck $preregCheck -ServerUrl $ServerUrl -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel -ExpectedServiceSha256 $ExpectedServiceSha256 -ExpectedBundledHelperSha256 $ExpectedBundledHelperSha256
  $summary['binary_refresh_fallback_used'] = $false
  $summary['binary_refresh_fallback_reason'] = $null
  $summary['initial_reinstall_binary_state'] = $null

  if ((-not $ForceFreshInstall) -and (-not $ApplyRegistryOverrides) -and $existingProductCodes.Count -gt 0) {
    $mismatchList = @(Get-MyTunnelConfigMismatchList -Summary $summary -ServerUrl $ServerUrl -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel)
    if ($mismatchList.Count -gt 0) {
      $fallbackSummary = Invoke-MyTunnelAppSilentInstall -ServerUrl $ServerUrl -ClientUid $ClientUid -EnrollmentSecret $EnrollmentSecret -ExpectedDeviceId $ExpectedDeviceId -MsiPath $resolvedMsiPath -PollInterval $PollInterval -RenewBefore $RenewBefore -LogLevel $LogLevel -ExpectedServiceSha256 $ExpectedServiceSha256 -ExpectedBundledHelperSha256 $ExpectedBundledHelperSha256 -ForceFreshInstall -AllowExistingCertificateReuse -ConvergeToLocalService:$ConvergeToLocalService -RequireManagedThumbprintChange:$RequireManagedThumbprintChange -WaitSeconds $WaitSeconds
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
