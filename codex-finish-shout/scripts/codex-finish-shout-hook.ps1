# Codex Finish Shout lifecycle hook adapter.
# Reads one official hook JSON object from stdin and records lifecycle state
# plus short task titles. Full prompts, tool input, and assistant output are
# not stored; transcript paths allow the Controls view to resolve task labels.

[CmdletBinding()]
param(
    [string] $StateDirectory,
    [string] $DefinitionId = 'lifecycle-v2'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$hookEvent = $null
$eventName = ''

# Codex emits hook JSON as UTF-8. Windows PowerShell otherwise inherits the
# active console code page, which can corrupt non-ASCII project paths before
# ConvertFrom-Json sees them.
try {
    if ([Console]::InputEncoding.CodePage -ne 65001) {
        [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
    }
}
catch {
    # Continue with the inherited encoding on hosts that do not expose it.
}

function Write-CodexFinishHookReadyMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Directory,
        [Parameter(Mandatory = $true)]
        [string] $EventName,
        [Parameter(Mandatory = $true)]
        [string] $HookDefinitionId
    )

    $null = [IO.Directory]::CreateDirectory($Directory)
    $markerPath = Join-Path $Directory 'lifecycle-hook-ready.json'
    $lockPath = $markerPath + '.lock'
    $lockStream = $null

    # Different Codex sessions can invoke this adapter concurrently. Serialize
    # the small global readiness marker so the Controls extension never reads
    # a partially replaced JSON document.
    for ($attempt = 0; $attempt -lt 40 -and $null -eq $lockStream; $attempt++) {
        try {
            $lockStream = [IO.File]::Open(
                $lockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        }
        catch [IO.IOException] {
            Start-Sleep -Milliseconds 25
        }
    }
    if ($null -eq $lockStream) {
        return
    }

    $temporaryPath = $markerPath + '.tmp.' + [Guid]::NewGuid().ToString('N')
    $replacementBackup = $markerPath + '.replace.' + [Guid]::NewGuid().ToString('N')
    try {
        $marker = [ordered] @{
            schemaVersion = 1
            guard         = 'Codex Finish Shout lifecycle state guard'
            definitionId  = $HookDefinitionId
            eventName     = $EventName
            observedUtc   = [DateTime]::UtcNow.ToString('o')
        }
        $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText(
            $temporaryPath,
            (($marker | ConvertTo-Json -Depth 4) + [Environment]::NewLine),
            $utf8WithoutBom
        )

        if ([IO.File]::Exists($markerPath)) {
            try {
                [IO.File]::Replace($temporaryPath, $markerPath, $replacementBackup)
                [IO.File]::Delete($replacementBackup)
            }
            catch {
                [IO.File]::Copy($temporaryPath, $markerPath, $true)
                [IO.File]::Delete($temporaryPath)
            }
        }
        else {
            [IO.File]::Move($temporaryPath, $markerPath)
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
        if ([IO.File]::Exists($replacementBackup)) {
            [IO.File]::Delete($replacementBackup)
        }
        $lockStream.Dispose()
    }
}

try {
    $rawInput = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($rawInput)) {
        $rawInput = $rawInput.TrimStart([char]0xFEFF)
        $hookEvent = $rawInput | ConvertFrom-Json -ErrorAction Stop
        $eventName = [string] $hookEvent.hook_event_name
        Import-Module (Join-Path $PSScriptRoot 'CodexFinishShout.psm1') -Force -ErrorAction Stop
        $updateResult = Update-CodexFinishLifecycleState `
            -HookEvent $hookEvent `
            -StateDirectory $StateDirectory `
            -LockTimeoutMilliseconds 250 `
            -SkipDirtyReplay
        Write-CodexFinishHookReadyMarker `
            -Directory $StateDirectory `
            -EventName $eventName `
            -HookDefinitionId $DefinitionId

        # State collection is unconditional. Hardware delivery and delayed
        # Stop-only settlement are detached and must never affect the Hook.
        if ($updateResult.Updated) {
            try {
                try {
                    $settings = Get-CodexFinishSettings
                }
                catch {
                    # Invalid/missing presentation configuration must not turn
                    # off lifecycle convergence or leave a stopped project red.
                    $settings = Get-CodexFinishDefaultSettings
                }
                if (
                    $updateResult.ProjectSettling -and
                    $eventName -in @('Stop', 'SubagentStop')
                ) {
                    $settleGrace = if ($settings.completionGuard.enabled) {
                        [int]$settings.completionGuard.graceSeconds
                    }
                    else {
                        0
                    }
                    $null = Start-CodexFinishStoppedProjectSettlement `
                        -HookEvent $hookEvent `
                        -StateDirectory $StateDirectory `
                        -GraceSeconds $settleGrace
                }
                if (
                    $eventName -ceq 'SessionEnd' -and
                    $null -ne $updateResult.RecoverySettlementEvent
                ) {
                    # SessionEnd invalidates the old project candidate.  If
                    # another session in that project was already stopped,
                    # give that remaining session a fresh quiet boundary so
                    # the row cannot stay red forever.
                    $recoveryGrace = if ($settings.completionGuard.enabled) {
                        [int]$settings.completionGuard.graceSeconds
                    }
                    else { 0 }
                    $null = Start-CodexFinishStoppedProjectSettlement `
                        -HookEvent $updateResult.RecoverySettlementEvent `
                        -StateDirectory $StateDirectory `
                        -GraceSeconds $recoveryGrace
                }
                if (
                    $null -ne $updateResult.ProjectMonitorState -and
                    $settings.hardware.enabled
                ) {
                    # Serial work runs detached from the Hook. The child also
                    # uses short mutex/write timeouts for a missing board.
                    $hookHardware = [pscustomobject] [ordered] @{
                        enabled             = $true
                        transport           = $settings.hardware.transport
                        port                = $settings.hardware.port
                        autoDetect          = $settings.hardware.autoDetect
                        baudRate            = $settings.hardware.baudRate
                        timeoutMilliseconds = [Math]::Min(250, [int]$settings.hardware.timeoutMilliseconds)
                    }
                    $null = Start-CodexFinishBoardSnapshotDelivery `
                        -HardwareSettings $hookHardware `
                        -MaximumProjects $settings.projectMonitor.maximumProjects `
                        -StateDirectory $StateDirectory
                }
                if ($eventName -ceq 'SessionEnd') {
                    # Reconciliation remains detached so this synchronous Hook
                    # stays comfortably below Codex's three-second ceiling.
                    $null = Start-CodexFinishMonitorSyncWorker `
                        -StateDirectory $StateDirectory
                }
            }
            catch {
                # A missing/busy/disconnected board is never a Codex error.
            }
        }
    }
}
catch {
    # Lifecycle telemetry must never block a Codex turn. In require mode a
    # missing update suppresses the reminder instead of risking a false one.
}

# Stop-class hooks require JSON when they produce stdout. Returning continue
# preserves Codex behavior while satisfying the hook protocol on all paths.
if ($eventName -in @('Stop', 'SubagentStop')) {
    [Console]::Out.Write('{"continue":true}')
}
