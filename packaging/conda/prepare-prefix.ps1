[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$VcpkgRoot,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$RubyExecutable = Get-Command ruby.exe -CommandType Application `
    -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source

function Resolve-RequiredDirectory {
    param(
        [string]$Path,
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Missing $Name directory: $Path"
    }
    (Resolve-Path -LiteralPath $Path).Path
}

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Missing directory to package: $Source"
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item `
        -Destination $Destination -Recurse -Force
}

function Get-BinaryDependencies {
    param([string]$Path)

    $output = & $script:Dumpbin /DEPENDENTS $Path 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "dumpbin failed for '$Path':`n$output"
    }

    @(
        [regex]::Matches(
            $output,
            '(?im)^\s+([A-Za-z0-9_.+\-]+\.dll)\s*$') |
            ForEach-Object { $_.Groups[1].Value }
    )
}

function Test-ExternalRuntimeDependency {
    param([string]$Name)

    $Name -match '^(?i:api-ms-win-|ext-ms-win-)' -or
        $Name -match '^(?i:KERNEL32|USER32|ADVAPI32|IPHLPAPI|WS2_32|WINMM|SHELL32|OLE32|OLEAUT32|CRYPT32|BCRYPT|NTDLL|D3D11|D3DCOMPILER_47|DXGI|VERSION)\.dll$' -or
        $Name -match '^(?i:MSVCP140D?(?:_[0-9A-Z_]+)?|VCRUNTIME140D?(?:_[0-9A-Z_]+)?|CONCRT140D?|UCRTBASED?)\.dll$' -or
        $Name -match '^(?i:x64-.*ruby.*|ruby.*)\.dll$'
}

