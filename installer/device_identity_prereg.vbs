Option Explicit

Const CustomActionSuccess = 1
Const PowerShellProbeCommand = "$ErrorActionPreference='Stop'; $ekInfo = Get-TpmEndorsementKeyInfo -HashAlgorithm Sha256; if ($null -eq $ekInfo -or $null -eq $ekInfo.PublicKey -or $null -eq $ekInfo.PublicKey.RawData -or $ekInfo.PublicKey.RawData.Length -eq 0) { throw 'TPM endorsement key public key is unavailable' }; $sha = [System.Security.Cryptography.SHA256]::Create(); try { $hash = $sha.ComputeHash($ekInfo.PublicKey.RawData) } finally { $sha.Dispose() }; $deviceId = (-join ($hash | ForEach-Object { $_.ToString('x2') })); Write-Output $deviceId"

Function ProbeCurrentDeviceIdentity()
  On Error Resume Next

  Dim deviceId
  deviceId = ResolveCurrentDeviceId()
  If Err.Number <> 0 Then
    Session.Property("CURRENT_DEVICE_ID") = ""
    Session.Property("PROBE_STATUS_MESSAGE") = "Failed to read the canonical TPM device identity on this machine: " & Err.Description
    Session.Property("PREREG_CHECK_RESULT") = ""
    Session.Property("PREREG_STATUS_MESSAGE") = "Fix the TPM probe failure before continuing."
    Session.Log "MyTunnel MSI: device identity probe failed: " & Err.Description
    Err.Clear
    ProbeCurrentDeviceIdentity = CustomActionSuccess
    Exit Function
  End If

  Session.Property("CURRENT_DEVICE_ID") = deviceId
  If TrimValue(Session.Property("EXPECTED_DEVICE_ID")) = "" Then
    Session.Property("EXPECTED_DEVICE_ID") = deviceId
  End If
  Session.Property("PROBE_STATUS_MESSAGE") = "Canonical TPM device identity loaded. Copy CURRENT_DEVICE_ID, preregister it on the server, then continue to the preregistration check page."
  If TrimValue(Session.Property("PREREG_STATUS_MESSAGE")) = "" Then
    Session.Property("PREREG_STATUS_MESSAGE") = "Enter SERVER_URL and CLIENT_UID, then click Check preregistration."
  End If

  ProbeCurrentDeviceIdentity = CustomActionSuccess
End Function

Function CheckPreregistration()
  On Error Resume Next

  PerformPreregistrationCheck
  If Err.Number <> 0 Then
    Session.Property("PREREG_CHECK_RESULT") = "request_failed"
    Session.Property("PREREG_STATUS_MESSAGE") = "Preregistration check failed: " & Err.Description
    Session.Log "MyTunnel MSI: preregistration check failed: " & Err.Description
    Err.Clear
  End If

  CheckPreregistration = CustomActionSuccess
End Function

Function CleanupIssuanceArtifacts()
  Dim cleanupData
  Dim clientUid
  Dim expectedDeviceId
  Dim cleanupSummary

  AppendUninstallDebugLog "CleanupIssuanceArtifacts entry"
  On Error Resume Next

  cleanupData = Session.Property("CustomActionData")
  clientUid = ParseCustomActionDataValue(cleanupData, "CLIENT_UID")
  expectedDeviceId = ParseCustomActionDataValue(cleanupData, "EXPECTED_DEVICE_ID")

  AppendUninstallDebugLog "CleanupIssuanceArtifacts data client_uid=" & clientUid & " expected_device_id=" & expectedDeviceId
  Session.Log "MyTunnel MSI: uninstall cleanup starting; client_uid=" & clientUid & "; expected_device_id=" & expectedDeviceId
  cleanupSummary = ExecuteUninstallCleanup(clientUid, expectedDeviceId)
  If Err.Number <> 0 Then
    AppendUninstallDebugLog "CleanupIssuanceArtifacts failure: " & Err.Description
    Session.Log "MyTunnel MSI: uninstall cleanup failed; some MyTunnel-managed artifacts may remain: " & Err.Description
    Err.Clear
    CleanupIssuanceArtifacts = CustomActionSuccess
    Exit Function
  End If
  AppendUninstallDebugLog "CleanupIssuanceArtifacts success: " & cleanupSummary
  Session.Log "MyTunnel MSI: uninstall cleanup finished: " & cleanupSummary

  CleanupIssuanceArtifacts = CustomActionSuccess
End Function

