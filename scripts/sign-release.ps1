[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseDirectory,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$SigningConfig,
    [string]$ExpectedPublicKey,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$MinimumVersion = '1.0.0'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $repositoryRoot
if (-not $SigningConfig) {
    $SigningConfig = Join-Path $workspaceRoot '.signing/update-signing.clixml'
}
$config = Import-Clixml -LiteralPath $SigningConfig
if ($config.Credential -isnot [Management.Automation.PSCredential]) {
    throw 'Expected a DPAPI-protected update signing credential.'
}
if ($ExpectedPublicKey -and $ExpectedPublicKey -cne $config.PublicKey) {
    throw 'The signing key differs from the public key embedded in this build.'
}
$ReleaseDirectory = (Resolve-Path -LiteralPath $ReleaseDirectory).Path
$artifacts = @()
foreach ($entry in @(
    @{ Platform = 'android'; Filename = "iptvs-$Version-android.apk"; Maximum = 512MB },
    @{ Platform = 'windows-x64'; Filename = "iptvs-$Version-windows-x64.zip"; Maximum = 1GB }
)) {
    $path = Join-Path $ReleaseDirectory $entry.Filename
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $file = Get-Item -LiteralPath $path
    if ($file.Length -le 0 -or $file.Length -gt $entry.Maximum) { throw "Invalid artifact size: $($entry.Filename)" }
    $artifacts += [ordered]@{
        platform = $entry.Platform
        filename = $entry.Filename
        byte_size = $file.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
if ($artifacts.Count -eq 0) { throw 'No updater-compatible APK or Windows ZIP was found.' }
$manifestPath = Join-Path $ReleaseDirectory "iptvs-$Version-manifest.json"
if ((Test-Path -LiteralPath $manifestPath) -or (Test-Path -LiteralPath "$manifestPath.sig")) {
    throw 'A signed release manifest already exists. Create a new release directory; do not overwrite published metadata.'
}
$manifest = [ordered]@{ schema = 1; version = $Version; minimum_version = $MinimumVersion; artifacts = $artifacts }
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5 -Compress), [Text.UTF8Encoding]::new($false))
$openssl = (Get-Command openssl -ErrorAction Stop).Source
$scratch = Join-Path $ReleaseDirectory ('.sign-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$env:TVBRO_UPDATE_KEY_PASSWORD = $config.Credential.GetNetworkCredential().Password
try {
    $publicDer = Join-Path $scratch 'public.der'
    $signature = Join-Path $scratch 'signature.bin'
    & $openssl pkey -in $config.PrivateKeyPath -passin env:TVBRO_UPDATE_KEY_PASSWORD -pubout -outform DER -out $publicDer
    if ($LASTEXITCODE -ne 0) { throw 'Cannot derive signing public key.' }
    $der = [IO.File]::ReadAllBytes($publicDer)
    $actualPublicKey = [Convert]::ToBase64String($der[($der.Length - 32)..($der.Length - 1)])
    if ($actualPublicKey -cne $config.PublicKey) { throw 'Private and public update keys do not match.' }
    & $openssl pkeyutl -sign -rawin -inkey $config.PrivateKeyPath -passin env:TVBRO_UPDATE_KEY_PASSWORD -in $manifestPath -out $signature
    if ($LASTEXITCODE -ne 0) { throw 'Manifest signing failed.' }
    & $openssl pkeyutl -verify -rawin -pubin -inkey $publicDer -keyform DER -in $manifestPath -sigfile $signature
    if ($LASTEXITCODE -ne 0) { throw 'Manifest signature did not verify.' }
    [IO.File]::WriteAllText("$manifestPath.sig", [Convert]::ToBase64String([IO.File]::ReadAllBytes($signature)), [Text.UTF8Encoding]::new($false))
    Write-Host "Signed and verified: $manifestPath"
} finally {
    Remove-Item Env:TVBRO_UPDATE_KEY_PASSWORD -ErrorAction SilentlyContinue
    # Only delete this script's GUID-named scratch directory inside the release.
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    if ($resolvedScratch.StartsWith($ReleaseDirectory.TrimEnd('\') + '\.sign-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
    }
}
