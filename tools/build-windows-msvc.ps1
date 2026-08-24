[CmdletBinding()]
param(
    [string]$Workspace = (Join-Path (Get-Location) "build\windows-msvc"),
    [string]$Prefix = (Join-Path (Get-Location) "install\windows-msvc"),
    [string]$VcpkgRoot = (Join-Path (Get-Location) "vcpkg"),
    [string]$SourceLockPath,
    [string]$RubyGemCache,
    [switch]$RelocatablePrefix,
    [switch]$SkipGeneratorSmokeTests,
    [switch]$SuppressExternalWarnings,
    [string]$FarbotRepository = "https://github.com/liufang-robot/farbot.git",
    [string]$RtlogRepository = "https://github.com/liufang-robot/rtlog-cpp.git",
    [string]$RttRepository = "https://github.com/liufang-robot/rtt.git",
    [string]$Open62541Repository = "https://github.com/open62541/open62541.git",
    [string]$Open62541ppRepository = "https://github.com/open62541pp/open62541pp.git",
    [string]$RttOpcuaRepository = "https://github.com/liufang-robot/rtt_opcua.git",
    [string]$OclRepository = "https://github.com/liufang-robot/ocl.git",
    [string]$UtilmmRepository = "https://github.com/liufang-robot/utilmm.git",
    [string]$TypelibRepository = "https://github.com/liufang-robot/tools-typelib.git",
    [string]$RttTypelibRepository = "https://github.com/liufang-robot/tools-rtt_typelib.git",
    [string]$UtilrbRepository = "https://github.com/rock-core/tools-utilrb.git",
    [string]$MetarubyRepository = "https://github.com/rock-core/tools-metaruby.git",
    [string]$OrogenRepository = "https://github.com/liufang-robot/tools-orogen.git",
    [string]$VcpkgRepository = "https://github.com/microsoft/vcpkg.git",
    [string]$FarbotRef = "master",
    [string]$RtlogRef = "main",
    [string]$RttRef = "dev",
    [string]$Open62541Ref = "v1.4.15",
    [string]$Open62541ppRef = "v0.21.2",
    [string]$RttOpcuaRef = "dev",
    [string]$OclRef = "dev",
    [string]$UtilmmRef = "dev",
    [string]$TypelibRef = "dev",
    [string]$RttTypelibRef = "dev",
    [string]$UtilrbRef = "master",
    [string]$MetarubyRef = "master",
    [string]$OrogenRef = "dev",
    [string]$Open62541Version = "1.4.15",
    [string]$VcpkgRef = "master",
    [string]$Generator = "Visual Studio 17 2022"
)

$BoundParameterNames = @($PSBoundParameters.Keys)
$ErrorActionPreference = "Stop"
$RubyExecutable = Get-Command ruby.exe -CommandType Application `
    -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Script
    )

    Write-Host ""
    Write-Host "==> $Name"
    & $Script
}

function Invoke-Native {
    $FilePath = $args[0]
    $ArgumentList = @()
    if ($args.Count -gt 1) {
        $ArgumentList = $args[1..($args.Count - 1)]
    }

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath exited with code $LASTEXITCODE"
    }
}

function Get-NativeOutput {
    $FilePath = $args[0]
    $ArgumentList = @()
    if ($args.Count -gt 1) {
        $ArgumentList = $args[1..($args.Count - 1)]
    }

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        (& $FilePath @ArgumentList 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
}

function Invoke-NativeWithRetry {
    $Attempts = 6
    $DelaySeconds = 5
    $Command = $args

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Invoke-Native @Command
            return
        } catch {
            if ($attempt -eq $Attempts) {
                throw
            }

            Write-Warning "Command failed on attempt $attempt/${Attempts}: $($_.Exception.Message)"
            Start-Sleep -Seconds ($DelaySeconds * $attempt)
        }
    }
}

function Convert-ToFullPath {
    param([string]$Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-MsvcCompilerFlagArguments {
    param(
        [string]$DependencyInclude,
        [switch]$EnableExceptions,
        [switch]$SuppressExternalWarnings
    )

    $cOptions = @()
    $cxxOptions = @()
    if ($EnableExceptions) {
        $cxxOptions += "/EHsc"
    }
    if ($SuppressExternalWarnings) {
        $externalIncludes = @($DependencyInclude)
        foreach ($candidate in @($env:INCLUDE -split ";")) {
            if ($candidate -match '(?i)\\(?:Microsoft Visual Studio|Windows Kits)\\') {
                $externalIncludes += $candidate
            }
        }
        $externalOptions = @()
        foreach ($candidate in @($externalIncludes | Sort-Object -Unique)) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $fullPath = [IO.Path]::GetFullPath($candidate)
                $externalOptions += "/external:I`"$fullPath`""
            }
        }
        $externalOptions += "/external:W0"
        $cOptions += $externalOptions
        $cxxOptions += $externalOptions
    }

    $cmakeArguments = @()
    if ($cOptions.Count -gt 0) {
        $cmakeArguments += "-DCMAKE_C_FLAGS=$($cOptions -join ' ')"
    }
    if ($cxxOptions.Count -gt 0) {
        $cmakeArguments += "-DCMAKE_CXX_FLAGS=$($cxxOptions -join ' ')"
    }
    $cmakeArguments
}

function Resolve-GitRepository {
    param([string]$Repository)

    if (Test-Path -LiteralPath $Repository) {
        return Convert-ToFullPath $Repository
    }

    $Repository
}

function Get-GitConfigValue {
    param(
        [string]$Path,
        [string]$Name
    )

    $value = & git -C $Path config --get $Name
    if ($LASTEXITCODE -eq 1) {
        return $null
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git config --get $Name exited with code $LASTEXITCODE"
    }

    $value
}