Sub PerformPreregistrationCheck()
  Dim currentDeviceId
  Dim expectedDeviceId
  Dim serverUrl
  Dim clientUid
  Dim endpoint
  Dim result

  currentDeviceId = ResolveCurrentDeviceId()
  Session.Property("CURRENT_DEVICE_ID") = currentDeviceId
  If TrimValue(Session.Property("EXPECTED_DEVICE_ID")) = "" Then
    Session.Property("EXPECTED_DEVICE_ID") = currentDeviceId
  End If

  expectedDeviceId = LCase(TrimValue(Session.Property("EXPECTED_DEVICE_ID")))
  If expectedDeviceId <> "" And expectedDeviceId <> LCase(currentDeviceId) Then
    Session.Property("PREREG_CHECK_RESULT") = "device_id_mismatch"
    Session.Property("PREREG_STATUS_MESSAGE") = "This machine's current TPM identity does not match EXPECTED_DEVICE_ID. Re-preregister the device, issue a new initial secret, and retry."
    Exit Sub
  End If

  serverUrl = TrimValue(Session.Property("SERVER_URL"))
  clientUid = TrimValue(Session.Property("CLIENT_UID"))

  If serverUrl = "" Or clientUid = "" Then
    Session.Property("PREREG_CHECK_RESULT") = ""
    Session.Property("PREREG_STATUS_MESSAGE") = "SERVER_URL and CLIENT_UID are required before the preregistration check can run."
    Exit Sub
  End If

  If InStr(serverUrl, "://") = 0 Then
    Session.Property("PREREG_CHECK_RESULT") = ""
    Session.Property("PREREG_STATUS_MESSAGE") = "SERVER_URL must include a scheme such as https://scep.example.com/scep."
    Exit Sub
  End If

  If LCase(serverUrl) = "https://example.invalid/scep" Then
    Session.Property("PREREG_CHECK_RESULT") = ""
    Session.Property("PREREG_STATUS_MESSAGE") = "Replace the example.invalid placeholder with the real SCEP endpoint before checking preregistration."
    Exit Sub
  End If

  endpoint = BuildPreregCheckEndpoint(serverUrl)
  result = SendPreregCheck(endpoint, clientUid, currentDeviceId)
  Session.Property("PREREG_CHECK_RESULT") = result

  Select Case result
    Case "ready"
      Session.Property("PREREG_STATUS_MESSAGE") = "Server prereg-check returned ready. Continue to enter ENROLLMENT_SECRET."
    Case "client_not_found"
      Session.Property("PREREG_STATUS_MESSAGE") = "Server prereg-check returned client_not_found. Confirm CLIENT_UID preregistration first."
    Case "device_id_mismatch"
      Session.Property("PREREG_STATUS_MESSAGE") = "Server prereg-check returned device_id_mismatch. The server record does not match this machine's canonical TPM identity."
    Case "not_issuable_yet"
      Session.Property("PREREG_STATUS_MESSAGE") = "Server prereg-check returned not_issuable_yet. Wait for the administrator to issue the initial ENROLLMENT_SECRET, then retry."
    Case Else
      Session.Property("PREREG_CHECK_RESULT") = "request_failed"
      Session.Property("PREREG_STATUS_MESSAGE") = "Server prereg-check returned an unexpected result: " & result
  End Select
End Sub

Function ResolveCurrentDeviceId()
  Dim helperPath
  Dim helperFailure

  helperPath = ResolveDeviceIdentityProbePath()
  helperFailure = ""

  If helperPath <> "" Then
    On Error Resume Next
    ResolveCurrentDeviceId = ResolveCurrentDeviceIdViaHelper(helperPath)
    If Err.Number = 0 Then
      Exit Function
    End If
    helperFailure = Err.Description
    Session.Log "MyTunnel MSI: helper-backed device identity probe failed at " & helperPath & ": " & helperFailure
    Err.Clear
  End If

  On Error Resume Next
  ResolveCurrentDeviceId = ResolveCurrentDeviceIdViaPowerShell()
  If Err.Number <> 0 And helperFailure <> "" Then
    Err.Raise vbObjectError + 120, "ResolveCurrentDeviceId", "helper-backed probe failed: " & helperFailure & "; PowerShell fallback failed: " & Err.Description
  End If
End Function

