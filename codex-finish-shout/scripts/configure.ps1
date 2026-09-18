# Codex Finish Shout notify settings manager.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'Show',
        'SetAudio',
        'SetBuiltinAudio',
        'SetTts',
        'SetPlayback',
        'SetQuietHours',
        'DisableQuietHours',
        'Enable',
        'Disable',
        'Reset',
        'Test'
    )]
    [string] $Action = 'Show',

    [string] $AudioFile,
    [ValidateSet('soft-chime', 'bright-finish', 'gentle-rise')]
    [string] $Sound = 'soft-chime',
    [ValidateSet('once', 'loop', 'seconds')]
    [string] $PlaybackMode = 'once',
    [ValidateRange(1, 86400)]
    [int] $PlaybackSeconds = 30,
    [ValidateRange(1, 86400)]
    [int] $PlaybackMaximumSeconds = 3600,
    [string] $QuietStart = '22:00',
    [string] $QuietEnd = '08:00',
    [string] $ConfigPath,
    [string] $BackupDirectory,
    [switch] $NoAudio
)

$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'CodexFinishShout.psm1') -Force -ErrorAction Stop
    $resolvedConfig = Resolve-CodexFinishConfigPath -ConfigPath $ConfigPath

    if ($Action -eq 'Test') {
        & (Join-Path $PSScriptRoot 'codex-finish-shout.ps1') `
            -Test `
            -NoAudio:$NoAudio `
            -ConfigPath $resolvedConfig
        [Console]::Out.WriteLine()
        exit 0
    }

    if ($Action -eq 'Reset') {
        $settings = Get-CodexFinishDefaultSettings
    }
    else {
        $settings = Get-CodexFinishSettings -ConfigPath $resolvedConfig
    }

    switch ($Action) {
        'Show' {
            [pscustomobject] @{
                ConfigPath = $resolvedConfig
                Exists     = [IO.File]::Exists($resolvedConfig)
                Settings   = $settings
            } | ConvertTo-Json -Depth 10
            exit 0
        }
        'SetAudio' {
            if ([string]::IsNullOrWhiteSpace($AudioFile)) {
                throw 'SetAudio requires -AudioFile.'
            }
            if ($AudioFile -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
                throw 'Only local audio files are supported.'
            }
            $settings.mode = 'audioFile'
            $settings.audioFile = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables($AudioFile)
            )
        }
        'SetTts' {
            $settings.mode = 'tts'
        }
        'SetBuiltinAudio' {
            $settings.mode = 'audioFile'
            $settings.audioFile = 'builtin:' + $Sound
        }
        'SetPlayback' {
            $probe = [pscustomobject] @{
                playback = [pscustomobject] @{
                    mode           = $PlaybackMode
                    seconds        = $PlaybackSeconds
                    maximumSeconds = $PlaybackMaximumSeconds
                }
            }
            $validated = ConvertTo-CodexFinishSettings -InputObject $probe
            if (
                $validated.playback.mode -cne $PlaybackMode -or
                $validated.playback.seconds -ne $PlaybackSeconds -or
                $validated.playback.maximumSeconds -ne $PlaybackMaximumSeconds
            ) {
                throw 'Playback requires once, loop, or seconds; durations must be between 1 and 86400 seconds.'
            }
            $settings.playback.mode = $PlaybackMode
            $settings.playback.seconds = $PlaybackSeconds
            $settings.playback.maximumSeconds = $PlaybackMaximumSeconds
        }
        'SetQuietHours' {
            $probe = [pscustomobject] @{
                quietHours = [pscustomobject] @{
                    enabled = $true
                    start   = $QuietStart
                    end     = $QuietEnd
                }
            }
            $validated = ConvertTo-CodexFinishSettings -InputObject $probe
            if (
                $validated.quietHours.start -cne $QuietStart -or
                $validated.quietHours.end -cne $QuietEnd -or
                $QuietStart -ceq $QuietEnd
            ) {
                throw 'Quiet hours require two different HH:mm values.'
            }
            $settings.quietHours.enabled = $true
            $settings.quietHours.start = $QuietStart
            $settings.quietHours.end = $QuietEnd
        }
        'DisableQuietHours' {
            $settings.quietHours.enabled = $false
        }
        'Enable' {
            $settings.enabled = $true
        }
        'Disable' {
            $settings.enabled = $false
        }
    }

    $writeResult = Write-CodexFinishSettings `
        -Settings $settings `
        -ConfigPath $resolvedConfig `
        -BackupDirectory $BackupDirectory

    [pscustomobject] @{
        Action     = $Action
        ConfigPath = $writeResult.ConfigPath
        BackupPath = $writeResult.BackupPath
        Settings   = $writeResult.Settings
        AudioExists = Test-CodexFinishAudioFileSupported -AudioFile (
            Resolve-CodexFinishAudioFile -AudioFile $writeResult.Settings.audioFile -ConfigPath $resolvedConfig
        )
    } | ConvertTo-Json -Depth 10
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
