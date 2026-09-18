# Codex Finish Shout notify management wrapper.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Install', 'Uninstall', 'Enable', 'Disable', 'Status', 'Stop', 'Test')]
    [string] $Action = 'Status',

    [string] $TargetRoot,
    [switch] $Force,
    [switch] $NoAudio
)

$arguments = @{
    Action  = $Action
    Force   = $Force
    NoAudio = $NoAudio
}
if (-not [string]::IsNullOrWhiteSpace($TargetRoot)) {
    $arguments.TargetRoot = $TargetRoot
}

& (Join-Path $PSScriptRoot 'codex-finish-shout\scripts\manage.ps1') @arguments
