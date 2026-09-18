# Codex Finish Shout live-workspace reconciliation worker.
#
# This process is intentionally silent and single-instance.  It reconciles the
# public monitor snapshot every few seconds and periodically resends it so a
# board that reconnects (or a PC that resumes from sleep) converges without a
# new Codex completion event.

[CmdletBinding()]
param(
    [string] $StateDirectory,
    [string] $ConfigPath,
    [ValidateRange(1, 3600)]
    [int] $LeaseTtlSeconds = 20,
    [ValidateRange(1, 300)]
    [int] $PollSeconds = 5,
    [ValidateRange(1, 3600)]
    [int] $SnapshotIntervalSeconds = 30,
    [ValidateRange(20, 3600)]
    [int] $ResumeGraceSeconds = 20,
    [ValidateRange(0, 1000000)]
    [int] $MaximumIterations = 0,
    [ValidateRange(1, 60)]
    [int] $HandoffWaitSeconds = 12,
    [ValidateRange(1, 3600)]
    [int] $EmptyDeliveryRetrySeconds = 90,
    [switch] $SkipBoard
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$lockStream = $null

try {
    Import-Module (Join-Path $PSScriptRoot 'CodexFinishShout.psm1') -Force -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        $StateDirectory = Join-Path (
            [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        ) '.codex\codex-finish-shout-state'
    }
    $StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
    $null = [IO.Directory]::CreateDirectory($StateDirectory)

    $workerLockPath = Join-Path $StateDirectory 'monitor-sync-worker.lock'
    # FileShare.None is the cross-process single-instance check.  Launchers
    # without a live workspace still exit immediately.  A launcher that just
    # published a valid lease briefly acts as a hidden handoff waiter, closing
    # the narrow race where the prior worker is releasing its zero-lease lock.
    try {
        $lockStream = [IO.File]::Open(
            $workerLockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch {
        $handoffPreview = Get-CodexFinishWorkspaceLeaseState `
            -StateDirectory $StateDirectory `
            -LeaseTtlSeconds $LeaseTtlSeconds
        if (-not $handoffPreview.Enabled -or [int]$handoffPreview.ValidLeaseCount -eq 0) {
            return
        }
        $handoffStream = $null
        try {
            try {
                $handoffStream = [IO.File]::Open(
                    (Join-Path $StateDirectory 'monitor-sync-worker-handoff.lock'),
                    [IO.FileMode]::OpenOrCreate,
                    [IO.FileAccess]::ReadWrite,
                    [IO.FileShare]::None
                )
            }
            catch { return }
            $handoffDeadline = [DateTime]::UtcNow.AddSeconds($HandoffWaitSeconds)
            while ($null -eq $lockStream -and [DateTime]::UtcNow -lt $handoffDeadline) {
                try {
                    $lockStream = [IO.File]::Open(
                        $workerLockPath,
                        [IO.FileMode]::OpenOrCreate,
                        [IO.FileAccess]::ReadWrite,
                        [IO.FileShare]::None
                    )
                }
                catch {
                    Start-Sleep -Milliseconds 200
                }
            }
            if ($null -eq $lockStream) { return }
        }
        finally {
            if ($null -ne $handoffStream) { $handoffStream.Dispose() }
        }
    }

    $lastCycleUtc = [DateTime]::MinValue
    $lastSnapshotUtc = [DateTime]::MinValue
    $resumeGraceUntilUtc = [DateTime]::MinValue
    $emptyDeliveryStartedUtc = [DateTime]::MinValue
    $hadValidLeases = $false
    $iteration = 0

    while ($true) {
        $nowUtc = [DateTime]::UtcNow
        if ($lastCycleUtc -ne [DateTime]::MinValue) {
            $elapsedSeconds = ($nowUtc - $lastCycleUtc).TotalSeconds
            $longGapSeconds = [Math]::Max($LeaseTtlSeconds + 5, $PollSeconds * 3)
            if ($hadValidLeases -and ($elapsedSeconds -lt 0 -or $elapsedSeconds -gt $longGapSeconds)) {
                # Heartbeats can all look stale immediately after sleep.  Give
                # the extension at least one full TTL to refresh before an
                # empty snapshot is allowed to erase the board.
                $resumeGraceUntilUtc = $nowUtc.AddSeconds([Math]::Max(20, $ResumeGraceSeconds))
            }
        }
        $lastCycleUtc = $nowUtc

        $leasePreview = Get-CodexFinishWorkspaceLeaseState `
            -StateDirectory $StateDirectory `
            -LeaseTtlSeconds $LeaseTtlSeconds `
            -NowUtc $nowUtc
        if (-not $leasePreview.Enabled) {
            break
        }

        $insideResumeGrace = (
            $hadValidLeases -and
            [int]$leasePreview.ValidLeaseCount -eq 0 -and
            $nowUtc -lt $resumeGraceUntilUtc
        )
        if (-not $insideResumeGrace) {
            $forceSnapshot = [int]$leasePreview.ValidLeaseCount -eq 0
            $cycle = Invoke-CodexFinishProjectMonitorSync `
                -StateDirectory $StateDirectory `
                -ConfigPath $ConfigPath `
                -LeaseTtlSeconds $LeaseTtlSeconds `
                -SnapshotIntervalSeconds $SnapshotIntervalSeconds `
                -LastSnapshotUtc $lastSnapshotUtc `
                -NowUtc $nowUtc `
                -ForceSnapshot:$forceSnapshot `
                -SkipBoard:$SkipBoard
            if ($cycle.SnapshotSent) {
                $lastSnapshotUtc = $nowUtc
            }
            if ([int]$cycle.LeaseState.ValidLeaseCount -gt 0) {
                $hadValidLeases = $true
                $resumeGraceUntilUtc = [DateTime]::MinValue
                $emptyDeliveryStartedUtc = [DateTime]::MinValue
            }
            elseif ([int]$cycle.LeaseState.ValidLeaseCount -eq 0) {
                # The empty live snapshot was committed and, when enabled,
                # must reach the board before the last worker exits.  A busy
                # or disconnected serial port is retried on the next poll.
                $emptyDeliveryComplete = (
                    $SkipBoard -or
                    $cycle.SnapshotSent -or
                    $cycle.HardwareEnabled -eq $false
                )
                if ($emptyDeliveryComplete) {
                    # Recheck once before release; if a lease appears after
                    # this check, its launcher waits on the handoff protocol
                    # above and acquires the lock after finally runs.
                    $exitPreview = Get-CodexFinishWorkspaceLeaseState `
                        -StateDirectory $StateDirectory `
                        -LeaseTtlSeconds $LeaseTtlSeconds
                    if ([int]$exitPreview.ValidLeaseCount -eq 0) {
                        break
                    }
                    $hadValidLeases = $true
                }
                else {
                    if ($emptyDeliveryStartedUtc -eq [DateTime]::MinValue) {
                        $emptyDeliveryStartedUtc = $nowUtc
                    }
                    elseif (($nowUtc - $emptyDeliveryStartedUtc).TotalSeconds -ge $EmptyDeliveryRetrySeconds) {
                        # Bound orphaned hidden processes when the board stays
                        # disconnected forever.  A Controls ensure cycle or a
                        # later workspace lease can launch another worker.
                        break
                    }
                }
            }
        }

        $iteration++
        if ($MaximumIterations -gt 0 -and $iteration -ge $MaximumIterations) {
            break
        }
        Start-Sleep -Seconds $PollSeconds
    }
}
catch {
    # Reconciliation is best effort and must never surface as a Codex failure.
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}
