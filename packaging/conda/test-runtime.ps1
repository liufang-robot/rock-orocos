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

function Invoke-BatchEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BatchPath,
        [ValidateRange(1, 4)]
        [int]$Calls = 1,
        [hashtable]$InitialEnvironment = @{}
    )

    if (-not (Test-Path -LiteralPath $BatchPath -PathType Leaf)) {
        throw "Batch activation entrypoint does not exist: $BatchPath"
    }

    $callerRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("orocos-batch-caller-" + [guid]::NewGuid().ToString("N"))
    $callerPath = Join-Path $callerRoot "capture-environment.bat"
    New-Item -ItemType Directory -Path $callerRoot | Out-Null
    try {
        $callerLines = @()
        for ($index = 0; $index -lt $Calls; $index += 1) {
            $callerLines += '@call "{0}"' -f $BatchPath
            $callerLines += '@if errorlevel 1 exit /b %ERRORLEVEL%'
        }
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
        foreach ($entry in $InitialEnvironment.GetEnumerator()) {
            $startInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
        }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            [void]$process.Start()
            $standardOutput = $process.StandardOutput.ReadToEnd()
            $standardError = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                throw "Batch activation failed with code $($process.ExitCode): $standardError"
            }
        } finally {
            $process.Dispose()
        }

        $environment = [Collections.Generic.Dictionary[string, string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($line in $standardOutput -split "`r?`n") {
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

function Assert-PathEntriesUnique {
    param(
        [Collections.Generic.IDictionary[string, string]]$Environment,
        [string]$Name
    )

    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in Get-PathEntries -Environment $Environment -Name $Name) {
        if (-not $seen.Add($entry)) {
            throw "$Name contains duplicate path entry '$entry'."
        }
    }
}

$runtimeBatch = Join-Path $libraryPrefix "env.bat"
$activationHook = Join-Path $condaPrefix "etc\conda\activate.d\orocos-activate.bat"
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
$hookRttTypes = Join-Path $libraryPrefix "lib\orocos\win32\types"
$createdHookPkgConfig = -not (Test-Path -LiteralPath $hookPkgConfig `
    -PathType Container)
if ($createdHookPkgConfig) {
    New-Item -ItemType Directory -Path $hookPkgConfig | Out-Null
}
try {
    $hookEnvironment = Invoke-BatchEnvironment `
        -BatchPath $activationHook `
        -InitialEnvironment @{
            PATH = $rattlerPath
            OROCOS_PREFIX = "C:\stale-orocos-prefix"
            OROCOS_TARGET = "stale-target"
            RTT_COMPONENT_PATH = $staleHookDiscoveryPath
            PKG_CONFIG_LIBDIR = "C:\stale-pkg-config-libdir"
            PKG_CONFIG_PATH = $staleHookDiscoveryPath
            TYPELIB_PLUGIN_PATH = $staleHookDiscoveryPath
            CMAKE_PREFIX_PATH = $staleHookDiscoveryPath
        }
    Assert-EnvironmentValue `
        -Environment $hookEnvironment -Name "OROCOS_PREFIX" -Expected $libraryPrefix
    Assert-EnvironmentValue `
        -Environment $hookEnvironment -Name "OROCOS_TARGET" -Expected "win32"
    Assert-EnvironmentValueExact `
        -Environment $hookEnvironment -Name "PATH" -Expected $rattlerPath
    Assert-EnvironmentValue `
        -Environment $hookEnvironment `
        -Name "PKG_CONFIG_LIBDIR" -Expected $hookPkgConfig

    $hookExpectedPathEntries = @(
        [PSCustomObject]@{
            Name = "RTT_COMPONENT_PATH"
            Path = $hookRttTypes
        },
        [PSCustomObject]@{ Name = "PKG_CONFIG_PATH"; Path = $hookPkgConfig },
        [PSCustomObject]@{ Name = "TYPELIB_PLUGIN_PATH"; Path = $hookTypelib },
        [PSCustomObject]@{ Name = "CMAKE_PREFIX_PATH"; Path = $libraryPrefix }
    )
    foreach ($entry in $hookExpectedPathEntries) {
        Assert-PathEntryCount `
            -Environment $hookEnvironment `
            -Name $entry.Name `
            -ExpectedPath $entry.Path `
            -ExpectedCount 1
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
} finally {
    if ($createdHookPkgConfig) {
        Remove-Item -LiteralPath $hookPkgConfig -Force
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

    $fixtureEnvironment = Invoke-BatchEnvironment `
        -BatchPath (Join-Path $fixtureLibrary "env.bat") `
        -Calls 2 `
        -InitialEnvironment @{
            PATH = "$($fixtureBin.ToUpperInvariant());$fixturePreserved;$($fixturePreserved.ToUpperInvariant())"
            RTT_COMPONENT_PATH = `
                "$($fixtureRecursive.ToUpperInvariant());$fixturePreserved;$($fixturePreserved.ToUpperInvariant())"
            PKG_CONFIG_PATH = `
                "$($fixturePkgConfig.ToUpperInvariant());$fixturePreserved;$($fixturePreserved.ToUpperInvariant())"
            TYPELIB_PLUGIN_PATH = `
                "$($fixtureTypelib.ToUpperInvariant());$fixturePreserved;$($fixturePreserved.ToUpperInvariant())"
            CMAKE_PREFIX_PATH = `
                "$($fixtureLibrary.ToUpperInvariant());$fixturePreserved;$($fixturePreserved.ToUpperInvariant())"
            OROCOS_PREFIX = "C:\stale-orocos-prefix"
            OROCOS_TARGET = "stale-target"
        }

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
            -ExpectedCount 1
        Assert-PathEntriesUnique `
            -Environment $fixtureEnvironment `
            -Name $name
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
