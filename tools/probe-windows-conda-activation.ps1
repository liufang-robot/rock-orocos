[CmdletBinding()]
param(
    [string]$CondaPrefix = $env:CONDA_PREFIX,
    [ValidateRange(1, 120)]
    [int]$MaximumSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($CondaPrefix)) {
    throw "CONDA_PREFIX is required for the Windows activation probe."
}

$libraryPrefix = Join-Path $CondaPrefix "Library"
$activationHook = Join-Path $CondaPrefix `
    "etc\conda\activate.d\orocos-activate.bat"
$deactivationHook = Join-Path $CondaPrefix `
    "etc\conda\deactivate.d\orocos-deactivate.bat"
foreach ($path in @($activationHook, $deactivationHook)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Windows package lifecycle hook does not exist: $path"
    }
}

function Assert-ValueExact {
    param(
        [Collections.Generic.IDictionary[string, string]]$Environment,
        [string]$Name,
        [string]$Expected
    )

    $actual = [string]$Environment[$Name]
    if (-not [string]::Equals(
            $actual,
            $Expected,
            [StringComparison]::Ordinal)) {
        throw "$Name was '$actual', expected exactly '$Expected'."
    }
}

function Assert-ValueAbsent {
    param(
        [Collections.Generic.IDictionary[string, string]]$Environment,
        [string]$Name
    )

    if ($Environment.ContainsKey($Name)) {
        throw "$Name remained set to '$($Environment[$Name])'."
    }
}

function Assert-PathEntryCount {
    param(
        [Collections.Generic.IDictionary[string, string]]$Environment,
        [string]$Name,
        [string]$ExpectedPath,
        [int]$ExpectedCount
    )

    $matches = @(
        [string]$Environment[$Name] -split ";" |
            Where-Object {
                [string]::Equals(
                    $_,
                    $ExpectedPath,
                    [StringComparison]::OrdinalIgnoreCase)
            }
    )
    if ($matches.Count -ne $ExpectedCount) {
        throw "$Name contains '$ExpectedPath' $($matches.Count) times; expected $ExpectedCount."
    }
}

$captureMarker = "OROCOS_TEST_ENVIRONMENT_CAPTURE_BEGIN"
$callerRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("orocos-clean-consumer-activation-" + [guid]::NewGuid().ToString("N"))
$callerPath = Join-Path $callerRoot "probe-activation.bat"
$preservedDiscoveryPath = "C:\orocos-clean-consumer-preserved"
$preservedPkgConfigLibdir = "C:\orocos-clean-consumer-pkg-config-libdir"
$libraryBin = Join-Path $libraryPrefix "bin"
$runtimePlugins = Join-Path $libraryPrefix "lib\orocos\win32\plugins"
$runtimeTypes = Join-Path $libraryPrefix "lib\orocos\win32\types"
$pkgConfig = Join-Path $libraryPrefix "lib\pkgconfig"
$typelib = Join-Path $libraryPrefix "lib\typelib"
$rattlerPathEntries = @($libraryBin) + @(
    1..96 | ForEach-Object {
        "C:\rattler-build\host_env_placehold_placehold_placehold\Library\bin\$_"
    }
)
$rattlerPath = $rattlerPathEntries -join ";"
if ($rattlerPath.Length -lt 6500 -or $rattlerPath.Length -gt 7800) {
    throw "Rattler-length PATH fixture has unexpected length $($rattlerPath.Length)."
}

