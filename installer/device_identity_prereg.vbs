Option Explicit

Const CustomActionSuccess = 1
Const ProbeCommand = "$ErrorActionPreference='Stop'; $ekInfo = Get-TpmEndorsementKeyInfo -HashAlgorithm Sha256; if ($null -eq $ekInfo -or $null -eq $ekInfo.PublicKey -or $null -eq $ekInfo.PublicKey.RawData -or $ekInfo.PublicKey.RawData.Length -eq 0) { throw 'TPM endorsement key public key is unavailable' }; $sha = [System.Security.Cryptography.SHA256]::Create(); try { $hash = $sha.ComputeHash($ekInfo.PublicKey.RawData) } finally { $sha.Dispose() }; $deviceId = (-join ($hash | ForEach-Object { $_.ToString('x2') })); Write-Output $deviceId"

Function ProbeCurrentDeviceIdentity()
  On Error Resume Next

  Dim deviceId
  deviceId = ResolveCurrentDeviceId()
  If Err.Number <> 0 Then
    Session.Property("CURRENT_DEVICE_ID") = ""
    Session.Property("PROBE_STATUS_MESSAGE") = "Failed to read the canonical TPM device identity from the local endorsement key: " & Err.Description
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
  Dim shell
  Dim exec
  Dim commandLine
  Dim stdoutText
  Dim stderrText
  Dim exitCode

  Set shell = CreateObject("WScript.Shell")
  commandLine = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command " & QuoteForCommand(ProbeCommand)
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
    Err.Raise vbObjectError + 101, "ResolveCurrentDeviceId", "PowerShell TPM probe returned an empty device identity"
  End If

  ResolveCurrentDeviceId = LCase(stdoutText)
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
  Dim regex
  Dim matches

  Set regex = New RegExp
  regex.Pattern = """result""\s*:\s*""([^""]+)"""
  regex.IgnoreCase = True
  regex.Global = False

  Set matches = regex.Execute(responseText)
  If matches.Count = 0 Then
    Err.Raise vbObjectError + 103, "ParseResultValue", "prereg-check response did not contain a result field: " & responseText
  End If

  ParseResultValue = LCase(matches.Item(0).SubMatches.Item(0))
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

Function TrimValue(value)
  TrimValue = Trim(CStr(value))
End Function