Function ExecuteUninstallCleanup(clientUid, expectedDeviceId)
  Dim fso
  Dim shell
  Dim commandLine
  Dim resultText
  Dim exitCode
  Dim scriptText
  Dim tempDir
  Dim tempPath
  Dim tempBaseName
  Dim tempFile
  Dim resultPath

  Set fso = CreateObject("Scripting.FileSystemObject")
  Set shell = CreateObject("WScript.Shell")
  tempDir = shell.ExpandEnvironmentStrings("%TEMP%")
  tempBaseName = fso.GetTempName()
  If LCase(Right(tempBaseName, 4)) = ".tmp" Then
    tempBaseName = Left(tempBaseName, Len(tempBaseName) - 4)
  End If
  tempPath = fso.BuildPath(tempDir, tempBaseName & ".ps1")
  resultPath = fso.BuildPath(tempDir, tempBaseName & ".result.json")
  scriptText = BuildUninstallCleanupPowerShell(clientUid, expectedDeviceId, resultPath)
  Set tempFile = fso.CreateTextFile(tempPath, True, False)
  tempFile.Write scriptText
  tempFile.Close

  AppendUninstallDebugLog "ExecuteUninstallCleanup launching script " & tempPath
  commandLine = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & QuoteForCommand(tempPath)
  exitCode = shell.Run(commandLine, 0, True)

  resultText = ""
  If fso.FileExists(resultPath) Then
    resultText = TrimValue(fso.OpenTextFile(resultPath, 1, False).ReadAll())
  End If
  AppendUninstallDebugLog "ExecuteUninstallCleanup exit_code=" & exitCode & " result=" & resultText

  If exitCode <> 0 Then
    If resultText = "" Then
      resultText = "cleanup subprocess returned exit code " & exitCode
    End If
    Err.Raise vbObjectError + 140, "ExecuteUninstallCleanup", "certificate issuance cleanup failed: " & resultText
  End If

  On Error Resume Next
  If tempPath <> "" And fso.FileExists(tempPath) Then
    fso.DeleteFile tempPath, True
  End If
  If resultPath <> "" And fso.FileExists(resultPath) Then
    fso.DeleteFile resultPath, True
  End If
  On Error GoTo 0

  If resultText = "" Then
    ExecuteUninstallCleanup = "{""status"":""ok""}"
  Else
    ExecuteUninstallCleanup = resultText
  End If
End Function

