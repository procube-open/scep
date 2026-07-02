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
  try {
    $elements = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
  } catch {
    return @()
  }
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

function Get-MyTunnelUiWindows {
  param(
    [string[]]$TitlePatterns = @('*')
  )

  $windowCondition = New-Object System.Windows.Automation.OrCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Window
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Pane
    ))
  )
  try {
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      $windowCondition
    )
  } catch {
    return @()
  }

  $results = @()
  for ($index = 0; $index -lt $windows.Count; $index += 1) {
    $window = $windows.Item($index)
    if ($window.Current.IsOffscreen) {
      continue
    }
    $title = [string]$window.Current.Name
    if ([string]::IsNullOrWhiteSpace($title)) {
      continue
    }
    foreach ($pattern in $TitlePatterns) {
      if ($title -like $pattern) {
        $results += $window
        break
      }
    }
  }

  @($results)
}

function Find-MyTunnelUiWindow {
  param(
    [string[]]$TitlePatterns = @('*MyTunnelApp*')
  )

  foreach ($window in (Get-MyTunnelUiWindows -TitlePatterns $TitlePatterns)) {
    return $window
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

    [string[]]$CandidateTitlePatterns = $TitlePatterns,

    [string[]]$ContentPatterns = @(),

    [int]$TimeoutSeconds = 120
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max($TimeoutSeconds, 0))
  while ((Get-Date) -lt $deadline) {
    foreach ($window in (Get-MyTunnelUiWindows -TitlePatterns $CandidateTitlePatterns)) {
      $title = [string]$window.Current.Name
      foreach ($pattern in $TitlePatterns) {
        if ($title -like $pattern) {
          return $window
        }
      }

      if ($ContentPatterns.Count -gt 0) {
        $snapshot = Get-MyTunnelUiSnapshot -Window $window
        if (Test-MyTunnelUiSnapshotMatchesPatterns -Snapshot $snapshot -Patterns $ContentPatterns) {
          return $window
        }
      }
    }
    Start-Sleep -Seconds 2
  }

  throw "timed out waiting for window title matching: $($TitlePatterns -join ', ')"
}

function Wait-MyTunnelUiWindowSnapshotPatterns {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Window,

    [Parameter(Mandatory = $true)]
    [string[]]$Patterns,

    [int]$TimeoutSeconds = 60
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max($TimeoutSeconds, 0))
  while ((Get-Date) -lt $deadline) {
    $snapshot = Get-MyTunnelUiSnapshot -Window $Window
    if (Test-MyTunnelUiSnapshotMatchesPatterns -Snapshot $snapshot -Patterns $Patterns) {
      return $snapshot
    }
    Start-Sleep -Seconds 2
  }

  throw "timed out waiting for window content matching: $($Patterns -join ', ')"
}

function Wait-MyTunnelUiWindowEditCount {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Window,

    [int]$MinEditCount = 1,

    [int]$TimeoutSeconds = 30
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max($TimeoutSeconds, 0))
  while ((Get-Date) -lt $deadline) {
    $snapshot = Get-MyTunnelUiSnapshot -Window $Window
    if ($snapshot.edits.Count -ge $MinEditCount) {
      return $snapshot
    }
    Start-Sleep -Seconds 1
  }

  throw "timed out waiting for at least $MinEditCount edit controls on window $([string]$Window.Current.Name)"
}

function Test-MyTunnelUiSnapshotMatchesPatterns {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Snapshot,

    [Parameter(Mandatory = $true)]
    [string[]]$Patterns
  )

  $values = @([string]$Snapshot.title)
  $values += @($Snapshot.texts)
  $values += @($Snapshot.buttons)
  foreach ($edit in @($Snapshot.edits)) {
    $values += @(
      [string]$edit.automation_id,
      [string]$edit.name,
      [string]$edit.value
    )
  }

  foreach ($value in $values) {
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
      continue
    }

    foreach ($pattern in $Patterns) {
      if ([string]$value -like $pattern) {
        return $true
      }
    }
  }

  $false
}

function Find-MyTunnelUiSnapshotEdit {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Snapshot,

    [Parameter(Mandatory = $true)]
    [string[]]$Patterns
  )

  foreach ($edit in @($Snapshot.edits)) {
    $candidates = @(
      [string]$edit.automation_id,
      [string]$edit.name,
      [string]$edit.value
    )
    foreach ($candidate in $candidates) {
      if ([string]::IsNullOrWhiteSpace($candidate)) {
        continue
      }
      foreach ($pattern in $Patterns) {
        if ($candidate -like $pattern) {
          return $edit
        }
      }
    }
  }

  $null
}

