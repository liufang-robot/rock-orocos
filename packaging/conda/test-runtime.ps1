Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:BatchActivationOutput = ""
$script:BatchActivationElapsed = [TimeSpan]::Zero
$script:BatchExitCode = 0

$condaPrefix = if ($env:PREFIX) { $env:PREFIX } else { $env:CONDA_PREFIX }
if ([string]::IsNullOrWhiteSpace($condaPrefix)) {
    throw "Neither PREFIX nor CONDA_PREFIX identifies the package test environment."
}

$libraryPrefix = if ($env:LIBRARY_PREFIX) {
    $env:LIBRARY_PREFIX
} else {
    Join-Path $condaPrefix "Library"
}

function Invoke-BatchEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BatchPath,
        [ValidateRange(1, 4)]
        [int]$Calls = 1,
        [hashtable]$InitialEnvironment = @{},
        [string]$FollowupBatchPath,
        [ValidateRange(0, 4)]
        [int]$FollowupCalls = 0,
        [string[]]$RemoveEnvironmentVariables = @(),
        [switch]$EchoCommands,
        [ValidateRange(0, 255)]
        [int]$ExpectedExitCode = 0
    )

    if (-not (Test-Path -LiteralPath $BatchPath -PathType Leaf)) {
        throw "Batch activation entrypoint does not exist: $BatchPath"
    }
    if ($FollowupCalls -gt 0 -and
        -not (Test-Path -LiteralPath $FollowupBatchPath -PathType Leaf)) {
        throw "Batch follow-up entrypoint does not exist: $FollowupBatchPath"
    }

    $callerRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("orocos-batch-caller-" + [guid]::NewGuid().ToString("N"))
    $callerPath = Join-Path $callerRoot "capture-environment.bat"
    New-Item -ItemType Directory -Path $callerRoot | Out-Null
    try {
        $captureMarker = "OROCOS_TEST_ENVIRONMENT_CAPTURE_BEGIN"
        $callerLines = @()
        if ($EchoCommands) {
            $callerLines += "@echo on"
        }
        $callPrefix = if ($EchoCommands) { "call" } else { "@call" }
        for ($index = 0; $index -lt $Calls; $index += 1) {
            $callerLines += '{0} "{1}"' -f $callPrefix, $BatchPath
            $callerLines += '@if errorlevel 1 exit /b %ERRORLEVEL%'
        }
        for ($index = 0; $index -lt $FollowupCalls; $index += 1) {
            $callerLines += '{0} "{1}"' -f $callPrefix, $FollowupBatchPath
            $callerLines += '@if errorlevel 1 exit /b %ERRORLEVEL%'
        }
        if ($EchoCommands) {
            $callerLines += "@echo off"
        }
        $callerLines += "@echo $captureMarker"
        $callerLines += "@set"
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
            if ([string]$name -like "__OROCOS_ROCK_*") {
                $startInfo.EnvironmentVariables.Remove([string]$name)
            }
        }
        foreach ($name in $RemoveEnvironmentVariables) {
            $startInfo.EnvironmentVariables.Remove($name)
        }
        foreach ($entry in $InitialEnvironment.GetEnumerator()) {
            $startInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
        }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            [void]$process.Start()
            $standardOutput = $process.StandardOutput.ReadToEnd()
            $standardError = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $stopwatch.Stop()
            $script:BatchExitCode = $process.ExitCode
            if ($process.ExitCode -ne $ExpectedExitCode) {
                throw "Batch activation returned $($process.ExitCode), expected ${ExpectedExitCode}: $standardError"
            }
        } finally {
            if ($stopwatch.IsRunning) {
                $stopwatch.Stop()
            }
            $process.Dispose()
        }

        if ($ExpectedExitCode -ne 0) {
            $script:BatchActivationOutput = $standardOutput
            $script:BatchActivationElapsed = $stopwatch.Elapsed
            $environment = [Collections.Generic.Dictionary[string, string]]::new(
                [StringComparer]::OrdinalIgnoreCase)
            return ,$environment
        }

        $outputLines = @($standardOutput -split "`r?`n")
        $captureIndex = [Array]::IndexOf($outputLines, $captureMarker)
        if ($captureIndex -lt 0) {
            throw "Batch activation did not emit the environment capture marker."
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
        $script:BatchActivationOutput = $activationLines -join "`n"
        $script:BatchActivationElapsed = $stopwatch.Elapsed

        $environment = [Collections.Generic.Dictionary[string, string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($line in $environmentLines) {
            $separator = $line.IndexOf("=")
            if ($separator -le 0) {
                continue
            }
            $environment[$line.Substring(0, $separator)] = `
                $line.Substring($separator + 1)
        }
        return ,$environment
    } finally {
        if (Test-Path -LiteralPath $callerRoot -PathType Container) {
            Remove-Item -LiteralPath $callerRoot -Recurse -Force
        }
    }
}

function Assert-EnvironmentValue {
    param(
        [Collections.Generic.IDictionary[string, string]]$Environment,
        [string]$Name,
        [string]$Expected
    )

    $actual = $Environment[$Name]
    if (-not [string]::Equals(
            $actual,
            $Expected,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name was '$actual', expected '$Expected'."
    }
}

function Assert-EnvironmentValueExact {
    param(
        [Collections.Generic.IDictionary[string, string]]$Environment,
        [string]$Name,
        [string]$Expected
    )

    $actual = $Environment[$Name]
    if (-not [string]::Equals(
            $actual,
            $Expected,
            [StringComparison]::Ordinal)) {
        throw "$Name was '$actual', expected exactly '$Expected'."
    }
}

function Assert-EnvironmentAbsent {
    param(
        [Collections.Generic.IDictionary[string, string]]$Environment,
        [string]$Name
    )

    if ($Environment.ContainsKey($Name)) {
        throw "$Name remained set to '$($Environment[$Name])'."
    }
}

function Assert-NoOrocosHookState {
    param(
        [Collections.Generic.IDictionary[string, string]]$Environment
    )

    $leakedState = @(
        $Environment.Keys |
            Where-Object { $_ -like "__OROCOS_ROCK_*" }
    )
    if ($leakedState.Count -ne 0) {
        throw "Orocos package hooks leaked state: $($leakedState -join ', ')"
    }
}

function Get-PathEntries {
    param(
        [Collections.Generic.IDictionary[string, string]]$Environment,
        [string]$Name
    )

    @(
        [string]$Environment[$Name] -split ";" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Assert-PathEntryCount {
    param(
        [Collections.Generic.IDictionary[string, string]]$Environment,
        [string]$Name,
        [string]$ExpectedPath,
        [int]$ExpectedCount
    )

    $matches = @(
        Get-PathEntries -Environment $Environment -Name $Name |
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

function Assert-PathValuePreservedAsSuffix {
    param(
        [Collections.Generic.IDictionary[string, string]]$Environment,
        [string]$Name,
        [string]$OriginalValue
    )

    $actual = [string]$Environment[$Name]
    if (-not [string]::Equals(
            $actual,
            $OriginalValue,
            [StringComparison]::Ordinal) -and
        -not $actual.EndsWith(
            ";$OriginalValue",
            [StringComparison]::Ordinal)) {
        throw "$Name did not preserve its original value as an exact suffix."
    }
}

$runtimeBatch = Join-Path $libraryPrefix "env.bat"
$activationHook = Join-Path $condaPrefix "etc\conda\activate.d\orocos-activate.bat"
$deactivationHook = Join-Path $condaPrefix "etc\conda\deactivate.d\orocos-deactivate.bat"
$minimalBatchPath = Split-Path -Parent $env:ComSpec
$batchEnvironment = Invoke-BatchEnvironment -BatchPath $runtimeBatch -Calls 2 `
    -InitialEnvironment @{ PATH = $minimalBatchPath }
Assert-EnvironmentValue `
    -Environment $batchEnvironment -Name "OROCOS_PREFIX" -Expected $libraryPrefix
Assert-EnvironmentValue `
    -Environment $batchEnvironment -Name "OROCOS_TARGET" -Expected "win32"

$rattlerPathEntries = @(
    1..96 | ForEach-Object {
        "C:\rattler-build\host_env_placehold_placehold_placehold\Library\bin\$_"
    }
)
$rattlerPath = $rattlerPathEntries -join ";"
if ($rattlerPath.Length -lt 6500 -or $rattlerPath.Length -gt 7600) {
    throw "Rattler-length PATH fixture has unexpected length $($rattlerPath.Length)."
}
$staleHookDiscoveryPath = "C:\stale-orocos-discovery"
$hookPkgConfig = Join-Path $libraryPrefix "lib\pkgconfig"
$hookTypelib = Join-Path $libraryPrefix "lib\typelib"
$hookRuntimePlugins = Join-Path $libraryPrefix "lib\orocos\win32\plugins"
$hookRttTypes = Join-Path $libraryPrefix "lib\orocos\win32\types"
$hookExpectedPath = "$hookRuntimePlugins;$rattlerPath"
$hookManagedVariables = @(
    "OROCOS_PREFIX",
    "OROCOS_TARGET",
    "RTT_COMPONENT_PATH",
    "PKG_CONFIG_LIBDIR",
    "PKG_CONFIG_PATH",
    "TYPELIB_PLUGIN_PATH",
    "CMAKE_PREFIX_PATH"
)
$hookInitialEnvironment = @{
    PATH = $rattlerPath
    OROCOS_PREFIX = "C:\stale-orocos-prefix"
    OROCOS_TARGET = "stale-target"
    RTT_COMPONENT_PATH = $staleHookDiscoveryPath
    PKG_CONFIG_LIBDIR = "C:\stale-pkg-config-libdir"
    PKG_CONFIG_PATH = $staleHookDiscoveryPath
    TYPELIB_PLUGIN_PATH = $staleHookDiscoveryPath
    CMAKE_PREFIX_PATH = $staleHookDiscoveryPath
}
$hookPkgConfigExpectedCount = 0
if (Test-Path -LiteralPath $hookPkgConfig -PathType Container) {
    throw "The runtime package unexpectedly contains the development pkg-config directory: $hookPkgConfig"
}
try {
    $hookEnvironment = Invoke-BatchEnvironment `
        -BatchPath $activationHook `
        -Calls 2 `
        -InitialEnvironment $hookInitialEnvironment `
        -EchoCommands
    $activationConsoleLines = @(
        $script:BatchActivationOutput -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($script:BatchActivationOutput -match "__OROCOS_ROCK_PATH_") {
        throw "Batch activation echoed internal PATH implementation commands."
    }
    if ($activationConsoleLines.Count -gt 8) {
        throw "Batch activation emitted $($activationConsoleLines.Count) console lines; expected at most 8."
    }
    if ($script:BatchActivationElapsed.TotalSeconds -gt 30) {
        throw "Batch activation took $($script:BatchActivationElapsed.TotalSeconds) seconds; expected at most 30."
    }
    Write-Host (
        "Long-PATH activation completed in {0:N3}s with {1} console line(s)." -f `
            $script:BatchActivationElapsed.TotalSeconds,
            $activationConsoleLines.Count)
    Assert-EnvironmentValue `
        -Environment $hookEnvironment -Name "OROCOS_PREFIX" -Expected $libraryPrefix
    Assert-EnvironmentValue `
        -Environment $hookEnvironment -Name "OROCOS_TARGET" -Expected "win32"
    Assert-EnvironmentValueExact `
        -Environment $hookEnvironment -Name "PATH" -Expected $hookExpectedPath
    Assert-EnvironmentValue `
        -Environment $hookEnvironment `
        -Name "PKG_CONFIG_LIBDIR" -Expected $hookPkgConfig

    $hookExpectedPathEntries = @(
        [PSCustomObject]@{
            Name = "PATH"
            Path = $hookRuntimePlugins
            Count = 1
        },
        [PSCustomObject]@{
            Name = "RTT_COMPONENT_PATH"
            Path = $hookRttTypes
            Count = 1
        },
        [PSCustomObject]@{
            Name = "PKG_CONFIG_PATH"
            Path = $hookPkgConfig
            Count = $hookPkgConfigExpectedCount
        },
        [PSCustomObject]@{
            Name = "TYPELIB_PLUGIN_PATH"
            Path = $hookTypelib
            Count = 1
        },
        [PSCustomObject]@{
            Name = "CMAKE_PREFIX_PATH"
            Path = $libraryPrefix
            Count = 1
        }
    )
    foreach ($entry in $hookExpectedPathEntries) {
        Assert-PathEntryCount `
            -Environment $hookEnvironment `
            -Name $entry.Name `
            -ExpectedPath $entry.Path `
            -ExpectedCount $entry.Count
    }

    $hookPreservedPathNames = @(
        "RTT_COMPONENT_PATH",
        "PKG_CONFIG_PATH",
        "TYPELIB_PLUGIN_PATH",
        "CMAKE_PREFIX_PATH"
    )
    foreach ($name in $hookPreservedPathNames) {
        Assert-PathEntryCount `
            -Environment $hookEnvironment `
            -Name $name `
            -ExpectedPath $staleHookDiscoveryPath `
            -ExpectedCount 1
    }

    $restoredHookEnvironment = Invoke-BatchEnvironment `
        -BatchPath $activationHook `
        -Calls 2 `
        -FollowupBatchPath $deactivationHook `
        -FollowupCalls 2 `
        -InitialEnvironment $hookInitialEnvironment
    foreach ($entry in $hookInitialEnvironment.GetEnumerator()) {
        Assert-EnvironmentValueExact `
            -Environment $restoredHookEnvironment `
            -Name ([string]$entry.Key) `
            -Expected ([string]$entry.Value)
    }
    Assert-NoOrocosHookState -Environment $restoredHookEnvironment

    $preexistingPluginPath = "$hookRuntimePlugins;$rattlerPath"
    $unsetHookEnvironment = Invoke-BatchEnvironment `
        -BatchPath $activationHook `
        -Calls 2 `
        -FollowupBatchPath $deactivationHook `
        -FollowupCalls 2 `
        -RemoveEnvironmentVariables $hookManagedVariables `
        -InitialEnvironment @{ PATH = $preexistingPluginPath }
    Assert-EnvironmentValueExact `
        -Environment $unsetHookEnvironment `
        -Name "PATH" `
        -Expected $preexistingPluginPath
    foreach ($name in $hookManagedVariables) {
        Assert-EnvironmentAbsent `
            -Environment $unsetHookEnvironment -Name $name
    }
    Assert-NoOrocosHookState -Environment $unsetHookEnvironment

    [void](Invoke-BatchEnvironment `
        -BatchPath $activationHook `
        -Calls 1 `
        -RemoveEnvironmentVariables $hookManagedVariables `
        -InitialEnvironment @{
            PATH = $minimalBatchPath
            SystemRoot = "C:\orocos-missing-system-root"
        } `
        -ExpectedExitCode 1)
    if ($script:BatchExitCode -ne 1) {
        throw "The activation hook did not propagate env.bat's internal failure."
    }
} finally {
    if (Test-Path -LiteralPath $hookPkgConfig -PathType Container) {
        throw "Runtime activation created the development pkg-config directory: $hookPkgConfig"
    }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("orocos activation " + [guid]::NewGuid().ToString("N"))
$fixtureLibrary = Join-Path $fixtureRoot "Library"
$fixtureBin = Join-Path $fixtureLibrary "bin"
$fixturePkgConfig = Join-Path $fixtureLibrary "lib\pkgconfig"
$fixtureTypelib = Join-Path $fixtureLibrary "lib\typelib"
$fixtureRecursive = Join-Path $fixtureLibrary `
    "lib\orocos\win32\custom\plugins"
$fixtureMissing = Join-Path $fixtureLibrary `
    "lib\orocos\win32\ocl\plugins"
$fixturePreserved = Join-Path $fixtureRoot "preserved"
try {
    foreach ($directory in @(
            $fixtureBin,
            $fixturePkgConfig,
            $fixtureTypelib,
            $fixtureRecursive,
            $fixturePreserved
        )) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    Copy-Item -LiteralPath $runtimeBatch `
        -Destination (Join-Path $fixtureLibrary "env.bat")

    $fixtureInitialPathValues = @{
        PATH = "$($fixtureBin.ToUpperInvariant());$fixturePreserved;$($fixturePreserved.ToUpperInvariant())"
        RTT_COMPONENT_PATH = `
            "$($fixtureRecursive.ToUpperInvariant());$fixturePreserved;$($fixturePreserved.ToUpperInvariant())"
        PKG_CONFIG_PATH = `
            "$($fixturePkgConfig.ToUpperInvariant());$fixturePreserved;$($fixturePreserved.ToUpperInvariant())"
        TYPELIB_PLUGIN_PATH = `
            "$($fixtureTypelib.ToUpperInvariant());$fixturePreserved;$($fixturePreserved.ToUpperInvariant())"
        CMAKE_PREFIX_PATH = `
            "$($fixtureLibrary.ToUpperInvariant());$fixturePreserved;$($fixturePreserved.ToUpperInvariant())"
    }
    $fixtureInitialEnvironment = $fixtureInitialPathValues.Clone()
    $fixtureInitialEnvironment["OROCOS_PREFIX"] = "C:\stale-orocos-prefix"
    $fixtureInitialEnvironment["OROCOS_TARGET"] = "stale-target"
    $fixtureEnvironment = Invoke-BatchEnvironment `
        -BatchPath (Join-Path $fixtureLibrary "env.bat") `
        -Calls 2 `
        -InitialEnvironment $fixtureInitialEnvironment `
        -EchoCommands

    Assert-EnvironmentValue `
        -Environment $fixtureEnvironment `
        -Name "OROCOS_PREFIX" `
        -Expected $fixtureLibrary
    Assert-EnvironmentValue `
        -Environment $fixtureEnvironment `
        -Name "OROCOS_TARGET" `
        -Expected "win32"
    Assert-EnvironmentValue `
        -Environment $fixtureEnvironment `
        -Name "PKG_CONFIG_LIBDIR" `
        -Expected $fixturePkgConfig

    $expectedPathEntries = @(
        [PSCustomObject]@{ Name = "PATH"; Path = $fixtureBin },
        [PSCustomObject]@{ Name = "PATH"; Path = $fixtureRecursive },
        [PSCustomObject]@{
            Name = "RTT_COMPONENT_PATH"
            Path = $fixtureRecursive
        },
        [PSCustomObject]@{ Name = "PKG_CONFIG_PATH"; Path = $fixturePkgConfig },
        [PSCustomObject]@{
            Name = "TYPELIB_PLUGIN_PATH"
            Path = $fixtureTypelib
        },
        [PSCustomObject]@{
            Name = "CMAKE_PREFIX_PATH"
            Path = $fixtureLibrary
        }
    )
    foreach ($entry in $expectedPathEntries) {
        Assert-PathEntryCount `
            -Environment $fixtureEnvironment `
            -Name $entry.Name `
            -ExpectedPath $entry.Path `
            -ExpectedCount 1
    }
    foreach ($entry in $fixtureInitialPathValues.GetEnumerator()) {
        Assert-PathValuePreservedAsSuffix `
            -Environment $fixtureEnvironment `
            -Name ([string]$entry.Key) `
            -OriginalValue ([string]$entry.Value)
    }
    foreach ($name in @(
            "PATH",
            "RTT_COMPONENT_PATH",
            "PKG_CONFIG_PATH",
            "TYPELIB_PLUGIN_PATH",
            "CMAKE_PREFIX_PATH"
        )) {
        Assert-PathEntryCount `
            -Environment $fixtureEnvironment `
            -Name $name `
            -ExpectedPath $fixturePreserved `
            -ExpectedCount 2
    }
    Assert-PathEntryCount `
        -Environment $fixtureEnvironment `
        -Name "PATH" `
        -ExpectedPath $fixtureMissing `
        -ExpectedCount 0
    Assert-PathEntryCount `
        -Environment $fixtureEnvironment `
        -Name "RTT_COMPONENT_PATH" `
        -ExpectedPath $fixtureMissing `
        -ExpectedCount 0

    $leakedHelpers = @(
        $fixtureEnvironment.Keys |
            Where-Object { $_.StartsWith("__OROCOS_ROCK_", [StringComparison]::Ordinal) }
    )
    if ($leakedHelpers.Count -ne 0) {
        throw "env.bat leaked helper variables: $($leakedHelpers -join ', ')"
    }
} finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

$runtimeEnvironment = Join-Path $libraryPrefix "env.ps1"
if (-not (Test-Path -LiteralPath $runtimeEnvironment -PathType Leaf)) {
    throw "The orocos package did not install env.ps1 at $runtimeEnvironment"
}

. $runtimeEnvironment

if ($env:OROCOS_PREFIX -ne $libraryPrefix -or $env:OROCOS_TARGET -ne "win32") {
    throw "The runtime activation script exported the wrong prefix or target."
}
if ($env:PATH -match '(?i)(build[\\/]vcpkg|\.vcpkg)') {
    throw "The runtime PATH still refers to a vcpkg build checkout."
}

foreach ($relativePath in @(
        "bin\readline.dll",
        "bin\boost_filesystem-vc143-mt-x64-1_91.dll",
        "bin\libxml2.dll"
    )) {
    $path = Join-Path $libraryPrefix $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing packaged runtime dependency: $path"
    }
}

foreach ($command in @(
        "deployer-win32.exe",
        "rttscript-win32.exe",
        "deployer-opcua-win32.exe"
    )) {
    $executable = (Get-Command $command -ErrorAction Stop).Source
    & $executable --check --no-consolelog
    if ($LASTEXITCODE -ne 0) {
        throw "$command validation failed with exit code $LASTEXITCODE."
    }
}

$taskBrowser = (Get-Command "ctaskbrowser-opcua-win32.exe" -ErrorAction Stop).Source
$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    $taskBrowserHelp = & $taskBrowser --help 2>&1 | Out-String
} finally {
    $ErrorActionPreference = $savedErrorActionPreference
}
if ($taskBrowserHelp -notmatch "--import PACKAGE") {
    throw "The packaged OPC UA TaskBrowser failed its help check."
}
