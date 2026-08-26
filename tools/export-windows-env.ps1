[CmdletBinding()]
param(
    [string]$Prefix = (Join-Path (Get-Location) "install\windows-msvc"),
    [string]$VcpkgRoot = (Join-Path (Get-Location) "build\vcpkg"),
    [string]$VcpkgTriplet = "x64-windows",
    [ValidateSet("win32")]
    [string]$Target = "win32",
    [switch]$BundledDependencies
)

$ErrorActionPreference = "Stop"

function Convert-ToFullPath {
    param([string]$Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Convert-ToSingleQuotedLiteral {
    param([string]$Value)

    $Value.Replace("'", "''")
}

function Convert-ToPowerShellPathExpressions {
    param(
        [string[]]$RelativePaths,
        [int]$Indent = 8
    )

    @(
        $RelativePaths | ForEach-Object {
            $literal = Convert-ToSingleQuotedLiteral $_
            "{0}(Join-Path `$Prefix '{1}')" -f (" " * $Indent), $literal
        }
    ) -join ",`n"
}

function Convert-ToBatchCandidateCalls {
    param([string[]]$RelativePaths)

    @(
        $RelativePaths | ForEach-Object {
            @(
                '@call :orocos_add_candidate "%OROCOS_PREFIX%\{0}"' -f $_
                '@if defined __OROCOS_ROCK_PATH_ERROR @goto orocos_runtime_failed'
            ) -join "`n"
        }
    ) -join "`n"
}

function Write-PowerShellScript {
    param(
        [string]$Path,
        [string]$Contents
    )

    $normalized = $Contents -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", ""
    $normalized = ($normalized.TrimEnd() + "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText(
        $Path,
        $normalized,
        [System.Text.UTF8Encoding]::new($false))
}

function Write-BatchScript {
    param(
        [string]$Path,
        [string]$Contents
    )

    Write-PowerShellScript -Path $Path -Contents $Contents
}

function Get-RubyConfigValue {
    param([string]$Name)

    $value = & ruby -rrbconfig -e "print RbConfig::CONFIG.fetch(ARGV.fetch(0))" $Name
    if ($LASTEXITCODE -ne 0) {
        throw "ruby failed while reading RbConfig::CONFIG[$Name]"
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Ruby configuration value is empty: $Name"
    }

    $value
}

$Prefix = Convert-ToFullPath $Prefix
$runtimeVcpkgPrefix = ""
if ($BundledDependencies) {
    $VcpkgRoot = ""
    $bundledVcpkgPrefix = Join-Path $Prefix "vcpkg"
    if (-not (Test-Path -LiteralPath $bundledVcpkgPrefix -PathType Container)) {
        throw "Missing bundled development dependencies: $bundledVcpkgPrefix"
    }
    $VcpkgPrefix = ""
} else {
    $VcpkgRoot = Convert-ToFullPath $VcpkgRoot
    $VcpkgPrefix = Join-Path $VcpkgRoot "installed\$VcpkgTriplet"
    if (-not (Test-Path -LiteralPath $VcpkgPrefix -PathType Container)) {
        throw "Missing vcpkg installed prefix: $VcpkgPrefix"
    }
    $runtimeVcpkgPrefix = $VcpkgPrefix
}

New-Item -ItemType Directory -Force -Path $Prefix | Out-Null

$vcpkgRootLiteral = Convert-ToSingleQuotedLiteral $VcpkgRoot
$vcpkgPrefixLiteral = Convert-ToSingleQuotedLiteral $VcpkgPrefix
$runtimeVcpkgPrefixLiteral = Convert-ToSingleQuotedLiteral $runtimeVcpkgPrefix
$targetLiteral = Convert-ToSingleQuotedLiteral $Target
$tripletLiteral = Convert-ToSingleQuotedLiteral $VcpkgTriplet
$rubyVersionLiteral = Convert-ToSingleQuotedLiteral (
    Get-RubyConfigValue -Name "ruby_version")
$rubyArchLiteral = Convert-ToSingleQuotedLiteral (
    Get-RubyConfigValue -Name "arch")

$runtimeDirectoriesBeforeRecursive = @(
    "bin",
    "lib",
    "lib\typelib",
    "lib\orocos",
    "lib\orocos\$Target\ocl",
    "lib\orocos\$Target\ocl\plugins",
    "lib\orocos\$Target\ocl\types",
    "lib\orocos\$Target\plugins",
    "lib\orocos\$Target\types",
    "lib\orocos\$Target\rtt_opcua\plugins"
)
$componentDirectoriesBeforeRecursive = @(
    "lib\orocos\$Target",
    "lib\orocos\$Target\ocl",
    "lib\orocos\$Target\ocl\plugins",
    "lib\orocos\$Target\plugins",
    "lib\orocos\$Target\types",
    "lib\orocos\$Target\rtt_opcua\plugins"
)
$componentDirectoriesAfterRecursive = @("lib\orocos")

$runtimePowerShellPaths = Convert-ToPowerShellPathExpressions `
    -RelativePaths $runtimeDirectoriesBeforeRecursive
$componentPowerShellPaths = Convert-ToPowerShellPathExpressions `
    -RelativePaths $componentDirectoriesBeforeRecursive
$componentPowerShellPathsAfterRecursive = Convert-ToPowerShellPathExpressions `
    -RelativePaths $componentDirectoriesAfterRecursive
$runtimeBatchCalls = Convert-ToBatchCandidateCalls `
    -RelativePaths @(
        $runtimeDirectoriesBeforeRecursive |
            Where-Object { $_ -notlike "lib\orocos\*" }
    )
$componentBatchCalls = Convert-ToBatchCandidateCalls `
    -RelativePaths @(
        $componentDirectoriesBeforeRecursive |
            Where-Object { $_ -notlike "lib\orocos\*" }
    )
$componentBatchCallsAfterRecursive = Convert-ToBatchCandidateCalls `
    -RelativePaths $componentDirectoriesAfterRecursive
$runtimeVcpkgBatchCall = if ([string]::IsNullOrWhiteSpace($runtimeVcpkgPrefix)) {
    ""
} else {
    @(
        '@call :orocos_add_candidate "{0}"' -f (
            Join-Path $runtimeVcpkgPrefix "bin")
        '@if defined __OROCOS_ROCK_PATH_ERROR @goto orocos_runtime_failed'
    ) -join "`n"
}

$runtimeTemplate = @'
# Generated by orocos-rock/tools/export-windows-env.ps1.
# Dot-source this file from PowerShell: . .\env.ps1

& {
    param(
        [string]$Prefix,
        [string]$VcpkgPrefix,
        [string]$Target
    )

    function Set-OrocosRockPathEntries {
        param(
            [string]$Name,
            [string[]]$Values
        )

        $availableValues = @(
            $Values | Where-Object {
                Test-Path -LiteralPath $_ -PathType Container
            }
        )
        $current = [Environment]::GetEnvironmentVariable($Name, "Process")
        $existing = if ([string]::IsNullOrWhiteSpace($current)) {
            @()
        } else {
            @($current -split [regex]::Escape([IO.Path]::PathSeparator))
        }

        $seen = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        $combined = [Collections.Generic.List[string]]::new()
        foreach ($entry in @($availableValues) + @($existing)) {
            if (-not [string]::IsNullOrWhiteSpace($entry) -and
                $seen.Add($entry)) {
                [void]$combined.Add($entry)
            }
        }

        [Environment]::SetEnvironmentVariable(
            $Name,
            ($combined -join [IO.Path]::PathSeparator),
            "Process")
    }

    $orocosDirectory = Join-Path $Prefix "lib\orocos"
    $installedOrocosDirectories = if (
        Test-Path -LiteralPath $orocosDirectory -PathType Container
    ) {
        @(Get-ChildItem -LiteralPath $orocosDirectory -Directory -Recurse |
            ForEach-Object FullName)
    } else {
        @()
    }
    $componentDirectories = @(
@COMPONENT_POWERSHELL_PATHS@
    ) + $installedOrocosDirectories + @(
@COMPONENT_POWERSHELL_PATHS_AFTER_RECURSIVE@
    )
    $runtimeDirectories = @(
@RUNTIME_POWERSHELL_PATHS@
    ) + $installedOrocosDirectories
    if (-not [string]::IsNullOrWhiteSpace($VcpkgPrefix)) {
        $runtimeDirectories += Join-Path $VcpkgPrefix "bin"
    }
    $pkgConfigDirectory = Join-Path $Prefix "lib\pkgconfig"
    $typelibPluginDirectory = Join-Path $Prefix "lib\typelib"

    $env:OROCOS_PREFIX = $Prefix
    $env:OROCOS_TARGET = $Target
    $env:PKG_CONFIG_LIBDIR = $pkgConfigDirectory
    Set-OrocosRockPathEntries -Name "PATH" -Values $runtimeDirectories
    Set-OrocosRockPathEntries `
        -Name "RTT_COMPONENT_PATH" -Values $componentDirectories
    Set-OrocosRockPathEntries `
        -Name "PKG_CONFIG_PATH" -Values @($pkgConfigDirectory)
    Set-OrocosRockPathEntries `
        -Name "TYPELIB_PLUGIN_PATH" -Values @($typelibPluginDirectory)
    Set-OrocosRockPathEntries -Name "CMAKE_PREFIX_PATH" -Values @($Prefix)
} $PSScriptRoot '@VCPKG_PREFIX@' '@TARGET@'
'@

$runtimeBatchTemplate = @'
@rem Generated by orocos-rock/tools/export-windows-env.ps1.
@rem Call this file from cmd.exe: call env.bat

@for %%I in ("%~dp0.") do @set "OROCOS_PREFIX=%%~fI"
@set "OROCOS_TARGET=@TARGET@"

@if /I not "%~1"=="--conda" @goto orocos_full_runtime_path
@call :orocos_begin_path PATH
@if errorlevel 1 @goto orocos_runtime_failed
@call :orocos_add_candidate "%OROCOS_PREFIX%\lib\orocos\@TARGET@\plugins"
@if defined __OROCOS_ROCK_PATH_ERROR @goto orocos_runtime_failed
@if not defined __OROCOS_ROCK_RECORD_RUNTIME_PLUGIN @goto orocos_conda_plugin_state_recorded
@set "__OROCOS_ROCK_PATH_RUNTIME_PLUGIN_PRESENT=1"
@if "%__OROCOS_ROCK_PATH_CANDIDATE_ADDED%"=="1" @set "__OROCOS_ROCK_PATH_RUNTIME_PLUGIN_PRESENT=0"
:orocos_conda_plugin_state_recorded
@call :orocos_commit_path
@if errorlevel 1 @goto orocos_runtime_failed
@goto orocos_runtime_path_ready

:orocos_full_runtime_path
@call :orocos_begin_path PATH
@if errorlevel 1 @goto orocos_runtime_failed
@RUNTIME_BATCH_CALLS@
@if exist "%OROCOS_PREFIX%\lib\orocos\" @for /d /r "%OROCOS_PREFIX%\lib\orocos" %%D in (*) do @call :orocos_add_candidate "%%~fD"
@if defined __OROCOS_ROCK_PATH_ERROR @goto orocos_runtime_failed
@RUNTIME_VCPKG_BATCH_CALL@
@call :orocos_commit_path
@if errorlevel 1 @goto orocos_runtime_failed
:orocos_runtime_path_ready

@call :orocos_begin_path RTT_COMPONENT_PATH
@if errorlevel 1 @goto orocos_runtime_failed
@COMPONENT_BATCH_CALLS@
@if exist "%OROCOS_PREFIX%\lib\orocos\" @for /d /r "%OROCOS_PREFIX%\lib\orocos" %%D in (*) do @call :orocos_add_candidate "%%~fD"
@if defined __OROCOS_ROCK_PATH_ERROR @goto orocos_runtime_failed
@COMPONENT_BATCH_CALLS_AFTER_RECURSIVE@
@call :orocos_commit_path
@if errorlevel 1 @goto orocos_runtime_failed

@set "PKG_CONFIG_LIBDIR=%OROCOS_PREFIX%\lib\pkgconfig"
@call :orocos_begin_path PKG_CONFIG_PATH
@if errorlevel 1 @goto orocos_runtime_failed
@call :orocos_add_candidate "%OROCOS_PREFIX%\lib\pkgconfig"
@if defined __OROCOS_ROCK_PATH_ERROR @goto orocos_runtime_failed
@call :orocos_commit_path
@if errorlevel 1 @goto orocos_runtime_failed

@call :orocos_begin_path TYPELIB_PLUGIN_PATH
@if errorlevel 1 @goto orocos_runtime_failed
@call :orocos_add_candidate "%OROCOS_PREFIX%\lib\typelib"
@if defined __OROCOS_ROCK_PATH_ERROR @goto orocos_runtime_failed
@call :orocos_commit_path
@if errorlevel 1 @goto orocos_runtime_failed

@call :orocos_begin_path CMAKE_PREFIX_PATH
@if errorlevel 1 @goto orocos_runtime_failed
@call :orocos_add_candidate "%OROCOS_PREFIX%"
@if defined __OROCOS_ROCK_PATH_ERROR @goto orocos_runtime_failed
@call :orocos_commit_path
@if errorlevel 1 @goto orocos_runtime_failed
@exit /b 0

:orocos_begin_path
@set "__OROCOS_ROCK_PATH_NAME=%~1"
@set "__OROCOS_ROCK_PATH_PREFIX="
@set "__OROCOS_ROCK_PATH_CANDIDATE="
@set "__OROCOS_ROCK_PATH_CANDIDATE_ADDED=0"
@set "__OROCOS_ROCK_PATH_ERROR="
@if not exist "%SystemRoot%\System32\findstr.exe" @goto orocos_begin_path_failed
@if /I "%~1"=="PATH" @exit /b 0
@if /I "%~1"=="RTT_COMPONENT_PATH" @exit /b 0
@if /I "%~1"=="PKG_CONFIG_PATH" @exit /b 0
@if /I "%~1"=="TYPELIB_PLUGIN_PATH" @exit /b 0
@if /I "%~1"=="CMAKE_PREFIX_PATH" @exit /b 0
:orocos_begin_path_failed
@set "__OROCOS_ROCK_PATH_ERROR=1"
@exit /b 1

:orocos_path_contains_candidate
@set "__OROCOS_ROCK_PATH_CANDIDATE=%~1"
@set %__OROCOS_ROCK_PATH_NAME% 2>nul | @"%SystemRoot%\System32\findstr.exe" /I /L /B /C:"%__OROCOS_ROCK_PATH_NAME%=" | @"%SystemRoot%\System32\findstr.exe" /I /L /X /C:"%__OROCOS_ROCK_PATH_NAME%=%__OROCOS_ROCK_PATH_CANDIDATE%" >nul
@if not errorlevel 1 @goto orocos_path_candidate_found_exact
@if errorlevel 2 @goto orocos_path_candidate_search_failed
@set %__OROCOS_ROCK_PATH_NAME% 2>nul | @"%SystemRoot%\System32\findstr.exe" /I /L /B /C:"%__OROCOS_ROCK_PATH_NAME%=" | @"%SystemRoot%\System32\findstr.exe" /I /L /B /C:"%__OROCOS_ROCK_PATH_NAME%=%__OROCOS_ROCK_PATH_CANDIDATE%;" >nul
@if not errorlevel 1 @goto orocos_path_candidate_found_beginning
@if errorlevel 2 @goto orocos_path_candidate_search_failed
@set %__OROCOS_ROCK_PATH_NAME% 2>nul | @"%SystemRoot%\System32\findstr.exe" /I /L /B /C:"%__OROCOS_ROCK_PATH_NAME%=" | @"%SystemRoot%\System32\findstr.exe" /I /L /C:";%__OROCOS_ROCK_PATH_CANDIDATE%;" >nul
@if not errorlevel 1 @goto orocos_path_candidate_found_middle
@if errorlevel 2 @goto orocos_path_candidate_search_failed
@set %__OROCOS_ROCK_PATH_NAME% 2>nul | @"%SystemRoot%\System32\findstr.exe" /I /L /B /C:"%__OROCOS_ROCK_PATH_NAME%=" | @"%SystemRoot%\System32\findstr.exe" /I /L /E /C:";%__OROCOS_ROCK_PATH_CANDIDATE%" >nul
@if not errorlevel 1 @goto orocos_path_candidate_found_end
@if errorlevel 2 @goto orocos_path_candidate_search_failed
@set "__OROCOS_ROCK_PATH_CANDIDATE="
@exit /b 1

:orocos_path_candidate_found_exact
@set "__OROCOS_ROCK_PATH_CANDIDATE="
@exit /b 0
:orocos_path_candidate_found_beginning
@set "__OROCOS_ROCK_PATH_CANDIDATE="
@exit /b 0
:orocos_path_candidate_found_middle
@set "__OROCOS_ROCK_PATH_CANDIDATE="
@exit /b 0
:orocos_path_candidate_found_end
@set "__OROCOS_ROCK_PATH_CANDIDATE="
@exit /b 0
:orocos_path_candidate_search_failed
@set "__OROCOS_ROCK_PATH_CANDIDATE="
@exit /b 2

:orocos_add_candidate_failed
@set "__OROCOS_ROCK_PATH_ERROR=1"
@exit /b 1

:orocos_add_candidate
@set "__OROCOS_ROCK_PATH_CANDIDATE_ADDED=0"
@if "%~1"=="" @exit /b 0
@if not exist "%~1\" @exit /b 0
@call :orocos_path_contains_candidate "%~1"
@if errorlevel 2 @goto orocos_add_candidate_failed
@if not errorlevel 1 @exit /b 0
@set "__OROCOS_ROCK_PATH_PREFIX=%__OROCOS_ROCK_PATH_PREFIX%;%~1"
@set "__OROCOS_ROCK_PATH_CANDIDATE_ADDED=1"
@exit /b 0

:orocos_commit_path
@if not defined __OROCOS_ROCK_PATH_PREFIX @goto orocos_path_committed
@if /I "%__OROCOS_ROCK_PATH_NAME%"=="PATH" @goto orocos_commit_PATH
@if /I "%__OROCOS_ROCK_PATH_NAME%"=="RTT_COMPONENT_PATH" @goto orocos_commit_RTT_COMPONENT_PATH
@if /I "%__OROCOS_ROCK_PATH_NAME%"=="PKG_CONFIG_PATH" @goto orocos_commit_PKG_CONFIG_PATH
@if /I "%__OROCOS_ROCK_PATH_NAME%"=="TYPELIB_PLUGIN_PATH" @goto orocos_commit_TYPELIB_PLUGIN_PATH
@if /I "%__OROCOS_ROCK_PATH_NAME%"=="CMAKE_PREFIX_PATH" @goto orocos_commit_CMAKE_PREFIX_PATH
@goto orocos_begin_path_failed

:orocos_commit_PATH
@if defined PATH @goto orocos_commit_PATH_with_existing
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "PATH=%__OROCOS_ROCK_PATH_PREFIX:~1%" && @set "__OROCOS_ROCK_PATH_COMMIT_OK=1"
@if not defined __OROCOS_ROCK_PATH_COMMIT_OK @goto orocos_runtime_failed
@goto orocos_path_committed
:orocos_commit_PATH_with_existing
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "PATH=%__OROCOS_ROCK_PATH_PREFIX:~1%;%PATH%" && @set "__OROCOS_ROCK_PATH_COMMIT_OK=1"
@if not defined __OROCOS_ROCK_PATH_COMMIT_OK @goto orocos_runtime_failed
@goto orocos_path_committed

:orocos_commit_RTT_COMPONENT_PATH
@if defined RTT_COMPONENT_PATH @goto orocos_commit_RTT_COMPONENT_PATH_with_existing
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "RTT_COMPONENT_PATH=%__OROCOS_ROCK_PATH_PREFIX:~1%" && @set "__OROCOS_ROCK_PATH_COMMIT_OK=1"
@if not defined __OROCOS_ROCK_PATH_COMMIT_OK @goto orocos_runtime_failed
@goto orocos_path_committed
:orocos_commit_RTT_COMPONENT_PATH_with_existing
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "RTT_COMPONENT_PATH=%__OROCOS_ROCK_PATH_PREFIX:~1%;%RTT_COMPONENT_PATH%" && @set "__OROCOS_ROCK_PATH_COMMIT_OK=1"
@if not defined __OROCOS_ROCK_PATH_COMMIT_OK @goto orocos_runtime_failed
@goto orocos_path_committed

:orocos_commit_PKG_CONFIG_PATH
@if defined PKG_CONFIG_PATH @goto orocos_commit_PKG_CONFIG_PATH_with_existing
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "PKG_CONFIG_PATH=%__OROCOS_ROCK_PATH_PREFIX:~1%" && @set "__OROCOS_ROCK_PATH_COMMIT_OK=1"
@if not defined __OROCOS_ROCK_PATH_COMMIT_OK @goto orocos_runtime_failed
@goto orocos_path_committed
:orocos_commit_PKG_CONFIG_PATH_with_existing
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "PKG_CONFIG_PATH=%__OROCOS_ROCK_PATH_PREFIX:~1%;%PKG_CONFIG_PATH%" && @set "__OROCOS_ROCK_PATH_COMMIT_OK=1"
@if not defined __OROCOS_ROCK_PATH_COMMIT_OK @goto orocos_runtime_failed
@goto orocos_path_committed

:orocos_commit_TYPELIB_PLUGIN_PATH
@if defined TYPELIB_PLUGIN_PATH @goto orocos_commit_TYPELIB_PLUGIN_PATH_with_existing
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "TYPELIB_PLUGIN_PATH=%__OROCOS_ROCK_PATH_PREFIX:~1%" && @set "__OROCOS_ROCK_PATH_COMMIT_OK=1"
@if not defined __OROCOS_ROCK_PATH_COMMIT_OK @goto orocos_runtime_failed
@goto orocos_path_committed
:orocos_commit_TYPELIB_PLUGIN_PATH_with_existing
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "TYPELIB_PLUGIN_PATH=%__OROCOS_ROCK_PATH_PREFIX:~1%;%TYPELIB_PLUGIN_PATH%" && @set "__OROCOS_ROCK_PATH_COMMIT_OK=1"
@if not defined __OROCOS_ROCK_PATH_COMMIT_OK @goto orocos_runtime_failed
@goto orocos_path_committed

:orocos_commit_CMAKE_PREFIX_PATH
@if defined CMAKE_PREFIX_PATH @goto orocos_commit_CMAKE_PREFIX_PATH_with_existing
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "CMAKE_PREFIX_PATH=%__OROCOS_ROCK_PATH_PREFIX:~1%" && @set "__OROCOS_ROCK_PATH_COMMIT_OK=1"
@if not defined __OROCOS_ROCK_PATH_COMMIT_OK @goto orocos_runtime_failed
@goto orocos_path_committed
:orocos_commit_CMAKE_PREFIX_PATH_with_existing
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "CMAKE_PREFIX_PATH=%__OROCOS_ROCK_PATH_PREFIX:~1%;%CMAKE_PREFIX_PATH%" && @set "__OROCOS_ROCK_PATH_COMMIT_OK=1"
@if not defined __OROCOS_ROCK_PATH_COMMIT_OK @goto orocos_runtime_failed

:orocos_path_committed
@set "__OROCOS_ROCK_PATH_NAME="
@set "__OROCOS_ROCK_PATH_PREFIX="
@set "__OROCOS_ROCK_PATH_CANDIDATE="
@set "__OROCOS_ROCK_PATH_CANDIDATE_ADDED="
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "__OROCOS_ROCK_PATH_ERROR="
@exit /b 0

:orocos_runtime_failed
@set "__OROCOS_ROCK_PATH_NAME="
@set "__OROCOS_ROCK_PATH_PREFIX="
@set "__OROCOS_ROCK_PATH_CANDIDATE="
@set "__OROCOS_ROCK_PATH_CANDIDATE_ADDED="
@set "__OROCOS_ROCK_PATH_COMMIT_OK="
@set "__OROCOS_ROCK_PATH_ERROR="
@exit /b 1
'@

$developmentTemplate = @'
# Generated by orocos-rock/tools/export-windows-env.ps1.
# Dot-source this file from PowerShell: . .\dev-env.ps1

. (Join-Path $PSScriptRoot "env.ps1")

& {
    param(
        [string]$Prefix,
        [string]$VcpkgRoot,
        [string]$VcpkgPrefix,
        [string]$VcpkgTriplet,
        [string]$RubyVersion,
        [string]$RubyArch
    )

    function Set-OrocosRockPathEntries {
        param(
            [string]$Name,
            [string[]]$Values
        )

        $availableValues = @(
            $Values | Where-Object {
                Test-Path -LiteralPath $_ -PathType Container
            }
        )
        $current = [Environment]::GetEnvironmentVariable($Name, "Process")
        $existing = if ([string]::IsNullOrWhiteSpace($current)) {
            @()
        } else {
            @($current -split [regex]::Escape([IO.Path]::PathSeparator))
        }
        $seen = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        $combined = [Collections.Generic.List[string]]::new()
        foreach ($entry in @($availableValues) + @($existing)) {
            if (-not [string]::IsNullOrWhiteSpace($entry) -and
                $seen.Add($entry)) {
                [void]$combined.Add($entry)
            }
        }

        [Environment]::SetEnvironmentVariable(
            $Name,
            ($combined -join [IO.Path]::PathSeparator),
            "Process")
    }

    if ([string]::IsNullOrWhiteSpace($VcpkgPrefix)) {
        $candidate = Join-Path $Prefix "vcpkg"
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $VcpkgPrefix = $candidate
        }
    }
    if ([string]::IsNullOrWhiteSpace($VcpkgRoot)) {
        [Environment]::SetEnvironmentVariable("VCPKG_ROOT", $null, "Process")
    } else {
        $env:VCPKG_ROOT = $VcpkgRoot
    }
    $env:VCPKG_DEFAULT_TRIPLET = $VcpkgTriplet
    $gemHome = Join-Path $Prefix "toolchain\gems"
    $env:GEM_HOME = $gemHome
    $rubyCommand = Get-Command ruby.exe -CommandType Application `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $rubyCommand) {
        throw "The Orocos development environment requires ruby.exe on PATH."
    }
    $developmentPathEntries = @(
        (Join-Path $Prefix "toolchain\bin"),
        (Split-Path -Parent $rubyCommand.Source)
    )
    if (-not [string]::IsNullOrWhiteSpace($VcpkgPrefix)) {
        $developmentPathEntries += Join-Path $VcpkgPrefix "debug\bin"
    }
    Set-OrocosRockPathEntries -Name "PATH" -Values $developmentPathEntries
    Set-OrocosRockPathEntries -Name "GEM_PATH" -Values @($gemHome)
    Set-OrocosRockPathEntries -Name "RUBYLIB" -Values @(
        (Join-Path $Prefix "lib\ruby\$RubyVersion"),
        (Join-Path $Prefix "lib\$RubyArch\ruby\$RubyVersion"),
        (Join-Path $Prefix "lib\ruby\$RubyVersion\$RubyArch")
    )
    $developmentPrefixes = @($Prefix)
    $pkgConfigDirectories = @(Join-Path $Prefix "lib\pkgconfig")
    if (-not [string]::IsNullOrWhiteSpace($VcpkgPrefix)) {
        $developmentPrefixes += $VcpkgPrefix
        $pkgConfigDirectories += Join-Path $VcpkgPrefix "lib\pkgconfig"
    }
    $env:PKG_CONFIG_LIBDIR = $pkgConfigDirectories -join [IO.Path]::PathSeparator
    Set-OrocosRockPathEntries `
        -Name "PKG_CONFIG_PATH" -Values $pkgConfigDirectories
    Set-OrocosRockPathEntries `
        -Name "CMAKE_PREFIX_PATH" -Values $developmentPrefixes
} $PSScriptRoot '@VCPKG_ROOT@' '@VCPKG_PREFIX@' '@VCPKG_TRIPLET@' `
    '@RUBY_VERSION@' '@RUBY_ARCH@'
'@

$runtimeScript = $runtimeTemplate.Replace(
    "@RUNTIME_POWERSHELL_PATHS@", $runtimePowerShellPaths).Replace(
    "@COMPONENT_POWERSHELL_PATHS@", $componentPowerShellPaths).Replace(
    "@COMPONENT_POWERSHELL_PATHS_AFTER_RECURSIVE@",
    $componentPowerShellPathsAfterRecursive).Replace(
    "@VCPKG_PREFIX@", $runtimeVcpkgPrefixLiteral).Replace(
    "@TARGET@", $targetLiteral)
$runtimeBatchScript = $runtimeBatchTemplate.Replace(
    "@RUNTIME_BATCH_CALLS@", $runtimeBatchCalls).Replace(
    "@COMPONENT_BATCH_CALLS@", $componentBatchCalls).Replace(
    "@COMPONENT_BATCH_CALLS_AFTER_RECURSIVE@",
    $componentBatchCallsAfterRecursive).Replace(
    "@RUNTIME_VCPKG_BATCH_CALL@", $runtimeVcpkgBatchCall).Replace(
    "@TARGET@", $Target)
$developmentScript = $developmentTemplate.Replace(
    "@VCPKG_ROOT@", $vcpkgRootLiteral).Replace(
    "@VCPKG_PREFIX@", $vcpkgPrefixLiteral).Replace(
    "@VCPKG_TRIPLET@", $tripletLiteral).Replace(
    "@RUBY_VERSION@", $rubyVersionLiteral).Replace(
    "@RUBY_ARCH@", $rubyArchLiteral)

$runtimePath = Join-Path $Prefix "env.ps1"
$runtimeBatchPath = Join-Path $Prefix "env.bat"
$developmentPath = Join-Path $Prefix "dev-env.ps1"
Write-PowerShellScript -Path $runtimePath -Contents $runtimeScript
Write-BatchScript -Path $runtimeBatchPath -Contents $runtimeBatchScript
Write-PowerShellScript -Path $developmentPath -Contents $developmentScript

Write-Host "Wrote $runtimePath"
Write-Host "Wrote $runtimeBatchPath"
Write-Host "Wrote $developmentPath"
