$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Initialize-MyTunnelUiAutomation {
  if (-not ('System.Windows.Automation.AutomationElement' -as [type])) {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
  }
  if (-not ('System.Windows.Forms.SendKeys' -as [type])) {
    Add-Type -AssemblyName System.Windows.Forms
  }
}

function Get-MyTunnelUiElementsByControlType {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Root,

    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.ControlType]$ControlType
  )

  $condition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    $ControlType
  )
  $elements = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
  $results = @()
  for ($index = 0; $index -lt $elements.Count; $index += 1) {
    $results += $elements.Item($index)
  }
  $results
}

function Get-MyTunnelUiElementText {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Element
  )

  try {
    $valuePattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($null -ne $valuePattern) {
      $value = [string]$valuePattern.Current.Value
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        return $value
      }
    }
  } catch {
  }

  [string]$Element.Current.Name
}

function Find-MyTunnelUiWindow {
  param(
    [string[]]$TitlePatterns = @('*MyTunnelApp*')
  )

  $windowCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
  )
  $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
    [System.Windows.Automation.TreeScope]::Children,
    $windowCondition
  )

  for ($index = 0; $index -lt $windows.Count; $index += 1) {
    $window = $windows.Item($index)
    $title = [string]$window.Current.Name
    if ([string]::IsNullOrWhiteSpace($title)) {
      continue
    }
    foreach ($pattern in $TitlePatterns) {
      if ($title -like $pattern) {
        return $window
      }
    }
  }

  $null
}

function Get-MyTunnelUiTopLevelWindowSummary {
  $windowCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
  )
  $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
    [System.Windows.Automation.TreeScope]::Children,
    $windowCondition
  )

  $titles = @()
  for ($index = 0; $index -lt $windows.Count; $index += 1) {
    $window = $windows.Item($index)
    $title = [string]$window.Current.Name
    if ([string]::IsNullOrWhiteSpace($title)) {
      $title = '<empty-title>'
    }
    $titles += ("{0}#{1}" -f $title, $window.Current.ProcessId)
  }

  if ($titles.Count -eq 0) {
    return '<no-top-level-windows>'
  }

  ConvertTo-MyTunnelCompactText -Value (($titles | Select-Object -First 20) -join ' | ') -MaxLength 800
}

function Wait-MyTunnelUiWindow {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$TitlePatterns,

    [int]$TimeoutSeconds = 120
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max($TimeoutSeconds, 0))
  while ((Get-Date) -lt $deadline) {
    $window = Find-MyTunnelUiWindow -TitlePatterns $TitlePatterns
    if ($null -ne $window) {
      return $window
    }
    Start-Sleep -Seconds 2
  }

  throw "timed out waiting for window title matching: $($TitlePatterns -join ', ')"
}

function Get-MyTunnelUiSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Window
  )

  $texts = @(
    Get-MyTunnelUiElementsByControlType -Root $Window -ControlType ([System.Windows.Automation.ControlType]::Text) |
      ForEach-Object { [string]$_.Current.Name } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  $buttons = @(
    Get-MyTunnelUiElementsByControlType -Root $Window -ControlType ([System.Windows.Automation.ControlType]::Button) |
      ForEach-Object { [string]$_.Current.Name } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  $edits = @()
  foreach ($element in (Get-MyTunnelUiElementsByControlType -Root $Window -ControlType ([System.Windows.Automation.ControlType]::Edit))) {
    $edits += [ordered]@{
      automation_id = [string]$element.Current.AutomationId
      name          = [string]$element.Current.Name
      value         = Get-MyTunnelUiElementText -Element $element
    }
  }

  [ordered]@{
    title   = [string]$Window.Current.Name
    texts   = $texts
    buttons = $buttons
    edits   = $edits
  }
}

function Add-MyTunnelGuiEvidence {
  param(
    [Parameter(Mandatory = $true)]
    [object]$DialogLog,

    [Parameter(Mandatory = $true)]
    [string]$Stage,

    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Window
  )

  $snapshot = Get-MyTunnelUiSnapshot -Window $Window
  $null = $DialogLog.Add([ordered]@{
    observed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    stage           = $Stage
    snapshot        = $snapshot
  })
  Write-MyTunnelProgress ("MYTUNNEL_GUI_PROGRESS phase={0} title={1}" -f $Stage, (ConvertTo-MyTunnelCompactText -Value $snapshot.title -MaxLength 120))
  $snapshot
}

function Find-MyTunnelUiButton {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Window,

    [Parameter(Mandatory = $true)]
    [string[]]$Names
  )

  foreach ($button in (Get-MyTunnelUiElementsByControlType -Root $Window -ControlType ([System.Windows.Automation.ControlType]::Button))) {
    $buttonName = [string]$button.Current.Name
    foreach ($name in $Names) {
      if ($buttonName -eq $name) {
        return $button
      }
    }
  }

  $null
}

