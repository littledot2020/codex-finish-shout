# Codex Finish Shout detached local audio player.
# Each process publishes one session file, waits on the shared audio lock, and
# removes its state in finally. This turns concurrent completions into a FIFO-
# like queue without coupling the Codex notify process to media playback.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $AudioFile,

    [ValidateRange(0, 100)]
    [int] $Volume = 100,

    [string] $StateDirectory,

    [ValidatePattern('^[A-Za-z0-9_-]{1,128}$')]
    [string] $SessionId = ([Guid]::NewGuid().ToString('N')),

    [string] $ProjectName = '当前项目',

    [string] $ProjectPath,

    [string] $ProjectKey,

    [ValidateSet('once', 'loop', 'seconds')]
    [string] $PlaybackMode = 'once',

    [ValidateRange(1, 86400)]
    [int] $PlaybackSeconds = 30,

    [ValidateRange(1, 86400)]
    [int] $MaximumPlaybackSeconds = 3600
)

$ErrorActionPreference = 'Stop'
$player = $null
$lockStream = $null
$resolvedState = $null
$stateFile = $null
$stopSignal = $null
$statePublished = $false
$state = $null
$utf8WithoutBom = New-Object Text.UTF8Encoding($false)

function Write-CodexFinishPlaybackState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [Collections.IDictionary] $Value
    )

    # Readers poll while playback is changing. Publish through a temporary file
    # so the VS Code extension never observes a half-written JSON document.
    $Value.updatedUtc = [DateTime]::UtcNow.ToString('o')
    $temporaryPath = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            (($Value | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
            $utf8WithoutBom
        )
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Copy($temporaryPath, $Path, $true)
            [IO.File]::Delete($temporaryPath)
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

try {
    $resolvedAudio = [IO.Path]::GetFullPath($AudioFile)
    if (-not [IO.File]::Exists($resolvedAudio)) {
        throw "Audio file not found: $resolvedAudio"
    }

    $extension = [IO.Path]::GetExtension($resolvedAudio).ToLowerInvariant()
    if ($extension -notin @('.wav', '.mp3', '.wma', '.m4a', '.aac')) {
        throw "Unsupported audio format: $extension"
    }

    if (-not [string]::IsNullOrWhiteSpace($StateDirectory)) {
        $resolvedState = [IO.Path]::GetFullPath($StateDirectory)
        $null = [IO.Directory]::CreateDirectory($resolvedState)
        $lockPath = Join-Path $resolvedState 'audio-player.lock'
        $stateFile = Join-Path $resolvedState ('audio-player-' + $SessionId + '.json')
        $stopSignal = Join-Path $resolvedState ('audio-stop-' + $SessionId + '.signal')

        $state = [ordered] @{
            schemaVersion        = 2
            sessionId            = $SessionId
            pid                  = [Diagnostics.Process]::GetCurrentProcess().Id
            projectName          = $ProjectName
            projectPath          = $ProjectPath
            projectKey           = $ProjectKey
            audioFile            = $resolvedAudio
            startedUtc           = [DateTime]::UtcNow.ToString('o')
            queuedUtc            = [DateTime]::UtcNow.ToString('o')
            playbackStartedUtc   = $null
            status               = 'queued'
            playbackMode         = $PlaybackMode
            playbackSeconds      = $PlaybackSeconds
            maximumPlaybackSeconds = $MaximumPlaybackSeconds
        }
        Write-CodexFinishPlaybackState -Path $stateFile -Value $state
        $statePublished = $true

        # Every completion has its own state file. Players then wait on one global
        # audio lock so simultaneous project completions are queued instead of
        # being discarded or playing over one another.
        while ($null -eq $lockStream) {
            if ([IO.File]::Exists($stopSignal)) {
                return
            }
            try {
                $lockStream = [IO.File]::Open(
                    $lockPath,
                    [IO.FileMode]::OpenOrCreate,
                    [IO.FileAccess]::ReadWrite,
                    [IO.FileShare]::None
                )
            }
            catch [IO.IOException] {
                Start-Sleep -Milliseconds 250
            }
        }

        $state.status = 'playing'
        $state.playbackStartedUtc = [DateTime]::UtcNow.ToString('o')
        Write-CodexFinishPlaybackState -Path $stateFile -Value $state
    }

    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    $player = New-Object Windows.Media.MediaPlayer
    $player.Volume = $Volume / 100.0
    $player.Open((New-Object Uri($resolvedAudio)))
    $player.Play()

    $openDeadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not $player.NaturalDuration.HasTimeSpan -and [DateTime]::UtcNow -lt $openDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not $player.NaturalDuration.HasTimeSpan) {
        throw 'Windows could not read the audio duration.'
    }

    $audioMilliseconds = [Math]::Ceiling($player.NaturalDuration.TimeSpan.TotalMilliseconds)
    $maximumMilliseconds = $MaximumPlaybackSeconds * 1000
    $playbackMilliseconds = switch ($PlaybackMode) {
        'seconds' { [Math]::Min($maximumMilliseconds, $PlaybackSeconds * 1000) }
        'loop'    { $maximumMilliseconds }
        default   { [Math]::Min($maximumMilliseconds, $audioMilliseconds + 750) }
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($playbackMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($null -ne $stopSignal -and [IO.File]::Exists($stopSignal)) {
            break
        }
        if (
            $PlaybackMode -eq 'loop' -and
            $player.NaturalDuration.HasTimeSpan -and
            $player.Position -ge $player.NaturalDuration.TimeSpan
        ) {
            $player.Position = [TimeSpan]::Zero
            $player.Play()
        }
        $remaining = [Math]::Max(50, [Math]::Min(250, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        Start-Sleep -Milliseconds ([int] $remaining)
    }
}
catch {
    try {
        [Console]::Beep(900, 350)
    }
    catch {
        # Detached player failures must remain local and silent.
    }
}
finally {
    if ($null -ne $player) {
        $player.Stop()
        $player.Close()
    }
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
    if ($null -ne $stopSignal -and [IO.File]::Exists($stopSignal)) {
        try {
            [IO.File]::Delete($stopSignal)
        }
        catch {
            # Cleanup is best effort.
        }
    }
    if ($statePublished -and $null -ne $stateFile -and [IO.File]::Exists($stateFile)) {
        try {
            $currentState = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json -ErrorAction Stop
            if ([string]$currentState.sessionId -ceq $SessionId) {
                [IO.File]::Delete($stateFile)
            }
        }
        catch {
            # Cleanup is best effort.
        }
    }
}
