param(
  [Parameter(Mandatory = $true)]
  [string]$ArtifactPath
)

$resolvedArtifact = Resolve-Path -Path $ArtifactPath -ErrorAction Stop
$signtool = if ($env:SIGNTOOL_PATH) {
  $env:SIGNTOOL_PATH
} else {
  (Get-Command signtool.exe -ErrorAction Stop).Source
}

$timestampUrl = if ($env:SIGN_TIMESTAMP_URL) {
  $env:SIGN_TIMESTAMP_URL
} else {
  "http://timestamp.digicert.com"
}
$fileDigest = if ($env:SIGN_FILE_DIGEST_ALGORITHM) {
  $env:SIGN_FILE_DIGEST_ALGORITHM
} else {
  "SHA256"
}
$timestampDigest = if ($env:SIGN_TIMESTAMP_DIGEST_ALGORITHM) {
  $env:SIGN_TIMESTAMP_DIGEST_ALGORITHM
} else {
  "SHA256"
}

$commonArgs = @("sign", "/fd", $fileDigest, "/td", $timestampDigest, "/tr", $timestampUrl, "/v")
$finalArgs = @()

if ($env:AZURE_TRUSTED_SIGNING_DLIB -and $env:AZURE_TRUSTED_SIGNING_METADATA) {
  $finalArgs += $commonArgs
  $finalArgs += @("/dlib", $env:AZURE_TRUSTED_SIGNING_DLIB, "/dmdf", $env:AZURE_TRUSTED_SIGNING_METADATA)
} elseif ($env:SIGN_CERT_THUMBPRINT) {
  $finalArgs += $commonArgs
  $finalArgs += @("/sha1", $env:SIGN_CERT_THUMBPRINT)
} else {
  throw "Set SIGN_CERT_THUMBPRINT (EV cert) or AZURE_TRUSTED_SIGNING_DLIB+AZURE_TRUSTED_SIGNING_METADATA."
}

$finalArgs += $resolvedArtifact.Path

Write-Host "Signing $($resolvedArtifact.Path) with $signtool"
& $signtool @finalArgs
if ($LASTEXITCODE -ne 0) {
  throw "signtool.exe failed with exit code $LASTEXITCODE"
}