Function BuildUninstallCleanupPowerShell(clientUid, expectedDeviceId, resultPath)
  Dim scriptText

  scriptText = ""
  scriptText = scriptText & "$ErrorActionPreference = 'Stop'" & vbCrLf
  scriptText = scriptText & "$resultPath = '" & EscapeForPowerShellSingleQuoted(resultPath) & "'" & vbCrLf
  scriptText = scriptText & "function Write-MyTunnelCleanupResult {" & vbCrLf
  scriptText = scriptText & "  param([Parameter(Mandatory = $true)][string]$Json)" & vbCrLf
  scriptText = scriptText & "  [System.IO.File]::WriteAllText($resultPath, $Json, [System.Text.Encoding]::ASCII)" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "trap {" & vbCrLf
  scriptText = scriptText & "  try {" & vbCrLf
  scriptText = scriptText & "    Write-MyTunnelCleanupResult ((@{status='error'; error=$_.Exception.Message} | ConvertTo-Json -Compress))" & vbCrLf
  scriptText = scriptText & "  } catch {}" & vbCrLf
  scriptText = scriptText & "  exit 1" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "function ConvertTo-MyTunnelSafeComponent {" & vbCrLf
  scriptText = scriptText & "  param([AllowNull()][string]$Value)" & vbCrLf
  scriptText = scriptText & "  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }" & vbCrLf
  scriptText = scriptText & "  $builder = New-Object System.Text.StringBuilder" & vbCrLf
  scriptText = scriptText & "  foreach ($ch in $Value.ToCharArray()) {" & vbCrLf
  scriptText = scriptText & "    if ((($ch -ge 'a') -and ($ch -le 'z')) -or (($ch -ge 'A') -and ($ch -le 'Z')) -or (($ch -ge '0') -and ($ch -le '9')) -or ($ch -eq '-') -or ($ch -eq '_')) {" & vbCrLf
  scriptText = scriptText & "      [void]$builder.Append($ch)" & vbCrLf
  scriptText = scriptText & "    } else {" & vbCrLf
  scriptText = scriptText & "      [void]$builder.Append('-')" & vbCrLf
  scriptText = scriptText & "    }" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "  $builder.ToString()" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "function Add-MyTunnelUniqueValue {" & vbCrLf
  scriptText = scriptText & "  param([hashtable]$Map, [AllowNull()][string]$Value)" & vbCrLf
  scriptText = scriptText & "  if (-not [string]::IsNullOrWhiteSpace($Value)) { $Map[$Value] = $true }" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "function ConvertFrom-MyTunnelPemText {" & vbCrLf
  scriptText = scriptText & "  param([Parameter(Mandatory = $true)][string]$PemText)" & vbCrLf
  scriptText = scriptText & "  $match = [regex]::Match($PemText, '-----BEGIN CERTIFICATE-----\s*(?<body>[A-Za-z0-9+/=\r\n]+?)\s*-----END CERTIFICATE-----')" & vbCrLf
  scriptText = scriptText & "  if (-not $match.Success) { throw 'PEM data does not contain a certificate body' }" & vbCrLf
  scriptText = scriptText & "  $body = (($match.Groups['body'].Value -split ""`r?`n"") | Where-Object { $_ }) -join ''" & vbCrLf
  scriptText = scriptText & "  if (-not $body) { throw 'PEM data does not contain a certificate body' }" & vbCrLf
  scriptText = scriptText & "  $bytes = [Convert]::FromBase64String($body)" & vbCrLf
  scriptText = scriptText & "  New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes)" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "function Get-MyTunnelCertificateKeyName {" & vbCrLf
  scriptText = scriptText & "  param([Parameter(Mandatory = $true)]$Cert)" & vbCrLf
  scriptText = scriptText & "  try {" & vbCrLf
  scriptText = scriptText & "    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Cert)" & vbCrLf
  scriptText = scriptText & "  } catch {" & vbCrLf
  scriptText = scriptText & "    return $null" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "  if ($null -eq $rsa) { return $null }" & vbCrLf
  scriptText = scriptText & "  try {" & vbCrLf
  scriptText = scriptText & "    if ($rsa -is [System.Security.Cryptography.RSACng]) {" & vbCrLf
  scriptText = scriptText & "      return $rsa.Key.KeyName" & vbCrLf
  scriptText = scriptText & "    }" & vbCrLf
  scriptText = scriptText & "    return $null" & vbCrLf
  scriptText = scriptText & "  } finally {" & vbCrLf
  scriptText = scriptText & "    if ($rsa -is [System.IDisposable]) { $rsa.Dispose() }" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "function Get-MyTunnelRunningProcesses {" & vbCrLf
  scriptText = scriptText & "  param([Parameter(Mandatory = $true)][string]$InstallDir)" & vbCrLf
  scriptText = scriptText & "  $matches = New-Object System.Collections.ArrayList" & vbCrLf
  scriptText = scriptText & "  foreach ($processName in @('service', 'scepclient')) {" & vbCrLf
  scriptText = scriptText & "    Get-Process -Name $processName -ErrorAction SilentlyContinue | ForEach-Object {" & vbCrLf
  scriptText = scriptText & "      $path = $null" & vbCrLf
  scriptText = scriptText & "      try { $path = $_.Path } catch { $path = $null }" & vbCrLf
  scriptText = scriptText & "      if ([string]::IsNullOrWhiteSpace($path) -or $path -like (Join-Path $InstallDir '*')) {" & vbCrLf
  scriptText = scriptText & "        [void]$matches.Add($_)" & vbCrLf
  scriptText = scriptText & "      }" & vbCrLf
  scriptText = scriptText & "    }" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "  @($matches | Sort-Object Id -Unique)" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "$clientUid = '" & EscapeForPowerShellSingleQuoted(clientUid) & "'" & vbCrLf
  scriptText = scriptText & "$expectedDeviceId = '" & EscapeForPowerShellSingleQuoted(expectedDeviceId) & "'" & vbCrLf
  scriptText = scriptText & "$installDir = 'C:\Program Files\MyTunnelApp'" & vbCrLf
  scriptText = scriptText & "$dataRoot = 'C:\ProgramData\MyTunnelApp'" & vbCrLf
  scriptText = scriptText & "$managedRoot = Join-Path $dataRoot 'managed'" & vbCrLf
  scriptText = scriptText & "$logsDir = Join-Path $dataRoot 'logs'" & vbCrLf
  scriptText = scriptText & "$eventLogSourceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\MyTunnelService'" & vbCrLf
  scriptText = scriptText & "$keyNames = @{}" & vbCrLf
  scriptText = scriptText & "$thumbprints = @{}" & vbCrLf
  scriptText = scriptText & "$removedThumbprints = New-Object System.Collections.ArrayList" & vbCrLf
  scriptText = scriptText & "$removedKeys = New-Object System.Collections.ArrayList" & vbCrLf
  scriptText = scriptText & "$removedPaths = New-Object System.Collections.ArrayList" & vbCrLf
  scriptText = scriptText & "$cleanupErrors = New-Object System.Collections.ArrayList" & vbCrLf
  scriptText = scriptText & "$waitDeadline = [DateTime]::UtcNow.AddSeconds(15)" & vbCrLf
  scriptText = scriptText & "do {" & vbCrLf
  scriptText = scriptText & "  $running = @(Get-MyTunnelRunningProcesses -InstallDir $installDir)" & vbCrLf
  scriptText = scriptText & "  if ($running.Count -eq 0) { break }" & vbCrLf
  scriptText = scriptText & "  Start-Sleep -Seconds 1" & vbCrLf
  scriptText = scriptText & "} while ([DateTime]::UtcNow -lt $waitDeadline)" & vbCrLf
  scriptText = scriptText & "foreach ($process in @(Get-MyTunnelRunningProcesses -InstallDir $installDir)) {" & vbCrLf
  scriptText = scriptText & "  try {" & vbCrLf
  scriptText = scriptText & "    Stop-Process -Id $process.Id -Force -ErrorAction Stop" & vbCrLf
  scriptText = scriptText & "  } catch {" & vbCrLf
  scriptText = scriptText & "    [void]$cleanupErrors.Add(""failed to stop lingering MyTunnel process $($process.ProcessName) pid=$($process.Id): $($_.Exception.Message)"")" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "Start-Sleep -Seconds 1" & vbCrLf
  scriptText = scriptText & "if (-not [string]::IsNullOrWhiteSpace($clientUid) -and -not [string]::IsNullOrWhiteSpace($expectedDeviceId)) {" & vbCrLf
  scriptText = scriptText & "  Add-MyTunnelUniqueValue -Map $keyNames -Value ((ConvertTo-MyTunnelSafeComponent $clientUid) + '-' + (ConvertTo-MyTunnelSafeComponent $expectedDeviceId))" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "if (Test-Path -LiteralPath $managedRoot) {" & vbCrLf
  scriptText = scriptText & "  try {" & vbCrLf
  scriptText = scriptText & "    Get-ChildItem -LiteralPath $managedRoot -Directory -Force | ForEach-Object {" & vbCrLf
  scriptText = scriptText & "      Add-MyTunnelUniqueValue -Map $keyNames -Value $_.Name" & vbCrLf
  scriptText = scriptText & "      $certPath = Join-Path $_.FullName 'cert.pem'" & vbCrLf
  scriptText = scriptText & "      if (Test-Path -LiteralPath $certPath) {" & vbCrLf
  scriptText = scriptText & "        try {" & vbCrLf
  scriptText = scriptText & "          $cert = ConvertFrom-MyTunnelPemText -PemText (Get-Content -LiteralPath $certPath -Raw)" & vbCrLf
  scriptText = scriptText & "          Add-MyTunnelUniqueValue -Map $thumbprints -Value $cert.Thumbprint" & vbCrLf
  scriptText = scriptText & "        } catch {" & vbCrLf
  scriptText = scriptText & "          [void]$cleanupErrors.Add(""failed to parse managed certificate cache $($certPath): $($_.Exception.Message)"")" & vbCrLf
  scriptText = scriptText & "        }" & vbCrLf
  scriptText = scriptText & "      }" & vbCrLf
  scriptText = scriptText & "    }" & vbCrLf
  scriptText = scriptText & "  } catch {" & vbCrLf
  scriptText = scriptText & "    [void]$cleanupErrors.Add(""failed to enumerate managed cache root $($managedRoot): $($_.Exception.Message)"")" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "$storeMatches = @()" & vbCrLf
  scriptText = scriptText & "try {" & vbCrLf
  scriptText = scriptText & "  $storeMatches = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object {" & vbCrLf
  scriptText = scriptText & "    $certKeyName = Get-MyTunnelCertificateKeyName -Cert $_" & vbCrLf
  scriptText = scriptText & "    $thumbprints.ContainsKey([string]$_.Thumbprint) -or (-not [string]::IsNullOrWhiteSpace($certKeyName) -and $keyNames.ContainsKey($certKeyName))" & vbCrLf
  scriptText = scriptText & "  })" & vbCrLf
  scriptText = scriptText & "} catch {" & vbCrLf
  scriptText = scriptText & "  [void]$cleanupErrors.Add(""failed to enumerate LocalMachine\My: $($_.Exception.Message)"")" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "$storeMatches = @($storeMatches | Sort-Object Thumbprint -Unique)" & vbCrLf
  scriptText = scriptText & "foreach ($cert in $storeMatches) {" & vbCrLf
  scriptText = scriptText & "  try {" & vbCrLf
  scriptText = scriptText & "    Remove-Item -Path ('Cert:\LocalMachine\My\' + $cert.Thumbprint) -Force -ErrorAction Stop" & vbCrLf
  scriptText = scriptText & "    [void]$removedThumbprints.Add($cert.Thumbprint)" & vbCrLf
  scriptText = scriptText & "  } catch {" & vbCrLf
  scriptText = scriptText & "    [void]$cleanupErrors.Add(""failed to delete machine certificate $($cert.Thumbprint): $($_.Exception.Message)"")" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "try {" & vbCrLf
  scriptText = scriptText & "  $provider = New-Object System.Security.Cryptography.CngProvider('Microsoft Platform Crypto Provider')" & vbCrLf
  scriptText = scriptText & "  foreach ($keyName in ($keyNames.Keys | Sort-Object)) {" & vbCrLf
  scriptText = scriptText & "    if ([string]::IsNullOrWhiteSpace($keyName)) { continue }" & vbCrLf
  scriptText = scriptText & "    try {" & vbCrLf
  scriptText = scriptText & "      if (-not [System.Security.Cryptography.CngKey]::Exists($keyName, $provider, [System.Security.Cryptography.CngKeyOpenOptions]::MachineKey)) {" & vbCrLf
  scriptText = scriptText & "        continue" & vbCrLf
  scriptText = scriptText & "      }" & vbCrLf
  scriptText = scriptText & "      $key = [System.Security.Cryptography.CngKey]::Open($keyName, $provider, [System.Security.Cryptography.CngKeyOpenOptions]::MachineKey)" & vbCrLf
  scriptText = scriptText & "      try {" & vbCrLf
  scriptText = scriptText & "        $key.Delete()" & vbCrLf
  scriptText = scriptText & "      } finally {" & vbCrLf
  scriptText = scriptText & "        $key.Dispose()" & vbCrLf
  scriptText = scriptText & "      }" & vbCrLf
  scriptText = scriptText & "      [void]$removedKeys.Add($keyName)" & vbCrLf
  scriptText = scriptText & "    } catch {" & vbCrLf
  scriptText = scriptText & "      [void]$cleanupErrors.Add(""failed to delete TPM key $($keyName): $($_.Exception.Message)"")" & vbCrLf
  scriptText = scriptText & "    }" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "} catch {" & vbCrLf
  scriptText = scriptText & "  [void]$cleanupErrors.Add(""failed to initialize Microsoft Platform Crypto Provider cleanup: $($_.Exception.Message)"")" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "if (Test-Path -LiteralPath $managedRoot) {" & vbCrLf
  scriptText = scriptText & "  try {" & vbCrLf
  scriptText = scriptText & "    Remove-Item -LiteralPath $managedRoot -Recurse -Force -ErrorAction Stop" & vbCrLf
  scriptText = scriptText & "    [void]$removedPaths.Add($managedRoot)" & vbCrLf
  scriptText = scriptText & "  } catch {" & vbCrLf
  scriptText = scriptText & "    [void]$cleanupErrors.Add(""failed to delete managed cache root $($managedRoot): $($_.Exception.Message)"")" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "if (Test-Path -LiteralPath $logsDir) {" & vbCrLf
  scriptText = scriptText & "  try {" & vbCrLf
  scriptText = scriptText & "    Remove-Item -LiteralPath $logsDir -Recurse -Force -ErrorAction Stop" & vbCrLf
  scriptText = scriptText & "    [void]$removedPaths.Add($logsDir)" & vbCrLf
  scriptText = scriptText & "  } catch {" & vbCrLf
  scriptText = scriptText & "    [void]$cleanupErrors.Add(""failed to delete log directory $($logsDir): $($_.Exception.Message)"")" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "if (Test-Path -LiteralPath $eventLogSourceKey) {" & vbCrLf
  scriptText = scriptText & "  try {" & vbCrLf
  scriptText = scriptText & "    Remove-Item -LiteralPath $eventLogSourceKey -Recurse -Force -ErrorAction Stop" & vbCrLf
  scriptText = scriptText & "    [void]$removedPaths.Add($eventLogSourceKey)" & vbCrLf
  scriptText = scriptText & "  } catch {" & vbCrLf
  scriptText = scriptText & "    [void]$cleanupErrors.Add(""failed to delete event log source registry key $($eventLogSourceKey): $($_.Exception.Message)"")" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "if (Test-Path -LiteralPath $dataRoot) {" & vbCrLf
  scriptText = scriptText & "  try {" & vbCrLf
  scriptText = scriptText & "    $remainingEntries = @(Get-ChildItem -LiteralPath $dataRoot -Force -ErrorAction Stop)" & vbCrLf
  scriptText = scriptText & "    if ($remainingEntries.Count -eq 0) {" & vbCrLf
  scriptText = scriptText & "      Remove-Item -LiteralPath $dataRoot -Force -ErrorAction Stop" & vbCrLf
  scriptText = scriptText & "      [void]$removedPaths.Add($dataRoot)" & vbCrLf
  scriptText = scriptText & "    }" & vbCrLf
  scriptText = scriptText & "  } catch {" & vbCrLf
  scriptText = scriptText & "    [void]$cleanupErrors.Add(""failed to finalize data root cleanup for $($dataRoot): $($_.Exception.Message)"")" & vbCrLf
  scriptText = scriptText & "  }" & vbCrLf
  scriptText = scriptText & "}" & vbCrLf
  scriptText = scriptText & "Write-MyTunnelCleanupResult ((@{status='ok'; removed_cert_thumbprints=@($removedThumbprints); removed_keys=@($removedKeys); removed_paths=@($removedPaths); cleanup_errors=@($cleanupErrors); data_root_removed=(-not (Test-Path -LiteralPath $dataRoot))} | ConvertTo-Json -Compress))" & vbCrLf

  BuildUninstallCleanupPowerShell = scriptText
