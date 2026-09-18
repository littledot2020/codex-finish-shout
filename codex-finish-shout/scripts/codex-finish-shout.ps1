# Codex Finish Shout user-level notify entry point.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $NotificationJson,

    [switch] $Test,
    [switch] $NoAudio,
    [switch] $NoOverlay,
    [string] $ConfigPath,
    [string] $StateDirectory
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$testFailure = $null
$testResult = $null

try {
    Import-Module (Join-Path $PSScriptRoot 'CodexFinishShout.psm1') -Force -ErrorAction Stop

    if ($Test) {
        $notifyEvent = [pscustomobject] @{
            type        = 'agent-turn-complete'
            client      = 'VS Code'
            'thread-id' = 'manual-test'
            'turn-id'   = [Guid]::NewGuid().ToString('N')
            cwd         = [Environment]::CurrentDirectory
            'last-assistant-message' = 'Codex finish reminder test.'
        }
        # Manual tests do not pass through Codex's lifecycle hooks. Seed the
        # matching root Stop evidence so the same guarded path is exercised.
        $null = Update-CodexFinishLifecycleState `
            -HookEvent ([pscustomobject] @{
                session_id       = $notifyEvent.'thread-id'
                turn_id          = $notifyEvent.'turn-id'
                cwd              = $notifyEvent.cwd
                hook_event_name  = 'Stop'
                transcript_path  = $null
            }) `
            -StateDirectory $StateDirectory
    }
    else {
        if ([string]::IsNullOrWhiteSpace($NotificationJson)) {
            return
        }
        $notifyEvent = $NotificationJson | ConvertFrom-Json -ErrorAction Stop
    }

    $testResult = Invoke-CodexFinishNotification `
        -Event $notifyEvent `
        -ConfigPath $ConfigPath `
        -StateDirectory $StateDirectory `
        -SkipAudio:$NoAudio `
        -SkipOverlay:$NoOverlay
}
catch {
    if ($Test) {
        $testFailure = $_.Exception.Message
    }
    # A notifier failure must never affect Codex.
}

if ($Test) {
    if ($null -ne $testResult) {
        [Console]::Out.Write(($testResult | ConvertTo-Json -Depth 5 -Compress))
    }
    else {
        [Console]::Out.Write('{"Notified":false}')
    }
}

if ($null -ne $testFailure) {
    throw ('Completion reminder test failed: ' + $testFailure)
}