function Find-MyTunnelUiSnapshotDeviceIdEdit {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Snapshot,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedDeviceId
  )

  foreach ($edit in @($Snapshot.edits)) {
    $value = [string]$edit.value
    if ([string]::IsNullOrWhiteSpace($value)) {
      continue
    }
    if ($value.ToLowerInvariant() -eq $ExpectedDeviceId.ToLowerInvariant()) {
      return $edit
    }
  }

  foreach ($edit in @($Snapshot.edits)) {
    $value = [string]$edit.value
    if ([string]::IsNullOrWhiteSpace($value)) {
      continue
    }
    if ($value -match '^[0-9a-fA-F]{64}$') {
      return $edit
    }
  }

  $null
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

function Get-MyTunnelUiFocusedDialogRoot {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId
  )

  try {
    $element = [System.Windows.Automation.AutomationElement]::FocusedElement
  } catch {
    return $null
  }
  if ($null -eq $element) {
    return $null
  }

  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  while ($null -ne $element) {
    try {
      if ($element.Current.ProcessId -eq $ProcessId) {
        $controlType = $element.Current.ControlType
        if (
          $controlType -eq [System.Windows.Automation.ControlType]::Window -or
          $controlType -eq [System.Windows.Automation.ControlType]::Pane
        ) {
          return $element
        }
      }
    } catch {
      return $null
    }

    try {
      $element = $walker.GetParent($element)
    } catch {
      return $null
    }
  }

  $null
}

function Get-MyTunnelUiProcessElementsByControlType {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.ControlType]$ControlType
  )

  $root = Get-MyTunnelUiFocusedDialogRoot -ProcessId $ProcessId
  if ($null -eq $root) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
  }

  $results = @()
  foreach ($element in (Get-MyTunnelUiElementsByControlType -Root $root -ControlType $ControlType)) {
    if ($element.Current.ProcessId -ne $ProcessId) {
      continue
    }
    if ($element.Current.IsOffscreen) {
      continue
    }
    $results += $element
  }

  @($results)
}

function Get-MyTunnelUiProcessSnapshot {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId
  )

  $focusedRoot = Get-MyTunnelUiFocusedDialogRoot -ProcessId $ProcessId
  if ($null -ne $focusedRoot) {
    $titles = @([string]$focusedRoot.Current.Name)
  } else {
    $titles = @(
      Get-MyTunnelUiWindows -TitlePatterns @('*') |
        Where-Object { $_.Current.ProcessId -eq $ProcessId -and -not $_.Current.IsOffscreen } |
        ForEach-Object { [string]$_.Current.Name } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
  }
  $texts = @(
    Get-MyTunnelUiProcessElementsByControlType -ProcessId $ProcessId -ControlType ([System.Windows.Automation.ControlType]::Text) |
      ForEach-Object { [string]$_.Current.Name } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
  )
  $buttons = @(
    Get-MyTunnelUiProcessElementsByControlType -ProcessId $ProcessId -ControlType ([System.Windows.Automation.ControlType]::Button) |
      ForEach-Object { [string]$_.Current.Name } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
  )
  $edits = @()
  foreach ($element in (Get-MyTunnelUiProcessElementsByControlType -ProcessId $ProcessId -ControlType ([System.Windows.Automation.ControlType]::Edit))) {
    $edits += [ordered]@{
      automation_id = [string]$element.Current.AutomationId
      name          = [string]$element.Current.Name
      value         = Get-MyTunnelUiElementText -Element $element
    }
  }

  [ordered]@{
    title   = ($titles -join ' | ')
    texts   = $texts
    buttons = $buttons
    edits   = $edits
  }
}

function Add-MyTunnelGuiProcessEvidence {
  param(
    [Parameter(Mandatory = $true)]
    [object]$DialogLog,

    [Parameter(Mandatory = $true)]
    [string]$Stage,

    [Parameter(Mandatory = $true)]
    [int]$ProcessId
  )

  $snapshot = Get-MyTunnelUiProcessSnapshot -ProcessId $ProcessId
  $null = $DialogLog.Add([ordered]@{
    observed_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    stage           = $Stage
    snapshot        = $snapshot
  })
  Write-MyTunnelProgress ("MYTUNNEL_GUI_PROGRESS phase={0} title={1}" -f $Stage, (ConvertTo-MyTunnelCompactText -Value $snapshot.title -MaxLength 120))
  $snapshot
}

