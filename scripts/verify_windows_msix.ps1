[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $PackagePath,

  [Parameter(Mandatory = $true)]
  [string] $ExpectedVersion,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[A-Za-z0-9.-]{3,50}$')]
  [string] $ExpectedIdentityName,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string] $ExpectedPublisher,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string] $ExpectedPublisherDisplayName,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string] $ExpectedDisplayName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($ExpectedVersion -notmatch '^\d+\.\d+\.\d+\.0$') {
  throw "ExpectedVersion must have four numeric components and end in .0: $ExpectedVersion"
}

function Find-WindowsSdkTool([string] $Name) {
  $Command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -ne $Command) {
    return $Command.Source
  }
  $SdkBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  $Candidates = @(Get-ChildItem -LiteralPath $SdkBin -Filter $Name -File -Recurse |
    Where-Object { $_.DirectoryName -match '[\\/]x64$' } |
    Sort-Object { [version] $_.Directory.Parent.Name } -Descending)
  if ($Candidates.Count -eq 0) {
    throw "$Name was not found in PATH or the Windows 10 SDK."
  }
  return $Candidates[0].FullName
}

$MakeAppx = Find-WindowsSdkTool 'makeappx.exe'
$ResolvedPackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
$TemporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$UnpackDirectory = Join-Path $TemporaryRoot "tvbro-msix-verify-$([guid]::NewGuid().ToString('N'))"

try {
  & $MakeAppx unpack /o /p $ResolvedPackagePath /d $UnpackDirectory
  if ($LASTEXITCODE -ne 0) {
    throw "MakeAppx unpack failed with exit code $LASTEXITCODE."
  }

  [xml] $Manifest = Get-Content -LiteralPath (Join-Path $UnpackDirectory 'AppxManifest.xml') -Raw
  $Namespace = New-Object System.Xml.XmlNamespaceManager($Manifest.NameTable)
  $Namespace.AddNamespace('f', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
  $Namespace.AddNamespace('uap', 'http://schemas.microsoft.com/appx/manifest/uap/windows10')
  $Namespace.AddNamespace('rescap', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities')

  $Identity = $Manifest.SelectSingleNode('/f:Package/f:Identity', $Namespace)
  $ExpectedIdentity = @{
    Name = $ExpectedIdentityName
    Publisher = $ExpectedPublisher
    Version = $ExpectedVersion
    ProcessorArchitecture = 'x64'
  }
  foreach ($Entry in $ExpectedIdentity.GetEnumerator()) {
    if ($Identity.GetAttribute($Entry.Key) -cne $Entry.Value) {
      throw "Unexpected MSIX identity $($Entry.Key): $($Identity.GetAttribute($Entry.Key))"
    }
  }

  # Partner Center also requires the exact publisher display name.
  $PublisherDisplayName = $Manifest.SelectSingleNode(
    '/f:Package/f:Properties/f:PublisherDisplayName',
    $Namespace
  )
  if ($null -eq $PublisherDisplayName -or
      $PublisherDisplayName.InnerText -cne $ExpectedPublisherDisplayName) {
    throw 'MSIX PublisherDisplayName does not match the Partner Center publisher.'
  }

  $DisplayName = $Manifest.SelectSingleNode('/f:Package/f:Properties/f:DisplayName', $Namespace)
  if ($null -eq $DisplayName -or $DisplayName.InnerText -cne $ExpectedDisplayName) {
    throw 'MSIX DisplayName does not match the reserved Partner Center name.'
  }

  $VCLibs = $Manifest.SelectSingleNode(
    '/f:Package/f:Dependencies/f:PackageDependency[@Name="Microsoft.VCLibs.140.00.UWPDesktop"]',
    $Namespace
  )
  if ($null -eq $VCLibs -or
      $VCLibs.GetAttribute('MinVersion') -cne '14.0.24217.0' -or
      $VCLibs.GetAttribute('Publisher') -cne 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US') {
    throw 'MSIX does not declare the expected Microsoft Visual C++ desktop runtime framework dependency.'
  }

  $Application = $Manifest.SelectSingleNode('/f:Package/f:Applications/f:Application', $Namespace)
  if ($Application.GetAttribute('Executable') -cne 'tvbro.exe' -or
      $Application.GetAttribute('EntryPoint') -cne 'Windows.FullTrustApplication') {
    throw 'MSIX application entry point is not the expected tvbro.exe full-trust process.'
  }
  $VisualElements = $Application.SelectSingleNode('uap:VisualElements', $Namespace)
  if ($null -eq $VisualElements -or $VisualElements.GetAttribute('DisplayName') -cne $ExpectedDisplayName) {
    throw 'MSIX application display name does not match the reserved Partner Center name.'
  }

  $Capabilities = @($Manifest.SelectNodes('/f:Package/f:Capabilities/*', $Namespace))
  if ($Capabilities.Count -ne 1 -or
      $Capabilities[0].NamespaceURI -cne 'http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities' -or
      $Capabilities[0].GetAttribute('Name') -cne 'runFullTrust') {
    throw 'MSIX must declare only the runFullTrust capability.'
  }

  $RequiredPayload = @(
    'tvbro.exe',
    'flutter_windows.dll',
    'libmpv-2.dll',
    'data\app.so',
    'data\icudtl.dat',
    'data\flutter_assets\AssetManifest.bin',
    'Assets\StoreLogo.png',
    'Assets\Square44x44Logo.png',
    'Assets\Square150x150Logo.png'
  )
  foreach ($RelativePath in $RequiredPayload) {
    if (-not (Test-Path -LiteralPath (Join-Path $UnpackDirectory $RelativePath) -PathType Leaf)) {
      throw "MSIX is missing required payload: $RelativePath"
    }
  }

  Write-Host "Verified Microsoft Store MSIX identity, version, VCLibs dependency, capabilities, and runtime payload: $ResolvedPackagePath"
} finally {
  if (Test-Path -LiteralPath $UnpackDirectory) {
    $ResolvedUnpackDirectory = (Resolve-Path -LiteralPath $UnpackDirectory).Path
    if (-not [string]::Equals((Split-Path -Parent $ResolvedUnpackDirectory), $TemporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Refusing to remove an MSIX verification directory outside the temporary root.'
    }
    Remove-Item -LiteralPath $ResolvedUnpackDirectory -Recurse -Force
  }
}