function Invoke-MyTunnelUiButtonIfPresent {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Window,

    [Parameter(Mandatory = $true)]
    [string[]]$Names
  )

  $button = Find-MyTunnelUiButton -Window $Window -Names $Names
  if ($null -eq $button) {
    return $false
  }

  try {
    $invokePattern = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invokePattern.Invoke()
  } catch {
    $button.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait(' ')
  }

  $true
}

function Set-MyTunnelUiEditValue {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Window,

    [Parameter(Mandatory = $true)]
    [int]$Index,

    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  $edits = @(Get-MyTunnelUiElementsByControlType -Root $Window -ControlType ([System.Windows.Automation.ControlType]::Edit))
  if ($Index -lt 0 -or $Index -ge $edits.Count) {
    throw "edit control index $Index was not present on window $([string]$Window.Current.Name)"
  }

  $element = $edits[$Index]
  try {
    $valuePattern = $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $valuePattern.SetValue($Value)
    return
  } catch {
  }

  $element.SetFocus()
  [System.Windows.Forms.Clipboard]::SetText($Value)
  Start-Sleep -Milliseconds 200
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  Start-Sleep -Milliseconds 100
  [System.Windows.Forms.SendKeys]::SendWait('^v')
}

function Select-MyTunnelAcceptanceControl {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Window
  )

  $selectionControls = @()
  $selectionControls += Get-MyTunnelUiElementsByControlType -Root $Window -ControlType ([System.Windows.Automation.ControlType]::CheckBox)
  $selectionControls += Get-MyTunnelUiElementsByControlType -Root $Window -ControlType ([System.Windows.Automation.ControlType]::RadioButton)

  foreach ($control in $selectionControls) {
    $name = [string]$control.Current.Name
    if ($name -notmatch '(?i)\baccept\b') {
      continue
    }

    try {
      $selectionPattern = $control.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
      $selectionPattern.Select()
      return $true
    } catch {
    }

    try {
      $togglePattern = $control.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
      if ($togglePattern.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        $togglePattern.Toggle()
      }
      return $true
    } catch {
    }
  }

  $false
}

function Remove-MyTunnelInstalledProductsForGuiRun {
  $removedProducts = @()
  foreach ($productCode in @(Get-MyTunnelInstalledProductCodes)) {
    Write-MyTunnelProgress ("MYTUNNEL_GUI_PROGRESS phase=preclean-uninstall product_code={0}" -f $productCode)
    $result = Invoke-MyTunnelCapturedProcess -FilePath 'msiexec.exe' -ArgumentList @('/x', $productCode, '/qn', '/norestart') -TimeoutSeconds 900
    if ($result.timed_out) {
      throw "msiexec.exe uninstall timed out for $productCode"
    }
    if ($result.exit_code -ne 0) {
      throw "msiexec.exe uninstall failed for $productCode with exit code $($result.exit_code)"
    }
    $removedProducts += [ordered]@{
      product_code = $productCode
      exit_code    = $result.exit_code
    }
  }

  Remove-Item -LiteralPath 'HKLM:\SOFTWARE\MyTunnelApp' -Recurse -Force -ErrorAction SilentlyContinue
  @($removedProducts)
}

function Wait-MyTunnelGuiStepWindow {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$SuccessTitlePatterns,

    [Parameter(Mandatory = $true)]
    [object]$DialogLog,

    [int]$TimeoutSeconds = 180,

    [string]$StandardAdvanceStage = 'advance-standard-ui'
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max($TimeoutSeconds, 0))
  while ((Get-Date) -lt $deadline) {
    $window = Find-MyTunnelUiWindow -TitlePatterns @('*MyTunnelApp*')
    if ($null -eq $window) {
      Start-Sleep -Seconds 2
      continue
    }

    $title = [string]$window.Current.Name
    foreach ($pattern in $SuccessTitlePatterns) {
      if ($title -like $pattern) {
        return $window
      }
    }

    if ($title -like '*validation*') {
      $snapshot = Add-MyTunnelGuiEvidence -DialogLog $DialogLog -Stage 'validation-dialog' -Window $window
      $message = ConvertTo-MyTunnelCompactText -Value ($snapshot.texts -join ' | ') -MaxLength 600
      throw "GUI validation dialog blocked progress: $message"
    }

    $snapshot = Add-MyTunnelGuiEvidence -DialogLog $DialogLog -Stage $StandardAdvanceStage -Window $window
    $advanced = $false
    if (Select-MyTunnelAcceptanceControl -Window $window) {
      $advanced = $true
    }
    if (Invoke-MyTunnelUiButtonIfPresent -Window $window -Names @('Next')) {
      $advanced = $true
    } elseif (Invoke-MyTunnelUiButtonIfPresent -Window $window -Names @('Install')) {
      $advanced = $true
    }

    if (-not $advanced) {
      $buttons = @($snapshot.buttons)
      throw "unexpected GUI dialog while waiting for $($SuccessTitlePatterns -join ', '): title=$title buttons=$($buttons -join ', ')"
    }

    Start-Sleep -Seconds 2
  }

  $visibleWindows = Get-MyTunnelUiTopLevelWindowSummary
  throw "timed out waiting for GUI step window: $($SuccessTitlePatterns -join ', ') visible_windows=$visibleWindows"
}

