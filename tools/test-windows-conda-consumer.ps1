[CmdletBinding(DefaultParameterSetName = "Remote")]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [Parameter(Mandatory = $true, ParameterSetName = "Local")]
    [string]$LocalChannelPath,
    [Parameter(Mandatory = $true, ParameterSetName = "Remote")]
    [string]$ChannelUrl,
    [ValidateRange(1, 20)]
    [int]$Attempts = 1,
    [ValidateRange(1, 60)]
    [int]$RetryDelaySeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command pixi -ErrorAction SilentlyContinue)) {
    throw "pixi is required for the clean package consumer checks."
}
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Release manifest does not exist: $ManifestPath"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$packages = @($manifest.packages)
$runtimeMatches = @($packages | Where-Object { [string]$_.name -ceq "orocos" })
$developmentMatches = @($packages | Where-Object { [string]$_.name -ceq "orocos-dev" })
if ($runtimeMatches.Count -ne 1 -or $developmentMatches.Count -ne 1) {
    throw "Release manifest must contain one orocos and one orocos-dev package."
}

$runtime = $runtimeMatches[0]
$development = $developmentMatches[0]
$runtimeSpec = "orocos==$($runtime.version)=$($runtime.build)"
$developmentSpec = "orocos-dev==$($development.version)=$($development.build)"

if ($PSCmdlet.ParameterSetName -eq "Local") {
    if (-not (Test-Path -LiteralPath $LocalChannelPath -PathType Container)) {
        throw "Local channel does not exist: $LocalChannelPath"
    }
    $resolvedChannel = (Resolve-Path -LiteralPath $LocalChannelPath).Path
    $channel = ([System.Uri]$resolvedChannel).AbsoluteUri.TrimEnd("/")
}
else {
    $channelUri = [System.Uri]$ChannelUrl
    if (-not $channelUri.IsAbsoluteUri -or $channelUri.Scheme -notin @("http", "https")) {
        throw "Remote channel must be an absolute HTTP(S) URL: $ChannelUrl"
    }
    $channel = $ChannelUrl.TrimEnd("/")
}

$activationScript = (
    Resolve-Path -LiteralPath (
        Join-Path $PSScriptRoot "..\examples\pixi-consumer\scripts\activate-orocos.ps1"
    )
).Path

$runtimeCommand = @'
& {
    $ErrorActionPreference = "Stop"
    . $env:OROCOS_PIXI_ACTIVATION_SCRIPT
    $developmentHeader = Join-Path $env:CONDA_PREFIX 'Library\include\orocos\rtt\RTT.hpp'
    if (Test-Path -LiteralPath $developmentHeader) {
        throw 'The runtime-only environment unexpectedly contains development headers.'
    }
    deployer-opcua-win32.exe --check --no-consolelog
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
'@

$developmentCommand = @'
& {
    $ErrorActionPreference = "Stop"
    . $env:OROCOS_PIXI_ACTIVATION_SCRIPT
    $developmentHeader = Join-Path $env:CONDA_PREFIX 'Library\include\orocos\rtt\RTT.hpp'
    if (-not (Test-Path -LiteralPath $developmentHeader -PathType Leaf)) {
        throw 'The development environment is missing the RTT headers.'
    }
    orogen --version
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    typegen --help
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    deployer-opcua-win32.exe --check --no-consolelog
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
'@

function Invoke-PixiConsumer {
    param(
        [Parameter(Mandatory = $true)][string]$Spec,
        [Parameter(Mandatory = $true)][string]$Command
    )

    $arguments = @(
        "exec",
        "--force-reinstall",
        "--spec", $Spec,
        "--channel", $channel,
        "--channel", "conda-forge",
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-Command", $Command
    )
    & pixi @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Clean consumer command for '$Spec' failed with exit code $LASTEXITCODE."
    }
}

$cacheParent = if ($env:RUNNER_TEMP) {
    $env:RUNNER_TEMP
}
else {
    [System.IO.Path]::GetTempPath()
}
$cacheRoot = Join-Path $cacheParent ("orocos-package-consumer-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $cacheRoot | Out-Null
$previousCache = [Environment]::GetEnvironmentVariable("PIXI_CACHE_DIR", "Process")
$previousActivationScript = [Environment]::GetEnvironmentVariable(
    "OROCOS_PIXI_ACTIVATION_SCRIPT",
    "Process"
)
$env:OROCOS_PIXI_ACTIVATION_SCRIPT = $activationScript

try {
    for ($attempt = 1; $attempt -le $Attempts; $attempt += 1) {
        try {
            $env:PIXI_CACHE_DIR = Join-Path $cacheRoot "attempt-$attempt"
            New-Item -ItemType Directory -Path $env:PIXI_CACHE_DIR | Out-Null
            Write-Host "Testing package consumers from $channel (attempt $attempt of $Attempts)."
            Invoke-PixiConsumer -Spec $runtimeSpec -Command $runtimeCommand
            Invoke-PixiConsumer -Spec $developmentSpec -Command $developmentCommand
            Write-Host "Clean runtime and development consumer checks passed."
            return
        }
        catch {
            if ($attempt -eq $Attempts) {
                throw
            }
            Write-Warning "$($_.Exception.Message) Retrying after $RetryDelaySeconds seconds."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}
finally {
    if ($null -eq $previousCache) {
        Remove-Item Env:PIXI_CACHE_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:PIXI_CACHE_DIR = $previousCache
    }
    if ($null -eq $previousActivationScript) {
        Remove-Item Env:OROCOS_PIXI_ACTIVATION_SCRIPT -ErrorAction SilentlyContinue
    }
    else {
        $env:OROCOS_PIXI_ACTIVATION_SCRIPT = $previousActivationScript
    }
}
