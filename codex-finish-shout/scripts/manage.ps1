# Codex Finish Shout notify management entry point.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Install', 'Uninstall', 'Enable', 'Disable', 'Status', 'Stop', 'Test')]
    [string] $Action = 'Status',

    [string] $TargetRoot,
    [switch] $Force,
    [switch] $NoAudio
)

$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'CodexFinishShout.Setup.psm1') -Force -ErrorAction Stop

    switch ($Action) {
        'Install' {
            Install-CodexFinishShout `
                -TargetRoot $TargetRoot `
                -SourceDirectory $PSScriptRoot `
                -Force:$Force |
                Format-List
        }
        'Uninstall' {
            Uninstall-CodexFinishShout `
                -TargetRoot $TargetRoot `
                -Force:$Force |
                Format-List
        }
        'Enable' {
            Set-CodexFinishShoutEnabled -Enabled $true -TargetRoot $TargetRoot |
                Format-List
        }
        'Disable' {
            Set-CodexFinishShoutEnabled -Enabled $false -TargetRoot $TargetRoot |
                Format-List
        }
        'Status' {
            Get-CodexFinishShoutStatus -TargetRoot $TargetRoot |
                Format-List
        }
        'Stop' {
            $status = Get-CodexFinishShoutStatus -TargetRoot $TargetRoot
            $stopScript = $null
            if (-not [string]::IsNullOrWhiteSpace($status.RuntimeScript)) {
                $stopScript = Join-Path ([IO.Path]::GetDirectoryName($status.RuntimeScript)) 'stop-audio.ps1'
            }
            if ($null -eq $stopScript -or -not [IO.File]::Exists($stopScript)) {
                $stopScript = Join-Path $PSScriptRoot 'stop-audio.ps1'
            }
            & $stopScript -StateDirectory $status.StateDirectory
            [pscustomobject]@{
                Action = 'Stop'
                Requested = $true
                StateDirectory = $status.StateDirectory
            } | Format-List
        }
        'Test' {
            $status = Get-CodexFinishShoutStatus -TargetRoot $TargetRoot
            $testScript = $status.RuntimeScript
            if (-not [IO.File]::Exists($testScript)) {
                $testScript = Join-Path $PSScriptRoot 'codex-finish-shout.ps1'
            }

            & $testScript -Test -NoAudio:$NoAudio
            [Console]::Out.WriteLine()
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