function ConvertTo-MyTunnelGuiMarkerSummary {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Summary
  )

  $marker = ConvertTo-MyTunnelMarkerSummary -Summary $Summary
  $marker['gui'] = $Summary.gui
  $marker
}

function Invoke-MyTunnelGuiInstall {
  param(
    [Parameter(Mandatory = $true)]
    [string]$MsiPath,

    [Parameter(Mandatory = $true)]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientUid,

    [Parameter(Mandatory = $true)]
    [string]$EnrollmentSecret,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId,

    [string]$DeviceIdProbePath = "",
    [string]$PollInterval = "10s",
    [string]$RenewBefore = "9000h",
    [string]$LogLevel = "debug",
    [string]$ExpectedServiceSha256 = "",
    [string]$ExpectedBundledHelperSha256 = "",
    [int]$WaitSeconds = 1800
  )

  Initialize-MyTunnelUiAutomation

  $resolvedMsiPath = Resolve-MyTunnelMsiPath -PreferredPath $MsiPath
  $preregCheckEndpoint = Resolve-MyTunnelAttestationPreregCheckEndpoint -ServerUrl $ServerUrl
  $preInstallSummary = Get-MyTunnelInstallSummary -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId
  $preInstallServerState = Get-MyTunnelServerCertificateState -ServerUrl $ServerUrl -ClientUid $ClientUid
  $removedProducts = Remove-MyTunnelInstalledProductsForGuiRun

  $guiLog = New-Object System.Collections.ArrayList
  $verboseLogPath = Join-Path 'C:\ProgramData\MyTunnelApp\logs' ("gui-install-{0}.log" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
  New-Item -ItemType Directory -Path (Split-Path -Parent $verboseLogPath) -Force | Out-Null

  Write-MyTunnelProgress ("MYTUNNEL_GUI_PROGRESS phase=launch msi_path={0}" -f $resolvedMsiPath)
  $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $resolvedMsiPath, '/l*v', $verboseLogPath) -PassThru

  $deviceWindow = Wait-MyTunnelGuiStepWindow -SuccessTitlePatterns @('*device identity*') -DialogLog $guiLog -TimeoutSeconds 90
  $deviceSnapshot = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'device-identity' -Window $deviceWindow
  if ($deviceSnapshot.edits.Count -lt 1) {
    throw 'device identity dialog did not expose CURRENT_DEVICE_ID'
  }

  $guiCurrentDeviceId = [string]$deviceSnapshot.edits[0].value
  if ([string]::IsNullOrWhiteSpace($guiCurrentDeviceId)) {
    throw 'device identity dialog returned an empty CURRENT_DEVICE_ID'
  }
  if ($guiCurrentDeviceId.ToLowerInvariant() -ne $ExpectedDeviceId.ToLowerInvariant()) {
    throw "device identity dialog showed CURRENT_DEVICE_ID=$guiCurrentDeviceId instead of preregistered EXPECTED_DEVICE_ID=$ExpectedDeviceId"
  }

  if (-not (Invoke-MyTunnelUiButtonIfPresent -Window $deviceWindow -Names @('Next'))) {
    throw 'device identity dialog did not expose a Next button'
  }

  $preregWindow = Wait-MyTunnelUiWindow -TitlePatterns @('*preregistration check*') -TimeoutSeconds 120
  $preregSnapshotBefore = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'preregistration-check-before-fill' -Window $preregWindow
  if ($preregSnapshotBefore.edits.Count -lt 3) {
    throw 'preregistration dialog did not expose the expected edit controls'
  }

  Set-MyTunnelUiEditValue -Window $preregWindow -Index 0 -Value $ServerUrl
  Set-MyTunnelUiEditValue -Window $preregWindow -Index 1 -Value $ClientUid
  $preregSnapshotAfter = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'preregistration-check-filled' -Window $preregWindow
  $preregCurrentDeviceId = [string]$preregSnapshotAfter.edits[2].value
  if ([string]::IsNullOrWhiteSpace($preregCurrentDeviceId)) {
    throw 'preregistration dialog returned an empty CURRENT_DEVICE_ID'
  }
  if ($preregCurrentDeviceId.ToLowerInvariant() -ne $ExpectedDeviceId.ToLowerInvariant()) {
    throw "preregistration dialog showed CURRENT_DEVICE_ID=$preregCurrentDeviceId instead of EXPECTED_DEVICE_ID=$ExpectedDeviceId"
  }

  if (-not (Invoke-MyTunnelUiButtonIfPresent -Window $preregWindow -Names @('Next'))) {
    throw 'preregistration dialog did not expose a Next button'
  }

  $nextWindow = Wait-MyTunnelUiWindow -TitlePatterns @('*enrollment secret*', '*validation*') -TimeoutSeconds 120
  if ([string]$nextWindow.Current.Name -like '*validation*') {
    $validationSnapshot = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'validation-dialog' -Window $nextWindow
    throw "GUI prereg-check did not advance to the enrollment secret dialog: $(ConvertTo-MyTunnelCompactText -Value ($validationSnapshot.texts -join ' | ') -MaxLength 600)"
  }

  $secretWindow = $nextWindow
  $preregCheck = [ordered]@{
    endpoint            = $preregCheckEndpoint
    result              = 'ready'
    source              = 'gui-dialog-transition'
    expected_device_id  = $ExpectedDeviceId
    current_device_id   = $preregCurrentDeviceId
    probe_path          = $DeviceIdProbePath
  }
  $secretSnapshotBefore = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'enrollment-secret-before-fill' -Window $secretWindow
  if ($secretSnapshotBefore.edits.Count -lt 1) {
    throw 'enrollment secret dialog did not expose ENROLLMENT_SECRET'
  }

  Set-MyTunnelUiEditValue -Window $secretWindow -Index 0 -Value $EnrollmentSecret
  $secretSnapshotAfter = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'enrollment-secret-filled' -Window $secretWindow

  if (-not (Invoke-MyTunnelUiButtonIfPresent -Window $secretWindow -Names @('Install'))) {
    throw 'enrollment secret dialog did not expose an Install button'
  }
  Write-MyTunnelProgress 'MYTUNNEL_GUI_PROGRESS phase=install-clicked'

  $uiDeadline = (Get-Date).AddSeconds([Math]::Max($WaitSeconds, 0))
  $finishTitle = $null
  while ((Get-Date) -lt $uiDeadline) {
    if ($process.HasExited) {
      break
    }

    $window = Find-MyTunnelUiWindow -TitlePatterns @('*MyTunnelApp*')
    if ($null -eq $window) {
      Start-Sleep -Seconds 2
      continue
    }

    $title = [string]$window.Current.Name
    if ($title -like '*validation*') {
      $validationSnapshot = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'validation-dialog' -Window $window
      throw "GUI install surfaced a validation dialog after Install: $(ConvertTo-MyTunnelCompactText -Value ($validationSnapshot.texts -join ' | ') -MaxLength 600)"
    }

    if (Invoke-MyTunnelUiButtonIfPresent -Window $window -Names @('Finish', 'Close')) {
      $finishTitle = $title
      Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'finish-dialog' -Window $window | Out-Null
      Start-Sleep -Seconds 2
      continue
    }

    if (Invoke-MyTunnelUiButtonIfPresent -Window $window -Names @('Install')) {
      Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'post-secret-install' -Window $window | Out-Null
      Start-Sleep -Seconds 2
      continue
    }

    Start-Sleep -Seconds 2
  }

  if (-not $process.HasExited) {
    if (-not $process.WaitForExit(15000)) {
      throw "timed out waiting for GUI msiexec process $($process.Id) to exit"
    }
  }
  if ($process.ExitCode -ne 0) {
    throw "GUI msiexec exited with code $($process.ExitCode)"
  }

  Write-MyTunnelProgress ("MYTUNNEL_GUI_PROGRESS phase=observation-start wait_seconds={0}" -f $WaitSeconds)
  $summary = Wait-MyTunnelInstallObservation -ClientUid $ClientUid -ExpectedDeviceId $ExpectedDeviceId -BaselineSummary $preInstallSummary -WaitSeconds $WaitSeconds
  Write-MyTunnelProgress ("MYTUNNEL_GUI_PROGRESS phase=observation-done managed_thumbprint={0} service_state={1}" -f $summary.managed.managed_thumbprint, $summary.service.state)

  $summary['prereg_check'] = $preregCheck
  $summary['msi_path'] = $resolvedMsiPath
  $summary['fresh_install_requested'] = $true
  $summary['fresh_install_removed_products'] = @($removedProducts)
  $summary['apply_registry_overrides_requested'] = $false
  $summary['converge_to_local_service_requested'] = $false
  $summary['reinstall_requested'] = $false
  $summary['msiexec_exit_code'] = $process.ExitCode
  $summary['reboot_required'] = $process.ExitCode -in @(1641, 3010)
  $summary['pre_install_summary'] = $preInstallSummary
  $summary['pre_install_server'] = $preInstallServerState
  $summary['managed_thumbprint_before'] = $preInstallSummary.managed.managed_thumbprint
  $summary['managed_thumbprint_after'] = $summary.managed.managed_thumbprint
  $summary['managed_thumbprint_changed'] = (
    $null -ne $preInstallSummary.managed.managed_thumbprint -and
    $null -ne $summary.managed.managed_thumbprint -and
    $preInstallSummary.managed.managed_thumbprint -ne $summary.managed.managed_thumbprint
  )
  $serverState = Get-MyTunnelServerCertificateState -ServerUrl $ServerUrl -ClientUid $ClientUid
  $summary['server'] = $serverState
  $summary['server_active_thumbprint_before'] = $preInstallServerState.active_thumbprint
  $summary['server_active_thumbprint_after'] = $serverState.active_thumbprint
  $summary['server_active_thumbprint_changed'] = (
    -not [string]::IsNullOrWhiteSpace([string]$preInstallServerState.active_thumbprint) -and
    -not [string]::IsNullOrWhiteSpace([string]$serverState.active_thumbprint) -and
    [string]$preInstallServerState.active_thumbprint -ne [string]$serverState.active_thumbprint
  )
  $summary['server_active_serial_before'] = $preInstallServerState.active_serial
  $summary['server_active_serial_after'] = $serverState.active_serial
  $summary['server_active_serial_changed'] = (
    -not [string]::IsNullOrWhiteSpace([string]$preInstallServerState.active_serial) -and
    -not [string]::IsNullOrWhiteSpace([string]$serverState.active_serial) -and
    [string]$preInstallServerState.active_serial -ne [string]$serverState.active_serial
  )
  $programFiles = Get-MyTunnelInstalledBinaryState -ExpectedServiceSha256 $ExpectedServiceSha256 -ExpectedBundledHelperSha256 $ExpectedBundledHelperSha256
  $summary['program_files'] = $programFiles
  $summary['expected_binaries'] = [ordered]@{
    service_sha256         = if ([string]::IsNullOrWhiteSpace($ExpectedServiceSha256)) { $null } else { $ExpectedServiceSha256.ToLowerInvariant() }
    bundled_helper_sha256  = if ([string]::IsNullOrWhiteSpace($ExpectedBundledHelperSha256)) { $null } else { $ExpectedBundledHelperSha256.ToLowerInvariant() }
  }
  $summary['program_files_match_expected'] = -not [bool]$programFiles.any_mismatch
  $summary['managed_matches_server_active'] = (
    -not [string]::IsNullOrWhiteSpace([string]$summary.managed.managed_thumbprint) -and
    -not [string]::IsNullOrWhiteSpace([string]$serverState.active_thumbprint) -and
    [string]$summary.managed.managed_thumbprint -eq [string]$serverState.active_thumbprint
  )
  $summary['require_managed_thumbprint_change'] = $false
  $summary['binary_refresh_fallback_used'] = $false
  $summary['binary_refresh_fallback_reason'] = $null
  $summary['initial_reinstall_binary_state'] = $null
  $summary['reconfigure_fallback_used'] = $false
  $summary['reconfigure_fallback_reason'] = $null
  $summary['requested_config'] = [ordered]@{
    server_url         = $ServerUrl
    client_uid         = $ClientUid
    expected_device_id = $ExpectedDeviceId
    poll_interval      = $PollInterval
    renew_before       = $RenewBefore
    log_level          = $LogLevel
  }
  $summary['gui'] = [ordered]@{
    dialogs_seen                     = @($guiLog)
    current_device_id_from_page1     = $guiCurrentDeviceId
    current_device_id_from_prereg    = $preregCurrentDeviceId
    finish_dialog_title              = $finishTitle
    msi_verbose_log_path             = $verboseLogPath
    step3_texts                      = @($secretSnapshotAfter.texts)
  }

  $summary
}
