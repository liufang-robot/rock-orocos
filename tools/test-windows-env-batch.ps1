[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:BatchStandardOutput = ""
$script:BatchStandardError = ""
$script:BatchActivationOutput = ""
$script:BatchActivationElapsed = [TimeSpan]::Zero
$script:ManagedHookVariables = @(
    "OROCOS_PREFIX",
    "OROCOS_TARGET",
    "RTT_COMPONENT_PATH",
    "PKG_CONFIG_LIBDIR",
    "PKG_CONFIG_PATH",
    "TYPELIB_PLUGIN_PATH",
    "CMAKE_PREFIX_PATH"
)

function Get-BatchEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CallerPath,
        [Parameter(Mandatory = $true)]
        [string]$InitialPath
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = '/d /s /c ""{0}""' -f $CallerPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
        if (([string]$name) -like "__OROCOS_ROCK_*") {
            $startInfo.EnvironmentVariables.Remove([string]$name)
        }
    }
    foreach ($name in $script:ManagedHookVariables) {
        $startInfo.EnvironmentVariables.Remove($name)
    }
    $startInfo.EnvironmentVariables["PATH"] = $InitialPath

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        [void]$process.Start()
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $standardError = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $stopwatch.Stop()
        $script:BatchStandardOutput = $standardOutput
        $script:BatchStandardError = $standardError
        if ($process.ExitCode -ne 0) {
            throw @"
Batch activation failed with code $($process.ExitCode).
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

    $captureMarker = "OROCOS_TEST_ENVIRONMENT_CAPTURE_BEGIN"
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
        if ($separator -gt 0) {
            $environment[$line.Substring(0, $separator)] =
                $line.Substring($separator + 1)
        }
    }
    return ,$environment
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
        $parsedKeys = @($Environment.Keys | Sort-Object) -join ", "
        throw @"
$Name was '$actual', expected '$Expected'.
Parsed keys: $parsedKeys
Batch output:
$script:BatchStandardOutput
"@
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

