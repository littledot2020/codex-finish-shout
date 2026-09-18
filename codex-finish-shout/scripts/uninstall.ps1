# Codex Finish Shout notify uninstaller.

[CmdletBinding()]
param(
    [string] $TargetRoot,
    [switch] $Force
)

$arguments = @{
    Action = 'Uninstall'
    Force  = $Force
}
if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) {
    $arguments.TargetRoot = $TargetRoot
}

& (Join-Path $PSScriptRoot 'manage.ps1') @arguments
