# Codex Finish Shout notify uninstaller.

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

& (Join-Path $PSScriptRoot 'codex-finish-shout\scripts\uninstall.ps1') @arguments
