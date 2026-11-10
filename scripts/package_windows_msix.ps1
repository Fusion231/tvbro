[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $BuildDirectory,

  [Parameter(Mandatory = $true)]
  [string] $Version,

  [Parameter(Mandatory = $true)]
  [string] $OutputPath,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[A-Za-z0-9.-]{3,50}$')]
  [string] $IdentityName,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string] $Publisher,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string] $PublisherDisplayName,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string] $DisplayName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$ManifestTemplate = Join-Path $RepositoryRoot 'windows\packaging\AppxManifest.xml.in'
$IconSource = Join-Path $RepositoryRoot 'assets\brand\tvbro-icon.png'
$ResolvedBuildDirectory = (Resolve-Path -LiteralPath $BuildDirectory).Path
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)

foreach ($Value in @($Publisher, $PublisherDisplayName, $DisplayName)) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw 'Publisher, PublisherDisplayName, and DisplayName must be copied from TVBro Product identity in Partner Center.'
  }
}

if ($Version -notmatch '^([1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
  throw "Version must contain exactly three numeric components and have a non-zero major component (for example 1.2.3): $Version"
}

$VersionParts = $Version.Split('.') | ForEach-Object { [int] $_ }
if ($VersionParts | Where-Object { $_ -gt 65535 }) {
  throw "Every MSIX version component must be between 0 and 65535: $Version"
}
$PackageVersion = "$Version.0"

$RequiredBuildFiles = @(
  'tvbro.exe',
  'flutter_windows.dll',
  'libmpv-2.dll',
  'data\app.so',
  'data\icudtl.dat',
  'data\flutter_assets\AssetManifest.bin'
)
foreach ($RelativePath in $RequiredBuildFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $ResolvedBuildDirectory $RelativePath) -PathType Leaf)) {
    throw "Windows Release payload is missing required file: $RelativePath"
  }
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

function Write-SquareLogo(
  [string] $Source,
  [string] $Destination,
  [int] $Size
) {
  Add-Type -AssemblyName System.Drawing
  $InputImage = [System.Drawing.Image]::FromFile($Source)
  try {
    $OutputImage = New-Object System.Drawing.Bitmap $Size, $Size
    try {
      $OutputImage.SetResolution(96, 96)
      $Graphics = [System.Drawing.Graphics]::FromImage($OutputImage)
      try {
        $Graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $Graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $Graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $Graphics.DrawImage($InputImage, 0, 0, $Size, $Size)
      } finally {
        $Graphics.Dispose()
      }
      $OutputImage.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
      $OutputImage.Dispose()
    }
  } finally {
    $InputImage.Dispose()
  }
}

$MakeAppx = Find-WindowsSdkTool 'makeappx.exe'
$TemporaryRoot = $env:RUNNER_TEMP
if ([string]::IsNullOrWhiteSpace($TemporaryRoot)) {
  $TemporaryRoot = [System.IO.Path]::GetTempPath()
}
$TemporaryRoot = [System.IO.Path]::GetFullPath($TemporaryRoot).TrimEnd('\')
$StagingDirectory = Join-Path $TemporaryRoot "tvbro-msix-$([guid]::NewGuid().ToString('N'))"

try {
  New-Item -ItemType Directory -Path $StagingDirectory | Out-Null
  Get-ChildItem -LiteralPath $ResolvedBuildDirectory -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $StagingDirectory -Recurse
  }

  $AssetsDirectory = Join-Path $StagingDirectory 'Assets'
  New-Item -ItemType Directory -Path $AssetsDirectory | Out-Null
  Write-SquareLogo $IconSource (Join-Path $AssetsDirectory 'StoreLogo.png') 50
  Write-SquareLogo $IconSource (Join-Path $AssetsDirectory 'Square44x44Logo.png') 44
  Write-SquareLogo $IconSource (Join-Path $AssetsDirectory 'Square150x150Logo.png') 150

  $Manifest = New-Object System.Xml.XmlDocument
  $Manifest.PreserveWhitespace = $true
  $Manifest.Load($ManifestTemplate)
  $Identity = $Manifest.GetElementsByTagName('Identity')[0]
  $Identity.SetAttribute('Name', $IdentityName)
  $Identity.SetAttribute('Publisher', $Publisher)
  $Identity.SetAttribute('Version', $PackageVersion)
  $Manifest.GetElementsByTagName('DisplayName')[0].InnerText = $DisplayName
  $Manifest.GetElementsByTagName('PublisherDisplayName')[0].InnerText = $PublisherDisplayName
  $VisualElements = $Manifest.GetElementsByTagName('VisualElements', 'http://schemas.microsoft.com/appx/manifest/uap/windows10')[0]
  $VisualElements.SetAttribute('DisplayName', $DisplayName)
  if ($Manifest.OuterXml -match '@PACKAGE_[A-Z_]+@') {
    throw 'MSIX manifest contains an unconfigured package identity or version.'
  }
  $Manifest.Save((Join-Path $StagingDirectory 'AppxManifest.xml'))

  $OutputDirectory = Split-Path -Parent $OutputPath
  New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
  & $MakeAppx pack /o /h SHA256 /d $StagingDirectory /p $OutputPath
  if ($LASTEXITCODE -ne 0) {
    throw "MakeAppx failed with exit code $LASTEXITCODE."
  }

  & (Join-Path $PSScriptRoot 'verify_windows_msix.ps1') `
    -PackagePath $OutputPath -ExpectedVersion $PackageVersion `
    -ExpectedIdentityName $IdentityName -ExpectedPublisher $Publisher `
    -ExpectedPublisherDisplayName $PublisherDisplayName -ExpectedDisplayName $DisplayName
} finally {
  if (Test-Path -LiteralPath $StagingDirectory) {
    $ResolvedStagingDirectory = (Resolve-Path -LiteralPath $StagingDirectory).Path
    if (-not [string]::Equals((Split-Path -Parent $ResolvedStagingDirectory), $TemporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Refusing to remove an MSIX staging directory outside the temporary root.'
    }
    Remove-Item -LiteralPath $ResolvedStagingDirectory -Recurse -Force
  }
}
