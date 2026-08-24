Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($name in @("PREFIX", "SRC_DIR")) {
    if ([string]::IsNullOrWhiteSpace(
            [Environment]::GetEnvironmentVariable($name))) {
        throw "Rattler-Build did not provide the required $name environment variable."
    }
}

$activationHookSource = Join-Path $env:SRC_DIR "packaging\conda\orocos-activate.bat"
if (-not (Test-Path -LiteralPath $activationHookSource -PathType Leaf)) {
    throw "Missing Windows runtime activation hook: $activationHookSource"
}
$deactivationHookSource = Join-Path $env:SRC_DIR "packaging\conda\orocos-deactivate.bat"
if (-not (Test-Path -LiteralPath $deactivationHookSource -PathType Leaf)) {
    throw "Missing Windows runtime deactivation hook: $deactivationHookSource"
}

$activationHookDirectory = Join-Path $env:PREFIX "etc\conda\activate.d"
New-Item -ItemType Directory -Force -Path $activationHookDirectory | Out-Null
Copy-Item -LiteralPath $activationHookSource `
    -Destination (Join-Path $activationHookDirectory "orocos-activate.bat") `
    -Force

$deactivationHookDirectory = Join-Path $env:PREFIX "etc\conda\deactivate.d"
New-Item -ItemType Directory -Force -Path $deactivationHookDirectory | Out-Null
Copy-Item -LiteralPath $deactivationHookSource `
    -Destination (Join-Path $deactivationHookDirectory "orocos-deactivate.bat") `
    -Force