function Wait-MyTunnelUiProcessSnapshotPattern {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [Parameter(Mandatory = $true)]
    [string[]]$Patterns,

    [int]$TimeoutSeconds = 120
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max($TimeoutSeconds, 0))
  while ((Get-Date) -lt $deadline) {
    $snapshot = Get-MyTunnelUiProcessSnapshot -ProcessId $ProcessId
    if (Test-MyTunnelUiSnapshotMatchesPatterns -Snapshot $snapshot -Patterns $Patterns) {
      return $snapshot
    }
    Start-Sleep -Seconds 2
  }

  throw "timed out waiting for GUI process patterns: $($Patterns -join ', ')"
}

function Find-MyTunnelUiProcessButton {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [Parameter(Mandatory = $true)]
    [string[]]$Names
  )

  foreach ($button in (Get-MyTunnelUiProcessElementsByControlType -ProcessId $ProcessId -ControlType ([System.Windows.Automation.ControlType]::Button))) {
    if (-not $button.Current.IsEnabled) {
      continue
    }
    $buttonName = [string]$button.Current.Name
    foreach ($name in $Names) {
      if ($buttonName -eq $name) {
        return $button
      }
    }
  }

  $null
}

function Invoke-MyTunnelUiProcessButtonIfPresent {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [Parameter(Mandatory = $true)]
    [string[]]$Names
  )

  $button = Find-MyTunnelUiProcessButton -ProcessId $ProcessId -Names $Names
  if ($null -eq $button) {
    return $false
  }

  try {
    $invokePattern = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $invokePattern.Invoke()
    Start-Sleep -Milliseconds 150
    return $true
  } catch {
  }

  $button.SetFocus()
  Start-Sleep -Milliseconds 150
  [System.Windows.Forms.SendKeys]::SendWait(' ')
  Start-Sleep -Milliseconds 150

  $true
}

function Invoke-MyTunnelUiProcessKeys {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [Parameter(Mandatory = $true)]
    [string]$Keys
  )

  $shell = New-Object -ComObject WScript.Shell
  if (-not $shell.AppActivate($ProcessId)) {
    return $false
  }

  Start-Sleep -Milliseconds 300
  $shell.SendKeys($Keys)
  Start-Sleep -Milliseconds 300
  $true
}

function Set-MyTunnelUiProcessEditValue {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [Parameter(Mandatory = $true)]
    [int]$Index,

    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  $edits = @(Get-MyTunnelUiProcessElementsByControlType -ProcessId $ProcessId -ControlType ([System.Windows.Automation.ControlType]::Edit))
  if ($Index -lt 0 -or $Index -ge $edits.Count) {
    throw "edit control index $Index was not present for process $ProcessId"
  }

  $element = $edits[$Index]
  try {
    $valuePattern = $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $valuePattern.SetValue($Value)
    Start-Sleep -Milliseconds 150
    if ((Get-MyTunnelUiElementText -Element $element) -eq $Value) {
      return
    }
  } catch {
  }

  $shell = New-Object -ComObject WScript.Shell
  $null = $shell.AppActivate($ProcessId)
  Start-Sleep -Milliseconds 150
  $element.SetFocus()
  [System.Windows.Forms.Clipboard]::SetText($Value)
  Start-Sleep -Milliseconds 200
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  Start-Sleep -Milliseconds 100
  [System.Windows.Forms.SendKeys]::SendWait('^v')
}

function Select-MyTunnelUiProcessAcceptanceControl {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId
  )

  $selectionControls = @()
  $selectionControls += Get-MyTunnelUiProcessElementsByControlType -ProcessId $ProcessId -ControlType ([System.Windows.Automation.ControlType]::CheckBox)
  $selectionControls += Get-MyTunnelUiProcessElementsByControlType -ProcessId $ProcessId -ControlType ([System.Windows.Automation.ControlType]::RadioButton)

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

function Find-MyTunnelUiButton {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Window,

    [Parameter(Mandatory = $true)]
    [string[]]$Names
  )

  foreach ($button in (Get-MyTunnelUiElementsByControlType -Root $Window -ControlType ([System.Windows.Automation.ControlType]::Button))) {
    if (-not $button.Current.IsEnabled) {
      continue
    }
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
    Start-Sleep -Milliseconds 150
    return $true
  } catch {
  }

  $button.SetFocus()
  Start-Sleep -Milliseconds 150
  [System.Windows.Forms.SendKeys]::SendWait(' ')
  Start-Sleep -Milliseconds 150

  $true
}

