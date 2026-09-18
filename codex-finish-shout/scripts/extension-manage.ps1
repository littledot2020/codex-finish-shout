# Codex Finish Shout VS Code management bridge. JSON on stdout; errors on stderr.
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall', 'Status')][string] $Action = 'Status',
    [Parameter(Mandatory = $true)][string] $TargetRoot
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
try {
    Import-Module (Join-Path $PSScriptRoot 'CodexFinishShout.Setup.psm1') -Force
    $result = switch ($Action) {
        'Install' { Install-CodexFinishShout -TargetRoot $TargetRoot -SourceDirectory $PSScriptRoot }
        'Uninstall' { Uninstall-CodexFinishShout -TargetRoot $TargetRoot }
        'Status' { Get-CodexFinishShoutStatus -TargetRoot $TargetRoot }
    }
    $result | ConvertTo-Json -Depth 12 -Compress
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
