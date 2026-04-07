$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Set-CopilotTls12 {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  } catch {
    Write-Warning "Unable to force TLS 1.2: $($_.Exception.Message)"
  }
}

function Get-CopilotChromePath {
  $candidates = @(
    (Join-Path ${env:ProgramFiles} "Google\Chrome\Application\chrome.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe")
  )
  foreach ($candidate in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  return $null
}

function Get-CopilotEdgePath {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe"),
    (Join-Path ${env:ProgramFiles} "Microsoft\Edge\Application\msedge.exe")
  )
  foreach ($candidate in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  return $null
}

function Get-CopilotBrowserPath {
  $browserPath = Get-CopilotChromePath
  if ($null -ne $browserPath) {
    return $browserPath
  }

  $browserPath = Get-CopilotEdgePath
  if ($null -ne $browserPath) {
    return $browserPath
  }

  return $null
}

function Test-CopilotInstalledProduct {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DisplayNamePattern
  )

  $uninstallRoots = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )

  foreach ($root in $uninstallRoots) {
    $product = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
      Where-Object {
        $_.PSObject.Properties.Match("DisplayName").Count -gt 0 -and
        $_.DisplayName -like $DisplayNamePattern
      } |
      Select-Object -First 1
    if ($null -ne $product) {
      return $true
    }
  }

  return $false
}

function Invoke-CopilotDownloadFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath
  )

  $parent = Split-Path -Parent $DestinationPath
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $DestinationPath
}

function Install-CopilotMsiPackage {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $true)]
    [string]$DisplayName
  )

  $arguments = @("/i", $InstallerPath, "/qn", "/norestart")
  $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
  if ($process.ExitCode -notin @(0, 1641, 3010)) {
    throw "$DisplayName installation failed with exit code $($process.ExitCode)"
  }
}

function New-CopilotChromeRemoteDesktopShortcut {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SupportUrl,

    [Parameter(Mandatory = $true)]
    [string]$BrowserPath
  )

  $desktopDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
  $shortcutPath = Join-Path $desktopDir "Chrome Remote Desktop Support.url"
  $shortcutContent = @(
    "[InternetShortcut]",
    "URL=$SupportUrl",
    "IconFile=$BrowserPath",
    "IconIndex=0"
  )
  Set-Content -Path $shortcutPath -Encoding ASCII -Value $shortcutContent
  return $shortcutPath
}

function New-CopilotChromeRemoteDesktopInstructions {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SupportUrl
  )

  $desktopDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory)
  $instructionsPath = Join-Path $desktopDir "Chrome Remote Desktop Support Instructions.txt"
  $instructions = @(
    "Chrome Remote Desktop one-time support codes cannot be generated headlessly.",
    "",
    "Next steps:",
    "1. Sign in to the browser with the Google account that will host the remote support session.",
    "2. Open $SupportUrl",
    "3. In 'Get Support', click 'Generate Code'.",
    "4. Copy the one-time access code into the browser that will connect to this VM."
  )
  Set-Content -Path $instructionsPath -Encoding ASCII -Value $instructions
  return $instructionsPath
}

function New-CopilotChromeRemoteDesktopStartupLauncher {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SupportUrl
  )

  $startupDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonStartup)
  $launcherPath = Join-Path $startupDir "launch-chrome-remote-desktop-support.cmd"
  $launcherLines = @(
    "@echo off",
    "setlocal",
    "set ""BROWSER=%ProgramFiles%\Google\Chrome\Application\chrome.exe""",
    "if not exist ""%BROWSER%"" set ""BROWSER=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe""",
    "if not exist ""%BROWSER%"" set ""BROWSER=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe""",
    "if not exist ""%BROWSER%"" set ""BROWSER=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe""",
    ("if exist ""%BROWSER%"" start """" ""%BROWSER%"" --new-window ""{0}""" -f $SupportUrl),
    "del ""%~f0"""
  )
  Set-Content -Path $launcherPath -Encoding ASCII -Value $launcherLines
  return $launcherPath
}