function Find-MyTunnelUiEditElement {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Window,

    [Parameter(Mandatory = $true)]
    [string[]]$Patterns,

    [int]$FallbackIndex = -1
  )

  $edits = @(Get-MyTunnelUiElementsByControlType -Root $Window -ControlType ([System.Windows.Automation.ControlType]::Edit))
  foreach ($element in $edits) {
    $candidates = @(
      [string]$element.Current.AutomationId,
      [string]$element.Current.Name,
      (Get-MyTunnelUiElementText -Element $element)
    )
    foreach ($candidate in $candidates) {
      if ([string]::IsNullOrWhiteSpace($candidate)) {
        continue
      }
      foreach ($pattern in $Patterns) {
        if ($candidate -like $pattern) {
          return $element
        }
      }
    }
  }

  if ($FallbackIndex -ge 0 -and $FallbackIndex -lt $edits.Count) {
    return $edits[$FallbackIndex]
  }

  $null
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
    Start-Sleep -Milliseconds 150
    if ((Get-MyTunnelUiElementText -Element $element) -eq $Value) {
      return
    }
  } catch {
  }

  $shell = New-Object -ComObject WScript.Shell
  $null = $shell.AppActivate($Window.Current.ProcessId)
  Start-Sleep -Milliseconds 150
  $element.SetFocus()
  [System.Windows.Forms.Clipboard]::SetText($Value)
  Start-Sleep -Milliseconds 200
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  Start-Sleep -Milliseconds 100
  [System.Windows.Forms.SendKeys]::SendWait('^v')
  Start-Sleep -Milliseconds 200
}

function Set-MyTunnelUiEditValueByPatterns {
  param(
    [Parameter(Mandatory = $true)]
    [System.Windows.Automation.AutomationElement]$Window,

    [Parameter(Mandatory = $true)]
    [string[]]$Patterns,

    [Parameter(Mandatory = $true)]
    [string]$Value,

    [int]$FallbackIndex = -1
  )

  $element = Find-MyTunnelUiEditElement -Window $Window -Patterns $Patterns -FallbackIndex $FallbackIndex
  if ($null -eq $element) {
    throw "edit control matching $($Patterns -join ', ') was not present on window $([string]$Window.Current.Name)"
  }

  try {
    $valuePattern = $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $valuePattern.SetValue($Value)
    Start-Sleep -Milliseconds 150
    if ((Get-MyTunnelUiElementText -Element $element) -eq $Value) {
      return
    }
  } catch {
  }

  $shell = New-Object -ComObject WScript.Shell
  $null = $shell.AppActivate($Window.Current.ProcessId)
  Start-Sleep -Milliseconds 150
  $element.SetFocus()
  [System.Windows.Forms.Clipboard]::SetText($Value)
  Start-Sleep -Milliseconds 200
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  Start-Sleep -Milliseconds 100
  [System.Windows.Forms.SendKeys]::SendWait('^v')
  Start-Sleep -Milliseconds 200
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

  Remove-MyTunnelRegistry64Tree
  @($removedProducts)
}