$callerLines = @(
    "@echo on",
    ('call "{0}"' -f $activationHook),
    "@if errorlevel 1 exit /b %ERRORLEVEL%",
    ('call "{0}"' -f $activationHook),
    "@if errorlevel 1 exit /b %ERRORLEVEL%",
    "@set \"OROCOS_TEST_ACTIVE_PREFIX=%OROCOS_PREFIX%\"",
    "@set \"OROCOS_TEST_ACTIVE_TARGET=%OROCOS_TARGET%\"",
    "@set \"OROCOS_TEST_ACTIVE_PATH=%PATH%\"",
    "@set \"OROCOS_TEST_ACTIVE_RTT_COMPONENT_PATH=%RTT_COMPONENT_PATH%\"",
    "@set \"OROCOS_TEST_ACTIVE_PKG_CONFIG_PATH=%PKG_CONFIG_PATH%\"",
    "@set \"OROCOS_TEST_ACTIVE_TYPELIB_PLUGIN_PATH=%TYPELIB_PLUGIN_PATH%\"",
    "@set \"OROCOS_TEST_ACTIVE_CMAKE_PREFIX_PATH=%CMAKE_PREFIX_PATH%\"",
    "@deployer-opcua-win32.exe --check --no-consolelog",
    "@if errorlevel 1 exit /b %ERRORLEVEL%",
    ('call "{0}"' -f $deactivationHook),
    "@if errorlevel 1 exit /b %ERRORLEVEL%",
    ('call "{0}"' -f $deactivationHook),
    "@if errorlevel 1 exit /b %ERRORLEVEL%",
    "@echo off",
    "@echo $captureMarker",
    "@set"
)

