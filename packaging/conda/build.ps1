Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($name in @(
        "PREFIX",
        "LIBRARY_PREFIX",
        "RECIPE_DIR",
        "SRC_DIR",
        "BUILD_PREFIX",
        "SUBDIR"
    )) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Rattler-Build did not provide the required $name environment variable."
    }
}

if ($env:SUBDIR -ne "win-64") {
    throw "The initial Orocos package supports only win-64, not '$($env:SUBDIR)'."
}

$repositoryRoot = (Resolve-Path -LiteralPath $env:SRC_DIR).Path
$sourceLockPath = Join-Path $repositoryRoot "packaging\source-lock.json"
$sourceLockHelper = Join-Path $repositoryRoot "tools\windows-source-lock.ps1"
if (-not (Test-Path -LiteralPath $sourceLockHelper -PathType Leaf)) {
    throw "Missing Windows source-lock helper: $sourceLockHelper"
}

. $sourceLockHelper
$sourceLock = Import-OrocosWindowsSourceLock -Path $sourceLockPath

$temporaryParent = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path
$temporaryRoot = Join-Path $temporaryParent `
    ("orocos-rb-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$workspace = Join-Path $temporaryRoot "b"
$configuredVcpkgRoot = [Environment]::GetEnvironmentVariable(
    "OROCOS_VCPKG_ROOT",
    [EnvironmentVariableTarget]::Process)
if ([string]::IsNullOrWhiteSpace($configuredVcpkgRoot)) {
    $vcpkgRoot = Join-Path $temporaryRoot "v"
} else {
    if (-not [IO.Path]::IsPathRooted($configuredVcpkgRoot)) {
        throw "OROCOS_VCPKG_ROOT must be an absolute path."
    }
    $vcpkgRoot = [IO.Path]::GetFullPath($configuredVcpkgRoot)
    Write-Host "Using persistent vcpkg root: $vcpkgRoot"
}
$temporaryProfile = Join-Path $temporaryRoot "p"
$temporaryLocalAppData = Join-Path $temporaryProfile "AppData\Local"
$temporaryAppData = Join-Path $temporaryProfile "AppData\Roaming"
$builder = Join-Path $repositoryRoot "tools\build-windows-msvc.ps1"
$profileEnvironmentNames = @(
    "USERPROFILE",
    "LOCALAPPDATA",
    "APPDATA",
    "PSModuleAnalysisCachePath",
    "VCPKG_DEFAULT_BINARY_CACHE",
    "VCPKG_DOWNLOADS"
)
$savedProfileEnvironment = @{}
foreach ($name in $profileEnvironmentNames) {
    $savedProfileEnvironment[$name] = [Environment]::GetEnvironmentVariable(
        $name,
        [EnvironmentVariableTarget]::Process)
}

New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
New-Item -ItemType Directory -Path $temporaryLocalAppData | Out-Null
New-Item -ItemType Directory -Path $temporaryAppData | Out-Null
$hostLocalAppData = $savedProfileEnvironment["LOCALAPPDATA"]
if ([string]::IsNullOrWhiteSpace($hostLocalAppData)) {
    throw "LOCALAPPDATA must identify the persistent vcpkg cache root."
}
$vcpkgCacheRoot = Join-Path $hostLocalAppData "vcpkg"
$vcpkgBinaryCache = Join-Path $vcpkgCacheRoot "archives"
$vcpkgDownloads = Join-Path $vcpkgCacheRoot "downloads"
New-Item -ItemType Directory -Force -Path $vcpkgBinaryCache | Out-Null
New-Item -ItemType Directory -Force -Path $vcpkgDownloads | Out-Null
$env:USERPROFILE = $temporaryProfile
$env:LOCALAPPDATA = $temporaryLocalAppData
$env:APPDATA = $temporaryAppData
$env:PSModuleAnalysisCachePath = Join-Path $temporaryRoot "ModuleAnalysisCache"
if ([string]::IsNullOrWhiteSpace(
        $savedProfileEnvironment["VCPKG_DEFAULT_BINARY_CACHE"])) {
    $env:VCPKG_DEFAULT_BINARY_CACHE = $vcpkgBinaryCache
}
if ([string]::IsNullOrWhiteSpace(
        $savedProfileEnvironment["VCPKG_DOWNLOADS"])) {
    $env:VCPKG_DOWNLOADS = $vcpkgDownloads
}
try {
    & $builder `
        -Workspace $workspace `
        -Prefix $env:LIBRARY_PREFIX `
        -VcpkgRoot $vcpkgRoot `
        -SourceLockPath $sourceLockPath `
        -RubyGemCache (Join-Path $repositoryRoot ".ruby-gems") `
        -RelocatablePrefix `
        -SuppressExternalWarnings `
        -Generator Ninja `
        -SkipGeneratorSmokeTests

    & (Join-Path $repositoryRoot "packaging\conda\prepare-prefix.ps1") `
        -Prefix $env:LIBRARY_PREFIX `
        -Workspace $workspace `
        -VcpkgRoot $vcpkgRoot `
        -RepositoryRoot $repositoryRoot

    if (-not [string]::IsNullOrWhiteSpace($configuredVcpkgRoot)) {
        Set-Content `
            -LiteralPath (Join-Path $vcpkgRoot ".orocos-package-cache-ready") `
            -Value "ready" `
            -NoNewline
    }
} finally {
    foreach ($name in $profileEnvironmentNames) {
        $savedValue = $savedProfileEnvironment[$name]
        if ($null -eq $savedValue) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $null,
                [EnvironmentVariableTarget]::Process)
        } else {
            [Environment]::SetEnvironmentVariable(
                $name,
                $savedValue,
                [EnvironmentVariableTarget]::Process)
        }
    }

    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        $resolvedTemporaryRoot = (Resolve-Path -LiteralPath $temporaryRoot).Path
        $expectedPrefix = $temporaryParent.TrimEnd("\") + "\orocos-rb-"
        if (-not $resolvedTemporaryRoot.StartsWith(
                $expectedPrefix,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected temporary path: $resolvedTemporaryRoot"
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}

Write-Host "Staged relocatable Orocos prefix from $($sourceLock.Count) locked sources."
