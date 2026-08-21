function Get-OrocosWindowsExpectedSourceNames {
    @(
        "farbot"
        "rtlog-cpp"
        "rtt"
        "open62541"
        "open62541pp"
        "rtt_opcua"
        "ocl"
        "utilmm"
        "typelib"
        "rtt_typelib"
        "utilrb"
        "metaruby"
        "orogen"
        "rock-package-set"
        "vcpkg"
    )
}

function Get-OrocosWindowsExpectedRepositories {
    $sourceOrganization = "liufang-robot"
    @{
        "farbot" = "https://github.com/$sourceOrganization/farbot.git"
        "rtlog-cpp" = "https://github.com/$sourceOrganization/rtlog-cpp.git"
        "rtt" = "https://github.com/$sourceOrganization/rtt.git"
        "open62541" = "https://github.com/open62541/open62541.git"
        "open62541pp" = "https://github.com/open62541pp/open62541pp.git"
        "rtt_opcua" = "https://github.com/$sourceOrganization/rtt_opcua.git"
        "ocl" = "https://github.com/$sourceOrganization/ocl.git"
        "utilmm" = "https://github.com/$sourceOrganization/utilmm.git"
        "typelib" = "https://github.com/$sourceOrganization/tools-typelib.git"
        "rtt_typelib" = "https://github.com/$sourceOrganization/tools-rtt_typelib.git"
        "utilrb" = "https://github.com/rock-core/tools-utilrb.git"
        "metaruby" = "https://github.com/rock-core/tools-metaruby.git"
        "orogen" = "https://github.com/$sourceOrganization/tools-orogen.git"
        "rock-package-set" = "https://github.com/rock-core/package_set.git"
        "vcpkg" = "https://github.com/microsoft/vcpkg.git"
    }
}

function Assert-OrocosJsonProperties {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($Value -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$Context must be a JSON object."
    }

    $actual = @($Value.PSObject.Properties.Name)
    $missing = @($Expected | Where-Object { $actual -notcontains $_ })
    $unexpected = @($actual | Where-Object { $Expected -notcontains $_ })

    if ($missing.Count -gt 0) {
        throw "$Context is missing field(s): $($missing -join ', ')."
    }
    if ($unexpected.Count -gt 0) {
        throw "$Context contains unknown field(s): $($unexpected -join ', ')."
    }
}

function Import-OrocosWindowsSourceLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing Windows source lock: $Path"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    try {
        $document = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    } catch {
        throw "Invalid JSON in Windows source lock '$resolvedPath': $($_.Exception.Message)"
    }

    Assert-OrocosJsonProperties -Value $document `
        -Expected @("schema_version", "sources") `
        -Context "Windows source lock root"

    $schemaVersion = $document.schema_version
    $isInteger = $schemaVersion -is [int] -or $schemaVersion -is [long]
    if (-not $isInteger -or $schemaVersion -ne 1) {
        throw "Unsupported Windows source-lock schema version '$schemaVersion'; expected integer 1."
    }

    if ($document.sources -isnot [System.Array]) {
        throw "Windows source lock field 'sources' must be a JSON array."
    }

    $expectedNames = @(Get-OrocosWindowsExpectedSourceNames)
    $expectedRepositories = Get-OrocosWindowsExpectedRepositories
    $sourcesByName = [ordered]@{}
    foreach ($source in @($document.sources)) {
        Assert-OrocosJsonProperties -Value $source `
            -Expected @("name", "repository", "revision") `
            -Context "Windows source lock entry"

        if ($source.name -isnot [string] -or [string]::IsNullOrWhiteSpace($source.name)) {
            throw "Windows source lock entry has an invalid 'name'."
        }
        $name = $source.name
        if ($expectedNames -notcontains $name) {
            throw "Windows source lock contains unknown source '$name'."
        }
        if ($sourcesByName.Contains($name)) {
            throw "Windows source lock contains duplicate source '$name'."
        }
        if ($source.repository -isnot [string] -or [string]::IsNullOrWhiteSpace($source.repository)) {
            throw "Windows source lock source '$name' has an invalid repository."
        }
        $expectedRepository = $expectedRepositories[$name]
        if ($source.repository -cne $expectedRepository) {
            throw "Windows source lock source '$name' expected repository '$expectedRepository', got '$($source.repository)'."
        }
        if ($source.revision -isnot [string] -or $source.revision -notmatch '^[0-9a-fA-F]{40}$') {
            throw "Windows source lock source '$name' must use a full 40-character Git commit revision."
        }

        $sourcesByName[$name] = [pscustomobject]@{
            name = $name
            repository = $source.repository
            revision = $source.revision.ToLowerInvariant()
        }
    }

    $missingNames = @($expectedNames | Where-Object { -not $sourcesByName.Contains($_) })
    if ($missingNames.Count -gt 0) {
        throw "Windows source lock is missing source(s): $($missingNames -join ', ')."
    }

    $sourcesByName
}