function Read-BatchVariableFile {
    param(
        [string]$Path,
        [string]$Name
    )

    $prefix = "$Name="
    $line = @(
        [IO.File]::ReadAllLines($Path) |
            Where-Object {
                $_.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
            }
    )
    if ($line.Count -ne 1) {
        throw "$Path contains $($line.Count) $Name entries; expected 1."
    }
    return $line[0].Substring($prefix.Length)
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("orocos-windows-env-batch-" + [guid]::NewGuid().ToString("N"))
$condaPrefix = Join-Path $testRoot "conda"
$libraryPrefix = Join-Path $condaPrefix "Library"
$activationHookDirectory = Join-Path $condaPrefix "etc\conda\activate.d"
$activationHookPath = Join-Path $activationHookDirectory "orocos-activate.bat"
$deactivationHookDirectory = Join-Path $condaPrefix "etc\conda\deactivate.d"
$deactivationHookPath = Join-Path $deactivationHookDirectory "orocos-deactivate.bat"
$fakeBin = Join-Path $testRoot "fake-bin"
$fakeRuby = Join-Path $fakeBin "ruby.cmd"
$callerPath = Join-Path $testRoot "capture-environment.bat"
$membershipProbePath = Join-Path $testRoot "membership-probe.bat"
$membershipLabelProbePath = Join-Path $testRoot "membership-label-probe.bat"
$membershipProxyPath = Join-Path $testRoot "membership-proxy.bat"
$membershipGotoProbePath = Join-Path $testRoot "membership-goto-probe.bat"
$callerPathFile = Join-Path $testRoot "caller-path.txt"
$hookPathFile = Join-Path $testRoot "hook-path.txt"
$envPathFile = Join-Path $testRoot "env-path.txt"
$addPathFile = Join-Path $testRoot "add-path.txt"
$preservedPath = Join-Path $testRoot "preserved"
$runtimePluginPath = Join-Path $libraryPrefix "lib\orocos\win32\plugins"
$componentPath = Join-Path $libraryPrefix "lib\orocos\win32\types"
$pkgConfigPath = Join-Path $libraryPrefix "lib\pkgconfig"
$typelibPath = Join-Path $libraryPrefix "lib\typelib"
$originalPath = $env:PATH

try {
    foreach ($directory in @(
            (Join-Path $libraryPrefix "vcpkg"),
            $activationHookDirectory,
            $deactivationHookDirectory,
            $fakeBin,
            $preservedPath,
            $runtimePluginPath,
            $componentPath,
            $pkgConfigPath,
            $typelibPath
        )) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    [IO.File]::WriteAllText(
        $fakeRuby,
        "@echo test`r`n",
        [Text.ASCIIEncoding]::new())
    $env:PATH = "$fakeBin;$originalPath"
    & (Join-Path $repositoryRoot "tools\export-windows-env.ps1") `
        -Prefix $libraryPrefix `
        -BundledDependencies
    Copy-Item `
        -LiteralPath (Join-Path $repositoryRoot "packaging\conda\orocos-activate.bat") `
        -Destination $activationHookPath
    Copy-Item `
        -LiteralPath (Join-Path $repositoryRoot "packaging\conda\orocos-deactivate.bat") `
        -Destination $deactivationHookPath

    $membershipCommand = '@set %__OROCOS_ROCK_PATH_NAME% | @"%SystemRoot%\System32\findstr.exe" /I /L /B /C:"%__OROCOS_ROCK_PATH_NAME%=" | @"%SystemRoot%\System32\findstr.exe" /I /L /B /C:"%__OROCOS_ROCK_PATH_NAME%=%__OROCOS_ROCK_PATH_CANDIDATE%;" >nul'
    [IO.File]::WriteAllText(
        $membershipProbePath,
        ((@(
            '@set "__OROCOS_ROCK_PATH_NAME=PATH"',
            '@set "__OROCOS_ROCK_PATH_CANDIDATE=%~1"',
            $membershipCommand,
            '@exit /b %ERRORLEVEL%'
        ) -join "`r`n") + "`r`n"),
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $membershipLabelProbePath,
        ((@(
            '@call :orocos_test_membership "%~1"',
            '@exit /b %ERRORLEVEL%',
            ':orocos_test_membership',
            '@set "__OROCOS_ROCK_PATH_NAME=PATH"',
            '@set "__OROCOS_ROCK_PATH_CANDIDATE=%~1"',
            $membershipCommand,
            '@exit /b %ERRORLEVEL%'
        ) -join "`r`n") + "`r`n"),
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $membershipProxyPath,
        ((@(
            ('@call "{0}" "%~1"' -f $membershipLabelProbePath),
            '@exit /b %ERRORLEVEL%'
        ) -join "`r`n") + "`r`n"),
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $membershipGotoProbePath,
        ((@(
            '@if defined __OROCOS_ROCK_CONDA_ACTIVE @goto orocos_test_membership',
            '@exit /b 99',
            ':orocos_test_membership',
            '@set "__OROCOS_ROCK_PATH_NAME=PATH"',
            '@set "__OROCOS_ROCK_PATH_CANDIDATE=%~1"',
            $membershipCommand,
            '@set "OROCOS_TEST_GOTO_INNER=%ERRORLEVEL%"',
            '@exit /b %OROCOS_TEST_GOTO_INNER%'
        ) -join "`r`n") + "`r`n"),
        [Text.UTF8Encoding]::new($false))

    $callerLines = @(
        '@echo on',
        '@set "OROCOS_TEST_MEMBERSHIP_PROBE=1"',
        ('@set "OROCOS_TEST_CALLER_PATH_FILE={0}"' -f $callerPathFile),
        ('@set "OROCOS_TEST_HOOK_PATH_FILE={0}"' -f $hookPathFile),
        ('@set "OROCOS_TEST_ENV_PATH_FILE={0}"' -f $envPathFile),
        ('@set "OROCOS_TEST_ADD_PATH_FILE={0}"' -f $addPathFile),
        '@set "__OROCOS_TEST_BEFORE_FIRST=1"',
        ('call "{0}"' -f $activationHookPath),
        '@if errorlevel 1 exit /b %ERRORLEVEL%',
        '@set "__OROCOS_TEST_AFTER_FIRST=1"',
        ('@call "{0}" "{1}"' -f $membershipProbePath, $runtimePluginPath),
        '@set "OROCOS_TEST_EXTERNAL_BATCH=%ERRORLEVEL%"',
        ('@call "{0}" "{1}"' -f $membershipLabelProbePath, $runtimePluginPath),
        '@set "OROCOS_TEST_EXTERNAL_LABEL=%ERRORLEVEL%"',
        ('@call "{0}" "{1}"' -f $membershipProxyPath, $runtimePluginPath),
        '@set "OROCOS_TEST_PROXY_LABEL=%ERRORLEVEL%"',
        ('@call "{0}" "{1}"' -f $membershipGotoProbePath, $runtimePluginPath),
        '@set "OROCOS_TEST_GOTO_OUTER=%ERRORLEVEL%"',
        '@set "OROCOS_TEST_MEMBERSHIP_PHASE=SECOND"',
        ('@set PATH | @"%SystemRoot%\System32\findstr.exe" /I /L /B /C:"PATH=" | @"%SystemRoot%\System32\findstr.exe" /I /L /B /C:"PATH={0};" >nul' -f $runtimePluginPath),
        '@set "OROCOS_TEST_CALLER_SECOND=%ERRORLEVEL%"',
        '@set PATH | @"%SystemRoot%\System32\findstr.exe" /I /L /C:"OROCOS_TEST_DEFINITELY_MISSING" >nul',
        '@set "OROCOS_TEST_CALLER_NEGATIVE=%ERRORLEVEL%"',
        '@set PATH > "%OROCOS_TEST_CALLER_PATH_FILE%"',
        ('call "{0}"' -f $activationHookPath),
        '@if errorlevel 1 exit /b %ERRORLEVEL%',
        '@set "__OROCOS_TEST_AFTER_SECOND=1"',
        '@set "__OROCOS_TEST_ACTIVE_PREFIX=%OROCOS_PREFIX%"',
        '@set "__OROCOS_TEST_ACTIVE_TARGET=%OROCOS_TARGET%"',
        '@set "__OROCOS_TEST_ACTIVE_PATH=%PATH%"',
        '@set "__OROCOS_TEST_ACTIVE_COMPONENT_PATH=%RTT_COMPONENT_PATH%"',
        '@set "__OROCOS_TEST_ACTIVE_PKG_CONFIG_PATH=%PKG_CONFIG_PATH%"',
        '@set "__OROCOS_TEST_ACTIVE_TYPELIB_PATH=%TYPELIB_PLUGIN_PATH%"',
        '@set "__OROCOS_TEST_ACTIVE_CMAKE_PATH=%CMAKE_PREFIX_PATH%"',
        ('call "{0}"' -f $deactivationHookPath),
        '@if errorlevel 1 exit /b %ERRORLEVEL%',
        '@set "__OROCOS_TEST_AFTER_DEACTIVATION=1"',
        ('call "{0}"' -f $deactivationHookPath),
        '@if errorlevel 1 exit /b %ERRORLEVEL%',
        '@set "__OROCOS_TEST_AFTER_SECOND_DEACTIVATION=1"',
        '@echo off',
        '@echo OROCOS_TEST_ENVIRONMENT_CAPTURE_BEGIN',
        '@set',
        '@exit /b 0'
    )
    [IO.File]::WriteAllText(
        $callerPath,
        (($callerLines -join "`r`n") + "`r`n"),
        [Text.UTF8Encoding]::new($false))

    $rattlerPath = @(
        1..96 | ForEach-Object {
            "C:\rattler-build\host_env_placehold_placehold_placehold\Library\bin\$_"
        }
    ) -join ";"
    if ($rattlerPath.Length -lt 6500 -or $rattlerPath.Length -gt 7600) {
        throw "Rattler-length PATH fixture has unexpected length $($rattlerPath.Length)."
    }
    $environment = Get-BatchEnvironment `
        -CallerPath $callerPath `
        -InitialPath $rattlerPath

    if (-not [string]::IsNullOrWhiteSpace($script:BatchStandardError)) {
        throw "Batch lifecycle wrote to stderr:`n$script:BatchStandardError"
    }
    Write-Host (
        "Depth probe: external-batch={0}, external-label={1}, proxy-label={2}, goto-inner={3}, goto-outer={4}, production-candidate-match={5}" -f
            $environment["OROCOS_TEST_EXTERNAL_BATCH"],
            $environment["OROCOS_TEST_EXTERNAL_LABEL"],
            $environment["OROCOS_TEST_PROXY_LABEL"],
            $environment["OROCOS_TEST_GOTO_INNER"],
            $environment["OROCOS_TEST_GOTO_OUTER"],
            [string]::Equals(
                $environment["OROCOS_TEST_PRODUCTION_CANDIDATE_PATH"],
                $runtimePluginPath,
                [StringComparison]::OrdinalIgnoreCase))
    Write-Host (
        "Production boundaries: hook={0}, env={1}, add={2}" -f
            $environment["OROCOS_TEST_HOOK_MEMBERSHIP"],
            $environment["OROCOS_TEST_ENV_MEMBERSHIP"],
            $environment["OROCOS_TEST_ADD_MEMBERSHIP_PATH"])
    $pathBeforeSecondActivation = "$runtimePluginPath;$rattlerPath"
    $callerPathValue = Read-BatchVariableFile -Path $callerPathFile -Name "PATH"
    $hookPathValue = Read-BatchVariableFile -Path $hookPathFile -Name "PATH"
    $envPathValue = Read-BatchVariableFile -Path $envPathFile -Name "PATH"
    $addPathValue = Read-BatchVariableFile -Path $addPathFile -Name "PATH"
    Write-Host (
        "Caller controls: positive={0}, negative={1}; data matches: caller={2}, hook={3}, env={4}, add={5}, hook-candidate={6}, env-candidate={7}" -f
            $environment["OROCOS_TEST_CALLER_SECOND"],
            $environment["OROCOS_TEST_CALLER_NEGATIVE"],
            [string]::Equals($callerPathValue, $pathBeforeSecondActivation, [StringComparison]::Ordinal),
            [string]::Equals($hookPathValue, $pathBeforeSecondActivation, [StringComparison]::Ordinal),
            [string]::Equals($envPathValue, $pathBeforeSecondActivation, [StringComparison]::Ordinal),
            [string]::Equals($addPathValue, $pathBeforeSecondActivation, [StringComparison]::Ordinal),
            [string]::Equals($environment["OROCOS_TEST_HOOK_CANDIDATE"], $runtimePluginPath, [StringComparison]::OrdinalIgnoreCase),
            [string]::Equals($environment["OROCOS_TEST_ENV_CANDIDATE"], $runtimePluginPath, [StringComparison]::OrdinalIgnoreCase))
    $activationConsoleLines = @(
        $script:BatchActivationOutput -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($script:BatchActivationOutput -match "__OROCOS_ROCK_PATH_") {
        throw "Batch activation echoed internal PATH implementation commands."
    }
    if ($activationConsoleLines.Count -gt 16) {
        throw "Batch lifecycle emitted $($activationConsoleLines.Count) console lines; expected at most 16."
    }
    if ($script:BatchActivationElapsed.TotalSeconds -gt 30) {
        throw "Batch lifecycle took $($script:BatchActivationElapsed.TotalSeconds) seconds; expected at most 30."
    }

    Assert-EnvironmentValue `
        -Environment $environment -Name "__OROCOS_TEST_BEFORE_FIRST" -Expected "1"
    Assert-EnvironmentValue `
        -Environment $environment -Name "__OROCOS_TEST_AFTER_FIRST" -Expected "1"
    Assert-EnvironmentValue `
        -Environment $environment -Name "__OROCOS_TEST_AFTER_SECOND" -Expected "1"
    Assert-EnvironmentValue `
        -Environment $environment -Name "__OROCOS_TEST_AFTER_DEACTIVATION" -Expected "1"
    Assert-EnvironmentValue `
        -Environment $environment -Name "__OROCOS_TEST_AFTER_SECOND_DEACTIVATION" -Expected "1"
    Assert-EnvironmentValue `
        -Environment $environment -Name "__OROCOS_TEST_ACTIVE_PREFIX" -Expected $libraryPrefix
    Assert-EnvironmentValue `
        -Environment $environment -Name "__OROCOS_TEST_ACTIVE_TARGET" -Expected "win32"
    Assert-PathEntryCount `
        -Environment $environment `
        -Name "__OROCOS_TEST_ACTIVE_PATH" `
        -ExpectedPath $runtimePluginPath `
        -ExpectedCount 1
    $expectedPath = "$runtimePluginPath;$rattlerPath"
    if ($environment["__OROCOS_TEST_ACTIVE_PATH"] -cne $expectedPath) {
        throw "Package activation did not prepend only the runtime loader path."
    }
    foreach ($entry in @(
            [PSCustomObject]@{ Name = "__OROCOS_TEST_ACTIVE_COMPONENT_PATH"; Path = $componentPath },
            [PSCustomObject]@{ Name = "__OROCOS_TEST_ACTIVE_PKG_CONFIG_PATH"; Path = $pkgConfigPath },
            [PSCustomObject]@{ Name = "__OROCOS_TEST_ACTIVE_TYPELIB_PATH"; Path = $typelibPath },
            [PSCustomObject]@{ Name = "__OROCOS_TEST_ACTIVE_CMAKE_PATH"; Path = $libraryPrefix }
        )) {
        Assert-PathEntryCount `
            -Environment $environment `
            -Name $entry.Name `
            -ExpectedPath $entry.Path `
            -ExpectedCount 1
    }
    if ($environment["PATH"] -cne $rattlerPath) {
        throw "Package deactivation did not restore the inherited PATH exactly."
    }
    foreach ($name in $script:ManagedHookVariables) {
        Assert-EnvironmentAbsent -Environment $environment -Name $name
    }
    $leakedHelpers = @(
        $environment.Keys |
            Where-Object {
                $_.StartsWith("__OROCOS_ROCK_", [StringComparison]::Ordinal)
            }
    )
    if ($leakedHelpers.Count -ne 0) {
        throw "env.bat leaked helper variables: $($leakedHelpers -join ', ')"
    }
} finally {
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host "Validated generated Windows batch package activation."