End Function

Sub AppendUninstallDebugLog(message)
  On Error Resume Next

  Dim fso
  Dim shell
  Dim stream
  Dim path

  Set fso = CreateObject("Scripting.FileSystemObject")
  Set shell = CreateObject("WScript.Shell")
  path = fso.BuildPath(shell.ExpandEnvironmentStrings("%WINDIR%\Temp"), "MyTunnelApp-uninstall-ca.log")
  Set stream = fso.OpenTextFile(path, 8, True, False)
  stream.WriteLine Now & " " & message
  stream.Close
End Sub

Function ResolveCurrentDeviceIdViaPowerShell()
  Dim shell
  Dim exec
  Dim commandLine
  Dim stdoutText
  Dim stderrText
  Dim exitCode

  Set shell = CreateObject("WScript.Shell")
  commandLine = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command " & QuoteForCommand(PowerShellProbeCommand)
  Set exec = shell.Exec(commandLine)

  stdoutText = TrimValue(exec.StdOut.ReadAll())
  stderrText = TrimValue(exec.StdErr.ReadAll())
  exitCode = exec.ExitCode

  If exitCode <> 0 Then
    If stderrText = "" Then
      stderrText = stdoutText
    End If
    Err.Raise vbObjectError + 100, "ResolveCurrentDeviceId", "PowerShell TPM probe failed: " & stderrText
  End If
  If stdoutText = "" Then
    Err.Raise vbObjectError + 101, "ResolveCurrentDeviceIdViaPowerShell", "PowerShell TPM probe returned an empty device identity"
  End If

  ResolveCurrentDeviceIdViaPowerShell = LCase(stdoutText)