function Initialize-GitRepository {
    param(
        [string]$Repository,
        [string]$Path
    )

    $gitPath = Join-Path $Path ".git"
    if (Test-Path -LiteralPath $gitPath) {
        Remove-Item -LiteralPath $gitPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Invoke-Native git init --quiet $Path
    Invoke-Native git -C $Path remote add origin $Repository
    Invoke-Native git -C $Path config core.autocrlf false
}

function Sync-GitRepository {
    param(
        [string]$Repository,
        [string]$Ref,
        [string]$Path
    )

    $gitPath = Join-Path $Path ".git"
    $needsInitialization = -not (Test-Path -LiteralPath $gitPath)
    if (-not $needsInitialization) {
        $configuredRepository = Get-GitConfigValue -Path $Path -Name "remote.origin.url"
        $needsInitialization = $configuredRepository -ne $Repository
    }

    if ($needsInitialization) {
        Initialize-GitRepository -Repository $Repository -Path $Path
    } else {
        Invoke-Native git -C $Path remote set-url origin $Repository
        Invoke-Native git -C $Path config core.autocrlf false
    }

    $promisor = Get-GitConfigValue -Path $Path -Name "remote.origin.promisor"
    $partialCloneFilter = Get-GitConfigValue -Path $Path -Name "remote.origin.partialclonefilter"
    $fetchArguments = @(
        "-c", "http.sslBackend=openssl",
        "-C", $Path,
        "fetch", "--force", "--depth", "1", "--no-tags", "--no-filter"
    )
    if ($promisor -eq "true" -or $null -ne $partialCloneFilter) {
        $fetchArguments += "--refetch"
    }
    $fetchArguments += @("origin", "--", $Ref)

    try {
        Invoke-NativeWithRetry git @fetchArguments
    } catch {
        Write-Warning "Reinitializing disposable checkout after fetch failure: $Path"
        Initialize-GitRepository -Repository $Repository -Path $Path
        $promisor = $null
        $partialCloneFilter = $null
        Invoke-NativeWithRetry git @fetchArguments
    }

    if ($null -ne $promisor) {
        Invoke-Native git -C $Path config --unset-all remote.origin.promisor
    }
    if ($null -ne $partialCloneFilter) {
        Invoke-Native git -C $Path config --unset-all remote.origin.partialclonefilter
    }

    Invoke-Native git -C $Path checkout --detach --force FETCH_HEAD

    if ($Ref -match '^[0-9a-fA-F]{40}$') {
        $checkedOutRevision = (& git -C $Path rev-parse --verify HEAD | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "git rev-parse --verify HEAD exited with code $LASTEXITCODE"
        }
        if (-not [string]::Equals(
                $checkedOutRevision,
                $Ref,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Locked source '$Repository' resolved to '$checkedOutRevision', expected '$Ref'."
        }
    }
}

function Apply-SourcePatch {
    param(
        [string]$Path,
        [string]$Patch
    )

    if (-not (Test-Path -LiteralPath $Patch)) {
        throw "Missing Windows source patch: $Patch"
    }

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & git -C $Path apply --check --unidiff-zero $Patch *> $null
        $canApply = $LASTEXITCODE -eq 0
        & git -C $Path apply --reverse --check --unidiff-zero $Patch *> $null
        $isApplied = $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    if ($canApply) {
        Invoke-Native git -C $Path apply --unidiff-zero $Patch
        return
    }

    if ($isApplied) {
        Write-Host "Patch already present: $Patch"
        return
    }

    throw "Windows source patch does not apply cleanly: $Patch"
}

function Write-Open62541PkgConfig {
    param(
        [string]$PrefixPath,
        [string]$Version
    )

    $pkgConfigDirectory = Join-Path $PrefixPath "lib\pkgconfig"
    New-Item -ItemType Directory -Force -Path $pkgConfigDirectory | Out-Null
    $pkgPrefix = $PrefixPath -replace "\\", "/"
    $contents = @(
        "prefix=$pkgPrefix"
        'libdir=${prefix}/lib'
        'sharedlibdir=${libdir}'
        "includedir=$pkgPrefix/include"
        ""
        "Name: open62541"
        "Description: open62541 is an open source C implementation of OPC UA"
        "Version: $Version"
        'Cflags: -I${includedir}'
        'Libs: -L${libdir} -lopen62541'
    ) -join "`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $pkgConfigDirectory "open62541.pc"),
        "$contents`n",
        [System.Text.UTF8Encoding]::new($false))
}

$SourceLock = $null
if (-not [string]::IsNullOrWhiteSpace($SourceLockPath)) {
    $sourceOverrideParameters = @(
        "FarbotRepository", "RtlogRepository", "RttRepository",
        "Open62541Repository", "Open62541ppRepository", "RttOpcuaRepository",
        "OclRepository", "UtilmmRepository", "TypelibRepository",
        "RttTypelibRepository", "UtilrbRepository", "MetarubyRepository",
        "OrogenRepository", "VcpkgRepository", "FarbotRef", "RtlogRef",
        "RttRef", "Open62541Ref", "Open62541ppRef", "RttOpcuaRef",
        "OclRef", "UtilmmRef", "TypelibRef", "RttTypelibRef", "UtilrbRef",
        "MetarubyRef", "OrogenRef", "VcpkgRef"
    )
    $conflictingParameters = @(
        $sourceOverrideParameters | Where-Object { $BoundParameterNames -contains $_ }
    )
    if ($conflictingParameters.Count -gt 0) {
        throw "-SourceLockPath cannot be combined with source override parameter(s): $($conflictingParameters -join ', ')."
    }

    $SourceLockPath = Convert-ToFullPath $SourceLockPath
    . (Join-Path $PSScriptRoot "windows-source-lock.ps1")
    $SourceLock = Import-OrocosWindowsSourceLock -Path $SourceLockPath

    $FarbotRepository = $SourceLock["farbot"].repository
    $FarbotRef = $SourceLock["farbot"].revision
    $RtlogRepository = $SourceLock["rtlog-cpp"].repository
    $RtlogRef = $SourceLock["rtlog-cpp"].revision
    $RttRepository = $SourceLock["rtt"].repository
    $RttRef = $SourceLock["rtt"].revision
    $Open62541Repository = $SourceLock["open62541"].repository
    $Open62541Ref = $SourceLock["open62541"].revision
    $Open62541ppRepository = $SourceLock["open62541pp"].repository
    $Open62541ppRef = $SourceLock["open62541pp"].revision
    $RttOpcuaRepository = $SourceLock["rtt_opcua"].repository
    $RttOpcuaRef = $SourceLock["rtt_opcua"].revision
    $OclRepository = $SourceLock["ocl"].repository
    $OclRef = $SourceLock["ocl"].revision
    $UtilmmRepository = $SourceLock["utilmm"].repository
    $UtilmmRef = $SourceLock["utilmm"].revision
    $TypelibRepository = $SourceLock["typelib"].repository
    $TypelibRef = $SourceLock["typelib"].revision
    $RttTypelibRepository = $SourceLock["rtt_typelib"].repository
    $RttTypelibRef = $SourceLock["rtt_typelib"].revision
    $UtilrbRepository = $SourceLock["utilrb"].repository
    $UtilrbRef = $SourceLock["utilrb"].revision
    $MetarubyRepository = $SourceLock["metaruby"].repository
    $MetarubyRef = $SourceLock["metaruby"].revision
    $OrogenRepository = $SourceLock["orogen"].repository
    $OrogenRef = $SourceLock["orogen"].revision
    $VcpkgRepository = $SourceLock["vcpkg"].repository
    $VcpkgRef = $SourceLock["vcpkg"].revision

    Write-Host "Using Windows source lock: $SourceLockPath"
    foreach ($source in $SourceLock.Values) {
        Write-Host ("  {0,-13} {1}" -f $source.name, $source.revision)
    }
}

$Workspace = Convert-ToFullPath $Workspace
$Prefix = Convert-ToFullPath $Prefix
$VcpkgRoot = Convert-ToFullPath $VcpkgRoot
$FarbotRepository = Resolve-GitRepository $FarbotRepository
$RtlogRepository = Resolve-GitRepository $RtlogRepository
$RttRepository = Resolve-GitRepository $RttRepository
$Open62541Repository = Resolve-GitRepository $Open62541Repository
$Open62541ppRepository = Resolve-GitRepository $Open62541ppRepository
$RttOpcuaRepository = Resolve-GitRepository $RttOpcuaRepository
$OclRepository = Resolve-GitRepository $OclRepository
$UtilmmRepository = Resolve-GitRepository $UtilmmRepository
$TypelibRepository = Resolve-GitRepository $TypelibRepository
$RttTypelibRepository = Resolve-GitRepository $RttTypelibRepository
$UtilrbRepository = Resolve-GitRepository $UtilrbRepository
$MetarubyRepository = Resolve-GitRepository $MetarubyRepository
$OrogenRepository = Resolve-GitRepository $OrogenRepository
$VcpkgRepository = Resolve-GitRepository $VcpkgRepository
$Platform = "x64"
$VcpkgTriplet = "x64-windows"
$IsVisualStudioGenerator = $Generator.StartsWith(
    "Visual Studio ",
    [StringComparison]::OrdinalIgnoreCase)
$IsMultiConfigurationGenerator = (
    $IsVisualStudioGenerator -or
    $Generator.Equals("Ninja Multi-Config", [StringComparison]::OrdinalIgnoreCase))
$CMakeGeneratorArguments = @("-G", $Generator)
if ($IsVisualStudioGenerator) {
    $CMakeGeneratorArguments += @("-A", $Platform)
}
$CMakeInstallTarget = if ($IsMultiConfigurationGenerator) {
    "INSTALL"
} else {
    "install"
}
$prefixForCMake = $Prefix -replace "\\", "/"
$rttDefaultPluginPath = if ($RelocatablePrefix) {
    "."
} else {
    "$prefixForCMake/lib/orocos"
}
$typelibDefaultPluginPath = if ($RelocatablePrefix) {
    "."
} else {
    "$prefixForCMake/lib/typelib"
}

$FarbotSource = Join-Path $Workspace "src\farbot"
$RtlogSource = Join-Path $Workspace "src\rtlog-cpp"
$RttSource = Join-Path $Workspace "src\rtt"
$Open62541Source = Join-Path $Workspace "src\open62541"
$Open62541ppSource = Join-Path $Workspace "src\open62541pp"
$RttOpcuaSource = Join-Path $Workspace "src\rtt_opcua"
$OclSource = Join-Path $Workspace "src\ocl"
$UtilmmSource = Join-Path $Workspace "src\utilmm"
$TypelibSource = Join-Path $Workspace "src\typelib"
$RttTypelibSource = Join-Path $Workspace "src\rtt_typelib"
$UtilrbSource = Join-Path $Workspace "src\utilrb"
$MetarubySource = Join-Path $Workspace "src\metaruby"
$OrogenSource = Join-Path $Workspace "src\orogen"
$FarbotBuild = Join-Path $Workspace "build\farbot"
$RtlogBuild = Join-Path $Workspace "build\rtlog-cpp"
$RttBuild = Join-Path $Workspace "build\rtt"
$Open62541Build = Join-Path $Workspace "build\open62541"
$Open62541ppBuild = Join-Path $Workspace "build\open62541pp"
$RttOpcuaBuild = Join-Path $Workspace "build\rtt_opcua"
$OclBuild = Join-Path $Workspace "build\ocl"
$UtilmmBuild = Join-Path $Workspace "build\utilmm"
$TypelibBuild = Join-Path $Workspace "build\typelib"
$RttTypelibBuild = Join-Path $Workspace "build\rtt_typelib"
$RttTypelibTestExecutable = if ($IsMultiConfigurationGenerator) {
    Join-Path $RttTypelibBuild "Release\get_marshaller_for_test.exe"
} else {
    Join-Path $RttTypelibBuild "get_marshaller_for_test.exe"
}
$GeneratorSmokeSource = Join-Path $Workspace "smoke\orogen"
$GeneratorSmokeBuild = Join-Path $Workspace "smoke\build"
$TypegenSmokeSource = Join-Path $Workspace "smoke\typegen"
$TypegenSmokeBuild = Join-Path $Workspace "smoke\typegen-build"
$PatchRoot = Join-Path $PSScriptRoot "windows-patches"

New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
New-Item -ItemType Directory -Force -Path $Prefix | Out-Null

$env:OROCOS_TARGET = "win32"
$env:VCPKG_ROOT = $VcpkgRoot
foreach ($name in @("VCPKG_DEFAULT_BINARY_CACHE", "VCPKG_DOWNLOADS")) {
    $configuredPath = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($configuredPath)) {
        continue
    }

    $resolvedPath = Convert-ToFullPath $configuredPath
    New-Item -ItemType Directory -Force -Path $resolvedPath | Out-Null
    [Environment]::SetEnvironmentVariable(
        $name,
        $resolvedPath,
        [EnvironmentVariableTarget]::Process)
}

