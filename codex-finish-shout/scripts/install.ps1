# Codex Finish Shout notify one-time installer.

[CmdletBinding()]
param(
    [string] $TargetRoot,
    [switch] $Force
)

$arguments = @{
    Action = 'Install'
    Force  = $Force
}
if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) {
    $arguments.TargetRoot = $TargetRoot
}

& (Join-Path $PSScriptRoot 'manage.ps1') @arguments