End Function

Function ResolveCurrentDeviceIdViaHelper(probePath)
  Dim shell
  Dim exec
  Dim commandLine
  Dim stdoutText
  Dim stderrText
  Dim exitCode
  Dim deviceId

  Set shell = CreateObject("WScript.Shell")
  commandLine = QuoteForCommand(probePath) & " -json"
  Set exec = shell.Exec(commandLine)

  stdoutText = TrimValue(exec.StdOut.ReadAll())
  stderrText = TrimValue(exec.StdErr.ReadAll())
  exitCode = exec.ExitCode

  If exitCode <> 0 Then
    If stderrText = "" Then
      stderrText = stdoutText
    End If
    Err.Raise vbObjectError + 121, "ResolveCurrentDeviceIdViaHelper", "device-id-probe.exe failed: " & stderrText
  End If
  If stdoutText = "" Then
    Err.Raise vbObjectError + 122, "ResolveCurrentDeviceIdViaHelper", "device-id-probe.exe returned an empty JSON payload"
  End If

  deviceId = ParseJsonStringValue(stdoutText, "expected_device_id")
  If deviceId = "" Then
    Err.Raise vbObjectError + 123, "ResolveCurrentDeviceIdViaHelper", "device-id-probe.exe JSON did not contain expected_device_id: " & stdoutText
  End If

  ResolveCurrentDeviceIdViaHelper = LCase(deviceId)