Invoke-Step "Check out source repositories" {
    Sync-GitRepository -Repository $FarbotRepository -Ref $FarbotRef -Path $FarbotSource
    Sync-GitRepository -Repository $RtlogRepository -Ref $RtlogRef -Path $RtlogSource
    Sync-GitRepository -Repository $RttRepository -Ref $RttRef -Path $RttSource
    Sync-GitRepository -Repository $Open62541Repository -Ref $Open62541Ref -Path $Open62541Source
    Sync-GitRepository -Repository $Open62541ppRepository -Ref $Open62541ppRef -Path $Open62541ppSource
    Sync-GitRepository -Repository $RttOpcuaRepository -Ref $RttOpcuaRef -Path $RttOpcuaSource
    Sync-GitRepository -Repository $OclRepository -Ref $OclRef -Path $OclSource
    Sync-GitRepository -Repository $UtilmmRepository -Ref $UtilmmRef -Path $UtilmmSource
    Sync-GitRepository -Repository $TypelibRepository -Ref $TypelibRef -Path $TypelibSource
    Sync-GitRepository -Repository $RttTypelibRepository -Ref $RttTypelibRef -Path $RttTypelibSource
    Sync-GitRepository -Repository $UtilrbRepository -Ref $UtilrbRef -Path $UtilrbSource
    Sync-GitRepository -Repository $MetarubyRepository -Ref $MetarubyRef -Path $MetarubySource
    Sync-GitRepository -Repository $OrogenRepository -Ref $OrogenRef -Path $OrogenSource
}