function Copy-RuntimeDependencyClosure {
    param(
        [string]$InstalledPrefix,
        [string]$VcpkgBin
    )

    $destination = Join-Path $InstalledPrefix "bin"
    $available = @{}
    Get-ChildItem -LiteralPath $VcpkgBin -File -Filter "*.dll" |
        ForEach-Object { $available[$_.Name.ToLowerInvariant()] = $_.FullName }

    $knownNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($runtimeDirectory in @(
            $destination,
            (Join-Path $InstalledPrefix "lib"),
            (Join-Path $InstalledPrefix "lib\typelib"),
            (Join-Path $InstalledPrefix "lib\orocos")
        )) {
        if (-not (Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
            continue
        }
        $recurse = $runtimeDirectory.EndsWith("\orocos")
        Get-ChildItem -LiteralPath $runtimeDirectory -File -Filter "*.dll" `
            -Recurse:$recurse |
            ForEach-Object { [void]$knownNames.Add($_.Name) }
    }

    $queue = [Collections.Generic.Queue[string]]::new()
    $bundledSdk = Join-Path $InstalledPrefix "vcpkg"
    Get-ChildItem -LiteralPath $InstalledPrefix -Recurse -File |
        Where-Object {
            $_.Extension -in @(".dll", ".exe", ".so") -and
            -not $_.FullName.StartsWith(
                $bundledSdk + "\",
                [StringComparison]::OrdinalIgnoreCase)
        } |
        ForEach-Object { $queue.Enqueue($_.FullName) }
    $processed = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $copied = [Collections.Generic.List[string]]::new()

    while ($queue.Count -gt 0) {
        $binary = $queue.Dequeue()
        if (-not $processed.Add($binary)) {
            continue
        }

        foreach ($dependency in Get-BinaryDependencies -Path $binary) {
            if ($knownNames.Contains($dependency) -or
                (Test-ExternalRuntimeDependency -Name $dependency)) {
                continue
            }

            $key = $dependency.ToLowerInvariant()
            if (-not $available.ContainsKey($key)) {
                throw "No packaged or external provider found for '$dependency', required by '$binary'."
            }

            $target = Join-Path $destination $dependency
            Copy-Item -LiteralPath $available[$key] -Destination $target -Force
            [void]$knownNames.Add($dependency)
            [void]$copied.Add($dependency)
            $queue.Enqueue($target)
        }
    }

    $copied | Sort-Object -Unique
}

function Remove-PackagingSmokeArtifacts {
    param([string]$InstalledPrefix)

    $directories = @(
        "include\orocos\windows_smoke",
        "include\orocos\windows_typegen_smoke"
    )
    foreach ($relativePath in $directories) {
        $path = Join-Path $InstalledPrefix $relativePath
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }

    $files = @(
        "bin\windows_smoke_deployer.exe",
        "bin\helloworld-win32.exe",
        "bin\ctaskbrowser-opcua",
        "bin\deployer",
        "bin\deployer-opcua",
        "bin\rttscript",
        "etc\orocos\profile.d\00.rtt.sh"
    )
    foreach ($relativePath in $files) {
        $path = Join-Path $InstalledPrefix $relativePath
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    $patternsByDirectory = [ordered]@{
        "lib\orocos" = @("windows_smoke-*")
        "lib\orocos\types" = @("windows_smoke-*", "windows_typegen_smoke-*")
        "lib\pkgconfig" = @(
            "orogen-project-windows_smoke.pc",
            "orogen-windows_smoke_deployer.pc",
            "windows_smoke-*.pc",
            "windows_typegen_smoke-*.pc"
        )
        "share\orogen" = @("windows_smoke.*", "windows_typegen_smoke.*")
    }
    foreach ($entry in $patternsByDirectory.GetEnumerator()) {
        $directory = Join-Path $InstalledPrefix $entry.Key
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            continue
        }
        foreach ($pattern in $entry.Value) {
            Get-ChildItem -LiteralPath $directory -File -Filter $pattern |
                Remove-Item -Force
        }
    }

    $rubyBin = Join-Path $InstalledPrefix "toolchain\bin"
    if (Test-Path -LiteralPath $rubyBin -PathType Container) {
        foreach ($launcher in Get-ChildItem -LiteralPath $rubyBin -File |
                Where-Object { [string]::IsNullOrEmpty($_.Extension) }) {
            $contents = Get-Content -LiteralPath $launcher.FullName -Raw
            $contents = [regex]::Replace(
                $contents,
                '(?m)^#![A-Za-z]:[/\\].*[/\\]ruby(?:\.exe)?\r?$',
                '#!ruby')
            Write-Utf8Text -Path $launcher.FullName -Contents $contents
        }
    }
    $rubyGemCache = Join-Path $InstalledPrefix "toolchain\gems\cache"
    if (Test-Path -LiteralPath $rubyGemCache -PathType Container) {
        Remove-Item -LiteralPath $rubyGemCache -Recurse -Force
    }
}

function Write-Utf8Text {
    param(
        [string]$Path,
        [string]$Contents
    )

    [IO.File]::WriteAllText(
        $Path,
        $Contents,
        [Text.UTF8Encoding]::new($false))
}

function Convert-PkgConfigFiles {
    param(
        [string]$InstalledPrefix,
        [string]$VcpkgInstalled
    )

    $prefixForward = $InstalledPrefix -replace "\\", "/"
    $vcpkgForward = $VcpkgInstalled -replace "\\", "/"
    $pkgConfigRoot = Join-Path $InstalledPrefix "lib\pkgconfig"
    foreach ($file in Get-ChildItem -LiteralPath $pkgConfigRoot -File -Filter "*.pc") {
        $contents = Get-Content -LiteralPath $file.FullName -Raw
        $contents = $contents.Replace($vcpkgForward, '${prefix}/vcpkg')
        $contents = $contents.Replace($VcpkgInstalled, '${prefix}/vcpkg')
        $contents = $contents.Replace($prefixForward, '${prefix}')
        $contents = $contents.Replace($InstalledPrefix, '${prefix}')
        if ($contents -match '(?m)^prefix=') {
            $contents = [regex]::Replace(
                $contents,
                '(?m)^prefix=.*$',
                'prefix=${pcfiledir}/../..')
        } else {
            $contents = "prefix=`${pcfiledir}/../..`n$contents"
        }
        Write-Utf8Text -Path $file.FullName -Contents $contents
    }
}

function Convert-RttCMakeFiles {
    param(
        [string]$InstalledPrefix,
        [string]$VcpkgInstalled
    )

    $vcpkgForward = $VcpkgInstalled -replace "\\", "/"
    $cmakeRoot = Join-Path $InstalledPrefix "lib\cmake\orocos-rtt"
    $replacements = [ordered]@{
        "orocos-rtt-win32-libraries.cmake" = '${_IMPORT_PREFIX}/vcpkg'
        "orocos-rtt-config-win32.cmake" = '${SELF_DIR}/../../../vcpkg'
    }
    foreach ($entry in $replacements.GetEnumerator()) {
        $path = Join-Path $cmakeRoot $entry.Key
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing RTT CMake metadata: $path"
        }
        $contents = Get-Content -LiteralPath $path -Raw
        $contents = $contents.Replace($vcpkgForward, $entry.Value)
        $contents = $contents.Replace($VcpkgInstalled, $entry.Value)
        Write-Utf8Text -Path $path -Contents $contents
    }
}

function Assert-NoBuildPathReferences {
    param(
        [string]$InstalledPrefix,
        [string[]]$Paths
    )

    $needles = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or $path.Length -lt 4) {
            continue
        }
        [void]$needles.Add($path.TrimEnd([char[]]"\/"))
        [void]$needles.Add(($path -replace "\\", "/").TrimEnd("/"))
    }

    $violations = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $InstalledPrefix -Recurse -File) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $sampleLength = [Math]::Min($bytes.Length, 8192)
        $isText = $true
        for ($index = 0; $index -lt $sampleLength; $index++) {
            if ($bytes[$index] -eq 0) {
                $isText = $false
                break
            }
        }
        if (-not $isText) {
            continue
        }
        $contents = [Text.Encoding]::UTF8.GetString($bytes)
        foreach ($needle in $needles) {
            if ($contents.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [void]$violations.Add(
                    "$($file.FullName.Substring($InstalledPrefix.Length + 1)): $needle")
                break
            }
        }
    }

    if ($violations.Count -gt 0) {
        $summary = @($violations | Select-Object -First 20) -join "`n"
        throw "Packaged prefix contains build-path references:`n$summary"
    }
}

$Prefix = Resolve-RequiredDirectory -Path $Prefix -Name "installed prefix"
$Workspace = Resolve-RequiredDirectory -Path $Workspace -Name "build workspace"
$VcpkgRoot = Resolve-RequiredDirectory -Path $VcpkgRoot -Name "vcpkg"
$RepositoryRoot = Resolve-RequiredDirectory -Path $RepositoryRoot -Name "repository"
$vcpkgInstalled = Resolve-RequiredDirectory `
    -Path (Join-Path $VcpkgRoot "installed\x64-windows") `
    -Name "vcpkg installed prefix"
$vcpkgBin = Resolve-RequiredDirectory `
    -Path (Join-Path $vcpkgInstalled "bin") `
    -Name "vcpkg runtime"
$Dumpbin = (Get-Command "dumpbin.exe" -ErrorAction Stop).Source

$bundledVcpkg = Join-Path $Prefix "vcpkg"
Copy-DirectoryContents -Source (Join-Path $vcpkgInstalled "include") `
    -Destination (Join-Path $bundledVcpkg "include")
Copy-DirectoryContents -Source (Join-Path $vcpkgInstalled "lib") `
    -Destination (Join-Path $bundledVcpkg "lib")
Copy-DirectoryContents -Source (Join-Path $vcpkgInstalled "share") `
    -Destination (Join-Path $bundledVcpkg "share")
$bundledReleaseBin = Join-Path $bundledVcpkg "bin"
New-Item -ItemType Directory -Force -Path $bundledReleaseBin | Out-Null
Get-ChildItem -LiteralPath (Join-Path $vcpkgInstalled "bin") `
    -File -Filter "*.dll" | Copy-Item -Destination $bundledReleaseBin -Force
Copy-DirectoryContents -Source (Join-Path $vcpkgInstalled "debug\lib") `
    -Destination (Join-Path $bundledVcpkg "debug\lib")
$bundledDebugBin = Join-Path $bundledVcpkg "debug\bin"
New-Item -ItemType Directory -Force -Path $bundledDebugBin | Out-Null
Get-ChildItem -LiteralPath (Join-Path $vcpkgInstalled "debug\bin") `
    -File -Filter "*.dll" | Copy-Item -Destination $bundledDebugBin -Force
Get-ChildItem -LiteralPath $bundledVcpkg -Recurse -File `
    -Filter "vcpkg_abi_info.txt" | Remove-Item -Force

$copiedRuntimeDependencies = @(
    Copy-RuntimeDependencyClosure -InstalledPrefix $Prefix -VcpkgBin $vcpkgBin
)
Write-Host "Bundled runtime DLLs: $($copiedRuntimeDependencies -join ', ')"

Remove-PackagingSmokeArtifacts -InstalledPrefix $Prefix
Convert-PkgConfigFiles -InstalledPrefix $Prefix -VcpkgInstalled $vcpkgInstalled
Convert-RttCMakeFiles -InstalledPrefix $Prefix -VcpkgInstalled $vcpkgInstalled
$licenseStager = Join-Path $RepositoryRoot "tools\stage-license-corpus.rb"
& $RubyExecutable @(
    $licenseStager,
    "--inventory", (Join-Path $RepositoryRoot "packaging\license-corpus.json"),
    "--source-lock", (Join-Path $RepositoryRoot "packaging\source-lock.json"),
    "--platform", "windows",
    "--source-root", $Workspace,
    "--gem-home", (Join-Path $Prefix "toolchain\gems"),
    "--gem-cache", (Join-Path $RepositoryRoot ".ruby-gems"),
    "--prefix", $Prefix,
    "--vcpkg-share", (Join-Path $vcpkgInstalled "share")
)
if ($LASTEXITCODE -ne 0) {
    throw "License corpus staging exited with code $LASTEXITCODE"
}

& (Join-Path $RepositoryRoot "tools\export-windows-env.ps1") `
    -Prefix $Prefix `
    -VcpkgRoot $VcpkgRoot `
    -VcpkgTriplet "x64-windows" `
    -Target "win32" `
    -BundledDependencies

$pathReferences = @(
    $Prefix,
    $Workspace,
    $VcpkgRoot,
    $RepositoryRoot,
    $env:PREFIX,
    $env:BUILD_PREFIX,
    $env:SRC_DIR
)
Assert-NoBuildPathReferences -InstalledPrefix $Prefix -Paths $pathReferences

Write-Host "Prepared relocatable Orocos prefix: $Prefix"
