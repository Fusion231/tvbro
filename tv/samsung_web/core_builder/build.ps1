param(
  [string]$Owner = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path,
  [string]$Out = '',
  [string]$Flutter = ''
)
$ErrorActionPreference = 'Stop'
$env:CI = 'true'
if (-not $Out) { $Out = Join-Path $Owner 'tv/output/samsung-web/core' }
if (-not $Flutter) { $Flutter = Join-Path (Split-Path $Owner -Parent) 'evaluation/tooling/flutter' }
$dart = Join-Path $Flutter 'bin/cache/dart-sdk/bin/dart.exe'
$config = Join-Path $Flutter 'packages/flutter_tools/.dart_tool/package_config.json'
& $dart "--packages=$config" (Join-Path $PSScriptRoot 'build_core.dart') $Owner $Out $dart $config
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