function Invoke-CopilotChromeRemoteDesktopSetup {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ActionId,

    [Parameter(Mandatory = $true)]
    [string]$ChromeMsiUrl,

    [Parameter(Mandatory = $true)]
    [string]$ChromeRemoteDesktopHostMsiUrl,

    [Parameter(Mandatory = $true)]
    [string]$SupportUrl
  )

  Set-CopilotTls12

  $workDir = "C:\Users\Public\ChromeRemoteDesktopSetup"
  $downloadsDir = Join-Path $workDir "downloads"
  $chromeInstallerPath = Join-Path $downloadsDir "GoogleChromeStandaloneEnterprise64.msi"
  $crdInstallerPath = Join-Path $downloadsDir "chromeremotedesktophost.msi"

  New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null

  Write-Host ("COPILOT_CRD_SETUP_START id={0} support_url={1}" -f $ActionId, $SupportUrl)

  $browserPath = Get-CopilotBrowserPath
  if ($null -eq $browserPath) {
    Write-Host ("COPILOT_CRD_SETUP_PROGRESS id={0} phase=download-chrome url={1}" -f $ActionId, $ChromeMsiUrl)
    Invoke-CopilotDownloadFile -Url $ChromeMsiUrl -DestinationPath $chromeInstallerPath
    Write-Host ("COPILOT_CRD_SETUP_PROGRESS id={0} phase=install-chrome path={1}" -f $ActionId, $chromeInstallerPath)
    Install-CopilotMsiPackage -InstallerPath $chromeInstallerPath -DisplayName "Google Chrome"
    $browserPath = Get-CopilotBrowserPath
    if ($null -eq $browserPath) {
      throw "No supported browser was found after Google Chrome installation."
    }
  } else {
    Write-Host ("COPILOT_CRD_SETUP_PROGRESS id={0} phase=browser-already-installed path={1}" -f $ActionId, $browserPath)
  }

  if (-not (Test-CopilotInstalledProduct -DisplayNamePattern "Chrome Remote Desktop Host*")) {
    Write-Host ("COPILOT_CRD_SETUP_PROGRESS id={0} phase=download-crd-host url={1}" -f $ActionId, $ChromeRemoteDesktopHostMsiUrl)
    Invoke-CopilotDownloadFile -Url $ChromeRemoteDesktopHostMsiUrl -DestinationPath $crdInstallerPath
    Write-Host ("COPILOT_CRD_SETUP_PROGRESS id={0} phase=install-crd-host path={1}" -f $ActionId, $crdInstallerPath)
    Install-CopilotMsiPackage -InstallerPath $crdInstallerPath -DisplayName "Chrome Remote Desktop Host"
    if (-not (Test-CopilotInstalledProduct -DisplayNamePattern "Chrome Remote Desktop Host*")) {
      throw "Chrome Remote Desktop Host was not found after installation."
    }
  } else {
    Write-Host ("COPILOT_CRD_SETUP_PROGRESS id={0} phase=crd-host-already-installed" -f $ActionId)
  }

  $shortcutPath = New-CopilotChromeRemoteDesktopShortcut -SupportUrl $SupportUrl -BrowserPath $browserPath
  $instructionsPath = New-CopilotChromeRemoteDesktopInstructions -SupportUrl $SupportUrl
  $launcherPath = New-CopilotChromeRemoteDesktopStartupLauncher -SupportUrl $SupportUrl

  Write-Host ("COPILOT_CRD_SETUP_NOTE id={0} message=Chrome Remote Desktop one-time support codes still require interactive browser sign-in and a manual Generate Code click on the VM." -f $ActionId)
  Write-Host ("COPILOT_CRD_SETUP_DONE id={0} browser_path={1} shortcut={2} launcher={3} instructions={4}" -f $ActionId, $browserPath, $shortcutPath, $launcherPath, $instructionsPath)
}