End Function

Function ResolveDeviceIdentityProbePath()
  Dim fso
  Dim installerPath
  Dim installerDir
  Dim adjacentProbePath
  Dim installedProbePath

  Set fso = CreateObject("Scripting.FileSystemObject")

  installerPath = TrimValue(Session.Property("OriginalDatabase"))
  If installerPath <> "" And fso.FileExists(installerPath) Then
    installerDir = fso.GetParentFolderName(installerPath)
    adjacentProbePath = fso.BuildPath(installerDir, "device-id-probe.exe")
    If fso.FileExists(adjacentProbePath) Then
      ResolveDeviceIdentityProbePath = adjacentProbePath
      Exit Function
    End If
  End If

  installedProbePath = "C:\Program Files\MyTunnelApp\device-id-probe.exe"
  If fso.FileExists(installedProbePath) Then
    ResolveDeviceIdentityProbePath = installedProbePath
    Exit Function
  End If

  ResolveDeviceIdentityProbePath = ""
End Function

Function SendPreregCheck(endpoint, clientUid, deviceId)
  Dim request
  Dim responseText

  Set request = CreateObject("WinHttp.WinHttpRequest.5.1")
  request.Open "POST", endpoint, False
  request.SetRequestHeader "Content-Type", "application/json"
  request.Send "{""client_uid"":""" & JsonEscape(clientUid) & """,""device_id"":""" & JsonEscape(deviceId) & """}"

  If request.Status < 200 Or request.Status >= 300 Then
    responseText = TrimValue(request.ResponseText)
    If responseText = "" Then
      responseText = "HTTP " & CStr(request.Status)
    End If
    Err.Raise vbObjectError + 102, "SendPreregCheck", "HTTP prereg-check failed: " & responseText
  End If

  responseText = TrimValue(request.ResponseText)
  SendPreregCheck = ParseResultValue(responseText)
End Function

Function ParseResultValue(responseText)
  ParseResultValue = ParseJsonStringValue(responseText, "result")
  If ParseResultValue = "" Then
    Err.Raise vbObjectError + 103, "ParseResultValue", "prereg-check response did not contain a result field: " & responseText
  End If
  ParseResultValue = LCase(ParseResultValue)
End Function

Function ParseJsonStringValue(responseText, fieldName)
  Dim regex
  Dim matches

  Set regex = New RegExp
  regex.Pattern = """" & fieldName & """\s*:\s*""([^""]+)"""
  regex.IgnoreCase = True
  regex.Global = False

  Set matches = regex.Execute(responseText)
  If matches.Count = 0 Then
    ParseJsonStringValue = ""
    Exit Function
  End If

  ParseJsonStringValue = TrimValue(matches.Item(0).SubMatches.Item(0))
End Function

Function BuildPreregCheckEndpoint(serverUrl)
  Dim normalizedUrl

  normalizedUrl = TrimValue(serverUrl)
  Do While Len(normalizedUrl) > 0 And Right(normalizedUrl, 1) = "/"
    normalizedUrl = Left(normalizedUrl, Len(normalizedUrl) - 1)
  Loop

  If LCase(Right(normalizedUrl, 5)) = "/scep" Then
    BuildPreregCheckEndpoint = Left(normalizedUrl, Len(normalizedUrl) - 5) & "/api/attestation/prereg-check"
  Else
    BuildPreregCheckEndpoint = normalizedUrl & "/api/attestation/prereg-check"
  End If
End Function

Function JsonEscape(value)
  Dim escaped

  escaped = Replace(value, "\", "\\")
  escaped = Replace(escaped, Chr(34), "\" & Chr(34))
  JsonEscape = escaped
End Function

Function QuoteForCommand(value)
  QuoteForCommand = """" & Replace(value, """", """""") & """"
End Function

Function EscapeForPowerShellSingleQuoted(value)
  EscapeForPowerShellSingleQuoted = Replace(value, "'", "''")
End Function

Function ParseCustomActionDataValue(data, fieldName)
  Dim regex
  Dim matches

  Set regex = New RegExp
  regex.Pattern = "(?:^|;)" & fieldName & "=([^;]*)"
  regex.IgnoreCase = True
  regex.Global = False

  Set matches = regex.Execute(data)
  If matches.Count = 0 Then
    ParseCustomActionDataValue = ""
    Exit Function
  End If

  ParseCustomActionDataValue = TrimValue(matches.Item(0).SubMatches.Item(0))
End Function

Function TrimValue(value)
  TrimValue = Trim(CStr(value))
End Function
