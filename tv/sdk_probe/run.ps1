param(
    [string]$FlutterSdk,
    [string]$CompilerArchive,
    [string]$PatchedSdk,
    [string]$Variant = 'host-platform',
    [ValidateSet('SourceFixture', 'Application')]
    [string]$EntryPoint = 'SourceFixture'
)

$ErrorActionPreference = 'Stop'
$appDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workspaceDirectory = Split-Path $appDirectory -Parent
$outputDirectory = Join-Path $appDirectory 'tv/output/sdk-probe'
$applicationMode = $EntryPoint -eq 'Application'
if (-not $FlutterSdk) { $FlutterSdk = Join-Path $workspaceDirectory 'evaluation/tooling/flutter' }
$FlutterSdk = [IO.Path]::GetFullPath($FlutterSdk)
if (-not $CompilerArchive) { $CompilerArchive = Join-Path $outputDirectory 'tizen-arm-release_windows-x64.zip' }
if (-not $PatchedSdk) { $PatchedSdk = Join-Path $FlutterSdk 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product' }
$PatchedSdk = [IO.Path]::GetFullPath($PatchedSdk)
if ($Variant -notmatch '^[a-z0-9-]+$') { throw 'Variant must contain only lowercase letters, digits and hyphens.' }

$artifactUrl = 'https://github.com/flutter-tizen/flutter/releases/download/a0e550d2/tizen-arm-release_windows-x64.zip'
$expectedArchiveHash = '48b4a0975bd3ef277c312a961e3d59aaad5d5b582ac0854627fcdc7a69b8dfa4'
$packageConfigPath = Join-Path $appDirectory '.dart_tool/package_config.json'
$runtimePath = Join-Path $FlutterSdk 'bin/cache/dart-sdk/bin/dartaotruntime.exe'
$frontendPath = Join-Path $FlutterSdk 'bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot'
$versionPath = Join-Path $FlutterSdk 'bin/cache/flutter.version.json'
$platformPath = Join-Path $PatchedSdk 'platform_strong.dill'
$controlCompiler = Join-Path $FlutterSdk 'bin/cache/artifacts/engine/android-arm-release/windows-x64/gen_snapshot.exe'
$mainPath = if ($applicationMode) { Join-Path $appDirectory 'tv/app/main.dart' } else { Join-Path $PSScriptRoot 'main.dart' }
$prerequisites = @($packageConfigPath, $runtimePath, $frontendPath, $versionPath, $platformPath, $mainPath)
$prerequisites += if ($applicationMode) { $controlCompiler } else { $CompilerArchive }
foreach ($path in $prerequisites) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing cached prerequisite: $path. This probe does not download or install dependencies." }
}
if (-not $applicationMode -and (Get-FileHash -LiteralPath $CompilerArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedArchiveHash) {
    throw 'The compiler archive does not match the SHA-256 published for the pinned official release.'
}
$version = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
if ($version.frameworkRevision -ne 'abaf9c523780a608bd46686fd5e53740a07077f8' -or $version.dartSdkVersion -ne '3.13.5') {
    throw 'This experiment is pinned to Flutter 3.47.7 / Dart 3.13.5; another host SDK requires a separate qualification.'
}
$config = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json
$configUri = [Uri]::new($packageConfigPath)
$iptvs = @($config.packages | Where-Object { $_.name -eq 'iptvs' })
$flutter = @($config.packages | Where-Object { $_.name -eq 'flutter' })
$sourceUri = [Uri]::new($appDirectory + [IO.Path]::DirectorySeparatorChar).AbsoluteUri.TrimEnd('/')
$flutterUri = [Uri]::new((Join-Path $FlutterSdk 'packages/flutter') + [IO.Path]::DirectorySeparatorChar).AbsoluteUri.TrimEnd('/')
if ($iptvs.Count -ne 1 -or [Uri]::new($configUri, $iptvs[0].rootUri).AbsoluteUri.TrimEnd('/') -ne $sourceUri) {
    throw 'The package graph must import iptvs from the original app directory.'
}
if ($flutter.Count -ne 1 -or [Uri]::new($configUri, $flutter[0].rootUri).AbsoluteUri.TrimEnd('/') -ne $flutterUri) {
    throw 'The package graph Flutter root must match the selected host SDK.'
}
$rootSdkConstraint = $null
if ($applicationMode) {
    if ($iptvs[0].packageUri -ne 'lib/' -or $iptvs[0].languageVersion -ne '3.13' -or $config.generatorVersion -ne '3.13.5') {
        throw 'Application qualification requires the original lib/ package and its Dart 3.13.5 package graph.'
    }
    $manifest = Get-Content -LiteralPath (Join-Path $appDirectory 'pubspec.yaml') -Raw
    $environment = [regex]::Match($manifest, '(?m)^environment:[^\r\n]*\r?\n(?<body>(?:[ \t]+[^\r\n]*\r?\n|[ \t]*\r?\n)*)')
    $sdk = [regex]::Match($environment.Groups['body'].Value, '(?m)^[ \t]+sdk:[ \t]*(?<value>[^\r\n#]+)')
    $rootSdkConstraint = $sdk.Groups['value'].Value.Trim().Trim("'", '"')
    if ($rootSdkConstraint -ne '^3.13.5') {
        throw 'The original SDK constraint differs from ^3.13.5; qualify the changed requirement separately without overriding it.'
    }
}

function Read-OwnerDependencies([string]$Path) {
    $contents = Get-Content -LiteralPath $Path -Raw
    $separator = $contents.IndexOf(': ')
    if ($separator -lt 0) { throw 'The frontend depfile has no target/input separator.' }
    $ownerPrefix = (Join-Path $appDirectory 'lib') + [IO.Path]::DirectorySeparatorChar
    $inputs = foreach ($token in [regex]::Matches($contents.Substring($separator + 2), '(?:\\.|[^\s])+')) {
        $unescaped = [regex]::Replace($token.Value, '\\(.)', '$1')
        $absolute = [IO.Path]::GetFullPath($unescaped, $appDirectory)
        if ($absolute.StartsWith($ownerPrefix, [StringComparison]::OrdinalIgnoreCase) -and $absolute.EndsWith('.dart', [StringComparison]::OrdinalIgnoreCase)) {
            [IO.Path]::GetRelativePath($appDirectory, $absolute).Replace('\', '/')
        }
    }
    return @($inputs | Sort-Object -Unique)
}

function Read-KernelHeader([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $header = [byte[]]::new(18)
        if ($stream.Read($header, 0, 18) -ne 18) { throw "Truncated kernel: $Path" }
        return [ordered]@{
            magic = [Convert]::ToHexString($header[0..3])
            formatHex = [Convert]::ToHexString($header[4..7])
            sdkHash = [Text.Encoding]::ASCII.GetString($header[8..17])
        }
    } finally { $stream.Dispose() }
}

function Invoke-ProbeCommand([string]$Name, [string]$Executable, [string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = $appDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['DASH__SUPPRESS_ANALYTICS'] = 'true'
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $deadline = [Threading.CancellationTokenSource]::new(120000)
    try { [void]$process.WaitForExitAsync($deadline.Token).GetAwaiter().GetResult() }
    catch { $process.Kill($true); throw "Timed out: $Name" }
    finally { $deadline.Dispose() }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $stdout | Set-Content -LiteralPath (Join-Path $runDirectory "$Name.stdout.log") -Encoding UTF8
    $stderr | Set-Content -LiteralPath (Join-Path $runDirectory "$Name.stderr.log") -Encoding UTF8
    $result = [ordered]@{ executable = $Executable; arguments = $Arguments; exitCode = $process.ExitCode; stdout = $stdout; stderr = $stderr }
    $process.Dispose()
    return $result
}

$protectedPaths = @('pubspec.yaml', 'pubspec.lock', '.dart_tool/package_config.json',
    'lib/sources/source.dart', 'lib/sources/source_config.dart', 'lib/sources/source_identity.dart',
    'lib/sources/m3u_source.dart', 'lib/sources/xtream_source.dart', 'lib/sources/stalker_source.dart', 'lib/sources/demo_source.dart')
$before = [ordered]@{}
foreach ($path in $protectedPaths) { $before[$path] = (Get-FileHash -LiteralPath (Join-Path $appDirectory $path) -Algorithm SHA256).Hash }
$ownerBefore = [ordered]@{}
if ($applicationMode) {
    foreach ($path in @('tv/app/main.dart', '.dart_tool/package_graph.json', '.dart_tool/native_assets.yaml')) {
        if (Test-Path -LiteralPath (Join-Path $appDirectory $path) -PathType Leaf) {
            $before[$path] = (Get-FileHash -LiteralPath (Join-Path $appDirectory $path) -Algorithm SHA256).Hash
        }
    }
    # Snapshot before compilation; the emitted depfile selects the actual owner graph.
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $appDirectory 'lib') -Filter '*.dart' -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath($appDirectory, $file.FullName).Replace('\', '/')
        $ownerBefore[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
}
$runDirectory = Join-Path $outputDirectory ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + $Variant)
[void][IO.Directory]::CreateDirectory($runDirectory)
$compilerPath = $controlCompiler
if (-not $applicationMode) {
    $compilerPath = Join-Path $runDirectory 'gen_snapshot.exe'
    $zip = [IO.Compression.ZipFile]::OpenRead($CompilerArchive)
    try {
        $entry = $zip.GetEntry('gen_snapshot.exe')
        if ($null -eq $entry -or $zip.Entries.Count -ne 1) { throw 'Unexpected official compiler archive contents.' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $compilerPath)
    } finally { $zip.Dispose() }
}
$image = [IO.File]::ReadAllBytes($compilerPath)
$peOffset = [BitConverter]::ToInt32($image, 0x3c)
if ($image[0] -ne 0x4d -or $image[1] -ne 0x5a -or [BitConverter]::ToUInt32($image, $peOffset) -ne 0x00004550) { throw 'Expected a Windows PE compiler executable.' }
$machine = [BitConverter]::ToUInt16($image, $peOffset + 4)
if ($machine -notin @(0x014c, 0x8664)) { throw 'The compiler is not an x86/x64 Windows host executable.' }

$kernelPath = Join-Path $runDirectory 'app.dill'
$depfilePath = Join-Path $runDirectory 'kernel.d'
$elfPath = Join-Path $runDirectory $(if ($applicationMode) { 'control-3.13.5.so' } else { 'app.so' })
$evidence = [ordered]@{
    timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'incomplete'
    variant = $Variant
    entryPoint = $EntryPoint
    entrypointPath = $mainPath
    compilerSha256 = (Get-FileHash -LiteralPath $compilerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    compilerPeMachineHex = '{0:X4}' -f $machine
    hostFlutter = $version
    originalPackageRoot = $sourceUri
    entrypointSha256 = (Get-FileHash -LiteralPath $mainPath -Algorithm SHA256).Hash.ToLowerInvariant()
    patchedSdk = $PatchedSdk
    platformHeader = Read-KernelHeader $platformPath
    platformSha256 = (Get-FileHash -LiteralPath $platformPath -Algorithm SHA256).Hash.ToLowerInvariant()
    frontendSha256 = (Get-FileHash -LiteralPath $frontendPath -Algorithm SHA256).Hash.ToLowerInvariant()
    runtimeSha256 = (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant()
    sourceHashes = $before
    commands = [ordered]@{}
    nativeBuild = $false
    runtimeExecution = $false
}
$expectedSuccess = 'arm_aot_compiled_only'
if ($applicationMode) {
    $expectedSuccess = 'application_arm_control_compiled_only'
    $evidence.proofKind = 'application_host_frontend_arm_control_non_tizen'
    $evidence.compilerOrigin = 'cached Flutter Windows-host ARM compiler; not a Tizen runtime or package'
    $evidence.rootSdkConstraint = $rootSdkConstraint
    $evidence.dartDefines = @('TVBRO_CLOUD_ENABLED=false')
    $evidence.ownerGraph = [ordered]@{ depfile = $depfilePath; status = 'not_emitted'; importedOriginalDart = @() }
    $evidence.nativeAssetsLinked = $false
    $evidence.pluginLinking = $false
    $evidence.tizenBuild = $false
} else {
    $evidence.artifactUrl = $artifactUrl
    $evidence.artifactMetadataUrl = 'https://api.github.com/repos/flutter-tizen/flutter/releases/tags/a0e550d2'
    $evidence.archiveSha256 = $expectedArchiveHash
    $evidence.tizenEngineRevision = 'a0e550d2b728d26d86bdbd981b33c9e9de7a656b'
    $evidence.tizenDartRevision = 'b530c21f7de367b94fb04787bfed9d8e989d75e8'
}
try {
    $evidence.commands.runtimeVersion = Invoke-ProbeCommand 'runtime-version' $runtimePath @('--version')
    $evidence.commands.compilerVersion = Invoke-ProbeCommand 'compiler-version' $compilerPath @('--version')
    if ($evidence.commands.runtimeVersion.exitCode -ne 0 -or $evidence.commands.compilerVersion.exitCode -ne 0) { throw 'Could not execute the Windows host tools.' }
    $compilerVersionPattern = if ($applicationMode) { 'Dart SDK version: 3\.13\.5 ' } else { 'Dart SDK version: 3\.13\.4 ' }
    if ($evidence.commands.runtimeVersion.stdout -notmatch 'Dart SDK version: 3\.13\.5 ' -or $evidence.commands.compilerVersion.stderr -notmatch $compilerVersionPattern) { throw 'The executed compiler/runtime versions differ from the pinned experiment.' }
    $frontendArguments = @($frontendPath, '--sdk-root', $PatchedSdk, '--target=flutter', '--target-os=linux',
        '--aot', '--tfa', '-Ddart.vm.product=true', '--no-embed-source-text', '--no-print-incremental-dependencies', '--packages', $packageConfigPath,
        '--output-dill', $kernelPath, '--depfile', $depfilePath, '--verbosity=error')
    if ($applicationMode) { $frontendArguments += '-DTVBRO_CLOUD_ENABLED=false' }
    $frontendArguments += $mainPath
    $evidence.commands.frontend = Invoke-ProbeCommand 'frontend' $runtimePath $frontendArguments
    if ($applicationMode -and (Test-Path -LiteralPath $depfilePath -PathType Leaf)) {
        $dependencies = @(Read-OwnerDependencies $depfilePath)
        $evidence.ownerGraph.importedOriginalDart = $dependencies
        $evidence.ownerGraph.importedOriginalDartCount = $dependencies.Count
        $evidence.ownerGraph.depfileSha256 = (Get-FileHash -LiteralPath $depfilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach ($path in $dependencies) { $before[$path] = $ownerBefore[$path] }
        if ($dependencies -notcontains 'lib/main.dart') { throw 'The frontend depfile did not import canonical lib/main.dart.' }
        $evidence.ownerGraph.status = 'canonical_main_imported'
    }
    if ($evidence.commands.frontend.exitCode -ne 0 -or -not (Test-Path -LiteralPath $kernelPath)) {
        $evidence.status = 'blocked_frontend'
    } else {
        $evidence.kernelHeader = Read-KernelHeader $kernelPath
        $evidence.kernelSha256 = (Get-FileHash -LiteralPath $kernelPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $evidence.compilerDartSdkHash = if ($applicationMode) { '04bcd1036c' } else { $evidence.tizenDartRevision.Substring(0, 10) }
        $evidence.kernelMatchesCompilerSdkHash = if ($applicationMode) { $evidence.kernelHeader.sdkHash -eq $evidence.compilerDartSdkHash } else { $evidence.kernelHeader.sdkHash -in @('0000000000', $evidence.compilerDartSdkHash) }
        if ($applicationMode -and ($evidence.ownerGraph.status -ne 'canonical_main_imported' -or -not $evidence.kernelMatchesCompilerSdkHash)) {
            throw 'Application control requires the canonical entrypoint graph and the unchanged matching SDK hash.'
        }
        $aotName = if ($applicationMode) { 'control-aot' } else { 'aot' }
        $aotResult = Invoke-ProbeCommand $aotName $compilerPath @('--deterministic', '--snapshot_kind=app-aot-elf', "--elf=$elfPath", '--strip', $kernelPath)
        if ($applicationMode) { $evidence.commands.controlAot = $aotResult } else { $evidence.commands.aot = $aotResult }
        if ($aotResult.exitCode -ne 0) {
            $evidence.status = if (-not $evidence.kernelMatchesCompilerSdkHash) { 'blocked_aot_with_sdk_hash_mismatch' } else { 'blocked_aot' }
            if (-not $applicationMode -and (Test-Path -LiteralPath $controlCompiler -PathType Leaf)) {
                $evidence.controlCompilerSha256 = (Get-FileHash -LiteralPath $controlCompiler -Algorithm SHA256).Hash.ToLowerInvariant()
                $evidence.commands.controlVersion = Invoke-ProbeCommand 'control-version' $controlCompiler @('--version')
                if ($evidence.commands.controlVersion.exitCode -ne 0 -or $evidence.commands.controlVersion.stderr -notmatch 'Dart SDK version: 3\.13\.5 ') { throw 'The cached control compiler is not the expected Dart 3.13.5 compiler.' }
                $controlElfPath = Join-Path $runDirectory 'control-3.13.5.so'
                $evidence.commands.controlAot = Invoke-ProbeCommand 'control-aot' $controlCompiler @('--deterministic', '--snapshot_kind=app-aot-elf', "--elf=$controlElfPath", '--strip', $kernelPath)
                if ($evidence.commands.controlAot.exitCode -eq 0 -and (Test-Path -LiteralPath $controlElfPath)) {
                    $controlElf = [IO.File]::ReadAllBytes($controlElfPath)
                    if ([Convert]::ToHexString($controlElf[0..3]) -ne '7F454C46' -or [BitConverter]::ToUInt16($controlElf, 18) -ne 40) { throw 'Expected an ARM ELF control artifact.' }
                    $evidence.controlElfMachine = 40
                    $evidence.controlElfSha256 = (Get-FileHash -LiteralPath $controlElfPath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        } elseif (-not (Test-Path -LiteralPath $elfPath)) { $evidence.status = 'blocked_missing_elf' }
        else {
            $elf = [IO.File]::ReadAllBytes($elfPath)
            if ([Convert]::ToHexString($elf[0..3]) -ne '7F454C46' -or [BitConverter]::ToUInt16($elf, 18) -ne 40) { throw 'Expected an ARM ELF artifact.' }
            $evidence.elfSha256 = (Get-FileHash -LiteralPath $elfPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $evidence.status = $expectedSuccess
        }
    }
} catch {
    $evidence.error = $_.Exception.Message
    if ($evidence.status -eq 'incomplete') { $evidence.status = 'blocked_probe_error' }
} finally {
    if ($applicationMode -and $evidence.ownerGraph.status -ne 'canonical_main_imported') {
        # A failed frontend may omit its depfile. Retain the pre-run inventory
        # without claiming those files form a successfully compiled import graph.
        foreach ($path in $ownerBefore.Keys) { $before[$path] = $ownerBefore[$path] }
        $evidence.ownerGraph.fallbackInventoryCount = $ownerBefore.Count
    }
    $changed = @($before.Keys | Where-Object {
        $absolute = Join-Path $appDirectory $_
        -not (Test-Path -LiteralPath $absolute -PathType Leaf) -or $null -eq $before[$_] -or $before[$_] -ne (Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash
    })
    $evidence.protectedInputsChanged = $changed
    if ($applicationMode -and $changed.Count -ne 0) {
        $evidence.compilationStatus = $evidence.status
        $evidence.status = 'blocked_inputs_changed'
    }
    $evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $runDirectory 'evidence.json') -Encoding UTF8
}
Write-Output "$($evidence.status): $(Join-Path $runDirectory 'evidence.json')"
if ($changed.Count -ne 0 -or $evidence.status -ne $expectedSuccess) { exit 1 }