Invoke-Step "Apply remaining Windows portability patches" {
    Apply-SourcePatch -Path $UtilrbSource -Patch (Join-Path $PatchRoot "utilrb-windows.patch")
    Apply-SourcePatch -Path $OrogenSource -Patch (Join-Path $PatchRoot "orogen-cross-volume-paths.patch")
}

Invoke-Step "Set up vcpkg" {
    Sync-GitRepository -Repository $VcpkgRepository -Ref $VcpkgRef -Path $VcpkgRoot
    if ($null -ne $SourceLock -or
        -not (Test-Path -LiteralPath (Join-Path $VcpkgRoot "vcpkg.exe"))) {
        Invoke-NativeWithRetry (Join-Path $VcpkgRoot "bootstrap-vcpkg.bat") -disableMetrics
    }
}

$VcpkgToolchain = Join-Path $VcpkgRoot "scripts\buildsystems\vcpkg.cmake"
$VcpkgInstalled = Join-Path $VcpkgRoot "installed\$VcpkgTriplet"
$VcpkgBin = Join-Path $VcpkgInstalled "bin"
$CMakeCompilerFlagArguments = @(
    Get-MsvcCompilerFlagArguments `
        -DependencyInclude (Join-Path $VcpkgInstalled "include") `
        -EnableExceptions:((-not $IsVisualStudioGenerator) -or $SuppressExternalWarnings) `
        -SuppressExternalWarnings:$SuppressExternalWarnings
)

Invoke-Step "Install vcpkg dependencies" {
    Invoke-NativeWithRetry (Join-Path $VcpkgRoot "vcpkg.exe") install `
        "boost-assign:${VcpkgTriplet}" `
        "boost-filesystem:${VcpkgTriplet}" `
        "boost-functional:${VcpkgTriplet}" `
        "boost-serialization:${VcpkgTriplet}" `
        "boost-thread:${VcpkgTriplet}" `
        "boost-uuid:${VcpkgTriplet}" `
        "boost-graph:${VcpkgTriplet}" `
        "boost-program-options:${VcpkgTriplet}" `
        "boost-regex:${VcpkgTriplet}" `
        "boost-test:${VcpkgTriplet}" `
        "libxml2:${VcpkgTriplet}" `
        "readline:${VcpkgTriplet}"
}

Invoke-Step "Configure farbot" {
    Invoke-Native cmake -S $FarbotSource -B $FarbotBuild @CMakeGeneratorArguments `
        @CMakeCompilerFlagArguments `
        -DCMAKE_INSTALL_PREFIX="$Prefix" `
        -DCMAKE_BUILD_TYPE=Release
}

