[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
    $startInfo.EnvironmentVariables["PATH"] = $InitialPath

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
        throw "$Name was '$actual', expected '$Expected'."
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

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("orocos-windows-env-batch-" + [guid]::NewGuid().ToString("N"))
$condaPrefix = Join-Path $testRoot "conda"
$libraryPrefix = Join-Path $condaPrefix "Library"
$hookDirectory = Join-Path $condaPrefix "etc\conda\activate.d"
$hookPath = Join-Path $hookDirectory "orocos-activate.bat"
$fakeBin = Join-Path $testRoot "fake-bin"
$fakeRuby = Join-Path $fakeBin "ruby.cmd"
$callerPath = Join-Path $testRoot "capture-environment.bat"
$preservedPath = Join-Path $testRoot "preserved"
$componentPath = Join-Path $libraryPrefix "lib\orocos\win32\types"
$pkgConfigPath = Join-Path $libraryPrefix "lib\pkgconfig"
$typelibPath = Join-Path $libraryPrefix "lib\typelib"
$originalPath = $env:PATH

try {
    foreach ($directory in @(
            (Join-Path $libraryPrefix "vcpkg"),
            $hookDirectory,
            $fakeBin,
            $preservedPath,
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
        -Destination $hookPath

    $callerLines = @(
        '@call "{0}"' -f $hookPath,
        '@if errorlevel 1 exit /b %ERRORLEVEL%',
        '@call "{0}"' -f $hookPath,
        '@if errorlevel 1 exit /b %ERRORLEVEL%',
        '@set'
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
    $environment = Get-BatchEnvironment `
        -CallerPath $callerPath `
        -InitialPath $rattlerPath

    Assert-EnvironmentValue `
        -Environment $environment -Name "OROCOS_PREFIX" -Expected $libraryPrefix
    Assert-EnvironmentValue `
        -Environment $environment -Name "OROCOS_TARGET" -Expected "win32"
    if ($environment["PATH"] -cne $rattlerPath) {
        throw "Conda-owned PATH changed during package activation."
    }
    foreach ($entry in @(
            [PSCustomObject]@{ Name = "RTT_COMPONENT_PATH"; Path = $componentPath },
            [PSCustomObject]@{ Name = "PKG_CONFIG_PATH"; Path = $pkgConfigPath },
            [PSCustomObject]@{ Name = "TYPELIB_PLUGIN_PATH"; Path = $typelibPath },
            [PSCustomObject]@{ Name = "CMAKE_PREFIX_PATH"; Path = $libraryPrefix }
        )) {
        Assert-PathEntryCount `
            -Environment $environment `
            -Name $entry.Name `
            -ExpectedPath $entry.Path `
            -ExpectedCount 1
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
