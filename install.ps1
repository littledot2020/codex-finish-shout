# Codex Finish Shout notify one-time installer.

[CmdletBinding()]
param(
    [string] $TargetRoot,
    [switch] $Force
)

$arguments = @{
    Force = $Force
}
if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) {
    $arguments.TargetRoot = $TargetRoot
}

& (Join-Path $PSScriptRoot 'codex-finish-shout\scripts\install.ps1') @arguments