Invoke-Step "Install farbot" {
    Invoke-Native cmake --build $FarbotBuild --config Release `
        --target $CMakeInstallTarget --parallel 4
}

Invoke-Step "Configure rtlog-cpp" {
    Invoke-Native cmake -S $RtlogSource -B $RtlogBuild @CMakeGeneratorArguments `
        @CMakeCompilerFlagArguments `
        -DCMAKE_PREFIX_PATH="$Prefix" `
        -DCMAKE_INSTALL_PREFIX="$Prefix" `
        -DRTLOG_BUILD_TESTS=OFF `
        -DCMAKE_BUILD_TYPE=Release
}

Invoke-Step "Install rtlog-cpp" {
    Invoke-Native cmake --build $RtlogBuild --config Release `
        --target $CMakeInstallTarget --parallel 4
}

Invoke-Step "Configure RTT" {
    Invoke-Native cmake -S $RttSource -B $RttBuild @CMakeGeneratorArguments `
        @CMakeCompilerFlagArguments `
        -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
        -DCMAKE_PREFIX_PATH="$Prefix;$VcpkgInstalled" `
        -DCMAKE_INSTALL_PREFIX="$Prefix" `
        -DOROCOS_TARGET=win32 `
        -DENABLE_CORBA=OFF `
        -DENABLE_TESTS=OFF `
        -DBUILD_TESTING=OFF `
        -DBUILD_DOCS=OFF `
        -DOROBLD_FORCE_TINY_DEMARSHALLER=ON `
        -DPLUGINS_ENABLE=ON `
        -DPLUGINS_ENABLE_MARSHALLING=ON `
        -DPLUGINS_ENABLE_TYPEKIT=ON `
        -DPLUGINS_ENABLE_SCRIPTING=ON `
        -DORO_OS_USE_BOOST_THREAD=ON `
        -DDEFAULT_PLUGIN_PATH="$rttDefaultPluginPath" `
        -DCMAKE_BUILD_TYPE=Release
}

Invoke-Step "Install RTT" {
    Invoke-Native cmake --build $RttBuild --config Release `
        --target $CMakeInstallTarget --parallel 4
}

Invoke-Step "Configure open62541" {
    Invoke-Native cmake -S $Open62541Source -B $Open62541Build @CMakeGeneratorArguments `
        @CMakeCompilerFlagArguments `
        -DCMAKE_INSTALL_PREFIX="$Prefix" `
        -DBUILD_SHARED_LIBS=ON `
        -DUA_NAMESPACE_ZERO=REDUCED `
        -DUA_ENABLE_PUBSUB=OFF `
        -DUA_ENABLE_PUBSUB_INFORMATIONMODEL=OFF `
        -DUA_BUILD_EXAMPLES=OFF `
        -DUA_BUILD_UNIT_TESTS=OFF `
        -DCMAKE_BUILD_TYPE=Release
}

Invoke-Step "Install open62541" {
    Invoke-Native cmake --build $Open62541Build --config Release `
        --target $CMakeInstallTarget --parallel 4
    Write-Open62541PkgConfig -PrefixPath $Prefix -Version $Open62541Version
}

Invoke-Step "Configure open62541pp" {
    Invoke-Native cmake -S $Open62541ppSource -B $Open62541ppBuild @CMakeGeneratorArguments `
        @CMakeCompilerFlagArguments `
        -DCMAKE_PREFIX_PATH="$Prefix" `
        -DCMAKE_INSTALL_PREFIX="$Prefix" `
        -DBUILD_SHARED_LIBS=ON `
        -DUAPP_INTERNAL_OPEN62541=OFF `
        -DUAPP_BUILD_TESTS=OFF `
        -DUAPP_BUILD_EXAMPLES=OFF `
        -DUAPP_BUILD_DOCUMENTATION=OFF `
        -DCMAKE_BUILD_TYPE=Release
}

Invoke-Step "Install open62541pp" {
    Invoke-Native cmake --build $Open62541ppBuild --config Release `
        --target $CMakeInstallTarget --parallel 4
}

Invoke-Step "Configure rtt_opcua" {
    Invoke-Native cmake -S $RttOpcuaSource -B $RttOpcuaBuild @CMakeGeneratorArguments `
        @CMakeCompilerFlagArguments `
        -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
        -DCMAKE_PREFIX_PATH="$Prefix;$VcpkgInstalled" `
        -DCMAKE_INSTALL_PREFIX="$Prefix" `
        -DOROCOS_TARGET=win32 `
        -DBUILD_TESTING=OFF `
        -DRTT_OPCUA_WARNINGS_AS_ERRORS=ON `
        -DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON `
        -DCMAKE_BUILD_TYPE=Release
}

