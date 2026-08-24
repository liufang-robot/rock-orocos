Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$condaPrefix = if ($env:PREFIX) { $env:PREFIX } else { $env:CONDA_PREFIX }
if ([string]::IsNullOrWhiteSpace($condaPrefix)) {
    throw "Neither PREFIX nor CONDA_PREFIX identifies the package test environment."
}

$libraryPrefix = if ($env:LIBRARY_PREFIX) {
    $env:LIBRARY_PREFIX
} else {
    Join-Path $condaPrefix "Library"
}

$developmentEnvironment = Join-Path $libraryPrefix "dev-env.ps1"
if (-not (Test-Path -LiteralPath $developmentEnvironment -PathType Leaf)) {
    throw "The orocos-dev package did not install dev-env.ps1 at $developmentEnvironment"
}

. $developmentEnvironment

function Invoke-Native {
    $executable = $args[0]
    $arguments = @()
    if ($args.Count -gt 1) {
        $arguments = $args[1..($args.Count - 1)]
    }
    & $executable @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$executable failed with exit code $LASTEXITCODE."
    }
}

function Get-MsvcExternalWarningArguments {
    param([string]$DependencyInclude)

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
    $externalFlags = $externalOptions -join " "
    $cxxFlags = (@("/EHsc") + $externalOptions) -join " "

    @(
        "-DCMAKE_C_FLAGS=$externalFlags",
        "-DCMAKE_CXX_FLAGS=$cxxFlags"
    )
}

if (-not [string]::IsNullOrWhiteSpace($env:VCPKG_ROOT)) {
    throw "The packaged development environment must not require VCPKG_ROOT."
}
$bundledVcpkg = Join-Path $libraryPrefix "vcpkg"
if (($env:CMAKE_PREFIX_PATH -split [IO.Path]::PathSeparator) -notcontains $bundledVcpkg) {
    throw "The packaged development environment did not expose its bundled SDK."
}
$externalWarningArguments = @(
    Get-MsvcExternalWarningArguments `
        -DependencyInclude (Join-Path $bundledVcpkg "include")
)

$orogen = (Get-Command "orogen" -ErrorAction Stop).Source
$typegen = (Get-Command "typegen" -ErrorAction Stop).Source
Invoke-Native $orogen --version
Invoke-Native $typegen --help

$generator = if ([string]::IsNullOrWhiteSpace($env:CMAKE_GENERATOR)) {
    "Visual Studio 17 2022"
} else {
    $env:CMAKE_GENERATOR
}
$testDataRoot = Join-Path (Get-Location).Path "test-data"
if (-not (Test-Path -LiteralPath $testDataRoot -PathType Container)) {
    throw "Rattler Build did not stage the recipe test data at $testDataRoot"
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("orocos-package-dev-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $orogenSource = Join-Path $testRoot "orogen"
    $orogenBuild = Join-Path $testRoot "orogen-build"
    $orogenInstall = Join-Path $testRoot "orogen-install"
    New-Item -ItemType Directory -Path $orogenSource | Out-Null
    Copy-Item -LiteralPath (Join-Path $testDataRoot "PackageSmokeTypes.hpp") `
        -Destination $orogenSource
    Copy-Item -LiteralPath (Join-Path $testDataRoot "package_smoke.orogen") `
        -Destination $orogenSource

    Push-Location $orogenSource
    try {
        Invoke-Native $orogen --target=win32 --transports=typelib package_smoke.orogen
    } finally {
        Pop-Location
    }

    Invoke-Native cmake -S $orogenSource -B $orogenBuild `
        -G $generator -A x64 `
        @externalWarningArguments `
        "-DCMAKE_PREFIX_PATH=$libraryPrefix;$bundledVcpkg" `
        "-DCMAKE_INSTALL_PREFIX=$orogenInstall" `
        -DCMAKE_BUILD_TYPE=Release
    Invoke-Native cmake --build $orogenBuild --config Release `
        --target INSTALL --parallel 4

    $typegenSource = Join-Path $testRoot "typegen"
    $typegenBuild = Join-Path $testRoot "typegen-build"
    $typegenInstall = Join-Path $testRoot "typegen-install"
    $typegenInput = Join-Path $testRoot "PackageTypegenTypes.hpp"
    Copy-Item -LiteralPath `
        (Join-Path $testDataRoot "PackageTypegenTypes.hpp") `
        -Destination $typegenInput
    Push-Location $testRoot
    try {
        Invoke-Native $typegen `
            --transports=typelib `
            "--output=$typegenSource" `
            package_typegen_smoke `
            $typegenInput
    } finally {
        Pop-Location
    }
    Invoke-Native cmake -S $typegenSource -B $typegenBuild `
        -G $generator -A x64 `
        @externalWarningArguments `
        "-DCMAKE_PREFIX_PATH=$libraryPrefix;$bundledVcpkg" `
        "-DCMAKE_INSTALL_PREFIX=$typegenInstall" `
        -DCMAKE_BUILD_TYPE=Release
    Invoke-Native cmake --build $typegenBuild --config Release --target regen
    Invoke-Native cmake --build $typegenBuild --config Release `
        --target INSTALL --parallel 4

    foreach ($artifact in @(
            (Join-Path $orogenInstall "bin\package_smoke_deployer.exe"),
            (Join-Path $typegenInstall "lib\orocos\types\package_typegen_smoke-typekit-win32.dll"),
            (Join-Path $typegenInstall "lib\orocos\types\package_typegen_smoke-transport-typelib-win32.dll")
        )) {
        if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
            throw "The clean downstream build did not produce $artifact"
        }
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
