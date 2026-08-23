if ([string]::IsNullOrWhiteSpace($env:CONDA_PREFIX)) {
    throw "Cannot activate Orocos: CONDA_PREFIX is not set."
}

$libraryPrefix = Join-Path -Path $env:CONDA_PREFIX -ChildPath "Library"
$developmentScript = Join-Path -Path $libraryPrefix -ChildPath "dev-env.ps1"
$runtimeScript = Join-Path -Path $libraryPrefix -ChildPath "env.ps1"

if (Test-Path -LiteralPath $developmentScript -PathType Leaf) {
    . $developmentScript
} elseif (Test-Path -LiteralPath $runtimeScript -PathType Leaf) {
    . $runtimeScript
} else {
    throw "Cannot activate Orocos: $env:CONDA_PREFIX does not contain an Orocos package."
}