New-Item -ItemType Directory -Path $callerRoot | Out-Null
try {
    [IO.File]::WriteAllText(
        $callerPath,
        (($callerLines -join "`r`n") + "`r`n"),
        [Text.UTF8Encoding]::new($false))

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = '/d /s /c ""{0}""' -f $callerPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
        if (([string]$name) -like "__OROCOS_ROCK_*") {
            $startInfo.EnvironmentVariables.Remove([string]$name)
        }
    }
    foreach ($name in @(
            "OROCOS_PREFIX",
            "OROCOS_TARGET",
            "RTT_COMPONENT_PATH",
            "PKG_CONFIG_LIBDIR",
            "PKG_CONFIG_PATH",
            "TYPELIB_PLUGIN_PATH",
            "CMAKE_PREFIX_PATH"
        )) {
        $startInfo.EnvironmentVariables.Remove($name)
    }
    $startInfo.EnvironmentVariables["PATH"] = $rattlerPath
    foreach ($name in @(
            "RTT_COMPONENT_PATH",
            "PKG_CONFIG_PATH",
            "TYPELIB_PLUGIN_PATH",
            "CMAKE_PREFIX_PATH"
        )) {
        $startInfo.EnvironmentVariables[$name] = $preservedDiscoveryPath
    }
    $startInfo.EnvironmentVariables["PKG_CONFIG_LIBDIR"] = `
        $preservedPkgConfigLibdir

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $stopwatch.Stop()
        if ($process.ExitCode -ne 0) {
            throw @"
Clean consumer batch activation failed with code $($process.ExitCode).
stdout:
$standardOutput
stderr:
$standardError
"@
        }
    } finally {
        if ($stopwatch.IsRunning) {
            $stopwatch.Stop()
        }
        $process.Dispose()
    }

    $outputLines = @($standardOutput -split "`r?`n")
    $captureIndex = [Array]::IndexOf($outputLines, $captureMarker)
    if ($captureIndex -lt 0) {
        throw "Clean consumer activation did not emit the capture marker."
    }
    $activationLines = if ($captureIndex -eq 0) {
        @()
    } else {
        @($outputLines[0..($captureIndex - 1)])
    }
    $environmentLines = if ($captureIndex -ge ($outputLines.Count - 1)) {
        @()
    } else {
        @($outputLines[($captureIndex + 1)..($outputLines.Count - 1)])
    }
    $activationOutput = $activationLines -join "`n"
    $consoleLines = @(
        $activationLines |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($activationOutput -match "__OROCOS_ROCK_PATH_") {
        throw "Clean consumer activation echoed internal PATH implementation commands."
    }
    if ($consoleLines.Count -gt 24) {
        throw "Clean consumer lifecycle emitted $($consoleLines.Count) console lines; expected at most 24."
    }
    if ($stopwatch.Elapsed.TotalSeconds -gt $MaximumSeconds) {
        throw "Clean consumer lifecycle took $($stopwatch.Elapsed.TotalSeconds) seconds; expected at most $MaximumSeconds."
    }

    $environment = [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $environmentLines) {
        $separator = $line.IndexOf("=")
        if ($separator -gt 0) {
            $environment[$line.Substring(0, $separator)] = `
                $line.Substring($separator + 1)
        }
    }

    Assert-ValueExact `
        -Environment $environment `
        -Name "OROCOS_TEST_ACTIVE_PREFIX" `
        -Expected $libraryPrefix
    Assert-ValueExact `
        -Environment $environment `
        -Name "OROCOS_TEST_ACTIVE_TARGET" `
        -Expected "win32"
    Assert-ValueExact `
        -Environment $environment `
        -Name "OROCOS_TEST_ACTIVE_PATH" `
        -Expected "$runtimePlugins;$rattlerPath"
    foreach ($entry in @(
            [PSCustomObject]@{
                Name = "OROCOS_TEST_ACTIVE_PATH"
                Path = $runtimePlugins
            },
            [PSCustomObject]@{
                Name = "OROCOS_TEST_ACTIVE_RTT_COMPONENT_PATH"
                Path = $runtimeTypes
            },
            [PSCustomObject]@{
                Name = "OROCOS_TEST_ACTIVE_PKG_CONFIG_PATH"
                Path = $pkgConfig
            },
            [PSCustomObject]@{
                Name = "OROCOS_TEST_ACTIVE_TYPELIB_PLUGIN_PATH"
                Path = $typelib
            },
            [PSCustomObject]@{
                Name = "OROCOS_TEST_ACTIVE_CMAKE_PREFIX_PATH"
                Path = $libraryPrefix
            }
        )) {
        Assert-PathEntryCount `
            -Environment $environment `
            -Name $entry.Name `
            -ExpectedPath $entry.Path `
            -ExpectedCount 1
    }
    foreach ($name in @(
            "OROCOS_TEST_ACTIVE_RTT_COMPONENT_PATH",
            "OROCOS_TEST_ACTIVE_PKG_CONFIG_PATH",
            "OROCOS_TEST_ACTIVE_TYPELIB_PLUGIN_PATH",
            "OROCOS_TEST_ACTIVE_CMAKE_PREFIX_PATH"
        )) {
        Assert-PathEntryCount `
            -Environment $environment `
            -Name $name `
            -ExpectedPath $preservedDiscoveryPath `
            -ExpectedCount 1
    }

    Assert-ValueExact -Environment $environment -Name "PATH" -Expected $rattlerPath
    Assert-ValueExact `
        -Environment $environment `
        -Name "PKG_CONFIG_LIBDIR" `
        -Expected $preservedPkgConfigLibdir
    foreach ($name in @(
            "RTT_COMPONENT_PATH",
            "PKG_CONFIG_PATH",
            "TYPELIB_PLUGIN_PATH",
            "CMAKE_PREFIX_PATH"
        )) {
        Assert-ValueExact `
            -Environment $environment `
            -Name $name `
            -Expected $preservedDiscoveryPath
    }
    Assert-ValueAbsent -Environment $environment -Name "OROCOS_PREFIX"
    Assert-ValueAbsent -Environment $environment -Name "OROCOS_TARGET"
    $leakedState = @(
        $environment.Keys |
            Where-Object { $_ -like "__OROCOS_ROCK_*" }
    )
    if ($leakedState.Count -ne 0) {
        throw "Clean consumer hooks leaked state: $($leakedState -join ', ')"
    }

    Write-Host (
        "Clean consumer long-PATH lifecycle completed in {0:N3}s with {1} console line(s)." -f `
            $stopwatch.Elapsed.TotalSeconds,
            $consoleLines.Count)
} finally {
    if (Test-Path -LiteralPath $callerRoot -PathType Container) {
        Remove-Item -LiteralPath $callerRoot -Recurse -Force
    }
}