Invoke-Step "Install rtt_opcua" {
    Invoke-Native cmake --build $RttOpcuaBuild --config Release `
        --target $CMakeInstallTarget --parallel 4
}

Invoke-Step "Configure OCL" {
    $env:PKG_CONFIG_PATH = Join-Path $Prefix "lib\pkgconfig"
    $env:PKG_CONFIG_LIBDIR = $env:PKG_CONFIG_PATH
    Invoke-Native cmake -S $OclSource -B $OclBuild @CMakeGeneratorArguments `
        @CMakeCompilerFlagArguments `
        -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
        -DCMAKE_PREFIX_PATH="$Prefix;$VcpkgInstalled" `
        -DCMAKE_INSTALL_PREFIX="$Prefix" `
        -DOROCOS_TARGET=win32 `
        -DBUILD_OPCUA=ON `
        -DENABLE_CORBA=OFF `
        -DBUILD_TESTING=OFF `
        -DBUILD_TESTS=OFF `
        -DBUILD_DOCS=OFF `
        -DBUILD_TASKBROWSER=ON `
        -DNO_GPL=OFF `
        -DBUILD_DEPLOYMENT=ON `
        -DBUILD_REPORTING=ON `
        -DBUILD_REPORTING_NETCDF=OFF `
        -DBUILD_LUA_RTT=OFF `
        -DBUILD_TIMER=ON `
        -DBUILD_LOGGING=OFF `
        -DCMAKE_BUILD_TYPE=Release

    if (-not (Select-String -LiteralPath (Join-Path $OclBuild "CMakeCache.txt") `
            -Pattern '^READLINE:INTERNAL=1$' -Quiet)) {
        throw "OCL did not enable required readline support"
    }
}

Invoke-Step "Build OCL deployer tools" {
    Invoke-Native cmake --build $OclBuild --config Release `
        --target deployer rttscript deployer-opcua ctaskbrowser-opcua --parallel 4
}

Invoke-Step "Install OCL" {
    Invoke-Native cmake --build $OclBuild --config Release `
        --target $CMakeInstallTarget --parallel 4
}

Invoke-Step "Configure utilmm" {
    Invoke-Native cmake -S $UtilmmSource -B $UtilmmBuild @CMakeGeneratorArguments `
        @CMakeCompilerFlagArguments `
        -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
        -DCMAKE_PREFIX_PATH="$Prefix;$VcpkgInstalled" `
        -DCMAKE_INSTALL_PREFIX="$Prefix" `
        -DENABLE_TESTS=OFF `
        -DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON `
        -DCMAKE_BUILD_TYPE=Release
}

Invoke-Step "Install utilmm" {
    Invoke-Native cmake --build $UtilmmBuild --config Release `
        --target $CMakeInstallTarget --parallel 4
}

Invoke-Step "Configure Typelib" {
    $env:PKG_CONFIG_PATH = Join-Path $Prefix "lib\pkgconfig"
    $env:PKG_CONFIG_LIBDIR = $env:PKG_CONFIG_PATH
    Invoke-Native cmake -S $TypelibSource -B $TypelibBuild @CMakeGeneratorArguments `
        @CMakeCompilerFlagArguments `
        -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
        -DCMAKE_PREFIX_PATH="$Prefix;$VcpkgInstalled" `
        -DCMAKE_INSTALL_PREFIX="$Prefix" `
        -DBUILD_CLANG_TLB_IMPORTER=OFF `
        -DBUILD_TESTING=OFF `
        -DBUILD_TESTS=OFF `
        -DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON `
        -DTYPELIB_HARDCODED_PLUGIN_PATH="$typelibDefaultPluginPath" `
        -DCMAKE_BUILD_TYPE=Release
}

Invoke-Step "Install Typelib" {
    Invoke-Native cmake --build $TypelibBuild --config Release `
        --target $CMakeInstallTarget --parallel 4
}

Invoke-Step "Configure rtt_typelib" {
    $env:PKG_CONFIG_PATH = Join-Path $Prefix "lib\pkgconfig"
    $env:PKG_CONFIG_LIBDIR = $env:PKG_CONFIG_PATH
    Invoke-Native cmake -S $RttTypelibSource -B $RttTypelibBuild @CMakeGeneratorArguments `
        @CMakeCompilerFlagArguments `
        -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
        -DCMAKE_PREFIX_PATH="$Prefix;$VcpkgInstalled" `
        -DCMAKE_INSTALL_PREFIX="$Prefix" `
        -DOROCOS_TARGET=win32 `
        -DBUILD_TESTING=ON `
        -DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON `
        -DCMAKE_BUILD_TYPE=Release
}

Invoke-Step "Install rtt_typelib" {
    Invoke-Native cmake --build $RttTypelibBuild --config Release `
        --target $CMakeInstallTarget --parallel 4
}

Invoke-Step "Install Ruby generator tools" {
    $rubyToolArguments = @{
        Prefix = $Prefix
        UtilrbSource = $UtilrbSource
        MetarubySource = $MetarubySource
        OrogenSource = $OrogenSource
    }
    if (-not [string]::IsNullOrWhiteSpace($RubyGemCache)) {
        $rubyToolArguments.GemCache = $RubyGemCache
    }
    & (Join-Path $PSScriptRoot "install-ruby-tools.ps1") `
        @rubyToolArguments
}

Invoke-Step "Export Windows environments" {
    & (Join-Path $PSScriptRoot "export-windows-env.ps1") `
        -Prefix $Prefix `
        -VcpkgRoot $VcpkgRoot `
        -VcpkgTriplet $VcpkgTriplet `
        -Target win32
}

