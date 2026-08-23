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

$activationHookDirectory = Join-Path $env:PREFIX "etc\conda\activate.d"
New-Item -ItemType Directory -Force -Path $activationHookDirectory | Out-Null
Copy-Item -LiteralPath $activationHookSource `
    -Destination (Join-Path $activationHookDirectory "orocos-activate.bat") `
    -Force