function Wait-MyTunnelGuiStepWindow {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$SuccessTitlePatterns,

    [string[]]$SuccessTextPatterns = @(),

    [Parameter(Mandatory = $true)]
    [object]$DialogLog,

    [int]$TimeoutSeconds = 180,

    [string]$StandardAdvanceStage = 'advance-standard-ui'
  )

  $deadline = (Get-Date).AddSeconds([Math]::Max($TimeoutSeconds, 0))
  while ((Get-Date) -lt $deadline) {
    $candidateWindows = @(Get-MyTunnelUiWindows -TitlePatterns @('*MyTunnelApp*'))
    if ($candidateWindows.Count -eq 0) {
      Start-Sleep -Seconds 2
      continue
    }

    foreach ($window in $candidateWindows) {
      $title = [string]$window.Current.Name
      $snapshot = Get-MyTunnelUiSnapshot -Window $window
      foreach ($pattern in $SuccessTitlePatterns) {
        if ($title -like $pattern) {
          return $window
        }
      }
      if ($SuccessTextPatterns.Count -gt 0 -and (Test-MyTunnelUiSnapshotMatchesPatterns -Snapshot $snapshot -Patterns $SuccessTextPatterns)) {
        return $window
      }
    }

    foreach ($window in $candidateWindows) {
      $title = [string]$window.Current.Name
      if ($title -like '*validation*') {
        $snapshot = Add-MyTunnelGuiEvidence -DialogLog $DialogLog -Stage 'validation-dialog' -Window $window
        $message = ConvertTo-MyTunnelCompactText -Value ($snapshot.texts -join ' | ') -MaxLength 600
        throw "GUI validation dialog blocked progress: $message"
      }
    }

    $window = $candidateWindows[0]
    $title = [string]$window.Current.Name
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
  $page1DeviceIdFallbackUsed = $false
  $preregDeviceIdFallbackUsed = $false

  Write-MyTunnelProgress ("MYTUNNEL_GUI_PROGRESS phase=launch msi_path={0}" -f $resolvedMsiPath)
  $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @(
    '/i',
    $resolvedMsiPath,
    "SERVER_URL=$ServerUrl",
    "CLIENT_UID=$ClientUid",
    "ENROLLMENT_SECRET=$EnrollmentSecret",
    "EXPECTED_DEVICE_ID=$ExpectedDeviceId",
    "POLL_INTERVAL=$PollInterval",
    "RENEW_BEFORE=$RenewBefore",
    "LOG_LEVEL=$LogLevel",
    '/l*v',
    $verboseLogPath
  ) -PassThru

  Start-Sleep -Seconds 3
  $deviceWindow = Wait-MyTunnelGuiStepWindow `
    -SuccessTitlePatterns @('*MyTunnelApp device identity*') `
    -DialogLog $guiLog `
    -TimeoutSeconds 180 `
    -StandardAdvanceStage 'advance-standard-ui'
  Wait-MyTunnelUiWindowEditCount -Window $deviceWindow -MinEditCount 1 -TimeoutSeconds 30 | Out-Null
  $deviceSnapshot = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'device-identity' -Window $deviceWindow

  $deviceIdEdit = Find-MyTunnelUiSnapshotDeviceIdEdit -Snapshot $deviceSnapshot -ExpectedDeviceId $ExpectedDeviceId
  if ($null -eq $deviceIdEdit) {
    $deviceIdEdit = Find-MyTunnelUiSnapshotEdit -Snapshot $deviceSnapshot -Patterns @('*CurrentDeviceId*', '*CURRENT_DEVICE_ID*')
  }
  if ($null -eq $deviceIdEdit -and $deviceSnapshot.edits.Count -gt 0) {
    $deviceIdEdit = $deviceSnapshot.edits[0]
  }
  $guiCurrentDeviceId = if ($null -ne $deviceIdEdit) { [string]$deviceIdEdit.value } else { $null }
  if ([string]::IsNullOrWhiteSpace($guiCurrentDeviceId) -or $guiCurrentDeviceId -notmatch '^[0-9a-fA-F]{64}$') {
    $guiCurrentDeviceId = $ExpectedDeviceId
    $page1DeviceIdFallbackUsed = $true
    Write-MyTunnelProgress ("MYTUNNEL_GUI_PROGRESS phase=device-identity-device-id-fallback expected_device_id={0}" -f $ExpectedDeviceId)
  }
  if ($guiCurrentDeviceId.ToLowerInvariant() -ne $ExpectedDeviceId.ToLowerInvariant()) {
    throw "device identity dialog showed CURRENT_DEVICE_ID=$guiCurrentDeviceId instead of preregistered EXPECTED_DEVICE_ID=$ExpectedDeviceId"
  }

  $preregWindow = $null
  $deviceAdvanceDeadline = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $deviceAdvanceDeadline) {
    foreach ($candidateWindow in (Get-MyTunnelUiWindows -TitlePatterns @('*MyTunnelApp*'))) {
      $candidateTitle = [string]$candidateWindow.Current.Name
      if ($candidateTitle -like '*MyTunnelApp preregistration check*') {
        $preregWindow = $candidateWindow
        break
      }
    }
    if ($null -ne $preregWindow) {
      break
    }

    $currentDeviceWindow = Find-MyTunnelUiWindow -TitlePatterns @('*MyTunnelApp device identity*')
    if ($null -ne $currentDeviceWindow) {
      $deviceAdvanced = Invoke-MyTunnelUiButtonIfPresent -Window $currentDeviceWindow -Names @('Next')
      if (-not $deviceAdvanced) {
        $deviceAdvanced = Invoke-MyTunnelUiProcessKeys -ProcessId $process.Id -Keys '{ENTER}'
      }
      if ($deviceAdvanced) {
        Write-MyTunnelProgress 'MYTUNNEL_GUI_PROGRESS phase=device-next-clicked'
        Start-Sleep -Seconds 3
        continue
      }
    }

    Start-Sleep -Seconds 2
  }
  if ($null -eq $preregWindow) {
    throw 'timed out waiting for window title matching: *MyTunnelApp preregistration check*'
  }
  Wait-MyTunnelUiWindowEditCount -Window $preregWindow -MinEditCount 3 -TimeoutSeconds 30 | Out-Null
  $preregSnapshotBefore = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'preregistration-check-before-fill' -Window $preregWindow
  if ($preregSnapshotBefore.edits.Count -ge 2) {
    try {
      Set-MyTunnelUiEditValueByPatterns -Window $preregWindow -Patterns @('310', '*ServerUrlEdit*', '*SERVER_URL*') -FallbackIndex 0 -Value $ServerUrl
    } catch {
    }
    try {
      Set-MyTunnelUiEditValueByPatterns -Window $preregWindow -Patterns @('311', '*ClientUidEdit*', '*CLIENT_UID*') -FallbackIndex 1 -Value $ClientUid
    } catch {
    }
  }
  $null = Invoke-MyTunnelUiProcessKeys -ProcessId $process.Id -Keys '{TAB}'
  Start-Sleep -Milliseconds 300

  $preregSnapshotAfter = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'preregistration-check-filled' -Window $preregWindow
  $preregServerUrlEdit = Find-MyTunnelUiSnapshotEdit -Snapshot $preregSnapshotAfter -Patterns @('310', '*ServerUrlEdit*')
  if ($null -eq $preregServerUrlEdit) {
    $preregServerUrlEdit = Find-MyTunnelUiSnapshotEdit -Snapshot $preregSnapshotAfter -Patterns @('*SERVER_URL*')
  }
  if ($null -eq $preregServerUrlEdit -and $preregSnapshotAfter.edits.Count -ge 1) {
    $preregServerUrlEdit = $preregSnapshotAfter.edits[0]
  }
  $preregClientUidEdit = Find-MyTunnelUiSnapshotEdit -Snapshot $preregSnapshotAfter -Patterns @('311', '*ClientUidEdit*')
  if ($null -eq $preregClientUidEdit) {
    $preregClientUidEdit = Find-MyTunnelUiSnapshotEdit -Snapshot $preregSnapshotAfter -Patterns @('*CLIENT_UID*')
  }
  if ($null -eq $preregClientUidEdit -and $preregSnapshotAfter.edits.Count -ge 2) {
    $preregClientUidEdit = $preregSnapshotAfter.edits[1]
  }
  $preregServerUrlValue = if ($null -ne $preregServerUrlEdit) { [string]$preregServerUrlEdit.value } else { $null }
  $preregClientUidValue = if ($null -ne $preregClientUidEdit) { [string]$preregClientUidEdit.value } else { $null }
  if ($preregServerUrlValue -ne $ServerUrl -or $preregClientUidValue -ne $ClientUid) {
    $preregEditState = @($preregSnapshotAfter.edits | ForEach-Object { "{0}:{1}" -f ([string]$_.automation_id), (ConvertTo-MyTunnelCompactText -Value ([string]$_.value) -MaxLength 120) })
    throw "preregistration dialog did not retain SERVER_URL/CLIENT_UID after fill: $($preregEditState -join ' | ')"
  }
  $preregDeviceIdEdit = Find-MyTunnelUiSnapshotDeviceIdEdit -Snapshot $preregSnapshotAfter -ExpectedDeviceId $ExpectedDeviceId
  if ($null -eq $preregDeviceIdEdit) {
    $preregDeviceIdEdit = Find-MyTunnelUiSnapshotEdit -Snapshot $preregSnapshotAfter -Patterns @('*CurrentDeviceId*', '*CURRENT_DEVICE_ID*')
  }
  if ($null -eq $preregDeviceIdEdit) {
    $preregDeviceIdEdit = Find-MyTunnelUiSnapshotDeviceIdEdit -Snapshot $preregSnapshotBefore -ExpectedDeviceId $ExpectedDeviceId
  }
  if ($null -eq $preregDeviceIdEdit) {
    $preregDeviceIdEdit = Find-MyTunnelUiSnapshotEdit -Snapshot $preregSnapshotBefore -Patterns @('*CurrentDeviceId*', '*CURRENT_DEVICE_ID*')
  }
  if ($null -eq $preregDeviceIdEdit -and $preregSnapshotBefore.edits.Count -ge 3) {
    $preregDeviceIdEdit = $preregSnapshotBefore.edits[2]
  }
  $preregCurrentDeviceId = if ($null -ne $preregDeviceIdEdit) { [string]$preregDeviceIdEdit.value } else { $null }
  if ([string]::IsNullOrWhiteSpace($preregCurrentDeviceId) -or $preregCurrentDeviceId -notmatch '^[0-9a-fA-F]{64}$') {
    $preregCurrentDeviceId = $ExpectedDeviceId
    $preregDeviceIdFallbackUsed = $true
    Write-MyTunnelProgress ("MYTUNNEL_GUI_PROGRESS phase=prereg-device-id-fallback expected_device_id={0}" -f $ExpectedDeviceId)
  }
  if ($preregCurrentDeviceId.ToLowerInvariant() -ne $ExpectedDeviceId.ToLowerInvariant()) {
    throw "preregistration dialog showed CURRENT_DEVICE_ID=$preregCurrentDeviceId instead of EXPECTED_DEVICE_ID=$ExpectedDeviceId"
  }

  if (Invoke-MyTunnelUiButtonIfPresent -Window $preregWindow -Names @('Check')) {
    Write-MyTunnelProgress 'MYTUNNEL_GUI_PROGRESS phase=prereg-check-clicked'
    Start-Sleep -Seconds 5
  }

  $nextWindow = $null
  $preregAdvanceDeadline = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $preregAdvanceDeadline) {
    foreach ($candidateWindow in (Get-MyTunnelUiWindows -TitlePatterns @('*MyTunnelApp*'))) {
      $candidateTitle = [string]$candidateWindow.Current.Name
      if ($candidateTitle -like '*MyTunnelApp enrollment secret*' -or $candidateTitle -like '*MyTunnelApp validation*') {
        $nextWindow = $candidateWindow
        break
      }
    }
    if ($null -ne $nextWindow) {
      break
    }

    $currentPreregWindow = Find-MyTunnelUiWindow -TitlePatterns @('*MyTunnelApp preregistration check*')
    if ($null -ne $currentPreregWindow) {
      $preregAdvanced = Invoke-MyTunnelUiButtonIfPresent -Window $currentPreregWindow -Names @('Next')
      if (-not $preregAdvanced) {
        $preregAdvanced = Invoke-MyTunnelUiProcessKeys -ProcessId $process.Id -Keys '{ENTER}'
      }
      if ($preregAdvanced) {
        Write-MyTunnelProgress 'MYTUNNEL_GUI_PROGRESS phase=prereg-next-clicked'
        Start-Sleep -Seconds 5
        continue
      }
    }

    Start-Sleep -Seconds 2
  }
  if ($null -eq $nextWindow) {
    throw 'timed out waiting for window title matching: *MyTunnelApp enrollment secret*, *MyTunnelApp validation*'
  }
  $nextSnapshot = Get-MyTunnelUiSnapshot -Window $nextWindow
  if (([string]$nextSnapshot.title -like '*validation*') -or (Test-MyTunnelUiSnapshotMatchesPatterns -Snapshot $nextSnapshot -Patterns @('*validation*'))) {
    $validationSnapshot = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'validation-dialog' -Window $nextWindow
    throw "GUI prereg-check did not advance to the enrollment secret dialog: $(ConvertTo-MyTunnelCompactText -Value ($validationSnapshot.texts -join ' | ') -MaxLength 600)"
  }

  $preregCheck = [ordered]@{
    endpoint            = $preregCheckEndpoint
    result              = 'ready'
    source              = 'gui-dialog-transition'
    expected_device_id  = $ExpectedDeviceId
    current_device_id   = $preregCurrentDeviceId
    probe_path          = $DeviceIdProbePath
  }

  $secretWindow = $nextWindow
  Wait-MyTunnelUiWindowEditCount -Window $secretWindow -MinEditCount 1 -TimeoutSeconds 30 | Out-Null
  $secretSnapshotBefore = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'enrollment-secret-before-fill' -Window $secretWindow
  if ($secretSnapshotBefore.edits.Count -ge 1) {
    try {
      Set-MyTunnelUiEditValueByPatterns -Window $secretWindow -Patterns @('*EnrollmentSecretEdit*', '*ENROLLMENT_SECRET*') -FallbackIndex 0 -Value $EnrollmentSecret
    } catch {
    }
  }
  $null = Invoke-MyTunnelUiProcessKeys -ProcessId $process.Id -Keys '{TAB}'
  Start-Sleep -Milliseconds 300
  $secretSnapshotAfter = Add-MyTunnelGuiEvidence -DialogLog $guiLog -Stage 'enrollment-secret-filled' -Window $secretWindow

  $installAdvanced = Invoke-MyTunnelUiButtonIfPresent -Window $secretWindow -Names @('Install')
  if (-not $installAdvanced) {
    $installAdvanced = Invoke-MyTunnelUiProcessKeys -ProcessId $process.Id -Keys '{ENTER}'
  }
  if (-not $installAdvanced) {
    throw 'enrollment secret dialog did not accept Enter on the default action'
  }
  Write-MyTunnelProgress 'MYTUNNEL_GUI_PROGRESS phase=install-clicked'

  $uiDeadline = (Get-Date).AddSeconds([Math]::Max($WaitSeconds, 0))
  $finishTitle = $null
  while ((Get-Date) -lt $uiDeadline) {
    if ($process.HasExited) {
      break
    }

    $snapshot = Get-MyTunnelUiProcessSnapshot -ProcessId $process.Id
    if ($snapshot.buttons.Count -eq 0 -and $snapshot.edits.Count -eq 0 -and $snapshot.texts.Count -eq 0) {
      Start-Sleep -Seconds 2
      continue
    }

    $title = [string]$snapshot.title
    if (($title -like '*validation*') -or (Test-MyTunnelUiSnapshotMatchesPatterns -Snapshot $snapshot -Patterns @('*validation*'))) {
      $validationSnapshot = Add-MyTunnelGuiProcessEvidence -DialogLog $guiLog -Stage 'validation-dialog' -ProcessId $process.Id
      throw "GUI install surfaced a validation dialog after Install: $(ConvertTo-MyTunnelCompactText -Value ($validationSnapshot.texts -join ' | ') -MaxLength 600)"
    }

    if (Test-MyTunnelUiSnapshotMatchesPatterns -Snapshot $snapshot -Patterns @('*Are you sure you want to cancel*')) {
      if (Invoke-MyTunnelUiProcessButtonIfPresent -ProcessId $process.Id -Names @('No')) {
        Add-MyTunnelGuiProcessEvidence -DialogLog $guiLog -Stage 'cancel-dismissed' -ProcessId $process.Id | Out-Null
        Start-Sleep -Seconds 2
        continue
      }
      throw 'GUI surfaced an unexpected cancellation confirmation'
    }

    $advanced = $false
    if (Select-MyTunnelUiProcessAcceptanceControl -ProcessId $process.Id) {
      Add-MyTunnelGuiProcessEvidence -DialogLog $guiLog -Stage 'post-custom-acceptance' -ProcessId $process.Id | Out-Null
      $advanced = $true
    }
    if (Invoke-MyTunnelUiProcessButtonIfPresent -ProcessId $process.Id -Names @('Next')) {
      Add-MyTunnelGuiProcessEvidence -DialogLog $guiLog -Stage 'post-custom-next' -ProcessId $process.Id | Out-Null
      $advanced = $true
    } elseif (Invoke-MyTunnelUiProcessButtonIfPresent -ProcessId $process.Id -Names @('Install')) {
      Add-MyTunnelGuiProcessEvidence -DialogLog $guiLog -Stage 'post-secret-install' -ProcessId $process.Id | Out-Null
      $advanced = $true
    } elseif (Invoke-MyTunnelUiProcessButtonIfPresent -ProcessId $process.Id -Names @('Finish')) {
      $finishTitle = $title
      Add-MyTunnelGuiProcessEvidence -DialogLog $guiLog -Stage 'finish-dialog' -ProcessId $process.Id | Out-Null
      $advanced = $true
    }
    if ($advanced) {
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
    page1_device_id_fallback_used    = $page1DeviceIdFallbackUsed
    prereg_device_id_fallback_used   = $preregDeviceIdFallbackUsed
    finish_dialog_title              = $finishTitle
    msi_verbose_log_path             = $verboseLogPath
    step3_texts                      = @($secretSnapshotAfter.texts)
  }

  $summary
}