if (-not $SkipGeneratorSmokeTests) {
    Invoke-Step "Generate Windows OroGen smoke project" {
        New-Item -ItemType Directory -Force -Path $GeneratorSmokeSource | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "windows-generator-smoke\WindowsSmokeTypes.hpp") `
            -Destination $GeneratorSmokeSource -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "windows-generator-smoke\windows_smoke.orogen") `
            -Destination $GeneratorSmokeSource -Force

        . (Join-Path $Prefix "dev-env.ps1")
        Push-Location $GeneratorSmokeSource
        try {
            Invoke-Native $RubyExecutable `
                (Join-Path $Prefix "toolchain\bin\orogen") `
                --target=win32 --transports=typelib windows_smoke.orogen
        } finally {
            Pop-Location
        }
    }

    Invoke-Step "Build Windows OroGen smoke project" {
        Invoke-Native cmake -S $GeneratorSmokeSource -B $GeneratorSmokeBuild `
            @CMakeGeneratorArguments `
            @CMakeCompilerFlagArguments `
            -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
            -DCMAKE_PREFIX_PATH="$Prefix;$VcpkgInstalled" `
            -DCMAKE_INSTALL_PREFIX="$Prefix" `
            -DCMAKE_BUILD_TYPE=Release
        Invoke-Native cmake --build $GeneratorSmokeBuild --config Release `
            --target $CMakeInstallTarget --parallel 4
    }

    Invoke-Step "Generate Windows Typegen smoke project" {
        New-Item -ItemType Directory -Force -Path $TypegenSmokeSource | Out-Null
        $typegenSmokeHeader = Join-Path $TypegenSmokeSource `
            "WindowsTypegenTypes.hpp"
        Copy-Item -LiteralPath `
            (Join-Path $PSScriptRoot "windows-generator-smoke\WindowsTypegenTypes.hpp") `
            -Destination $typegenSmokeHeader -Force
        . (Join-Path $Prefix "dev-env.ps1")
        Push-Location $TypegenSmokeSource
        try {
            Invoke-Native $RubyExecutable `
                (Join-Path $Prefix "toolchain\bin\typegen") `
                --transports=typelib `
                --output=$TypegenSmokeSource `
                windows_typegen_smoke `
                $typegenSmokeHeader
        } finally {
            Pop-Location
        }
    }

    Invoke-Step "Build Windows Typegen smoke project" {
        . (Join-Path $Prefix "dev-env.ps1")
        Invoke-Native cmake -S $TypegenSmokeSource -B $TypegenSmokeBuild `
            @CMakeGeneratorArguments `
            @CMakeCompilerFlagArguments `
            -DCMAKE_TOOLCHAIN_FILE="$VcpkgToolchain" `
            -DCMAKE_PREFIX_PATH="$Prefix;$VcpkgInstalled" `
            -DCMAKE_INSTALL_PREFIX="$Prefix" `
            -DCMAKE_BUILD_TYPE=Release
        $savedPath = $env:PATH
        try {
            $generatorCommandDirectories = @(
                (Join-Path $Prefix "toolchain\bin"),
                (Split-Path -Parent $RubyExecutable)
            )
            $env:PATH = @(
                $env:PATH -split ";" | Where-Object {
                    $generatorCommandDirectories -notcontains $_
                }
            ) -join ";"
            Invoke-Native cmake --build $TypegenSmokeBuild --config Release `
                --target regen
        } finally {
            $env:PATH = $savedPath
        }
        Invoke-Native cmake --build $TypegenSmokeBuild --config Release `
            --target $CMakeInstallTarget --parallel 4
    }
} else {
    Write-Host "Skipping workspace generator smoke tests; package acceptance tests cover the packaged generators."
}

Invoke-Step "Validate Windows prefix" {
    $requiredArtifacts = @(
        "bin\orocos-rtt-win32.dll",
        "bin\orocos-rtt-opcua-win32.dll",
        "bin\open62541.dll",
        "bin\open62541pp.dll",
        "bin\deployer-win32.exe",
        "bin\rttscript-win32.exe",
        "bin\deployer-opcua-win32.exe",
        "bin\ctaskbrowser-opcua-win32.exe",
        "bin\orocos-ocl-deployment-opcua-win32.dll",
        "bin\orocos-ocl-taskbrowser-win32.dll",
        "bin\utilmm.dll",
        "bin\typeLib.dll",
        "bin\rtt-typelib-win32.dll",
        "lib\cmake\farbot\farbotConfig.cmake",
        "lib\cmake\rtlog\rtlogConfig.cmake",
        "lib\utilmm.lib",
        "lib\typeLib.lib",
        "lib\rtt-typelib-win32.lib",
        "lib\typelib\typeLang_cSupport.dll",
        "lib\orocos\win32\plugins\rtt-scripting-win32.dll",
        "lib\orocos\win32\types\rtt-typekit-win32.dll",
        "lib\orocos\win32\rtt_opcua\plugins\rtt-transport-opcua-win32.dll",
        "lib\pkgconfig\open62541.pc",
        "lib\pkgconfig\rtt_opcua-win32.pc",
        "lib\pkgconfig\typelib.pc",
        "lib\pkgconfig\typelib_ruby.pc",
        "lib\pkgconfig\rtt_typelib-win32.pc",
        "toolchain\bin\orogen.bat",
        "toolchain\bin\typegen.bat",
        "env.ps1",
        "env.bat",
        "dev-env.ps1"
    )
    if (-not $SkipGeneratorSmokeTests) {
        $requiredArtifacts += @(
            "bin\windows_smoke_deployer.exe",
            "lib\orocos\windows_smoke-tasks-win32.dll",
            "lib\orocos\types\windows_smoke-typekit-win32.dll",
            "lib\orocos\types\windows_smoke-transport-typelib-win32.dll",
            "lib\orocos\types\windows_typegen_smoke-typekit-win32.dll",
            "lib\orocos\types\windows_typegen_smoke-transport-typelib-win32.dll",
            "lib\pkgconfig\windows_typegen_smoke-typekit-win32.pc",
            "lib\pkgconfig\windows_typegen_smoke-transport-typelib-win32.pc",
            "share\orogen\windows_smoke.orogen",
            "share\orogen\windows_typegen_smoke.tlb"
        )
    }

    foreach ($artifact in $requiredArtifacts) {
        $path = Join-Path $Prefix $artifact
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Missing expected artifact: $path"
        }
    }

    . (Join-Path $Prefix "dev-env.ps1")
    if ($env:OROCOS_PREFIX -ne $Prefix -or $env:OROCOS_TARGET -ne "win32") {
        throw "Windows environment scripts exported the wrong Orocos prefix or target"
    }
    if (($env:PATH -split ";") -notcontains $VcpkgBin) {
        throw "Windows environment scripts did not add the vcpkg runtime directory"
    }
    if (($env:CMAKE_PREFIX_PATH -split ";") -notcontains $VcpkgInstalled) {
        throw "Windows development environment did not add the vcpkg prefix"
    }
    if (($env:PATH -split ";") -notcontains (Join-Path $Prefix "toolchain\bin")) {
        throw "Windows development environment did not add the generator commands"
    }
    if (($env:PATH -split ";") -notcontains (Split-Path -Parent $RubyExecutable)) {
        throw "Windows development environment did not retain the active Ruby runtime"
    }
    if ($env:GEM_HOME -ne (Join-Path $Prefix "toolchain\gems")) {
        throw "Windows development environment exported the wrong Ruby gem home"
    }
    if (($env:TYPELIB_PLUGIN_PATH -split ";") -notcontains `
            (Join-Path $Prefix "lib\typelib")) {
        throw "Windows environment did not add the Typelib plugin directory"
    }
    $readlineRuntime = Join-Path $VcpkgBin "readline.dll"
    if (-not (Test-Path -LiteralPath $readlineRuntime -PathType Leaf)) {
        throw "Missing readline runtime: $readlineRuntime"
    }
    $opcuaPluginDirectory = Join-Path $Prefix "lib\orocos\win32\rtt_opcua\plugins"
    if (($env:RTT_COMPONENT_PATH -split ";") -notcontains $opcuaPluginDirectory) {
        throw "Windows runtime environment did not add the OPC UA plugin directory"
    }
    $componentPathEntries = @($env:RTT_COMPONENT_PATH -split ";")
    if ($componentPathEntries[0] -ne (Join-Path $Prefix "lib\orocos\win32")) {
        throw "Windows runtime environment must load the core RTT typekit first"
    }

    Invoke-Native $RttTypelibTestExecutable

    $orogenVersionOutput = Get-NativeOutput `
        $RubyExecutable `
        (Join-Path $Prefix "toolchain\bin\orogen") --version
    if ($orogenVersionOutput -notmatch "orogen") {
        throw "Installed orogen --version did not print the expected output"
    }

    $typegenHelpOutput = Get-NativeOutput `
        $RubyExecutable `
        (Join-Path $Prefix "toolchain\bin\typegen") --help
    if ($typegenHelpOutput -notmatch "Usage:") {
        throw "Installed typegen --help did not print the expected output"
    }

    if (-not $SkipGeneratorSmokeTests) {
        Invoke-Native $RubyExecutable `
            (Join-Path $PSScriptRoot "windows-generator-smoke\validate.rb") `
            (Join-Path $GeneratorSmokeSource "WindowsSmokeTypes.hpp")

        Invoke-Native (Join-Path $Prefix "bin\deployer-win32.exe") `
            --check --no-consolelog `
            (Join-Path $PSScriptRoot "windows-generator-smoke\typegen-import.ops")

        $smokeDeployerHelp = Get-NativeOutput `
            (Join-Path $Prefix "bin\windows_smoke_deployer.exe") --help
        if ($smokeDeployerHelp -notmatch "Options") {
            throw "Generated Windows deployer --help did not print the expected output"
        }
        Invoke-Native (Join-Path $Prefix "bin\windows_smoke_deployer.exe")
    }

    $deployerVersionOutput = Get-NativeOutput (Join-Path $Prefix "bin\deployer-win32.exe") --version
    if ($deployerVersionOutput -notmatch "OROCOS Toolchain version") {
        throw "deployer-win32.exe --version did not print the expected version output"
    }

    $deployerOpcuaHelp = Get-NativeOutput (Join-Path $Prefix "bin\deployer-opcua-win32.exe") --help
    if ($deployerOpcuaHelp -notmatch "OPC UA options") {
        throw "deployer-opcua-win32.exe --help did not expose OPC UA options"
    }

    $taskBrowserOpcuaHelp = Get-NativeOutput (Join-Path $Prefix "bin\ctaskbrowser-opcua-win32.exe") --help
    if ($taskBrowserOpcuaHelp -notmatch "--import PACKAGE") {
        throw "ctaskbrowser-opcua-win32.exe --help did not expose the OPC UA client CLI"
    }

    $taskBrowserDependencies = Get-NativeOutput dumpbin.exe /DEPENDENTS `
        (Join-Path $Prefix "bin\orocos-ocl-taskbrowser-win32.dll")
    if ($taskBrowserDependencies -notmatch "(?im)^\s*readline\.dll\s*$") {
        throw "Installed TaskBrowser is not linked to readline.dll"
    }

    Invoke-Native (Join-Path $Prefix "bin\deployer-win32.exe") --check --no-consolelog
    Invoke-Native (Join-Path $Prefix "bin\rttscript-win32.exe") --check --no-consolelog
    Invoke-Native (Join-Path $Prefix "bin\deployer-opcua-win32.exe") --check --no-consolelog
    $opcuaStartOutput = Get-NativeOutput `
        (Join-Path $Prefix "bin\deployer-opcua-win32.exe") `
        --opcua-port 4841 --check `
        (Join-Path $PSScriptRoot "windows-opcua-start-smoke.ops")
    if ($opcuaStartOutput -notmatch "Starting the EventLoop" -or
        $opcuaStartOutput -match "\[\s*ERROR\s*\]") {
        throw "OPC UA startup smoke check failed:`n$opcuaStartOutput"
    }
}
