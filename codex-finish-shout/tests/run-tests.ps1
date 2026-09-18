# Codex Finish Shout notify automated tests. No audio is played.

[CmdletBinding()]
param([switch] $AgentMonitorOnly, [string] $TestName = '')

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeModule = Join-Path $pluginRoot 'scripts\CodexFinishShout.psm1'
$setupModule = Join-Path $pluginRoot 'scripts\CodexFinishShout.Setup.psm1'
$notifyScript = Join-Path $pluginRoot 'scripts\codex-finish-shout.ps1'
$hookScript = Join-Path $pluginRoot 'scripts\codex-finish-shout-hook.ps1'
$monitorWorkerScript = Join-Path $pluginRoot 'scripts\monitor-sync-worker.ps1'
$configureScript = Join-Path $pluginRoot 'scripts\configure.ps1'
$manifestFile = Join-Path $pluginRoot '.codex-plugin\plugin.json'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'codex-finish-shout-notify-tests-' + [Guid]::NewGuid().ToString('N')
)
$null = [IO.Directory]::CreateDirectory($testRoot)
$utf8WithoutBom = New-Object Text.UTF8Encoding($false)

Import-Module $runtimeModule -Force
Import-Module $setupModule -Force

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param([object] $Expected, [object] $Actual, [string] $Message)
    if ($Expected -cne $Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

function Assert-Contains {
    param([string] $Text, [string] $Expected, [string] $Message)
    if ($Text.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) {
        throw "$Message Missing=[$Expected]"
    }
}

function Invoke-TestCase {
    param([string] $Name, [scriptblock] $Body)
    if ($TestName -and $Name -notlike $TestName) { return }
    try {
        & $Body
        $script:Passed++
        Write-Host "[PASS] $Name"
    }
    catch {
        $script:Failed++
        Write-Host "[FAIL] $Name"
        Write-Host ('       ' + $_.Exception.Message)
    }
}

function New-TestDirectory {
    $path = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($path)
    return $path
}

function Write-TestFile {
    param([string] $Path, [string] $Content)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Content, $utf8WithoutBom)
}

function Enable-TestWorkspaceMonitor {
    param([string] $StateDirectory)
    Write-TestFile `
        -Path (Join-Path $StateDirectory 'workspace-monitor.json') `
        -Content (([ordered]@{ schemaVersion = 1 } | ConvertTo-Json) + "`n")
}

function Write-TestWorkspaceLease {
    param(
        [string] $StateDirectory,
        [string[]] $WorkspacePaths,
        [string] $LeaseId = 'test-lease',
        [DateTime] $UpdatedAtUtc = ([DateTime]::UtcNow),
        [int] $ProcessId = $PID,
        [DateTime] $ProcessStartedUtc = ((Get-Process -Id $PID).StartTime.ToUniversalTime())
    )
    $lease = [ordered]@{
        schemaVersion     = 1
        leaseId           = $LeaseId
        processId         = $ProcessId
        processStartedUtc = $ProcessStartedUtc.ToUniversalTime().ToString('o')
        workspacePaths    = [string[]]$WorkspacePaths
        updatedAtUtc      = $UpdatedAtUtc.ToUniversalTime().ToString('o')
    }
    Write-TestFile `
        -Path (Join-Path $StateDirectory ('workspace-lease-' + $LeaseId + '.json')) `
        -Content (($lease | ConvertTo-Json -Depth 5) + "`n")
}

function New-TestNotificationConfig {
    param(
        [string] $Directory,
        [bool] $Enabled = $true,
        [bool] $HardwareEnabled = $false,
        [bool] $QuietAlways = $false
    )
    $path = Join-Path $Directory ('notify-settings-' + [Guid]::NewGuid().ToString('N') + '.json')
    $settings = Get-CodexFinishDefaultSettings
    $settings.enabled = $Enabled
    $settings.audioFile = Join-Path $Directory 'missing-test-audio.mp3'
    $settings.fallbackMode = 'tts'
    $settings.hardware.enabled = $HardwareEnabled
    $settings.visual.enabled = $true
    if ($QuietAlways) {
        $settings.quietHours.enabled = $true
        $settings.quietHours.start = '00:00'
        $settings.quietHours.end = '00:00'
    }
    $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $path
    return $path
}

function Start-TestScriptPowerShell {
    param([string] $Command)
    # Keep multiline fixture scripts out of the Windows process command line.
    # BOM preserves non-ASCII workspace paths in Windows PowerShell 5.1.
    $fixturePath = Join-Path $testRoot ('parallel-fixture-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($fixturePath, $Command, (New-Object Text.UTF8Encoding($true)))
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command powershell.exe).Source
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $fixturePath + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    return $process
}

function New-VSCodeCompleteEvent {
    param(
        [string] $TurnId = ([Guid]::NewGuid().ToString('N')),
        [string] $ThreadId = 'thread-test',
        [string] $Cwd = $testRoot
    )
    return [pscustomobject] @{
        type        = 'agent-turn-complete'
        client      = 'VS Code'
        'thread-id' = $ThreadId
        'turn-id'   = $TurnId
        cwd         = $Cwd
        'last-assistant-message' = 'completion-message'
    }
}

function Set-TestLifecycleEvent {
    param(
        [object] $Event,
        [string] $StateDirectory,
        [Parameter(Mandatory = $true)]
        [string] $HookEventName,
        [string] $TurnId,
        [string] $AgentId
    )

    if ([string]::IsNullOrWhiteSpace($TurnId)) {
        $TurnId = [string] $Event.'turn-id'
    }
    $hookEvent = [pscustomobject] @{
        session_id      = [string] $Event.'thread-id'
        turn_id         = $TurnId
        cwd             = [string] $Event.cwd
        hook_event_name = $HookEventName
        transcript_path = $null
        agent_id        = $AgentId
    }
    $result = Update-CodexFinishLifecycleState `
        -HookEvent $hookEvent `
        -StateDirectory $StateDirectory
    Assert-True $result.Updated "Lifecycle fixture failed: $($result.Reason)"
    return $result
}

function Set-TestTurnStopped {
    param([object] $Event, [string] $StateDirectory)
    return Set-TestLifecycleEvent `
        -Event $Event `
        -StateDirectory $StateDirectory `
        -HookEventName 'Stop'
}

function Invoke-NotifyProcess {
    param(
        [string] $InputJson,
        [string] $ConfigPath,
        [string] $StateDirectory
    )

    $jsonBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($InputJson))
    $escapedScript = $notifyScript.Replace("'", "''")
    $escapedConfig = $ConfigPath.Replace("'", "''")
    $escapedState = $StateDirectory.Replace("'", "''")
    $command = @"
`$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$jsonBase64'))
& '$escapedScript' `$json -NoAudio -NoOverlay -ConfigPath '$escapedConfig' -StateDirectory '$escapedState'
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command powershell.exe).Source
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
        $encodedCommand
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    if (-not $process.WaitForExit(15000)) {
        $process.Kill()
        throw 'Notify process timed out.'
    }

    return [pscustomobject] @{
        ExitCode = $process.ExitCode
        StdOut   = $process.StandardOutput.ReadToEnd()
        StdErr   = $process.StandardError.ReadToEnd()
    }
}

function Invoke-HookProcess {
    param(
        [object] $HookEvent,
        [string] $StateDirectory,
        [string] $ConfigPath
    )

    $hookJson = $HookEvent | ConvertTo-Json -Depth 8 -Compress
    $hookJsonBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($hookJson))
    # ProcessStartInfo.Arguments is ANSI on Windows PowerShell. Use an encoded
    # command so a checkout path containing Chinese characters reaches the
    # child process without being silently corrupted. Set Console.In inside the
    # child as well: powershell.exe can prepend a replacement character when
    # raw redirected stdin is combined with -EncodedCommand on Windows 5.1.
    $escapedHook = $hookScript.Replace("'", "''")
    $escapedState = $StateDirectory.Replace("'", "''")
    $hookCommand = @"
`$ProgressPreference = 'SilentlyContinue'
`$hookJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$hookJsonBase64'))
[Console]::InputEncoding = [Text.UTF8Encoding]::new(`$false)
[Console]::SetIn([IO.StringReader]::new(`$hookJson))
& '$escapedHook' -StateDirectory '$escapedState'
"@
    $encodedHookCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($hookCommand))
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command powershell.exe).Source
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
        $encodedHookCommand
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $hookTestConfig = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($hookTestConfig)) {
        $hookTestConfig = Join-Path $testRoot 'hook-test-settings.json'
    }
    if (-not [IO.File]::Exists($hookTestConfig)) {
        $hookSettings = Get-CodexFinishDefaultSettings
        # Detached Stop-only fallback must be exercised without creating real
        # overlay/audio presentation from test Hook processes.
        $hookSettings.enabled = $false
        $hookSettings.hardware.enabled = $false
        $null = Write-CodexFinishSettings -Settings $hookSettings -ConfigPath $hookTestConfig
    }
    $startInfo.EnvironmentVariables['CODEX_FINISH_SHOUT_CONFIG'] = $hookTestConfig

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    if (-not $process.WaitForExit(15000)) {
        $process.Kill()
        throw 'Hook process timed out.'
    }

    return [pscustomobject] @{
        ExitCode = $process.ExitCode
        StdOut   = $process.StandardOutput.ReadToEnd()
        StdErr   = $process.StandardError.ReadToEnd()
    }
}

try {
    . (Join-Path $PSScriptRoot 'agent-monitor-tests.ps1')
    if (-not $AgentMonitorOnly) {
    Invoke-TestCase 'Plugin package has no lifecycle Hook' {
        $manifest = [IO.File]::ReadAllText($manifestFile) | ConvertFrom-Json
        Assert-Equal 'codex-finish-shout' $manifest.name 'Plugin name is wrong.'
        Assert-True ($null -eq $manifest.PSObject.Properties['hooks']) 'Manifest must not declare hooks.'
        Assert-True (-not [IO.File]::Exists((Join-Path $pluginRoot 'hooks\hooks.json'))) 'Hook file must be absent.'
    }

    Invoke-TestCase 'Default settings require VS Code and prefer local MP3' {
        $settings = Get-CodexFinishDefaultSettings
        Assert-Equal 2 $settings.schemaVersion 'Settings schema should be version 2.'
        Assert-Equal 'VS Code' $settings.requiredClient 'Only VS Code should be eligible by default.'
        Assert-Equal 'audioFile' $settings.mode 'Default mode should prefer a local audio file.'
        Assert-Equal 'tts' $settings.fallbackMode 'Missing audio should fall back to TTS.'
        Assert-Equal 'builtin:soft-chime' $settings.audioFile 'Default should use the bundled completion cue.'
        Assert-True (Test-CodexFinishAudioFileSupported -AudioFile (Resolve-CodexFinishAudioFile -AudioFile $settings.audioFile)) 'Bundled default audio should exist.'
        Assert-Equal 'once' $settings.playback.mode 'Default playback mode should be once.'
        Assert-Equal 30 $settings.playback.seconds 'Default playback duration is wrong.'
        Assert-Equal 3600 $settings.playback.maximumSeconds 'Default playback safety limit is wrong.'
        Assert-True $settings.completionGuard.enabled 'Completion guard should be enabled by default.'
        Assert-Equal 10 $settings.completionGuard.graceSeconds 'Default completion quiet window is wrong.'
        Assert-Equal 'require' $settings.completionGuard.lifecycleMode 'Lifecycle evidence must be required by default.'
        Assert-True $settings.visual.enabled 'Completion overlay should be enabled by default.'
        Assert-Equal 2000 $settings.visual.durationMilliseconds 'Default overlay duration is wrong.'
        Assert-Equal 6 $settings.projectMonitor.maximumProjects 'Board snapshots should show at most six projects.'
        Assert-True (-not $settings.hardware.enabled) 'Hardware is opt-in for new installations.'
        Assert-Equal 'serial' $settings.hardware.transport 'Board transport should use serial.'
        Assert-Equal '#16A34A' $settings.hardware.backgroundColor 'Board completion background should be green.'
        Assert-Equal (Get-CodexFinishDefaultHardwareMessage) $settings.hardware.message 'Board completion message is wrong.'
    }

    Invoke-TestCase 'Completion overlay initializes in STA without showing a test window' {
        $overlayScript = (Join-Path $pluginRoot 'scripts\show-completion-overlay.ps1').Replace("'", "''")
        $command = "& '$overlayScript' -ProjectName 'overlay-test' -DurationMilliseconds 1500 -ValidateOnly -Diagnostic"
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = (Get-Command powershell.exe).Source
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -EncodedCommand ' +
            $encodedCommand
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        $null = $process.Start()
        Assert-True ($process.WaitForExit(10000)) 'Overlay validation process timed out.'
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        Assert-Equal 0 $process.ExitCode 'Overlay validation process failed.'
        Assert-Equal '' $stdout 'Overlay validation should stay silent on stdout.'
        Assert-Equal '' $stderr 'Overlay validation should stay silent on stderr.'
    }

    Invoke-TestCase 'Completion event accepts VS Code only' {
        $event = New-VSCodeCompleteEvent
        Assert-True (Test-CodexFinishNotifyEvent -Event $event) 'VS Code completion should be eligible.'

        $event.client = 'Codex CLI'
        Assert-True (-not (Test-CodexFinishNotifyEvent -Event $event)) 'CLI completion must be ignored.'

        $event.client = 'VS Code'
        $event.type = 'approval-requested'
        Assert-True (-not (Test-CodexFinishNotifyEvent -Event $event)) 'Non-completion events must be ignored.'

        $event.type = 'agent-turn-complete'
        $event.'turn-id' = ''
        Assert-True (-not (Test-CodexFinishNotifyEvent -Event $event)) 'Completion without a turn id must be ignored.'

        $event.'turn-id' = 'turn-test'
        $event.'thread-id' = ''
        Assert-True (-not (Test-CodexFinishNotifyEvent -Event $event)) 'Completion without a thread id must be ignored.'

        $event.'thread-id' = 'thread-test'
        $event.'last-assistant-message' = ''
        Assert-True (-not (Test-CodexFinishNotifyEvent -Event $event)) 'Completion without the final assistant message must be ignored.'

        $event.'last-assistant-message' = 'completion-message'
        Assert-True (Test-CodexFinishNotifyEvent -Event $event) 'Completion with a final assistant message should be eligible.'
    }

    Invoke-TestCase 'Startup placeholder event cannot claim a turn or start audio' {
        $directory = New-TestDirectory
        $event = New-VSCodeCompleteEvent -TurnId 'startup-placeholder'
        $event.PSObject.Properties.Remove('last-assistant-message')
        $result = Invoke-CodexFinishNotification `
            -Event $event `
            -ConfigPath (Join-Path $directory 'settings.json') `
            -StateDirectory (Join-Path $directory 'state') `
            -SkipAudio `
            -SkipOverlay
        Assert-Equal 'not-vscode-turn-complete' $result.SuppressedReason 'Startup placeholder should be suppressed.'
        Assert-True (-not $result.Claimed) 'Startup placeholder must not claim a turn.'
        Assert-True (-not $result.WouldNotify) 'Startup placeholder must not notify.'
    }

    Invoke-TestCase 'Board payload requests a green completed screen' {
        $settings = Get-CodexFinishDefaultSettings
        $payload = New-CodexFinishBoardPayload `
            -HardwareSettings $settings.hardware `
            -ProjectName 'demo-project' `
            -ProjectPath 'C:\demo-project' `
            -ProjectKey 'project-key' `
            -TurnId 'turn-board'
        Assert-Equal 1 $payload.version 'Board protocol version is wrong.'
        Assert-Equal 'completion' $payload.type 'Board message type is wrong.'
        Assert-Equal 'completed' $payload.status 'Board status is wrong.'
        Assert-Equal 'demo-project' $payload.project 'Board project name is wrong.'
        Assert-Equal '#16A34A' $payload.background 'Board background should be green.'
        Assert-Equal (Get-CodexFinishDefaultHardwareMessage) $payload.message 'Board completion message is wrong.'
    }

    Invoke-TestCase 'Fixed board ports must be present and successful delivery selects hardware presentation' {
        $settings = Get-CodexFinishDefaultSettings
        $settings.hardware.port = 'COM254'
        $settings.hardware.autoDetect = $false
        Assert-Equal 0 @(Get-CodexFinishBoardPortCandidates -HardwareSettings $settings.hardware).Count `
            'A stale fixed COM port was treated as connected.'

        Assert-Equal 'hardware' `
            (Get-CodexFinishPresentationRoute -BoardResult ([pscustomobject]@{ Sent = $true })) `
            'Successful board delivery did not select the hardware-only route.'
        Assert-Equal 'desktop' `
            (Get-CodexFinishPresentationRoute -BoardResult ([pscustomobject]@{ Sent = $false })) `
            'Failed board delivery did not select the desktop fallback.'
        Assert-Equal 'desktop' (Get-CodexFinishPresentationRoute -BoardResult $null) `
            'Missing board delivery did not select the desktop fallback.'
    }

    Invoke-TestCase 'Board snapshot prioritizes running projects and stays below the firmware line limit' {
        $projects = for ($index = 0; $index -lt 8; $index++) {
            [pscustomobject]@{
                name = ('中文项目' * 40) + $index
                status = if ($index -in @(1, 6)) { 'running' } else { 'completed' }
                projectKey = ([string]$index).PadLeft(64, 'a')
                updatedAtUtc = [DateTime]::UtcNow.AddMinutes(-1 * $index).ToString('o')
            }
        }
        $snapshot = New-CodexFinishBoardSnapshotPayload `
            -MonitorState ([pscustomobject]@{ total = 8; projects = $projects }) `
            -MaximumProjects 6
        $jsonLine = ($snapshot | ConvertTo-Json -Depth 6 -Compress) + "`n"

        Assert-Equal 'project_snapshot' $snapshot.type 'Snapshot message type is wrong.'
        Assert-Equal 8 $snapshot.total 'Snapshot total must describe all retained projects.'
        Assert-Equal 6 @($snapshot.projects).Count 'Snapshot should contain no more than six rows.'
        Assert-Equal 'running' $snapshot.projects[0].status 'Running projects must be ordered first.'
        Assert-Equal 'running' $snapshot.projects[1].status 'All running projects must precede completed projects.'
        Assert-True ([Text.Encoding]::UTF8.GetByteCount($snapshot.projects[0].name) -le 48) 'Board project name was not UTF-8 safely truncated.'
        Assert-True ([Text.Encoding]::UTF8.GetByteCount($jsonLine) -lt 2048) 'Snapshot JSON exceeds the firmware receive line.'
    }

    Invoke-TestCase 'Settings are normalized and bounded' {
        $input = [pscustomobject] @{
            enabled        = 'false'
            requiredClient = ''
            mode           = 'invalid'
            fallbackMode   = 'invalid'
            volume         = 999
            rate           = -99
            playback       = [pscustomobject] @{
                mode           = 'seconds'
                seconds        = 999999
                maximumSeconds = 0
            }
            completionGuard = [pscustomobject] @{
                enabled      = 'false'
                graceSeconds = 999999
            }
            visual          = [pscustomobject] @{
                enabled              = 'false'
                durationMilliseconds = 999999
            }
            projectMonitor  = [pscustomobject] @{
                maximumProjects = 99
            }
            quietHours     = [pscustomobject] @{
                enabled = $true
                start   = 'bad'
                end     = '07:30'
            }
        }
        $settings = ConvertTo-CodexFinishSettings -InputObject $input
        Assert-True (-not $settings.enabled) 'String false should normalize to Boolean false.'
        Assert-Equal 'VS Code' $settings.requiredClient 'Blank client should use the default.'
        Assert-Equal 'audioFile' $settings.mode 'Invalid mode should use the default.'
        Assert-Equal 100 $settings.volume 'Volume should be clamped.'
        Assert-Equal -10 $settings.rate 'Rate should be clamped.'
        Assert-Equal 'seconds' $settings.playback.mode 'Playback mode should be preserved.'
        Assert-Equal 86400 $settings.playback.seconds 'Playback seconds should be clamped.'
        Assert-Equal 1 $settings.playback.maximumSeconds 'Playback maximum should be clamped to one second.'
        Assert-True (-not $settings.completionGuard.enabled) 'Completion guard should normalize its enabled flag.'
        Assert-Equal 120 $settings.completionGuard.graceSeconds 'Completion quiet window should preserve the compatible 120-second upper bound.'
        $immediate = ConvertTo-CodexFinishSettings -InputObject ([pscustomobject]@{
            completionGuard = [pscustomobject]@{ graceSeconds = 0 }
        })
        Assert-Equal 0 $immediate.completionGuard.graceSeconds 'An explicit zero-second diagnostic window should remain supported.'
        Assert-True (-not $settings.visual.enabled) 'Overlay enabled flag should normalize.'
        Assert-Equal 2000 $settings.visual.durationMilliseconds 'Overlay duration should be capped at two seconds.'
        Assert-Equal 6 $settings.projectMonitor.maximumProjects 'Board monitor rows should be capped at six.'
        Assert-Equal '22:00' $settings.quietHours.start 'Invalid time should use the default.'
        Assert-Equal '07:30' $settings.quietHours.end 'Valid time should be preserved.'
    }

    Invoke-TestCase 'Authoritative root notify waits for the completion quiet window' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'settings.json'
        $state = Join-Path $directory 'state'
        $settings = Get-CodexFinishDefaultSettings
        $settings.audioFile = Join-Path $directory 'missing.mp3'
        $settings.fallbackMode = 'none'
        # Timing tests must not depend on a physical COM device being present,
        # busy, or running compatible firmware on the test machine.
        $settings.hardware.enabled = $false
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config

        $event = New-VSCodeCompleteEvent -TurnId 'guard'
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-CodexFinishNotification `
            -Event $event `
            -ConfigPath $config `
            -StateDirectory $state `
            -CompletionGraceSeconds 1 `
            -SkipOverlay
        $watch.Stop()

        Assert-True ($watch.ElapsedMilliseconds -ge 900) 'An authoritative root notify bypassed the quiet window.'
        Assert-True ($watch.ElapsedMilliseconds -lt 3000) 'The one-second authoritative quiet-window test took too long.'
        Assert-True $result.Claimed 'An authoritative root notify should claim after settling.'
        Assert-Equal 'no-fallback' $result.SuppressedReason 'Guard test should not start audio.'
        Assert-True $result.OverlayWouldNotify 'Visual completion should remain eligible without an audio fallback.'
        Assert-True (-not $result.OverlayNotified) 'SkipOverlay must suppress the test window.'
    }

    Invoke-TestCase 'Non-authoritative candidate still waits and newer activity cancels it' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'settings.json'
        $state = Join-Path $directory 'state'
        $settings = Get-CodexFinishDefaultSettings
        $settings.audioFile = Join-Path $directory 'missing.mp3'
        $settings.fallbackMode = 'none'
        $settings.completionGuard.lifecycleMode = 'prefer'
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config

        $event = New-VSCodeCompleteEvent -TurnId 'ordinary-guard'
        $newerEvent = New-VSCodeCompleteEvent -TurnId 'ordinary-newer'
        $timer = New-Object Timers.Timer 250
        $timer.AutoReset = $false
        $subscription = Register-ObjectEvent `
            -InputObject $timer `
            -EventName Elapsed `
            -MessageData ([pscustomobject]@{
                Event = $newerEvent
                StateDirectory = $state
            }) `
            -Action {
                $data = $event.MessageData
                $null = Register-CodexFinishPendingTurn `
                    -Event $data.Event `
                    -StateDirectory $data.StateDirectory `
                    -LifecycleMode prefer
            }

        try {
            $timer.Start()
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-CodexFinishNotification `
                -Event $event `
                -ConfigPath $config `
                -StateDirectory $state `
                -CompletionGraceSeconds 1 `
                -SkipOverlay
            $watch.Stop()

            $pendingPath = @(Get-ChildItem -LiteralPath $state -Filter '*.pending.json' -File)[0].FullName
            $pending = [IO.File]::ReadAllText($pendingPath) | ConvertFrom-Json
            Assert-True (-not $pending.authoritativeRootNotify) 'The lifecycle-free prefer candidate should remain non-authoritative.'
            Assert-True ($watch.ElapsedMilliseconds -ge 900) 'A non-authoritative candidate should retain the grace wait.'
            Assert-True (-not $result.Claimed) 'Newer activity during the grace wait must cancel the ordinary candidate.'
            Assert-Equal 'superseded-by-newer-candidate' $result.SuppressedReason 'The newer candidate should win the pending generation.'
        }
        finally {
            $timer.Stop()
            Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
            Remove-Job -Id $subscription.Id -Force -ErrorAction SilentlyContinue
            $timer.Dispose()
        }
    }

    Invoke-TestCase 'Same-project activity in another session cancels the quiet-window candidate' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'settings.json'
        $state = Join-Path $directory 'state'
        $settings = Get-CodexFinishDefaultSettings
        $settings.audioFile = Join-Path $directory 'missing.mp3'
        $settings.fallbackMode = 'none'
        $settings.hardware.enabled = $false
        $settings.visual.enabled = $false
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config

        $completed = New-VSCodeCompleteEvent `
            -TurnId 'project-candidate' -ThreadId 'project-session-a' -Cwd $directory
        $running = New-VSCodeCompleteEvent `
            -TurnId 'project-next-turn' -ThreadId 'project-session-b' -Cwd $directory
        $null = Set-TestTurnStopped -Event $completed -StateDirectory $state
        $timer = New-Object Timers.Timer 250
        $timer.AutoReset = $false
        $subscription = Register-ObjectEvent `
            -InputObject $timer `
            -EventName Elapsed `
            -MessageData ([pscustomobject]@{
                HookEvent = [pscustomobject]@{
                    session_id = [string]$running.'thread-id'
                    turn_id = [string]$running.'turn-id'
                    cwd = [string]$running.cwd
                    hook_event_name = 'UserPromptSubmit'
                }
                StateDirectory = $state
            }) `
            -Action {
                $data = $event.MessageData
                $null = Update-CodexFinishLifecycleState `
                    -HookEvent $data.HookEvent `
                    -StateDirectory $data.StateDirectory
            }
        try {
            $timer.Start()
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-CodexFinishNotification `
                -Event $completed `
                -ConfigPath $config `
                -StateDirectory $state `
                -CompletionGraceSeconds 1 `
                -SkipAudio `
                -SkipOverlay
            $watch.Stop()

            Assert-True ($watch.ElapsedMilliseconds -ge 900) 'Dry-run completion bypassed the project quiet window.'
            Assert-True (-not $result.Claimed) 'Cross-session project activity did not cancel completion.'
            Assert-Equal 'project-activity-after-candidate' $result.SuppressedReason 'Wrong cross-session cancellation reason.'
            $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
            Assert-Equal 'running' $monitor.projects[0].status 'Canceled project flashed or remained green.'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $state -Filter 'project-*.activity.*.json' -File).Count `
                'Successfully folded activity markers should not accumulate.'
        }
        finally {
            $timer.Stop()
            Unregister-Event -SubscriptionId $subscription.Id -ErrorAction SilentlyContinue
            Remove-Job -Id $subscription.Id -Force -ErrorAction SilentlyContinue
            $timer.Dispose()
        }
    }

    Invoke-TestCase 'Candidate registration rejects activity folded after its observation time' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $candidate = New-VSCodeCompleteEvent `
            -TurnId 'observed-before-lock' -ThreadId 'observed-session' -Cwd $directory
        $activityEvent = [pscustomobject]@{
            session_id = 'newer-project-session'
            turn_id = 'newer-project-turn'
            cwd = $directory
            hook_event_name = 'UserPromptSubmit'
        }
        $observedUtc = [DateTime]::UtcNow.ToString('o')
        Start-Sleep -Milliseconds 25
        $activity = Update-CodexFinishLifecycleState `
            -HookEvent $activityEvent `
            -StateDirectory $state
        Assert-True $activity.Updated 'Newer project activity was not recorded.'

        $runtime = Get-Module CodexFinishShout
        $registered = & $runtime {
            param($candidateEvent, $candidateState, $candidateObserved)
            Register-CodexFinishProjectPendingCandidate `
                -Event $candidateEvent `
                -CandidateId ([Guid]::NewGuid().ToString('N')) `
                -ObservedUtc $candidateObserved `
                -LifecycleGuardUsed $true `
                -AuthoritativeRootNotify $true `
                -StateDirectory $candidateState
        } $candidate $state $observedUtc
        Assert-True (-not $registered.Recorded) `
            'A candidate adopted an activity revision that occurred after it was observed.'
        Assert-Equal 'project-activity-after-candidate' $registered.Reason `
            'Folded activity used the wrong candidate rejection reason.'
    }

    Invoke-TestCase 'Latest same-project completion candidate wins across sessions and claims once' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $first = New-VSCodeCompleteEvent `
            -TurnId 'project-first' -ThreadId 'project-complete-a' -Cwd $directory
        $second = New-VSCodeCompleteEvent `
            -TurnId 'project-second' -ThreadId 'project-complete-b' -Cwd $directory
        # Model the VS Code path where root notify is authoritative but no
        # matching Stop Hook has arrived for either session.
        $null = Set-TestLifecycleEvent `
            -Event $first -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $null = Set-TestLifecycleEvent `
            -Event $second -StateDirectory $state -HookEventName 'UserPromptSubmit'

        $firstPending = Register-CodexFinishPendingTurn `
            -Event $first -StateDirectory $state -LifecycleMode require
        $secondPending = Register-CodexFinishPendingTurn `
            -Event $second -StateDirectory $state -LifecycleMode require
        Assert-True $firstPending.Recorded 'First project candidate was not recorded.'
        Assert-True $secondPending.Recorded 'Second project candidate was not recorded.'

        $firstClaim = Confirm-CodexFinishPendingTurn `
            -Event $first -CandidateId $firstPending.CandidateId -StateDirectory $state
        $secondClaim = Confirm-CodexFinishPendingTurn `
            -Event $second -CandidateId $secondPending.CandidateId -StateDirectory $state
        Assert-True (-not $firstClaim.Claimed) 'Older same-project candidate claimed completion.'
        Assert-Equal 'project-candidate-superseded' $firstClaim.Reason 'Older project candidate used the wrong reason.'
        Assert-True $secondClaim.Claimed 'Latest same-project candidate did not claim completion.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 0 $monitor.running 'Settled project still has a running aggregate.'
        Assert-Equal 2 @($monitor.projects[0].sessions).Count 'Final project sweep lost one session.'
        Assert-Equal 0 @($monitor.projects[0].sessions | Where-Object { $_.status -ceq 'running' }).Count `
            'Final project sweep did not complete every idle session.'
    }

    Invoke-TestCase 'Project activity marker survives settle-lock contention and fails closed' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $completed = New-VSCodeCompleteEvent `
            -TurnId 'locked-candidate' -ThreadId 'locked-session-a' -Cwd $directory
        $running = New-VSCodeCompleteEvent `
            -TurnId 'locked-activity' -ThreadId 'locked-session-b' -Cwd $directory
        $null = Set-TestTurnStopped -Event $completed -StateDirectory $state
        $pending = Register-CodexFinishPendingTurn `
            -Event $completed -StateDirectory $state -LifecycleMode require
        Assert-True $pending.Recorded 'Lock-contention candidate was not recorded.'
        $settleLockPath = @(Get-ChildItem -LiteralPath $state -Filter 'project-*.settle.lock' -File)[0].FullName
        $lockStream = [IO.File]::Open(
            $settleLockPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        try {
            $activity = Update-CodexFinishLifecycleState `
                -HookEvent ([pscustomobject]@{
                    session_id = [string]$running.'thread-id'
                    turn_id = [string]$running.'turn-id'
                    cwd = [string]$running.cwd
                    hook_event_name = 'UserPromptSubmit'
                }) `
                -StateDirectory $state `
                -LockTimeoutMilliseconds 50
        }
        finally {
            $lockStream.Dispose()
        }
        Assert-True $activity.Updated 'Lifecycle activity should remain non-blocking during settle-lock contention.'
        Assert-Equal 'project-settle-lock-unavailable' $activity.ProjectActivityReason `
            'Contended project activity did not report the settle-lock failure.'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $state -Filter 'project-*.activity.*.json' -File).Count `
            'Fail-closed activity marker was not retained.'

        $claim = Confirm-CodexFinishPendingTurn `
            -Event $completed -CandidateId $pending.CandidateId -StateDirectory $state
        Assert-True (-not $claim.Claimed) 'Candidate claimed despite durable activity during lock contention.'
        Assert-Equal 'project-activity-after-candidate' $claim.Reason 'Contended activity marker used the wrong reason.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'running' $monitor.projects[0].status 'Lock-contention cancellation did not stay red.'
    }

    Invoke-TestCase 'Activity during project finalization rolls a completed monitor back to running' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $completed = New-VSCodeCompleteEvent `
            -TurnId 'finalize-race' -ThreadId 'finalize-session-a' -Cwd $directory
        $activityEvent = [pscustomobject]@{
            session_id = 'finalize-session-b'
            turn_id = 'finalize-activity'
            cwd = $directory
            hook_event_name = 'UserPromptSubmit'
        }
        $null = Set-TestTurnStopped -Event $completed -StateDirectory $state
        $pending = Register-CodexFinishPendingTurn `
            -Event $completed -StateDirectory $state -LifecycleMode require
        Assert-True $pending.Recorded 'Finalization-race candidate was not recorded.'

        $monitorLockPath = Join-Path $state 'project-monitor.lock'
        $monitorLock = [IO.File]::Open(
            $monitorLockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $eventBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes(($completed | ConvertTo-Json -Depth 5 -Compress))
        )
        $escapedModule = $runtimeModule.Replace("'", "''")
        $escapedState = $state.Replace("'", "''")
        $confirmCommand = @"
`$ProgressPreference = 'SilentlyContinue'
Import-Module '$escapedModule' -Force
`$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$eventBase64'))
`$candidateEvent = `$json | ConvertFrom-Json
`$result = Confirm-CodexFinishPendingTurn -Event `$candidateEvent -CandidateId '$($pending.CandidateId)' -StateDirectory '$escapedState'
[Console]::Out.Write((`$result | ConvertTo-Json -Depth 5 -Compress))
"@
        $encodedConfirm = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($confirmCommand))
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = (Get-Command powershell.exe).Source
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
            $encodedConfirm
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            $null = $process.Start()
            $settleLockPath = @(Get-ChildItem -LiteralPath $state -Filter 'project-*.settle.lock' -File)[0].FullName
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            $confirmOwnsSettleLock = $false
            while (-not $confirmOwnsSettleLock -and [DateTime]::UtcNow -lt $deadline) {
                $probe = $null
                try {
                    $probe = [IO.File]::Open(
                        $settleLockPath,
                        [IO.FileMode]::Open,
                        [IO.FileAccess]::ReadWrite,
                        [IO.FileShare]::None
                    )
                }
                catch [IO.IOException] {
                    $confirmOwnsSettleLock = $true
                }
                finally {
                    if ($null -ne $probe) { $probe.Dispose() }
                }
                if (-not $confirmOwnsSettleLock) { Start-Sleep -Milliseconds 10 }
            }
            Assert-True $confirmOwnsSettleLock 'Confirm process never acquired the project settle lock.'
            # Give Confirm time to pass its initial marker scan and block on
            # the monitor lock before introducing lock-free activity.
            Start-Sleep -Milliseconds 150
            $runtime = Get-Module CodexFinishShout
            $invalidation = & $runtime {
                param($candidateActivity, $candidateState)
                Invalidate-CodexFinishProjectPendingCandidate `
                    -Event $candidateActivity `
                    -ActivityName 'UserPromptSubmit' `
                    -StateDirectory $candidateState `
                    -LockTimeoutMilliseconds 50
            } $activityEvent $state
            Assert-True (-not $invalidation.Updated) 'Activity unexpectedly acquired the settle lock held by Confirm.'
        }
        finally {
            $monitorLock.Dispose()
        }
        try {
            Assert-True ($process.WaitForExit(5000)) 'Finalization-race Confirm process timed out.'
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            Assert-Equal '' $stderr 'Finalization-race Confirm process wrote stderr.'
            $claim = $stdout | ConvertFrom-Json
            Assert-True (-not $claim.Claimed) 'Activity arriving during finalization still claimed completion.'
            Assert-Equal 'project-activity-after-candidate' $claim.Reason `
                'Post-finalization activity used the wrong suppression reason.'
            $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
            Assert-Equal 'running' $monitor.projects[0].status `
                'Post-finalization activity left the project green.'
        }
        finally {
            if (-not $process.HasExited) { $process.Kill() }
            $process.Dispose()
        }
    }

    Invoke-TestCase 'Settle commit failure rolls a finalized monitor back to running' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $event = New-VSCodeCompleteEvent `
            -TurnId 'settle-commit-failure' -ThreadId 'settle-failure-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $pending = Register-CodexFinishPendingTurn `
            -Event $event -StateDirectory $state -LifecycleMode require
        Assert-True $pending.Recorded 'Settle failure fixture did not register.'
        $settlePath = @(Get-ChildItem -LiteralPath $state -Filter 'project-*.settle.json' -File)[0].FullName
        [IO.File]::SetAttributes($settlePath, [IO.FileAttributes]::ReadOnly)
        try {
            $claim = Confirm-CodexFinishPendingTurn `
                -Event $event -CandidateId $pending.CandidateId -StateDirectory $state
        }
        finally {
            [IO.File]::SetAttributes($settlePath, [IO.FileAttributes]::Normal)
        }
        Assert-True (-not $claim.Claimed) 'A failed settle commit was reported as claimed.'
        Assert-Equal 'project-candidate-confirm-failed' $claim.Reason `
            'Settle commit failure used the wrong claim reason.'
        Assert-True $claim.MonitorRollbackUpdated 'Failed settle commit did not synchronously roll back the monitor.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'running' $monitor.projects[0].status `
            'Failed settle commit left a false green monitor.'
    }

    Invoke-TestCase 'Completion announcement uses the project folder name' {
        $event = New-VSCodeCompleteEvent
        $settings = Get-CodexFinishDefaultSettings
        $message = Get-CodexFinishAnnouncementMessage -Event $event -Settings $settings
        Assert-True $settings.announcement.enabled 'Announcement should be enabled by default.'
        Assert-Contains $message $event.cwd.Split('\')[-1] 'Announcement should include the project name.'
        Assert-Contains $message 'Codex' 'Announcement should identify Codex.'
    }

    Invoke-TestCase 'Completion event publishes a stable project identity' {
        $directory = New-TestDirectory
        $event = New-VSCodeCompleteEvent -TurnId 'project-identity-a'
        $event.cwd = $directory
        $projectPath = Get-CodexFinishProjectPath -Event $event
        $projectKey = Get-CodexFinishProjectKey -Event $event

        Assert-Equal ([IO.Path]::GetFullPath($directory)) $projectPath 'Project path should be normalized.'
        Assert-Equal ([IO.Path]::GetFileName($directory)) (Get-CodexFinishProjectName -Event $event) 'Project name is wrong.'
        Assert-True ($projectKey -match '^[0-9a-f]{64}$') 'Project key should be a SHA-256 hash.'

        $event.cwd = $directory.ToUpperInvariant()
        Assert-Equal $projectKey (Get-CodexFinishProjectKey -Event $event) 'Path casing must not change project identity.'
    }

    Invoke-TestCase 'Project monitor aggregates sessions and any running session wins' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $projectA = Join-Path $directory 'project-a'
        $projectB = Join-Path $directory 'project-b'
        $null = [IO.Directory]::CreateDirectory($projectA)
        $null = [IO.Directory]::CreateDirectory($projectB)
        $a1 = [pscustomobject]@{ session_id = 'a-session-1'; cwd = $projectA }
        $a2 = [pscustomobject]@{ session_id = 'a-session-2'; cwd = $projectA }
        $b1 = [pscustomobject]@{ session_id = 'b-session-1'; cwd = $projectB }

        $null = Update-CodexFinishProjectMonitorState -Event $a1 -Status running -StateDirectory $state
        $null = Update-CodexFinishProjectMonitorState -Event $a2 -Status completed -StateDirectory $state
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 1 $monitor.total 'Two sessions in one folder should aggregate into one project.'
        Assert-Equal 'running' $monitor.projects[0].status 'One running session must keep the project running.'
        Assert-Equal 2 @($monitor.projects[0].sessions).Count 'Both project sessions should be retained.'

        $null = Update-CodexFinishProjectMonitorState -Event $a1 -Status completed -StateDirectory $state
        $null = Update-CodexFinishProjectMonitorState -Event $b1 -Status running -StateDirectory $state
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 2 $monitor.total 'Distinct folders should remain distinct projects.'
        Assert-Equal 1 $monitor.running 'Only project B should be running.'
        Assert-Equal 'project-b' $monitor.projects[0].name 'Running project should be first in state ordering.'
        Assert-True ([IO.File]::Exists((Join-Path $state 'project-monitor.json'))) 'Project monitor state file is missing.'
    }

    Invoke-TestCase 'Moving one session to another cwd removes its old project row' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $projectA = Join-Path $directory 'move-a'
        $projectB = Join-Path $directory 'move-b'
        $null = [IO.Directory]::CreateDirectory($projectA)
        $null = [IO.Directory]::CreateDirectory($projectB)
        $event = [pscustomobject]@{ session_id = 'moving-session'; cwd = $projectA }
        $now = [DateTime]::UtcNow
        $null = Update-CodexFinishProjectMonitorState `
            -Event $event -Status running -StateDirectory $state -NowUtc $now
        $event.cwd = $projectB
        $null = Update-CodexFinishProjectMonitorState `
            -Event $event -Status running -StateDirectory $state -NowUtc $now.AddSeconds(1)
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state

        Assert-Equal 1 $monitor.total 'One session appeared in both its old and new project.'
        Assert-Equal 'move-b' $monitor.projects[0].name 'Moved session did not adopt its new cwd project.'
        Assert-Equal 1 @($monitor.projects[0].sessions).Count 'Moved session should appear exactly once.'

        $event.cwd = $projectA
        $null = Update-CodexFinishProjectMonitorState `
            -Event $event -Status running -StateDirectory $state -NowUtc $now.AddMilliseconds(500)
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 1 $monitor.total 'Delayed old cwd update duplicated the moved session.'
        Assert-Equal 'move-b' $monitor.projects[0].name 'Delayed old cwd update moved the session backwards.'
    }

    Invoke-TestCase 'Older same-session updates cannot overwrite newer project status' {
        $directory = New-TestDirectory
        $project = Join-Path $directory 'ordered-project'
        $state = Join-Path $directory 'state'
        $null = [IO.Directory]::CreateDirectory($project)
        $event = [pscustomobject]@{ session_id = 'ordered-session'; cwd = $project }
        $now = [DateTime]::UtcNow

        $null = Update-CodexFinishProjectMonitorState `
            -Event $event -Status running -StateDirectory $state -NowUtc $now
        $null = Update-CodexFinishProjectMonitorState `
            -Event $event -Status completed -StateDirectory $state -NowUtc $now.AddMinutes(-1)
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'running' $monitor.projects[0].status 'An older completion overwrote newer running state.'

        $null = Update-CodexFinishProjectMonitorState `
            -Event $event -Status completed -StateDirectory $state -NowUtc $now.AddMinutes(1)
        $null = Update-CodexFinishProjectMonitorState `
            -Event $event -Status running -StateDirectory $state -NowUtc $now
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'completed' $monitor.projects[0].status 'An older running update overwrote newer completion state.'
    }

    Invoke-TestCase 'Root Stop stays running while an observed subagent is active' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $event = New-VSCodeCompleteEvent -TurnId 'active-child-stop'
        $event.cwd = $directory
        $null = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $null = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'SubagentStart' -AgentId 'active-child'
        $stopped = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'Stop'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state

        Assert-Equal 1 $stopped.ActiveSubagents 'Stop fixture should retain the active child identity.'
        Assert-Equal 'running' $monitor.projects[0].status 'Project became completed while a child agent was still active.'

        [IO.File]::Delete((Join-Path $state 'project-monitor.json'))
        $otherProject = Join-Path $directory 'bootstrap-trigger'
        $null = [IO.Directory]::CreateDirectory($otherProject)
        $null = Update-CodexFinishProjectMonitorState `
            -Event ([pscustomobject]@{ session_id = 'bootstrap-trigger'; cwd = $otherProject }) `
            -Status running -StateDirectory $state
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        $rebuiltRoot = @($monitor.projects | Where-Object { $_.projectPath -ceq $directory })[0]
        Assert-Equal 'running' $rebuiltRoot.status 'Lifecycle bootstrap ignored an active child and turned the root green.'

        $childStopped = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'SubagentStop' -AgentId 'active-child'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        $completedRoot = @($monitor.projects | Where-Object { $_.projectPath -ceq $directory })[0]
        Assert-Equal 'stopped' $childStopped.RootStatus 'Last child Stop resurrected an already stopped root.'
        Assert-Equal 0 $childStopped.ActiveSubagents 'Last child identity was not removed.'
        Assert-Equal 'running' $completedRoot.status 'Stop-before-notify must remain red while awaiting confirmation.'

        $pending = Register-CodexFinishPendingTurn `
            -Event $event -StateDirectory $state -LifecycleMode require
        Assert-True $pending.Recorded 'Final-child completion candidate was not recorded.'
        $claim = Confirm-CodexFinishPendingTurn `
            -Event $event -CandidateId $pending.CandidateId -StateDirectory $state
        Assert-True $claim.Claimed 'Settled project completion was not claimed.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        $confirmedRoot = @($monitor.projects | Where-Object { $_.projectPath -ceq $directory })[0]
        Assert-Equal 'completed' $confirmedRoot.status 'Confirmed project did not transition to completed.'
    }

    Invoke-TestCase 'Late same-turn Stop preserves an already confirmed project completion' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $event = New-VSCodeCompleteEvent `
            -TurnId 'claimed-before-stop' -ThreadId 'late-stop-session' -Cwd $directory
        $null = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $pending = Register-CodexFinishPendingTurn -Event $event -StateDirectory $state
        $claim = Confirm-CodexFinishPendingTurn `
            -Event $event -CandidateId $pending.CandidateId -StateDirectory $state
        Assert-True $claim.Claimed 'Authoritative completion fixture did not claim.'

        $lateStop = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'Stop'
        Assert-True $lateStop.ProjectAlreadyClaimed 'Late Stop did not recognize its durable same-turn claim.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'completed' $monitor.projects[0].status `
            'Late same-turn Stop reverted a confirmed project to running.'
    }

    Invoke-TestCase 'Stop-only lifecycle settles the monitor without a notify callback' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = Join-Path $directory 'settings.json'
        $settings = Get-CodexFinishDefaultSettings
        $settings.enabled = $false
        $settings.hardware.enabled = $false
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config
        $event = New-VSCodeCompleteEvent `
            -TurnId 'stop-only-turn' -ThreadId 'stop-only-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'running' $monitor.projects[0].status 'Stop should remain red during its quiet boundary.'

        $hookEvent = [pscustomobject]@{
            session_id = [string]$event.'thread-id'
            turn_id = [string]$event.'turn-id'
            cwd = [string]$event.cwd
            hook_event_name = 'Stop'
        }
        $settled = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent $hookEvent `
            -StateDirectory $state `
            -ConfigPath $config `
            -ObservedUtc ([DateTime]::UtcNow.ToString('o'))
        Assert-True $settled.Claimed "Stop-only settlement failed: $($settled.Reason)"
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'completed' $monitor.projects[0].status `
            'Stop-only lifecycle remained permanently red.'
    }

    Invoke-TestCase 'Stop-only fallback uses the complete notification pipeline' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = New-TestNotificationConfig -Directory $directory
        $event = New-VSCodeCompleteEvent `
            -TurnId 'stop-pipeline-turn' -ThreadId 'stop-pipeline-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state

        $result = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $event.'thread-id'; turn_id = $event.'turn-id'; cwd = $event.cwd
            }) `
            -StateDirectory $state `
            -ConfigPath $config `
            -ObservedUtc ([DateTime]::UtcNow.ToString('o')) `
            -SkipAudio `
            -SkipOverlay

        Assert-True $result.Eligible 'Stop fallback did not enter the notification pipeline.'
        Assert-True $result.StopOnlyCandidate 'Stop fallback lost its synthetic candidate identity.'
        Assert-True $result.Claimed "Stop fallback did not claim: $($result.SuppressedReason)"
        Assert-True $result.WouldNotify 'Stop fallback did not reach the audio selection stage.'
        Assert-True $result.OverlayWouldNotify 'Stop fallback did not reach the overlay stage.'
        Assert-Equal 'tts' $result.SelectedMode 'Missing audio did not select the configured fallback.'
        Assert-Equal 'disabled' $result.BoardReason 'Stop fallback did not invoke the board batch path.'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $state -Filter '*.done' -File).Count `
            'Stop fallback did not create exactly one durable turn marker.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'completed' $monitor.projects[0].status 'Stop fallback did not turn the project green.'
    }

    Invoke-TestCase 'Official notify wins before Stop fallback without duplicate presentation' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = New-TestNotificationConfig -Directory $directory
        $event = New-VSCodeCompleteEvent `
            -TurnId 'official-first-turn' -ThreadId 'official-first-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $observed = [DateTime]::UtcNow.ToString('o')

        $official = Invoke-CodexFinishNotification `
            -Event $event -StateDirectory $state -ConfigPath $config `
            -CompletionGraceSeconds 0 -SkipAudio -SkipOverlay
        $fallback = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $event.'thread-id'; turn_id = $event.'turn-id'; cwd = $event.cwd
            }) `
            -StateDirectory $state -ConfigPath $config -ObservedUtc $observed `
            -SkipAudio -SkipOverlay

        Assert-True $official.Claimed 'Official notify did not win its uncontended fixture.'
        Assert-True (-not $fallback.Claimed) 'Late Stop fallback claimed the official turn again.'
        Assert-Equal 'duplicate-turn' $fallback.SuppressedReason 'Late Stop fallback used the wrong duplicate reason.'
        Assert-Equal 1 @($official, $fallback | Where-Object { $_.Claimed }).Count `
            'Official-first ordering produced more than one claim.'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $state -Filter '*.done' -File).Count `
            'Official-first ordering produced duplicate durable markers.'
    }

    Invoke-TestCase 'Stop fallback wins before late official notify without duplicate presentation' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = New-TestNotificationConfig -Directory $directory
        $event = New-VSCodeCompleteEvent `
            -TurnId 'fallback-first-turn' -ThreadId 'fallback-first-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state

        $fallback = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $event.'thread-id'; turn_id = $event.'turn-id'; cwd = $event.cwd
            }) `
            -StateDirectory $state -ConfigPath $config `
            -ObservedUtc ([DateTime]::UtcNow.ToString('o')) -SkipAudio -SkipOverlay
        $official = Invoke-CodexFinishNotification `
            -Event $event -StateDirectory $state -ConfigPath $config `
            -CompletionGraceSeconds 0 -SkipAudio -SkipOverlay

        Assert-True $fallback.Claimed 'Stop fallback did not win its uncontended fixture.'
        Assert-True (-not $official.Claimed) 'Late official notify claimed the fallback turn again.'
        Assert-Equal 'duplicate-turn' $official.SuppressedReason 'Late official notify used the wrong duplicate reason.'
        Assert-Equal 1 @($fallback, $official | Where-Object { $_.Claimed }).Count `
            'Fallback-first ordering produced more than one claim.'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $state -Filter '*.done' -File).Count `
            'Fallback-first ordering produced duplicate durable markers.'
    }

    Invoke-TestCase 'Concurrent official notify and Stop fallback claim exactly once' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = New-TestNotificationConfig -Directory $directory
        $event = New-VSCodeCompleteEvent `
            -TurnId 'concurrent-stop-turn' -ThreadId 'concurrent-stop-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $observed = [DateTime]::UtcNow.ToString('o')
        $eventBase64 = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes(($event | ConvertTo-Json -Compress))
        )
        $escapedModule = $runtimeModule.Replace("'", "''")
        $escapedState = $state.Replace("'", "''")
        $escapedConfig = $config.Replace("'", "''")
        $officialCommand = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
Import-Module '$escapedModule' -Force
`$event = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$eventBase64')) | ConvertFrom-Json
Invoke-CodexFinishNotification -Event `$event -StateDirectory '$escapedState' -ConfigPath '$escapedConfig' -CompletionGraceSeconds 0 -SkipAudio -SkipOverlay | ConvertTo-Json -Compress
"@
        $fallbackCommand = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
Import-Module '$escapedModule' -Force
`$event = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$eventBase64')) | ConvertFrom-Json
Invoke-CodexFinishStoppedProjectSettlement -HookEvent ([pscustomobject]@{ session_id = `$event.'thread-id'; turn_id = `$event.'turn-id'; cwd = `$event.cwd }) -StateDirectory '$escapedState' -ConfigPath '$escapedConfig' -ObservedUtc '$observed' -SkipAudio -SkipOverlay | ConvertTo-Json -Compress
"@
        $officialProcess = Start-TestScriptPowerShell -Command $officialCommand
        $fallbackProcess = Start-TestScriptPowerShell -Command $fallbackCommand
        Assert-True $officialProcess.WaitForExit(15000) 'Concurrent official process timed out.'
        Assert-True $fallbackProcess.WaitForExit(15000) 'Concurrent fallback process timed out.'
        $officialError = $officialProcess.StandardError.ReadToEnd().Trim()
        $fallbackError = $fallbackProcess.StandardError.ReadToEnd().Trim()
        $officialResult = $officialProcess.StandardOutput.ReadToEnd().Trim() | ConvertFrom-Json
        $fallbackResult = $fallbackProcess.StandardOutput.ReadToEnd().Trim() | ConvertFrom-Json

        Assert-Equal '' $officialError 'Concurrent official process wrote stderr.'
        Assert-Equal '' $fallbackError 'Concurrent fallback process wrote stderr.'
        Assert-Equal 1 @($officialResult, $fallbackResult | Where-Object { $_.Claimed }).Count `
            'Concurrent completion produced zero or multiple claims.'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $state -Filter '*.done' -File).Count `
            'Concurrent completion produced duplicate durable markers.'
    }

    Invoke-TestCase 'UserPrompt after Stop cancels the detached fallback' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = New-TestNotificationConfig -Directory $directory
        $event = New-VSCodeCompleteEvent `
            -TurnId 'resumed-stop-turn' -ThreadId 'resumed-stop-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $observed = [DateTime]::UtcNow.ToString('o')
        $null = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'UserPromptSubmit' -TurnId 'newer-turn'

        $result = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $event.'thread-id'; turn_id = $event.'turn-id'; cwd = $event.cwd
            }) `
            -StateDirectory $state -ConfigPath $config -ObservedUtc $observed `
            -SkipAudio -SkipOverlay
        Assert-True (-not $result.Claimed) 'Resumed root was announced by an old Stop worker.'
        Assert-Equal 'root-turn-still-running' $result.SuppressedReason `
            'Resumed root used the wrong suppression reason.'
        Assert-Equal 'running' (Get-CodexFinishProjectMonitorState -StateDirectory $state).projects[0].status `
            'Resumed root did not remain red.'
    }

    Invoke-TestCase 'SubagentStart after Stop cancels the detached fallback' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = New-TestNotificationConfig -Directory $directory
        $event = New-VSCodeCompleteEvent `
            -TurnId 'child-after-stop-turn' -ThreadId 'child-after-stop-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $observed = [DateTime]::UtcNow.ToString('o')
        $null = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'SubagentStart' -AgentId 'late-child'

        $result = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $event.'thread-id'; turn_id = $event.'turn-id'; cwd = $event.cwd
            }) `
            -StateDirectory $state -ConfigPath $config -ObservedUtc $observed `
            -SkipAudio -SkipOverlay
        Assert-True (-not $result.Claimed) 'Active child was announced by an old Stop worker.'
        Assert-Equal 'subagent-still-active' $result.SuppressedReason `
            'Active child used the wrong suppression reason.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $state -Filter '*.done' -File -ErrorAction SilentlyContinue).Count `
            'Active child created a completion marker.'
    }

    Invoke-TestCase 'A running same-project session blocks Stop fallback' {
        $directory = New-TestDirectory
        $project = Join-Path $directory 'shared-stop-project'
        $null = [IO.Directory]::CreateDirectory($project)
        $state = Join-Path $directory 'state'
        $config = New-TestNotificationConfig -Directory $directory
        $stopped = New-VSCodeCompleteEvent `
            -TurnId 'shared-stopped-turn' -ThreadId 'shared-stopped-session' -Cwd $project
        $running = New-VSCodeCompleteEvent `
            -TurnId 'shared-running-turn' -ThreadId 'shared-running-session' -Cwd $project
        $null = Set-TestTurnStopped -Event $stopped -StateDirectory $state
        $observed = [DateTime]::UtcNow.ToString('o')
        $null = Set-TestLifecycleEvent `
            -Event $running -StateDirectory $state -HookEventName 'UserPromptSubmit'

        $result = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $stopped.'thread-id'; turn_id = $stopped.'turn-id'; cwd = $project
            }) `
            -StateDirectory $state -ConfigPath $config -ObservedUtc $observed `
            -SkipAudio -SkipOverlay
        Assert-True (-not $result.Claimed) 'One stopped session completed a project with another running session.'
        Assert-Equal 'project-session-still-running' $result.SuppressedReason `
            'Running peer session used the wrong suppression reason.'
        Assert-Equal 'running' (Get-CodexFinishProjectMonitorState -StateDirectory $state).projects[0].status `
            'Shared project did not remain red.'
    }

    Invoke-TestCase 'Disabled presentation still commits Stop fallback completion' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = New-TestNotificationConfig -Directory $directory -Enabled $false
        $event = New-VSCodeCompleteEvent `
            -TurnId 'disabled-stop-turn' -ThreadId 'disabled-stop-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $result = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $event.'thread-id'; turn_id = $event.'turn-id'; cwd = $event.cwd
            }) `
            -StateDirectory $state -ConfigPath $config `
            -ObservedUtc ([DateTime]::UtcNow.ToString('o'))

        Assert-True $result.Claimed 'Disabled presentation prevented the monitor claim.'
        Assert-Equal 'disabled' $result.SuppressedReason 'Disabled presentation used the wrong reason.'
        Assert-True (-not $result.WouldNotify) 'Disabled presentation reached audio output.'
        Assert-True (-not $result.OverlayWouldNotify) 'Disabled presentation reached overlay output.'
        Assert-Equal 'completed' (Get-CodexFinishProjectMonitorState -StateDirectory $state).projects[0].status `
            'Disabled presentation did not turn the project green.'
    }

    Invoke-TestCase 'Quiet hours still commit Stop fallback completion' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = New-TestNotificationConfig -Directory $directory -QuietAlways $true
        $event = New-VSCodeCompleteEvent `
            -TurnId 'quiet-stop-turn' -ThreadId 'quiet-stop-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $result = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $event.'thread-id'; turn_id = $event.'turn-id'; cwd = $event.cwd
            }) `
            -StateDirectory $state -ConfigPath $config `
            -ObservedUtc ([DateTime]::UtcNow.ToString('o'))

        Assert-True $result.Claimed 'Quiet hours prevented the monitor claim.'
        Assert-Equal 'quiet-hours' $result.SuppressedReason 'Quiet hours used the wrong reason.'
        Assert-True (-not $result.WouldNotify) 'Quiet hours reached audio output.'
        Assert-True (-not $result.OverlayWouldNotify) 'Quiet hours reached overlay output.'
        Assert-Equal 'completed' (Get-CodexFinishProjectMonitorState -StateDirectory $state).projects[0].status `
            'Quiet hours did not turn the project green.'
    }

    Invoke-TestCase 'Board failure does not block Stop fallback overlay and audio eligibility' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = New-TestNotificationConfig -Directory $directory -HardwareEnabled $true
        $settings = Get-CodexFinishSettings -ConfigPath $config
        $settings.hardware.port = 'COM254'
        $settings.hardware.autoDetect = $false
        $settings.hardware.timeoutMilliseconds = 100
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config
        $event = New-VSCodeCompleteEvent `
            -TurnId 'board-failure-stop-turn' -ThreadId 'board-failure-stop-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state

        $result = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $event.'thread-id'; turn_id = $event.'turn-id'; cwd = $event.cwd
            }) `
            -StateDirectory $state -ConfigPath $config `
            -ObservedUtc ([DateTime]::UtcNow.ToString('o')) -SkipAudio -SkipOverlay
        Assert-True $result.Claimed 'Board failure prevented the completion claim.'
        Assert-True (-not $result.BoardNotified) 'Nonexistent board unexpectedly reported success.'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$result.BoardReason)) `
            'Board failure did not report its transport reason.'
        Assert-Equal 'desktop' $result.PresentationRoute 'Board failure did not select the desktop route.'
        Assert-True $result.DesktopFallbackUsed 'Board failure did not report desktop fallback use.'
        Assert-True $result.OverlayWouldNotify 'Board failure suppressed overlay eligibility.'
        Assert-True $result.WouldNotify 'Board failure suppressed audio eligibility.'
        Assert-Equal 'tts' $result.SelectedMode 'Board failure changed the selected audio fallback.'
    }

    Invoke-TestCase 'Stop-only candidates never replace official pending work' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $event = New-VSCodeCompleteEvent `
            -TurnId 'official-pending-turn' -ThreadId 'official-pending-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $official = Register-CodexFinishPendingTurn -Event $event -StateDirectory $state
        Assert-True $official.Recorded 'Official pending fixture was not recorded.'

        $fallback = Register-CodexFinishPendingTurn `
            -Event $event -StateDirectory $state -StopOnly `
            -ObservedUtc ([DateTime]::UtcNow.ToString('o'))
        Assert-True (-not $fallback.Recorded) 'Stop-only candidate replaced official pending work.'
        Assert-Equal 'thread-candidate-already-pending' $fallback.Reason `
            'Stop-only candidate used the wrong vacancy reason.'
        $pending = [IO.File]::ReadAllText(
            @(Get-ChildItem -LiteralPath $state -Filter '*.pending.json' -File)[0].FullName
        ) | ConvertFrom-Json
        Assert-Equal $official.CandidateId $pending.candidateId `
            'Official thread candidate identity was overwritten.'
    }

    Invoke-TestCase 'Official pending work replaces an unclaimed Stop-only candidate' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $event = New-VSCodeCompleteEvent `
            -TurnId 'fallback-pending-turn' -ThreadId 'fallback-pending-session' -Cwd $directory
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $fallback = Register-CodexFinishPendingTurn `
            -Event $event -StateDirectory $state -StopOnly `
            -ObservedUtc ([DateTime]::UtcNow.ToString('o'))
        Assert-True $fallback.Recorded 'Stop-only pending fixture was not recorded.'

        $official = Register-CodexFinishPendingTurn -Event $event -StateDirectory $state
        Assert-True $official.Recorded 'Official pending work could not replace Stop-only candidate.'
        Assert-True ($official.CandidateId -cne $fallback.CandidateId) `
            'Official candidate reused the Stop-only generation.'
        $pending = [IO.File]::ReadAllText(
            @(Get-ChildItem -LiteralPath $state -Filter '*.pending.json' -File)[0].FullName
        ) | ConvertFrom-Json
        Assert-Equal $official.CandidateId $pending.candidateId `
            'Official candidate was not durable in thread state.'
        Assert-True (-not [bool]$pending.stopOnlyCandidate) `
            'Official replacement retained the Stop-only marker.'
    }

    Invoke-TestCase 'SessionEnd preserves an older claimed turn across an unconfirmed Stop candidate' {
        $directory = New-TestDirectory
        $project = Join-Path $directory 'claimed-session-end-race'
        $null = [IO.Directory]::CreateDirectory($project)
        $state = Join-Path $directory 'state'
        $config = New-TestNotificationConfig -Directory $directory -Enabled $false
        $claimedEvent = New-VSCodeCompleteEvent `
            -TurnId 'already-claimed-turn' -ThreadId 'already-claimed-session' -Cwd $project
        $closingEvent = New-VSCodeCompleteEvent `
            -TurnId 'closing-stop-turn' -ThreadId 'closing-stop-session' -Cwd $project
        $null = Set-TestLifecycleEvent `
            -Event $claimedEvent -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $claimedPending = Register-CodexFinishPendingTurn -Event $claimedEvent -StateDirectory $state
        $claimed = Confirm-CodexFinishPendingTurn `
            -Event $claimedEvent -CandidateId $claimedPending.CandidateId -StateDirectory $state
        Assert-True $claimed.Claimed 'Older completion fixture did not claim.'

        $null = Set-TestLifecycleEvent `
            -Event $closingEvent -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $null = Set-TestTurnStopped -Event $closingEvent -StateDirectory $state
        $closingObserved = [DateTime]::UtcNow.ToString('o')
        $closingPending = Register-CodexFinishPendingTurn `
            -Event $closingEvent -StateDirectory $state -StopOnly -ObservedUtc $closingObserved
        Assert-True $closingPending.Recorded 'Closing Stop candidate was not registered.'

        $ended = Set-TestLifecycleEvent `
            -Event $closingEvent -StateDirectory $state -HookEventName 'SessionEnd'
        Assert-True ($null -eq $ended.RecoverySettlementEvent) `
            'SessionEnd re-armed an already completed remaining session.'
        $settle = [IO.File]::ReadAllText(
            @(Get-ChildItem -LiteralPath $state -Filter 'project-*.settle.json' -File)[0].FullName
        ) | ConvertFrom-Json
        Assert-Equal $claimedEvent.'turn-id' $settle.lastClaimedTurnId `
            'Register/SessionEnd erased the prior committed turn identity.'

        $duplicate = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $claimedEvent.'thread-id'; turn_id = $claimedEvent.'turn-id'; cwd = $project
            }) `
            -StateDirectory $state -ConfigPath $config `
            -ObservedUtc ([DateTime]::UtcNow.ToString('o'))
        Assert-True (-not $duplicate.Claimed) 'Older completed turn was claimed again after SessionEnd.'
        Assert-Equal 'duplicate-turn' $duplicate.SuppressedReason `
            'Older completed turn used the wrong durable duplicate reason.'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $state -Filter '*.done' -File).Count `
            'SessionEnd race created a second completion marker.'
    }

    Invoke-TestCase 'Project monitor removes stale running sessions after six hours and retains recent completion' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $stalePath = Join-Path $directory 'stale-running'
        $completePath = Join-Path $directory 'recent-complete'
        $triggerPath = Join-Path $directory 'current-running'
        foreach ($path in @($stalePath, $completePath, $triggerPath)) {
            $null = [IO.Directory]::CreateDirectory($path)
        }
        $now = [DateTime]::UtcNow
        $null = Update-CodexFinishProjectMonitorState `
            -Event ([pscustomobject]@{ session_id = 'stale'; cwd = $stalePath }) `
            -Status running -StateDirectory $state -NowUtc $now.AddHours(-7)
        $null = Update-CodexFinishProjectMonitorState `
            -Event ([pscustomobject]@{ session_id = 'complete'; cwd = $completePath }) `
            -Status completed -StateDirectory $state -NowUtc $now.AddHours(-23)
        $null = Update-CodexFinishProjectMonitorState `
            -Event ([pscustomobject]@{ session_id = 'current'; cwd = $triggerPath }) `
            -Status running -StateDirectory $state -NowUtc $now

        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 2 $monitor.total 'Stale running project should be pruned while recent completion remains.'
        Assert-True (-not (@($monitor.projects.name) -contains 'stale-running')) 'Six-hour stale running project was retained.'
        Assert-True (@($monitor.projects.name) -contains 'recent-complete') 'Completion inside the 24-hour window was removed.'
    }

    Invoke-TestCase 'Mojibake lifecycle cwd is repaired only when the UTF-8 directory exists' {
        $directory = New-TestDirectory
        $actualPath = Join-Path $directory ([string]([char]0x9879) + [char]0x76EE + '-' + [char]0x8FDB + [char]0x5EA6)
        $null = [IO.Directory]::CreateDirectory($actualPath)
        $garbled = [Text.Encoding]::GetEncoding(936).GetString([Text.Encoding]::UTF8.GetBytes($actualPath))
        $resolved = Get-CodexFinishProjectPath -Event ([pscustomobject]@{ cwd = $garbled })
        Assert-Equal ([IO.Path]::GetFullPath($actualPath)) $resolved 'Existing UTF-8 project path was not repaired from GBK mojibake.'
    }

    Invoke-TestCase 'Project monitor bootstraps and repairs existing lifecycle files' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $oldProjectName = [string]([char]0x9879) + [char]0x76EE + [char]0x8FDB + [char]0x5EA6
        $oldProjectPath = Join-Path $directory $oldProjectName
        $triggerPath = Join-Path $directory 'trigger-project'
        $null = [IO.Directory]::CreateDirectory($oldProjectPath)
        $null = [IO.Directory]::CreateDirectory($triggerPath)
        $garbled = [Text.Encoding]::GetEncoding(936).GetString([Text.Encoding]::UTF8.GetBytes($oldProjectPath))
        Write-TestFile `
            -Path (Join-Path $state 'legacy.lifecycle.json') `
            -Content (([pscustomobject]@{
                threadHash = ('b' * 64); sessionId = 'legacy-session'; cwd = $garbled
                rootStatus = 'running'; updatedUtc = [DateTime]::UtcNow.ToString('o')
            } | ConvertTo-Json -Depth 5) + "`n")

        $null = Update-CodexFinishProjectMonitorState `
            -Event ([pscustomobject]@{ session_id = 'trigger-session'; cwd = $triggerPath }) `
            -Status running `
            -StateDirectory $state
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 2 $monitor.total 'Existing lifecycle project was not imported.'
        Assert-True (@($monitor.projects.name) -contains $oldProjectName) 'Imported lifecycle project name was not repaired.'
    }

    Invoke-TestCase 'Workspace filtering uses path boundaries and supports nested git roots' {
        $directory = New-TestDirectory
        $workspace = Join-Path $directory 'foo'
        $nestedProject = Join-Path $workspace 'packages\app'
        $siblingPrefix = Join-Path $directory 'foobar'
        foreach ($path in @($workspace, $nestedProject, $siblingPrefix)) {
            $null = [IO.Directory]::CreateDirectory($path)
        }
        $now = [DateTime]::UtcNow
        $monitor = [pscustomobject][ordered]@{
            schemaVersion = 1; updatedAtUtc = $now.ToString('o'); total = 3; running = 3; completed = 0
            projects = [object[]]@(
                [pscustomobject]@{ name = 'git-root'; status = 'running'; projectKey = 'a'; projectPath = $workspace; updatedAtUtc = $now.ToString('o'); sessions = @([pscustomobject]@{ threadHash = 'a'; status = 'running'; updatedAtUtc = $now.ToString('o') }) },
                [pscustomobject]@{ name = 'nested'; status = 'running'; projectKey = 'b'; projectPath = $nestedProject; updatedAtUtc = $now.ToString('o'); sessions = @([pscustomobject]@{ threadHash = 'b'; status = 'running'; updatedAtUtc = $now.ToString('o') }) },
                [pscustomobject]@{ name = 'prefix-sibling'; status = 'running'; projectKey = 'c'; projectPath = $siblingPrefix; updatedAtUtc = $now.ToString('o'); sessions = @([pscustomobject]@{ threadHash = 'c'; status = 'running'; updatedAtUtc = $now.ToString('o') }) }
            )
        }

        $filtered = Select-CodexFinishProjectMonitorForWorkspaces `
            -MonitorState $monitor `
            -WorkspacePaths @($nestedProject) `
            -NowUtc $now
        Assert-Equal 2 $filtered.total 'Nested workspace should match itself and its enclosing git root.'
        Assert-True (@($filtered.projects.name) -contains 'git-root') 'Enclosing git root was not matched.'
        Assert-True (@($filtered.projects.name) -contains 'nested') 'Nested project was not matched.'
        Assert-True (-not (@($filtered.projects.name) -contains 'prefix-sibling')) `
            'Path prefix without a directory boundary was incorrectly matched.'
    }

    Invoke-TestCase 'Workspace leases clear closed projects and history restores a reopened workspace' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $projectA = Join-Path $directory 'workspace-a'
        $projectB = Join-Path $directory 'workspace-b'
        foreach ($path in @($projectA, $projectB)) { $null = [IO.Directory]::CreateDirectory($path) }
        $now = [DateTime]::UtcNow
        $null = Update-CodexFinishProjectMonitorState `
            -Event ([pscustomobject]@{ session_id = 'lease-a'; cwd = $projectA }) `
            -Status running -StateDirectory $state -NowUtc $now
        $null = Update-CodexFinishProjectMonitorState `
            -Event ([pscustomobject]@{ session_id = 'lease-b'; cwd = $projectB }) `
            -Status completed -StateDirectory $state -NowUtc $now

        Enable-TestWorkspaceMonitor -StateDirectory $state
        $cleared = Sync-CodexFinishProjectMonitorWithWorkspaceLeases `
            -StateDirectory $state -NowUtc $now
        Assert-Equal 0 $cleared.State.total 'No valid leases must publish an empty live snapshot.'
        Assert-Equal 2 $cleared.HistoryState.total 'Closed rows should remain in private history for reopen recovery.'

        Write-TestWorkspaceLease -StateDirectory $state -WorkspacePaths @($projectA) -UpdatedAtUtc $now
        $reopened = Sync-CodexFinishProjectMonitorWithWorkspaceLeases `
            -StateDirectory $state -NowUtc $now.AddSeconds(1)
        Assert-Equal 1 $reopened.State.total 'Reopened workspace was not restored from history.'
        Assert-Equal 'workspace-a' $reopened.State.projects[0].name 'Wrong workspace was restored.'

        $outsideUpdate = Update-CodexFinishProjectMonitorState `
            -Event ([pscustomobject]@{ session_id = 'lease-b-new'; cwd = $projectB }) `
            -Status running -StateDirectory $state -NowUtc $now.AddSeconds(2)
        Assert-Equal 1 $outsideUpdate.State.total 'A Hook resurrected a project outside current leases.'
        Assert-Equal 'workspace-a' $outsideUpdate.State.projects[0].name 'Lease-scoped live row changed unexpectedly.'
        Assert-True (@($outsideUpdate.HistoryState.projects.name) -contains 'workspace-b') `
            'Filtered Hook update was not retained in private history.'
    }

    Invoke-TestCase 'Workspace lease process identity survives sleep without accepting PID reuse' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $workspace = Join-Path $directory 'sleep-workspace'
        $null = [IO.Directory]::CreateDirectory($workspace)
        Enable-TestWorkspaceMonitor -StateDirectory $state
        $now = [DateTime]::UtcNow
        Write-TestWorkspaceLease `
            -StateDirectory $state `
            -WorkspacePaths @($workspace) `
            -UpdatedAtUtc $now.AddHours(-1)
        $alive = Get-CodexFinishWorkspaceLeaseState -StateDirectory $state -NowUtc $now
        Assert-Equal 1 $alive.ValidLeaseCount 'Matching live process should rescue a stale heartbeat after sleep.'
        Assert-Equal 'process' $alive.ValidLeases[0].aliveReason 'Stale heartbeat used the wrong liveness evidence.'

        Write-TestWorkspaceLease `
            -StateDirectory $state `
            -WorkspacePaths @($workspace) `
            -UpdatedAtUtc $now.AddHours(-1) `
            -ProcessStartedUtc $now.AddYears(-1)
        $reused = Get-CodexFinishWorkspaceLeaseState -StateDirectory $state -NowUtc $now
        Assert-Equal 0 $reused.ValidLeaseCount 'Mismatched process start time should reject PID reuse.'
    }

    Invoke-TestCase 'Background sync prunes dead and aged malformed leases only' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $workspace = Join-Path $directory 'cleanup-workspace'
        $null = [IO.Directory]::CreateDirectory($workspace)
        Enable-TestWorkspaceMonitor -StateDirectory $state
        $now = [DateTime]::UtcNow
        Write-TestWorkspaceLease `
            -StateDirectory $state -WorkspacePaths @($workspace) -LeaseId 'dead' `
            -UpdatedAtUtc $now.AddHours(-1) -ProcessId 2147483000 -ProcessStartedUtc $now.AddHours(-2)
        Write-TestWorkspaceLease `
            -StateDirectory $state -WorkspacePaths @($workspace) -LeaseId 'fresh-dead' `
            -UpdatedAtUtc $now -ProcessId 2147483000 -ProcessStartedUtc $now.AddHours(-2)
        Write-TestWorkspaceLease `
            -StateDirectory $state -WorkspacePaths @($workspace) -LeaseId 'sleep-live' `
            -UpdatedAtUtc $now.AddHours(-1)
        $malformedPath = Join-Path $state 'workspace-lease-malformed.json'
        Write-TestFile -Path $malformedPath -Content '{broken'
        [IO.File]::SetLastWriteTimeUtc($malformedPath, $now.AddMinutes(-5))

        $sync = Sync-CodexFinishProjectMonitorWithWorkspaceLeases `
            -StateDirectory $state -NowUtc $now
        Assert-Equal 2 $sync.LeaseCleanup.Removed 'Cleanup did not remove exactly dead and aged malformed leases.'
        Assert-True (-not [IO.File]::Exists((Join-Path $state 'workspace-lease-dead.json'))) `
            'Stale dead-process lease was retained.'
        Assert-True (-not [IO.File]::Exists($malformedPath)) 'Aged malformed lease was retained.'
        Assert-True ([IO.File]::Exists((Join-Path $state 'workspace-lease-fresh-dead.json'))) `
            'Fresh heartbeat was removed before its TTL.'
        Assert-True ([IO.File]::Exists((Join-Path $state 'workspace-lease-sleep-live.json'))) `
            'Stale heartbeat backed by matching process identity was removed.'
    }

    Invoke-TestCase 'Lease cleanup retains an atomically replaced heartbeat' {
        $directory = New-TestDirectory
        $leasePath = Join-Path $directory 'workspace-lease-race.json'
        $staleText = '{"schemaVersion":1,"leaseId":"race","updatedAtUtc":"2000-01-01T00:00:00Z"}'
        Write-TestFile -Path $leasePath -Content $staleText
        $staleInfo = [IO.FileInfo]::new($leasePath)
        $staleInfo.Refresh()
        $freshText = '{"schemaVersion":1,"leaseId":"race","updatedAtUtc":"2099-01-01T00:00:00Z"}'
        $replacement = {
            param($CanonicalPath, $QuarantinePath)
            [IO.File]::WriteAllText($CanonicalPath, $freshText, [Text.UTF8Encoding]::new($false))
        }.GetNewClosure()

        $deleted = & (Get-Module CodexFinishShout) {
            param($Path, $Text, $Ticks, $Length, $AfterMove)
            Remove-CodexFinishWorkspaceLeaseFileIfUnchanged `
                -Path $Path -ExpectedText $Text -ExpectedWriteTicks $Ticks `
                -ExpectedLength $Length -AfterQuarantineMove $AfterMove
        } $leasePath $staleText $staleInfo.LastWriteTimeUtc.Ticks $staleInfo.Length $replacement
        Assert-True $deleted 'Cleanup did not remove the exact stale file after quarantine.'
        Assert-True ([IO.File]::Exists($leasePath)) 'Fresh replacement file is missing.'
        Assert-Equal $freshText ([IO.File]::ReadAllText($leasePath)) 'Fresh replacement content changed.'
    }

    Invoke-TestCase 'Completion cannot claim after its workspace lease disappears' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $project = Join-Path $directory 'closing-workspace'
        $null = [IO.Directory]::CreateDirectory($project)
        Enable-TestWorkspaceMonitor -StateDirectory $state
        Write-TestWorkspaceLease -StateDirectory $state -WorkspacePaths @($project)
        $event = New-VSCodeCompleteEvent `
            -TurnId 'closing-turn' -ThreadId 'closing-session' -Cwd $project
        $null = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $candidate = Register-CodexFinishPendingTurn -Event $event -StateDirectory $state
        Assert-True $candidate.Recorded 'Closing-window fixture did not register its pending completion.'

        [IO.File]::Delete((Join-Path $state 'workspace-lease-test-lease.json'))
        $claim = Confirm-CodexFinishPendingTurn `
            -Event $event -CandidateId $candidate.CandidateId -StateDirectory $state
        Assert-True (-not $claim.Claimed) 'Sleeping completion claimed after the VS Code workspace closed.'
        Assert-Equal 'project-not-present' $claim.Reason 'Closed workspace used the wrong fail-closed reason.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $state -Filter '*.done' -File -ErrorAction SilentlyContinue).Count `
            'Closed workspace wrote a completion claim marker.'
        $threadHash = Get-CodexFinishProjectKey -Event ([pscustomobject]@{ cwd = $project })
        Assert-True (-not (@(Get-ChildItem -LiteralPath $state -Filter '*.pending.json' -File).Count)) `
            'Closed workspace left a retryable thread candidate.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-True ($monitor.total -eq 0 -or $monitor.projects[0].status -ceq 'running') `
            'Closed workspace was incorrectly published completed before playback.'
    }

    Invoke-TestCase 'Workspace migration repairs Chinese mojibake before lease matching' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $projectName = [string]([char]0x4E2D) + [char]0x6587 + [char]0x9879 + [char]0x76EE
        $projectPath = Join-Path $directory $projectName
        $null = [IO.Directory]::CreateDirectory($projectPath)
        $garbledPath = [Text.Encoding]::GetEncoding(936).GetString(
            [Text.Encoding]::UTF8.GetBytes($projectPath)
        )
        $now = [DateTime]::UtcNow
        $legacy = [ordered]@{
            schemaVersion = 1; updatedAtUtc = $now.ToString('o'); total = 1; running = 1; completed = 0
            projects = @([ordered]@{
                name = 'legacy-garbled'; status = 'running'; projectKey = ('f' * 64)
                projectPath = $garbledPath; updatedAtUtc = $now.ToString('o')
                sessions = @([ordered]@{ threadHash = ('e' * 64); status = 'running'; updatedAtUtc = $now.ToString('o') })
            })
        }
        Write-TestFile -Path (Join-Path $state 'project-monitor.json') `
            -Content (($legacy | ConvertTo-Json -Depth 8) + "`n")
        Enable-TestWorkspaceMonitor -StateDirectory $state
        Write-TestWorkspaceLease -StateDirectory $state -WorkspacePaths @($projectPath) -UpdatedAtUtc $now

        $migrated = Sync-CodexFinishProjectMonitorWithWorkspaceLeases -StateDirectory $state -NowUtc $now
        Assert-Equal 1 $migrated.State.total 'Correct Unicode lease failed to match a legacy mojibake row.'
        Assert-Equal $projectName $migrated.State.projects[0].name 'Legacy project name was not normalized.'
        Assert-Equal ([IO.Path]::GetFullPath($projectPath)) $migrated.State.projects[0].projectPath `
            'Legacy project path was not normalized.'
        $expectedKey = Get-CodexFinishProjectKey -Event ([pscustomobject]@{ cwd = $projectPath })
        Assert-Equal $expectedKey $migrated.State.projects[0].projectKey `
            'Project key was not recomputed from the repaired Unicode path.'
    }

    Invoke-TestCase 'Monitor sync exposes the thirty-second snapshot resend boundary' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $workspace = Join-Path $directory 'resend-workspace'
        $null = [IO.Directory]::CreateDirectory($workspace)
        Enable-TestWorkspaceMonitor -StateDirectory $state
        $now = [DateTime]::UtcNow
        Write-TestWorkspaceLease -StateDirectory $state -WorkspacePaths @($workspace) -UpdatedAtUtc $now
        $null = Update-CodexFinishProjectMonitorState `
            -Event ([pscustomobject]@{ session_id = 'resend-session'; cwd = $workspace }) `
            -Status running -StateDirectory $state -NowUtc $now

        $first = Invoke-CodexFinishProjectMonitorSync `
            -StateDirectory $state -NowUtc $now -SkipBoard
        $early = Invoke-CodexFinishProjectMonitorSync `
            -StateDirectory $state -NowUtc $now.AddSeconds(5) -LastSnapshotUtc $now -SkipBoard
        $due = Invoke-CodexFinishProjectMonitorSync `
            -StateDirectory $state -NowUtc $now.AddSeconds(31) -LastSnapshotUtc $now -SkipBoard
        Assert-True $first.SnapshotDue 'First worker cycle should request a snapshot.'
        Assert-True (-not $early.SnapshotDue) 'Snapshot was requested before the resend interval.'
        Assert-True $due.SnapshotDue 'Snapshot was not requested after thirty seconds.'
        Assert-True (-not $due.SnapshotAttempted) 'SkipBoard unit test unexpectedly opened serial hardware.'
    }

    Invoke-TestCase 'Monitor worker single-instance check is silent and non-blocking' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $null = [IO.Directory]::CreateDirectory($state)
        $lockStream = [IO.File]::Open(
            (Join-Path $state 'monitor-sync-worker.lock'),
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        try {
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = (Get-Command powershell.exe).Source
            $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
                $monitorWorkerScript + '" -StateDirectory "' + $state + '" -MaximumIterations 1 -SkipBoard'
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $startInfo
            $null = $process.Start()
            Assert-True ($process.WaitForExit(2500)) 'Second monitor worker blocked on the single-instance lock.'
            $watch.Stop()
            Assert-Equal 0 $process.ExitCode 'Second monitor worker should exit successfully.'
            Assert-Equal '' ($process.StandardOutput.ReadToEnd()) 'Monitor worker emitted stdout.'
            Assert-Equal '' ($process.StandardError.ReadToEnd()) 'Monitor worker emitted stderr.'
            Assert-True ($watch.ElapsedMilliseconds -lt 2500) 'Single-instance rejection took too long.'
        }
        finally {
            $lockStream.Dispose()
        }
    }

    Invoke-TestCase 'Monitor worker hands a newly published lease across lock release' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $workspace = Join-Path $directory 'handoff-workspace'
        $null = [IO.Directory]::CreateDirectory($workspace)
        Enable-TestWorkspaceMonitor -StateDirectory $state
        Write-TestWorkspaceLease -StateDirectory $state -WorkspacePaths @($workspace)
        $lockStream = [IO.File]::Open(
            (Join-Path $state 'monitor-sync-worker.lock'),
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $process = $null
        try {
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = (Get-Command powershell.exe).Source
            $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
                $monitorWorkerScript + '" -StateDirectory "' + $state +
                '" -MaximumIterations 1 -HandoffWaitSeconds 4 -SkipBoard'
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $startInfo
            $null = $process.Start()
            Start-Sleep -Milliseconds 500
            Assert-True (-not $process.HasExited) `
                'New valid lease launcher abandoned the old worker lock before handoff.'
            $lockStream.Dispose()
            $lockStream = $null
            Assert-True ($process.WaitForExit(6000)) 'Handoff worker did not acquire the released lock.'
            Assert-Equal 0 $process.ExitCode 'Handoff worker failed.'
            Assert-Equal '' ($process.StandardOutput.ReadToEnd()) 'Handoff worker emitted stdout.'
            Assert-Equal '' ($process.StandardError.ReadToEnd()) 'Handoff worker emitted stderr.'
            $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
            Assert-Equal 0 $monitor.total 'Handoff worker did not complete a reconciliation cycle.'
        }
        finally {
            if ($null -ne $lockStream) { $lockStream.Dispose() }
            if ($null -ne $process -and -not $process.HasExited) { $process.Kill() }
        }
    }

    Invoke-TestCase 'Monitor worker bounds retries for a permanently disconnected board' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = Join-Path $directory 'settings.json'
        Enable-TestWorkspaceMonitor -StateDirectory $state
        $settings = Get-CodexFinishDefaultSettings
        $settings.hardware.enabled = $true
        $settings.hardware.port = 'COM254'
        $settings.hardware.autoDetect = $false
        $settings.hardware.timeoutMilliseconds = 100
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = (Get-Command powershell.exe).Source
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
            $monitorWorkerScript + '" -StateDirectory "' + $state + '" -ConfigPath "' + $config +
            '" -PollSeconds 1 -EmptyDeliveryRetrySeconds 2'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $null = $process.Start()
        Assert-True ($process.WaitForExit(10000)) 'Disconnected-board worker exceeded its retry watchdog.'
        $watch.Stop()
        Assert-Equal 0 $process.ExitCode 'Disconnected-board worker failed.'
        Assert-True ($watch.ElapsedMilliseconds -ge 1500) `
            'Worker exited after the first failed empty snapshot instead of retrying.'
        Assert-True ($watch.ElapsedMilliseconds -lt 10000) 'Worker retry watchdog did not bound its lifetime.'
        Assert-Equal '' ($process.StandardOutput.ReadToEnd()) 'Disconnected-board worker emitted stdout.'
        Assert-Equal '' ($process.StandardError.ReadToEnd()) 'Disconnected-board worker emitted stderr.'
    }

    Invoke-TestCase 'Project monitor lock contention schedules a durable detached retry' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $project = Join-Path $directory 'retry-project'
        $null = [IO.Directory]::CreateDirectory($state)
        $null = [IO.Directory]::CreateDirectory($project)
        $lockPath = Join-Path $state 'project-monitor.lock'
        $lockStream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        try {
            $update = Update-CodexFinishProjectMonitorState `
                -Event ([pscustomobject]@{ session_id = 'retry-session'; cwd = $project }) `
                -Status running `
                -StateDirectory $state `
                -MonitorLockTimeoutMilliseconds 100
            Assert-True (-not $update.Updated) 'Contended project monitor unexpectedly acquired the lock.'
            Assert-True $update.RetryScheduled 'Contended project monitor did not schedule its detached retry.'
            Assert-True ([IO.File]::Exists($update.DirtyPath)) 'Durable retry marker was not written.'
        }
        finally {
            $lockStream.Dispose()
        }

        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        $monitorPath = Join-Path $state 'project-monitor.json'
        while (
            (
                -not [IO.File]::Exists($monitorPath) -or
                [IO.File]::Exists($update.DirtyPath)
            ) -and
            [DateTime]::UtcNow -lt $deadline
        ) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True ([IO.File]::Exists($monitorPath)) 'Detached retry did not reconcile the monitor state.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'retry-project' $monitor.projects[0].name 'Detached retry wrote the wrong project.'
        Assert-True (-not [IO.File]::Exists($update.DirtyPath)) 'Successful retry did not remove its dirty marker.'
    }

    Invoke-TestCase 'A later monitor update replays a durable dirty event' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $null = [IO.Directory]::CreateDirectory($state)
        $firstProject = Join-Path $directory 'dirty-first'
        $secondProject = Join-Path $directory 'dirty-second'
        $null = [IO.Directory]::CreateDirectory($firstProject)
        $null = [IO.Directory]::CreateDirectory($secondProject)
        $dirtyPath = Join-Path $state ('project-monitor.dirty.' + [Guid]::NewGuid().ToString('N') + '.json')
        $dirty = [ordered]@{
            event = [ordered]@{ session_id = 'dirty-first-session'; cwd = $firstProject }
            status = 'running'
            stateDirectory = $state
            observedUtc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
            dirtyPath = $dirtyPath
        }
        Write-TestFile -Path $dirtyPath -Content (($dirty | ConvertTo-Json -Depth 6) + [Environment]::NewLine)

        $update = Update-CodexFinishProjectMonitorState `
            -Event ([pscustomobject]@{ session_id = 'dirty-second-session'; cwd = $secondProject }) `
            -Status running `
            -StateDirectory $state
        Assert-True $update.Updated 'Live update failed while replaying a dirty event.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 2 $monitor.total 'Durable dirty replay lost the earlier project update.'
        Assert-True (-not [IO.File]::Exists($dirtyPath)) 'Successful durable replay did not remove its marker.'
    }

    Invoke-TestCase 'Stop script writes a session-specific signal' {
        $directory = New-TestDirectory
        $stateDirectory = Join-Path $directory 'state'
        $sessionId = 'session-stop-test'
        Write-TestFile `
            -Path (Join-Path $stateDirectory 'audio-player.json') `
            -Content (([pscustomobject]@{
                sessionId = $sessionId
                pid       = $PID
            } | ConvertTo-Json -Depth 3) + "`r`n")

        & (Join-Path $pluginRoot 'scripts\stop-audio.ps1') -StateDirectory $stateDirectory
        $signalPath = Join-Path $stateDirectory ('audio-stop-' + $sessionId + '.signal')
        Assert-True ([IO.File]::Exists($signalPath)) 'Stop signal should be created.'
        $signal = [IO.File]::ReadAllText($signalPath) | ConvertFrom-Json
        Assert-Equal $sessionId $signal.sessionId 'Stop signal should target the active session.'
    }

    Invoke-TestCase 'Stop script signals every active project session' {
        $directory = New-TestDirectory
        $stateDirectory = Join-Path $directory 'state'
        $sessions = @('project-a-session', 'project-b-session')
        foreach ($sessionId in $sessions) {
            Write-TestFile `
                -Path (Join-Path $stateDirectory ('audio-player-' + $sessionId + '.json')) `
                -Content (([pscustomobject]@{
                    schemaVersion = 2
                    sessionId     = $sessionId
                    pid           = $PID
                    projectPath   = Join-Path $directory $sessionId
                    status        = 'queued'
                } | ConvertTo-Json -Depth 3) + "`r`n")
        }

        & (Join-Path $pluginRoot 'scripts\stop-audio.ps1') -StateDirectory $stateDirectory
        foreach ($sessionId in $sessions) {
            $signalPath = Join-Path $stateDirectory ('audio-stop-' + $sessionId + '.signal')
            Assert-True ([IO.File]::Exists($signalPath)) "Stop signal was not created for $sessionId."
        }
    }

    Invoke-TestCase 'Busy audio player publishes a project-scoped queued session' {
        $directory = New-TestDirectory
        $stateDirectory = Join-Path $directory 'state'
        $projectDirectory = Join-Path $directory 'project-a'
        $audioFile = Join-Path $directory 'fixture.wav'
        $sessionId = 'queued-project-session'
        $null = [IO.Directory]::CreateDirectory($stateDirectory)
        $null = [IO.Directory]::CreateDirectory($projectDirectory)
        Write-TestFile -Path $audioFile -Content 'fixture'

        $lockStream = $null
        $process = $null
        try {
            $lockStream = [IO.File]::Open(
                (Join-Path $stateDirectory 'audio-player.lock'),
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )

            $playerScript = (Join-Path $pluginRoot 'scripts\play-audio.ps1').Replace("'", "''")
            $escapedAudio = $audioFile.Replace("'", "''")
            $escapedState = $stateDirectory.Replace("'", "''")
            $escapedProject = $projectDirectory.Replace("'", "''")
            $command = "& '$playerScript' -AudioFile '$escapedAudio' -StateDirectory '$escapedState' -SessionId '$sessionId' -ProjectName 'project-a' -ProjectPath '$escapedProject' -ProjectKey 'project-key-a'"
            $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = (Get-Command powershell.exe).Source
            $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
                $encodedCommand
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $startInfo
            $null = $process.Start()

            $stateFile = Join-Path $stateDirectory ('audio-player-' + $sessionId + '.json')
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not [IO.File]::Exists($stateFile) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            Assert-True ([IO.File]::Exists($stateFile)) 'Queued session state was not published.'
            $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
            Assert-Equal 2 $state.schemaVersion 'Queued state schema is wrong.'
            Assert-Equal 'queued' $state.status 'Busy player should wait in the queue.'
            Assert-Equal $projectDirectory $state.projectPath 'Queued state should preserve the project path.'

            & (Join-Path $pluginRoot 'scripts\stop-audio.ps1') `
                -StateDirectory $stateDirectory `
                -SessionId $sessionId
            Assert-True ($process.WaitForExit(5000)) 'Queued player did not stop after its signal.'
            Assert-True (-not [IO.File]::Exists($stateFile)) 'Stopped queued state should be removed.'
        }
        finally {
            if ($null -ne $process -and -not $process.HasExited) {
                $process.Kill()
                $null = $process.WaitForExit(5000)
            }
            if ($null -ne $lockStream) {
                $lockStream.Dispose()
            }
        }
    }

    Invoke-TestCase 'Quiet hours handle overnight windows' {
        $settings = Get-CodexFinishDefaultSettings
        $settings.quietHours.enabled = $true
        $settings.quietHours.start = '22:00'
        $settings.quietHours.end = '08:00'

        Assert-True (Test-CodexFinishQuietHours -Settings $settings -Now ([DateTime]'2026-07-30T23:00:00')) '23:00 should be quiet.'
        Assert-True (Test-CodexFinishQuietHours -Settings $settings -Now ([DateTime]'2026-07-30T07:30:00')) '07:30 should be quiet.'
        Assert-True (-not (Test-CodexFinishQuietHours -Settings $settings -Now ([DateTime]'2026-07-30T12:00:00'))) 'Noon should not be quiet.'
    }

    Invoke-TestCase 'Missing MP3 selects TTS fallback without playing audio' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'settings.json'
        $state = Join-Path $directory 'state'
        $settings = Get-CodexFinishDefaultSettings
        $settings.audioFile = Join-Path $directory 'missing.mp3'
        $settings.hardware.enabled = $false
        $null = Write-CodexFinishSettings `
            -Settings $settings `
            -ConfigPath $config `
            -BackupDirectory (Join-Path $directory 'backups')

        $event = New-VSCodeCompleteEvent
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $result = Invoke-CodexFinishNotification `
            -Event $event `
            -ConfigPath $config `
            -StateDirectory $state `
            -CompletionGraceSeconds 0 `
            -SkipAudio `
            -SkipOverlay
        Assert-Equal 'tts' $result.SelectedMode 'Missing song should select TTS.'
        Assert-Equal 'audio-file-missing-or-unsupported' $result.FallbackReason 'Fallback reason is wrong.'
        Assert-True $result.WouldNotify 'Fallback should still notify.'
        Assert-True $result.OverlayWouldNotify 'Missing audio must not suppress the visual completion.'
        Assert-Equal 2000 $result.OverlayDurationMilliseconds 'Notification should report the normalized overlay duration.'
    }

    Invoke-TestCase 'Supported local MP3 selects detached audio mode' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'settings.json'
        $state = Join-Path $directory 'state'
        $audio = Join-Path $directory 'song.mp3'
        Write-TestFile -Path $audio -Content 'fixture'
        $settings = Get-CodexFinishDefaultSettings
        $settings.audioFile = $audio
        $settings.hardware.enabled = $false
        $null = Write-CodexFinishSettings `
            -Settings $settings `
            -ConfigPath $config `
            -BackupDirectory (Join-Path $directory 'backups')

        $event = New-VSCodeCompleteEvent
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $result = Invoke-CodexFinishNotification `
            -Event $event `
            -ConfigPath $config `
            -StateDirectory $state `
            -CompletionGraceSeconds 0 `
            -SkipAudio `
            -SkipOverlay
        Assert-Equal 'audioFile' $result.SelectedMode 'Supported MP3 should select audio mode.'
        Assert-Equal $audio $result.AudioFile 'Resolved audio path is wrong.'
        Assert-True $result.OverlayWouldNotify 'Audio and visual completion should be independently eligible.'
    }

    Invoke-TestCase 'CLI events are suppressed before claiming a turn' {
        $directory = New-TestDirectory
        $event = New-VSCodeCompleteEvent
        $event.client = 'Codex CLI'
        $result = Invoke-CodexFinishNotification `
            -Event $event `
            -ConfigPath (Join-Path $directory 'settings.json') `
            -StateDirectory (Join-Path $directory 'state') `
            -SkipAudio `
            -SkipOverlay
        Assert-Equal 'not-vscode-turn-complete' $result.SuppressedReason 'CLI event should be suppressed.'
        Assert-True (-not $result.Claimed) 'CLI event must not claim a turn.'
    }

    Invoke-TestCase 'Disabled and quiet settings suppress presentation after monitor completion' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'settings.json'
        $state = Join-Path $directory 'state'
        $disabledEvent = New-VSCodeCompleteEvent -TurnId 'disabled-status' -ThreadId 'disabled-session'
        $settings = Get-CodexFinishDefaultSettings
        $settings.enabled = $false
        $settings.hardware.enabled = $false
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config
        $null = Set-TestTurnStopped -Event $disabledEvent -StateDirectory $state

        $disabled = Invoke-CodexFinishNotification `
            -Event $disabledEvent -ConfigPath $config -StateDirectory $state `
            -CompletionGraceSeconds 0 -SkipAudio -SkipOverlay
        Assert-Equal 'disabled' $disabled.SuppressedReason 'Disabled setting should suppress.'
        Assert-True $disabled.Claimed 'Disabled presentation must still settle project state.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'completed' $monitor.projects[0].status 'Disabled presentation left the monitor red.'

        $settings.enabled = $true
        $settings.quietHours.enabled = $true
        $settings.quietHours.start = '00:00'
        $settings.quietHours.end = '23:59'
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config
        $quietEvent = New-VSCodeCompleteEvent -TurnId 'quiet-status' -ThreadId 'quiet-session'
        $null = Set-TestTurnStopped -Event $quietEvent -StateDirectory $state
        $quiet = Invoke-CodexFinishNotification `
            -Event $quietEvent `
            -ConfigPath $config `
            -StateDirectory $state `
            -Now ([DateTime]'2026-07-30T12:00:00') `
            -CompletionGraceSeconds 0 `
            -SkipAudio `
            -SkipOverlay
        Assert-Equal 'quiet-hours' $quiet.SuppressedReason 'Quiet hours should suppress.'
        Assert-True $quiet.Claimed 'Quiet hours must still settle project state.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'completed' $monitor.projects[0].status 'Quiet hours left the monitor red.'
    }

    Invoke-TestCase 'Same thread and turn notify once' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'settings.json'
        $state = Join-Path $directory 'state'
        $settings = Get-CodexFinishDefaultSettings
        $settings.mode = 'beep'
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config
        $event = New-VSCodeCompleteEvent -TurnId 'dedup'
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state

        $first = Invoke-CodexFinishNotification `
            -Event $event -ConfigPath $config -StateDirectory $state -CompletionGraceSeconds 0 -SkipAudio -SkipOverlay
        $second = Invoke-CodexFinishNotification `
            -Event $event -ConfigPath $config -StateDirectory $state -CompletionGraceSeconds 0 -SkipAudio -SkipOverlay
        Assert-True $first.WouldNotify 'First event should notify.'
        Assert-Equal 'duplicate-turn' $second.SuppressedReason 'Second event should be deduplicated.'
    }

    Invoke-TestCase 'Dedup marker I/O failure fails closed' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $event = New-VSCodeCompleteEvent -TurnId 'dedup-io-failure'
        Assert-True (Register-CodexFinishTurn -Event $event -StateDirectory $state) `
            'Dedup fixture could not create its initial marker.'
        $markerPath = @(Get-ChildItem -LiteralPath $state -Filter '*.done' -File)[0].FullName
        [IO.File]::Delete($markerPath)
        $null = [IO.Directory]::CreateDirectory($markerPath)
        Assert-True (-not (Register-CodexFinishTurn -Event $event -StateDirectory $state)) `
            'A marker CreateNew I/O failure was treated as permission to notify.'
    }

    Invoke-TestCase 'Newer same-thread turn supersedes an earlier pending completion' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $first = New-VSCodeCompleteEvent -TurnId 'pending-first'
        $second = New-VSCodeCompleteEvent -TurnId 'pending-second'

        $null = Set-TestTurnStopped -Event $first -StateDirectory $state
        $firstRecord = Register-CodexFinishPendingTurn `
            -Event $first `
            -StateDirectory $state
        $null = Set-TestLifecycleEvent `
            -Event $second `
            -StateDirectory $state `
            -HookEventName 'UserPromptSubmit'
        $null = Set-TestTurnStopped -Event $second -StateDirectory $state
        $secondRecord = Register-CodexFinishPendingTurn `
            -Event $second `
            -StateDirectory $state

        Assert-True $firstRecord.Recorded 'First completion should enter the pending state.'
        Assert-True $secondRecord.Recorded 'Newer completion should replace the pending state.'

        $firstClaim = Confirm-CodexFinishPendingTurn `
            -Event $first `
            -CandidateId $firstRecord.CandidateId `
            -StateDirectory $state
        Assert-True (-not $firstClaim.Claimed) 'Older completion must not claim after a newer turn arrives.'
        Assert-Equal 'superseded-by-newer-candidate' $firstClaim.Reason 'Older completion should be suppressed as stale.'

        $secondClaim = Confirm-CodexFinishPendingTurn `
            -Event $second `
            -CandidateId $secondRecord.CandidateId `
            -StateDirectory $state
        Assert-True $secondClaim.Claimed 'Newest completion should remain eligible.'
    }

    Invoke-TestCase 'Activity between registration and confirmation cancels the candidate' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $completed = New-VSCodeCompleteEvent -TurnId 'pause-complete'
        $null = Set-TestTurnStopped -Event $completed -StateDirectory $state
        $candidate = Register-CodexFinishPendingTurn -Event $completed -StateDirectory $state

        # Even without a deliberate grace wait, activity that lands between
        # registration and confirmation must invalidate the candidate.
        $null = Set-TestLifecycleEvent `
            -Event $completed `
            -StateDirectory $state `
            -HookEventName 'UserPromptSubmit' `
            -TurnId 'pause-resumed'
        $claim = Confirm-CodexFinishPendingTurn `
            -Event $completed `
            -CandidateId $candidate.CandidateId `
            -StateDirectory $state

        Assert-True (-not $claim.Claimed) 'A resumed thread must cancel its previous completion.'
        Assert-Equal 'activity-after-candidate' $claim.Reason 'Resume should be detected by lifecycle revision.'
    }

    Invoke-TestCase 'Delayed old notify is rejected after the next turn already started' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $completed = New-VSCodeCompleteEvent -TurnId 'late-complete'
        $null = Set-TestTurnStopped -Event $completed -StateDirectory $state
        $null = Set-TestLifecycleEvent `
            -Event $completed `
            -StateDirectory $state `
            -HookEventName 'UserPromptSubmit' `
            -TurnId 'late-new-turn'

        $candidate = Register-CodexFinishPendingTurn -Event $completed -StateDirectory $state
        Assert-True (-not $candidate.Recorded) 'Old notify must not register over a running newer turn.'
        Assert-Equal 'root-turn-still-running' $candidate.Reason 'Late notify should see the running root state.'
    }

    Invoke-TestCase 'Repeated callback for the same turn resets the debounce generation' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $event = New-VSCodeCompleteEvent -TurnId 'same-turn-retry'
        $null = Set-TestTurnStopped -Event $event -StateDirectory $state
        $first = Register-CodexFinishPendingTurn -Event $event -StateDirectory $state
        $second = Register-CodexFinishPendingTurn -Event $event -StateDirectory $state

        $oldClaim = Confirm-CodexFinishPendingTurn `
            -Event $event -CandidateId $first.CandidateId -StateDirectory $state
        $newClaim = Confirm-CodexFinishPendingTurn `
            -Event $event -CandidateId $second.CandidateId -StateDirectory $state
        Assert-Equal 'superseded-by-newer-candidate' $oldClaim.Reason 'Old timer must not claim the rewritten candidate.'
        Assert-True $newClaim.Claimed 'The trailing candidate should remain claimable.'
    }

    Invoke-TestCase 'Root notify remains authoritative when reusable subagents have no Stop event' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $event = New-VSCodeCompleteEvent -TurnId 'root-with-child'
        $null = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $null = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'SubagentStart' -AgentId 'child-1'
        $candidate = Register-CodexFinishPendingTurn -Event $event -StateDirectory $state
        $claim = Confirm-CodexFinishPendingTurn `
            -Event $event -CandidateId $candidate.CandidateId -StateDirectory $state
        Assert-True $candidate.Recorded 'The root notify should survive missing Stop/SubagentStop evidence.'
        Assert-True $candidate.AuthoritativeRootNotify 'The same-session notify should be marked as authoritative.'
        Assert-True $claim.Claimed 'A stable root notify should claim after lifecycle revision remains unchanged.'
    }

    Invoke-TestCase 'Mid-turn compaction preserves subagent identities without permanently blocking root notify' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $event = New-VSCodeCompleteEvent -TurnId 'compact-root'
        $null = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'SubagentStart' -AgentId 'compact-child'
        $compact = [pscustomobject] @{
            session_id = $event.'thread-id'; turn_id = $event.'turn-id'; cwd = $event.cwd
            hook_event_name = 'SessionStart'; source = 'compact'; transcript_path = $null
        }
        $updated = Update-CodexFinishLifecycleState -HookEvent $compact -StateDirectory $state
        Assert-True $updated.Updated 'Compact lifecycle update should succeed.'
        Assert-Equal 1 $updated.ActiveSubagents 'Compaction must preserve the reusable child identity.'

        $candidate = Register-CodexFinishPendingTurn -Event $event -StateDirectory $state
        Assert-True $candidate.Recorded 'A stable root notify must not be blocked forever by a reusable child ID.'
        Assert-True $candidate.AuthoritativeRootNotify 'Compacted root state should still recognize the root notify.'
    }

    Invoke-TestCase 'Require mode fails closed when lifecycle hooks are unavailable' {
        $directory = New-TestDirectory
        $event = New-VSCodeCompleteEvent -TurnId 'no-hooks'
        $required = Register-CodexFinishPendingTurn `
            -Event $event -StateDirectory (Join-Path $directory 'required') -LifecycleMode require
        $preferred = Register-CodexFinishPendingTurn `
            -Event $event -StateDirectory (Join-Path $directory 'preferred') -LifecycleMode prefer
        Assert-Equal 'lifecycle-state-missing' $required.Reason 'Require mode must suppress rather than guess.'
        Assert-True $preferred.Recorded 'Prefer mode should retain explicit legacy compatibility.'
    }

    Invoke-TestCase 'Lifecycle hook adapter reads stdin and records a stopped root turn' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state with spaces'
        $event = New-VSCodeCompleteEvent -TurnId 'hook-process'
        $running = Invoke-HookProcess `
            -HookEvent ([pscustomobject] @{
                session_id = $event.'thread-id'; turn_id = $event.'turn-id'; cwd = $event.cwd
                hook_event_name = 'UserPromptSubmit'; transcript_path = $null
            }) `
            -StateDirectory $state
        $stopped = Invoke-HookProcess `
            -HookEvent ([pscustomobject] @{
                session_id = $event.'thread-id'; turn_id = $event.'turn-id'; cwd = $event.cwd
                hook_event_name = 'Stop'; transcript_path = $null; stop_hook_active = $false
            }) `
            -StateDirectory $state

        Assert-Equal 0 $running.ExitCode 'Running Hook should exit zero.'
        Assert-Equal '' $running.StdOut 'UserPromptSubmit must not emit model-visible output.'
        Assert-Equal '' $running.StdErr 'Hook adapter must stay silent on stderr.'
        Assert-Equal '{"continue":true}' $stopped.StdOut 'Stop must return valid non-blocking JSON.'
        $readyMarkerPath = Join-Path $state 'lifecycle-hook-ready.json'
        Assert-True ([IO.File]::Exists($readyMarkerPath)) 'A successful Hook should publish the authorization readiness marker.'
        $readyMarker = [IO.File]::ReadAllText($readyMarkerPath) | ConvertFrom-Json
        Assert-Equal 'Codex Finish Shout lifecycle state guard' $readyMarker.guard 'Readiness marker guard is wrong.'
        Assert-Equal 'lifecycle-v2' $readyMarker.definitionId 'Readiness marker definition is wrong.'
        Assert-Equal 'Stop' $readyMarker.eventName 'Readiness marker should record the latest Hook event.'
        $projectMonitor = [IO.File]::ReadAllText((Join-Path $state 'project-monitor.json')) | ConvertFrom-Json
        Assert-Equal 1 $projectMonitor.total 'Hook should publish one aggregated project.'
        Assert-Equal 'running' $projectMonitor.projects[0].status 'Stop must stay red until the quiet-window candidate is confirmed.'
        $candidate = Register-CodexFinishPendingTurn -Event $event -StateDirectory $state
        $claim = Confirm-CodexFinishPendingTurn `
            -Event $event -CandidateId $candidate.CandidateId -StateDirectory $state
        Assert-True $claim.Claimed 'The Stop process should publish usable lifecycle evidence.'
        $projectMonitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'completed' $projectMonitor.projects[0].status 'Confirmed Stop candidate did not turn the project green.'
    }

    Invoke-TestCase 'Lifecycle hook reads a UTF-8 Chinese project path without corruption' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $projectName = [string]([char]0x9879) + [char]0x76EE + [char]0x8FDB + [char]0x5EA6
        $projectPath = Join-Path $directory $projectName
        $null = [IO.Directory]::CreateDirectory($projectPath)
        $result = Invoke-HookProcess `
            -HookEvent ([pscustomobject]@{
                session_id = 'utf8-session'; turn_id = 'utf8-turn'; cwd = $projectPath
                hook_event_name = 'UserPromptSubmit'; transcript_path = $null
            }) `
            -StateDirectory $state

        Assert-Equal 0 $result.ExitCode 'UTF-8 lifecycle Hook should exit zero.'
        Assert-Equal '' $result.StdErr 'UTF-8 lifecycle Hook should remain silent.'
        $monitor = [IO.File]::ReadAllText((Join-Path $state 'project-monitor.json')) | ConvertFrom-Json
        Assert-Equal $projectName $monitor.projects[0].name 'Chinese project name was corrupted by Hook stdin decoding.'
        Assert-Equal 'running' $monitor.projects[0].status 'Prompt submission should mark the project running.'
    }

    Invoke-TestCase 'SessionEnd cancels pending completion and removes only the ended session' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $project = Join-Path $directory 'session-end-project'
        $null = [IO.Directory]::CreateDirectory($project)
        $first = New-VSCodeCompleteEvent `
            -TurnId 'session-end-first-turn' -ThreadId 'session-end-first' -Cwd $project
        $second = New-VSCodeCompleteEvent `
            -TurnId 'session-end-second-turn' -ThreadId 'session-end-second' -Cwd $project
        $null = Set-TestLifecycleEvent `
            -Event $first -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $null = Set-TestLifecycleEvent `
            -Event $second -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $null = Set-TestTurnStopped -Event $first -StateDirectory $state
        $candidate = Register-CodexFinishPendingTurn -Event $first -StateDirectory $state
        Assert-True $candidate.Recorded 'SessionEnd fixture did not create a pending completion.'

        $endedFirst = Set-TestLifecycleEvent `
            -Event $first -StateDirectory $state -HookEventName 'SessionEnd'
        Assert-Equal 'ended' $endedFirst.RootStatus 'SessionEnd did not publish terminal lifecycle state.'
        Assert-True (-not $endedFirst.ProjectSettling) 'SessionEnd incorrectly created a Stop-only settle candidate.'
        Assert-True $endedFirst.ProjectCandidateInvalidated 'SessionEnd did not cancel the project candidate.'
        $lateClaim = Confirm-CodexFinishPendingTurn `
            -Event $first -CandidateId $candidate.CandidateId -StateDirectory $state
        Assert-True (-not $lateClaim.Claimed) 'Detached completion still claimed after SessionEnd.'
        Assert-Equal 'pending-state-missing' $lateClaim.Reason 'SessionEnd did not remove the thread pending record.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 1 $monitor.total 'Ending one session removed the shared project too early.'
        Assert-Equal 1 @($monitor.projects[0].sessions).Count 'Ended session remained in the aggregate.'

        $endedSecond = Set-TestLifecycleEvent `
            -Event $second -StateDirectory $state -HookEventName 'SessionEnd'
        Assert-True (-not $endedSecond.ProjectSettling) 'Last SessionEnd created a completion candidate.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 0 $monitor.total 'Last SessionEnd did not clear the project.'
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $state -Filter '*.done' -File -ErrorAction SilentlyContinue).Count `
            'SessionEnd created a completion claim marker.'
    }

    Invoke-TestCase 'SessionEnd re-arms a remaining stopped session without duplicate settlement' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = Join-Path $directory 'settings.json'
        $settings = Get-CodexFinishDefaultSettings
        $settings.enabled = $false
        $settings.hardware.enabled = $false
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config
        $project = Join-Path $directory 'session-end-recovery'
        $null = [IO.Directory]::CreateDirectory($project)
        $stoppedEvent = New-VSCodeCompleteEvent `
            -TurnId 'recovery-stopped-turn' -ThreadId 'recovery-stopped-session' -Cwd $project
        $closingEvent = New-VSCodeCompleteEvent `
            -TurnId 'recovery-closing-turn' -ThreadId 'recovery-closing-session' -Cwd $project
        $null = Set-TestLifecycleEvent `
            -Event $stoppedEvent -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $null = Set-TestLifecycleEvent `
            -Event $closingEvent -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $oldObserved = [DateTime]::UtcNow.AddSeconds(-1)
        $null = Set-TestTurnStopped -Event $stoppedEvent -StateDirectory $state

        $ended = Set-TestLifecycleEvent `
            -Event $closingEvent -StateDirectory $state -HookEventName 'SessionEnd'
        Assert-True ($null -ne $ended.RecoverySettlementEvent) `
            'SessionEnd did not re-arm the remaining stopped session.'
        Assert-Equal 'recovery-stopped-session' $ended.RecoverySettlementEvent.session_id `
            'Recovery candidate belongs to the wrong session.'

        $oldWorker = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $stoppedEvent.'thread-id'; turn_id = $stoppedEvent.'turn-id'; cwd = $project
            }) `
            -StateDirectory $state `
            -ConfigPath $config `
            -ObservedUtc $oldObserved.ToString('o')
        Assert-True (-not $oldWorker.Claimed) 'Pre-SessionEnd worker survived project invalidation.'

        $recovered = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent $ended.RecoverySettlementEvent `
            -StateDirectory $state `
            -ConfigPath $config `
            -ObservedUtc ([DateTime]::UtcNow.AddMilliseconds(50).ToString('o'))
        Assert-True $recovered.Claimed "Recovery settlement failed: $($recovered.Reason)"
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'completed' $monitor.projects[0].status `
            'Remaining stopped session stayed red after recovery settlement.'

        $duplicate = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent $ended.RecoverySettlementEvent `
            -StateDirectory $state `
            -ConfigPath $config `
            -ObservedUtc ([DateTime]::UtcNow.AddSeconds(1).ToString('o'))
        Assert-True (-not $duplicate.Claimed) 'Same stopped turn settled twice.'
        Assert-Equal 'duplicate-turn' $duplicate.Reason 'Duplicate settlement used the wrong reason.'
    }

    Invoke-TestCase 'Lease reconciliation durably removes SessionEnd after monitor lock contention' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $project = Join-Path $directory 'session-end-contended'
        $null = [IO.Directory]::CreateDirectory($project)
        Enable-TestWorkspaceMonitor -StateDirectory $state
        Write-TestWorkspaceLease -StateDirectory $state -WorkspacePaths @($project)
        $event = New-VSCodeCompleteEvent `
            -TurnId 'session-end-contended-turn' -ThreadId 'session-end-contended' -Cwd $project
        $null = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $monitorLock = [IO.File]::Open(
            (Join-Path $state 'project-monitor.lock'),
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        try {
            $ended = Update-CodexFinishLifecycleState `
                -HookEvent ([pscustomobject]@{
                    session_id = $event.'thread-id'; cwd = $project
                    hook_event_name = 'SessionEnd'; reason = 'other'
                }) `
                -StateDirectory $state `
                -LockTimeoutMilliseconds 100 `
                -SkipDirtyReplay
            Assert-True $ended.Updated 'Contended SessionEnd did not persist lifecycle state.'
            Assert-True (-not $ended.ProjectMonitorUpdated) `
                'Contended SessionEnd unexpectedly acquired the monitor lock.'
        }
        finally {
            $monitorLock.Dispose()
        }

        $sync = Sync-CodexFinishProjectMonitorWithWorkspaceLeases -StateDirectory $state
        Assert-Equal 0 $sync.State.total 'Worker reconciliation left ended session in the live snapshot.'
        Assert-Equal 0 $sync.HistoryState.total 'Worker reconciliation left ended session in private history.'
    }

    Invoke-TestCase 'SessionEnd schedules durable removal when lease monitoring is disabled' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $project = Join-Path $directory 'session-end-retry'
        $null = [IO.Directory]::CreateDirectory($project)
        $event = New-VSCodeCompleteEvent `
            -TurnId 'session-end-retry-turn' -ThreadId 'session-end-retry' -Cwd $project
        $null = Set-TestLifecycleEvent `
            -Event $event -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $monitorLock = [IO.File]::Open(
            (Join-Path $state 'project-monitor.lock'),
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        try {
            $ended = Update-CodexFinishLifecycleState `
                -HookEvent ([pscustomobject]@{
                    session_id = $event.'thread-id'; cwd = $project
                    hook_event_name = 'SessionEnd'; reason = 'other'
                }) `
                -StateDirectory $state `
                -LockTimeoutMilliseconds 100 `
                -SkipDirtyReplay
            Assert-True $ended.ProjectMonitorRemovalRetryScheduled `
                'SessionEnd did not schedule a monitor removal retry.'
        }
        finally {
            $monitorLock.Dispose()
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        do {
            $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
            if ($monitor.total -eq 0) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert-Equal 0 $monitor.total 'Detached SessionEnd removal retry left a stale project row.'
    }

    Invoke-TestCase 'Closing a newer session does not re-claim an already completed turn' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $project = Join-Path $directory 'session-end-no-duplicate'
        $null = [IO.Directory]::CreateDirectory($project)
        $completed = New-VSCodeCompleteEvent `
            -TurnId 'already-completed-turn' -ThreadId 'already-completed-session' -Cwd $project
        $newer = New-VSCodeCompleteEvent `
            -TurnId 'newer-closed-turn' -ThreadId 'newer-closed-session' -Cwd $project
        $null = Set-TestLifecycleEvent `
            -Event $completed -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $pending = Register-CodexFinishPendingTurn -Event $completed -StateDirectory $state
        $claim = Confirm-CodexFinishPendingTurn `
            -Event $completed -CandidateId $pending.CandidateId -StateDirectory $state
        Assert-True $claim.Claimed 'Completed-session fixture did not claim.'

        $null = Set-TestLifecycleEvent `
            -Event $newer -StateDirectory $state -HookEventName 'UserPromptSubmit'
        $ended = Set-TestLifecycleEvent `
            -Event $newer -StateDirectory $state -HookEventName 'SessionEnd'
        Assert-True ($null -eq $ended.RecoverySettlementEvent) `
            'SessionEnd unnecessarily re-armed an already completed remaining turn.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 'completed' $monitor.projects[0].status `
            'Closing newer session did not restore the earlier completed state.'

        $duplicate = Invoke-CodexFinishStoppedProjectSettlement `
            -HookEvent ([pscustomobject]@{
                session_id = $completed.'thread-id'; turn_id = $completed.'turn-id'; cwd = $project
            }) `
            -StateDirectory $state `
            -ObservedUtc ([DateTime]::UtcNow.ToString('o'))
        Assert-True (-not $duplicate.Claimed) 'Already completed turn was claimed twice.'
        Assert-Equal 'duplicate-turn' $duplicate.Reason 'Duplicate completed turn used the wrong reason.'
    }

    Invoke-TestCase 'SessionEnd hook is silent and completes within the synchronous limit' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $project = Join-Path $directory 'session-end-hook'
        $null = [IO.Directory]::CreateDirectory($project)
        $start = Invoke-HookProcess `
            -HookEvent ([pscustomobject]@{
                session_id = 'session-end-hook'; turn_id = 'session-end-hook-turn'; cwd = $project
                hook_event_name = 'UserPromptSubmit'; transcript_path = $null
            }) `
            -StateDirectory $state
        Assert-Equal 0 $start.ExitCode 'SessionEnd Hook fixture could not start the session.'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $ended = Invoke-HookProcess `
            -HookEvent ([pscustomobject]@{
                session_id = 'session-end-hook'; cwd = $project
                hook_event_name = 'SessionEnd'; reason = 'other'; transcript_path = $null
            }) `
            -StateDirectory $state
        $watch.Stop()
        Assert-Equal 0 $ended.ExitCode 'SessionEnd Hook should exit zero.'
        Assert-Equal '' $ended.StdOut 'SessionEnd Hook must not emit model-visible output.'
        Assert-Equal '' $ended.StdErr 'SessionEnd Hook must remain silent on stderr.'
        Assert-True ($watch.ElapsedMilliseconds -lt 3000) 'SessionEnd Hook exceeded Codex synchronous timeout.'
        $lifecycle = @(Get-ChildItem -LiteralPath $state -Filter '*.lifecycle.json' -File)[0]
        $record = [IO.File]::ReadAllText($lifecycle.FullName) | ConvertFrom-Json
        Assert-Equal 'ended' $record.rootStatus 'SessionEnd Hook did not persist terminal lifecycle state.'
        Assert-Equal 'other' $record.endReason 'SessionEnd reason was not preserved.'
        $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
        Assert-Equal 0 $monitor.total 'SessionEnd Hook did not clear the last session.'
    }

    Invoke-TestCase 'Stop hook remains non-blocking when lifecycle state cannot be written' {
        $directory = New-TestDirectory
        $invalidState = Join-Path $directory 'not-a-directory'
        Write-TestFile -Path $invalidState -Content 'fixture'
        $result = Invoke-HookProcess `
            -HookEvent ([pscustomobject] @{
                session_id = 'failure-session'; turn_id = 'failure-turn'; cwd = $directory
                hook_event_name = 'Stop'; transcript_path = $null; stop_hook_active = $false
            }) `
            -StateDirectory $invalidState
        Assert-Equal 0 $result.ExitCode 'A telemetry failure must not fail Codex Stop.'
        Assert-Equal '{"continue":true}' $result.StdOut 'Failure path must still satisfy the Stop JSON contract.'
        Assert-Equal '' $result.StdErr 'Failure path must remain silent.'
    }

    Invoke-TestCase 'Lifecycle hook caps waits for a disconnected configured board' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $config = Join-Path $directory 'settings.json'
        $settings = Get-CodexFinishDefaultSettings
        $settings.hardware.port = 'COM254'
        $settings.hardware.autoDetect = $false
        $settings.hardware.timeoutMilliseconds = 5000
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-HookProcess `
            -HookEvent ([pscustomobject]@{
                session_id = 'missing-board'; turn_id = 'missing-board-turn'; cwd = $directory
                hook_event_name = 'UserPromptSubmit'; transcript_path = $null
            }) `
            -StateDirectory $state `
            -ConfigPath $config
        $watch.Stop()

        Assert-Equal 0 $result.ExitCode 'Disconnected board must not fail the Hook.'
        Assert-Equal '' $result.StdErr 'Disconnected board must remain silent.'
        Assert-True ($watch.ElapsedMilliseconds -lt 2500) 'Hook waited too long for a disconnected board.'
    }

    Invoke-TestCase 'Lifecycle hook caps a contended per-thread state lock' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $hookEvent = [pscustomobject]@{
            session_id = 'contended-thread'; turn_id = 'contended-one'; cwd = $directory
            hook_event_name = 'UserPromptSubmit'; transcript_path = $null
        }
        $first = Invoke-HookProcess -HookEvent $hookEvent -StateDirectory $state
        Assert-Equal 0 $first.ExitCode 'Thread-lock fixture Hook failed.'
        $threadLockPath = @(Get-ChildItem -LiteralPath $state -Filter '*.state.lock' -File)[0].FullName
        $lockStream = [IO.File]::Open(
            $threadLockPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        try {
            $hookEvent.turn_id = 'contended-two'
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-HookProcess -HookEvent $hookEvent -StateDirectory $state
            $watch.Stop()
        }
        finally {
            $lockStream.Dispose()
        }

        Assert-Equal 0 $result.ExitCode 'Contended state lock must not fail the Hook.'
        Assert-Equal '' $result.StdErr 'Contended state lock must remain silent.'
        Assert-True ($watch.ElapsedMilliseconds -lt 2000) 'Hook waited too long for a contended thread lock.'
    }

    Invoke-TestCase 'Lifecycle hook skips durable dirty replay while the monitor lock is contended' {
        $directory = New-TestDirectory
        $state = Join-Path $directory 'state'
        $dirtyProject = Join-Path $directory 'dirty-hook-project'
        $null = [IO.Directory]::CreateDirectory($state)
        $null = [IO.Directory]::CreateDirectory($dirtyProject)
        $dirtyPath = Join-Path $state ('project-monitor.dirty.' + [Guid]::NewGuid().ToString('N') + '.json')
        $dirty = [ordered]@{
            event = [ordered]@{ session_id = 'dirty-hook-session'; cwd = $dirtyProject }
            status = 'running'
            stateDirectory = $state
            observedUtc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
            dirtyPath = $dirtyPath
        }
        Write-TestFile -Path $dirtyPath -Content (($dirty | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
        $monitorLockPath = Join-Path $state 'project-monitor.lock'
        $lockStream = [IO.File]::Open(
            $monitorLockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-HookProcess `
                -HookEvent ([pscustomobject]@{
                    session_id = 'live-hook-session'; turn_id = 'live-hook-turn'; cwd = $directory
                    hook_event_name = 'UserPromptSubmit'; transcript_path = $null
                }) `
                -StateDirectory $state
            $watch.Stop()
            Assert-True ([IO.File]::Exists($dirtyPath)) `
                'Synchronous Hook path consumed a dirty marker while the monitor lock was held.'
        }
        finally {
            $lockStream.Dispose()
        }

        Assert-Equal 0 $result.ExitCode 'Dirty replay contention must not fail the Hook.'
        Assert-Equal '' $result.StdErr 'Dirty replay contention must remain silent.'
        Assert-True ($watch.ElapsedMilliseconds -lt 2000) `
            'Hook synchronously waited on the durable dirty replay queue.'
    }

    Invoke-TestCase 'Notify entry point accepts JSON argument and stays silent' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'settings.json'
        $state = Join-Path $directory 'state'
        $settings = Get-CodexFinishDefaultSettings
        $settings.mode = 'beep'
        $null = Write-CodexFinishSettings -Settings $settings -ConfigPath $config
        $json = (New-VSCodeCompleteEvent -TurnId 'process') | ConvertTo-Json -Compress

        $valid = Invoke-NotifyProcess -InputJson $json -ConfigPath $config -StateDirectory $state
        Assert-Equal 0 $valid.ExitCode 'Valid invocation should exit zero.'
        Assert-Equal '' $valid.StdOut 'Normal notifier must not write stdout.'
        Assert-Equal '' $valid.StdErr 'Normal notifier must not write stderr.'

        $invalid = Invoke-NotifyProcess -InputJson '{bad json' -ConfigPath $config -StateDirectory $state
        Assert-Equal 0 $invalid.ExitCode 'Malformed input must exit zero.'
        Assert-Equal '' $invalid.StdOut 'Malformed input must stay silent.'
        Assert-Equal '' $invalid.StdErr 'Malformed input must not write stderr.'
    }

    Invoke-TestCase 'Fresh install writes top-level notify before tables' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'config.toml'
        Write-TestFile -Path $config -Content "model = `"gpt-test`"`r`n`r`n[windows]`r`nsandbox = `"danger-full-access`"`r`n"

        $result = Install-CodexFinishShout `
            -TargetRoot $directory `
            -SourceDirectory (Join-Path $pluginRoot 'scripts')
        $content = [IO.File]::ReadAllText($config)
        Assert-True $result.NotifyConfigured 'Install should configure notify.'
        Assert-Contains $content '# BEGIN codex-finish-shout' 'Managed block is missing.'
        Assert-Contains $content 'notify = [' 'Notify assignment is missing.'
        Assert-True ($content.IndexOf('notify = [') -lt $content.IndexOf('[windows]')) 'Notify must be top-level.'
        Assert-Contains $content 'model = "gpt-test"' 'Existing root setting was lost.'
        Assert-True ([IO.File]::Exists($result.RuntimeScript)) 'Runtime script was not installed.'
        Assert-True ([IO.File]::Exists($result.RuntimeHookScript)) 'Lifecycle Hook script was not installed.'
        Assert-True ([IO.File]::Exists((Join-Path ([IO.Path]::GetDirectoryName($result.RuntimeScript)) 'show-completion-overlay.ps1'))) 'Completion overlay script was not installed.'
        Assert-True $result.HooksConfigured 'Install should configure lifecycle Hooks.'

        $hooksDocument = [IO.File]::ReadAllText($result.HooksFile) | ConvertFrom-Json
        $eventNames = @('SessionStart', 'UserPromptSubmit', 'SubagentStart', 'SubagentStop', 'Stop', 'SessionEnd')
        foreach ($eventName in $eventNames) {
            $eventGroups = @($hooksDocument.hooks.PSObject.Properties[$eventName].Value)
            Assert-Equal 1 $eventGroups.Count "Install should create one $eventName group."
            $handler = @($eventGroups[0].hooks)[0]
            Assert-Equal 'command' $handler.type "$eventName should use a command Hook."
            Assert-Equal $handler.command $handler.commandWindows "$eventName Windows command should be explicit."
            Assert-Contains $handler.command $result.RuntimeHookScript "$eventName command should use the installed absolute script."
            Assert-Contains $handler.command $result.StateDirectory "$eventName command should use the installed state directory."
            Assert-Contains $handler.command '-DefinitionId "lifecycle-v2"' "$eventName command should publish the stable authorization definition."
            Assert-Equal 3 $handler.timeout "$eventName timeout is wrong."
            Assert-True ($null -eq $handler.PSObject.Properties['async']) "$eventName Hook must remain synchronous."
        }
        Assert-Equal 'startup|resume|clear|compact' $hooksDocument.hooks.SessionStart[0].matcher 'SessionStart matcher is wrong.'
        Assert-Equal 'lifecycle-v2' $result.HookDefinitionId 'Install result should expose the Hook definition id.'
        Assert-True ([IO.File]::Exists((Join-Path ([IO.Path]::GetDirectoryName($result.RuntimeScript)) 'monitor-sync-worker.ps1'))) `
            'Monitor synchronization worker was not installed.'
        Assert-True ($null -eq $hooksDocument.hooks.PSObject.Properties['PreToolUse']) 'PreToolUse must not launch PowerShell for every tool.'
    }

    Invoke-TestCase 'Repeated install is idempotent' {
        $directory = New-TestDirectory
        $first = Install-CodexFinishShout -TargetRoot $directory -SourceDirectory (Join-Path $pluginRoot 'scripts')
        $second = Install-CodexFinishShout -TargetRoot $directory -SourceDirectory (Join-Path $pluginRoot 'scripts')
        $content = [IO.File]::ReadAllText((Join-Path $directory 'config.toml'))
        $count = ([regex]::Matches($content, [regex]::Escape('# BEGIN codex-finish-shout'))).Count
        Assert-Equal 1 $count 'Repeated install must leave one managed block.'
        Assert-True $first.NotifyConfigured 'First install failed.'
        Assert-True $second.NotifyConfigured 'Second install failed.'
        Assert-True $second.HooksConfigured 'Repeated install should keep lifecycle Hooks configured.'

        $hooksDocument = [IO.File]::ReadAllText($second.HooksFile) | ConvertFrom-Json
        foreach ($eventName in @('SessionStart', 'UserPromptSubmit', 'SubagentStart', 'SubagentStop', 'Stop', 'SessionEnd')) {
            $ownedHandlers = @(
                foreach ($group in @($hooksDocument.hooks.PSObject.Properties[$eventName].Value)) {
                    foreach ($handler in @($group.hooks)) {
                        if ($handler.command.IndexOf($second.RuntimeHookScript, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            $handler
                        }
                    }
                }
            )
            Assert-Equal 1 $ownedHandlers.Count "Repeated install duplicated the $eventName handler."
        }

        $installState = [IO.File]::ReadAllText(
            (Join-Path $directory 'codex-finish-shout\install-state.json')
        ) | ConvertFrom-Json
        Assert-Equal 3 $installState.schemaVersion 'Install state schema should be version 3.'
        Assert-Equal $second.RuntimeHookScript $installState.lifecycleHookScript 'Install state should record the Hook script.'
        Assert-Equal 'lifecycle-v2' $installState.lifecycleHookDefinitionId 'Install state should record the authorization definition.'
        Assert-True (-not $installState.hooksExistedBefore) 'Fresh install should remember that hooks.json was plugin-created.'
    }

    Invoke-TestCase 'Existing notify is protected without Force' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'config.toml'
        $original = "notify = [`"existing.exe`"]`r`n`r`n[windows]`r`nsandbox = `"read-only`"`r`n"
        Write-TestFile -Path $config -Content $original
        $failed = $false
        try {
            $null = Install-CodexFinishShout `
                -TargetRoot $directory `
                -SourceDirectory (Join-Path $pluginRoot 'scripts')
        }
        catch {
            $failed = $true
        }
        Assert-True $failed 'Installer should refuse to overwrite an unmanaged notify.'
        Assert-Equal $original ([IO.File]::ReadAllText($config)) 'Conflict must not change config.'
    }

    Invoke-TestCase 'Forced install restores previous notify on uninstall' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'config.toml'
        $originalNotify = 'notify = ["existing.exe", "--done"]'
        Write-TestFile -Path $config -Content ($originalNotify + "`r`n`r`n[windows]`r`nsandbox = `"read-only`"`r`n")
        $null = Install-CodexFinishShout `
            -TargetRoot $directory `
            -SourceDirectory (Join-Path $pluginRoot 'scripts') `
            -Force
        $null = Uninstall-CodexFinishShout -TargetRoot $directory
        $content = [IO.File]::ReadAllText($config)
        Assert-Contains $content $originalNotify 'Uninstall should restore the previous notify.'
        Assert-True ($content.IndexOf('# BEGIN codex-finish-shout') -lt 0) 'Managed block should be removed.'
        Assert-Contains $content '[windows]' 'Other config tables must remain.'
    }

    Invoke-TestCase 'Install migrates owned legacy Hook and preserves other Hooks' {
        $directory = New-TestDirectory
        $hooksFile = Join-Path $directory 'hooks.json'
        $legacyScript = Join-Path $directory 'hooks\codex-shout.ps1'
        $document = [pscustomobject] @{
            description = 'mixed hooks'
            hooks = [pscustomobject] @{
                Stop = [object[]] @(
                    [pscustomobject] @{
                        hooks = [object[]] @(
                            [pscustomobject] @{
                                type = 'command'
                                command = 'powershell.exe -File "' + $legacyScript + '"'
                            },
                            [pscustomobject] @{
                                type = 'command'
                                command = 'other-tool.exe'
                            }
                        )
                    }
                )
            }
        }
        Write-TestFile -Path $hooksFile -Content (($document | ConvertTo-Json -Depth 20) + "`r`n")

        $result = Install-CodexFinishShout `
            -TargetRoot $directory `
            -SourceDirectory (Join-Path $pluginRoot 'scripts')
        $updated = [IO.File]::ReadAllText($hooksFile)
        Assert-True $result.LegacyHookRemoved 'Installer should report legacy Hook migration.'
        Assert-True ($updated.IndexOf($legacyScript, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'Legacy handler remains.'
        Assert-Contains $updated 'other-tool.exe' 'Unrelated Hook was not preserved.'
    }

    Invoke-TestCase 'Install and uninstall preserve unrelated lifecycle Hook handlers' {
        $directory = New-TestDirectory
        $hooksFile = Join-Path $directory 'hooks.json'
        $document = [pscustomobject] @{
            description = 'user lifecycle hooks'
            custom      = 'keep-this-metadata'
            hooks       = [pscustomobject] @{
                UserPromptSubmit = [object[]] @(
                    [pscustomobject] @{
                        hooks = [object[]] @(
                            [pscustomobject] @{
                                type    = 'command'
                                command = 'user-prompt-handler.exe'
                            }
                        )
                    }
                )
                Stop = [object[]] @(
                    [pscustomobject] @{
                        hooks = [object[]] @(
                            [pscustomobject] @{
                                type           = 'command'
                                command        = 'user-stop-handler.exe'
                                commandWindows = 'user-stop-handler.exe'
                            }
                        )
                    }
                )
                PreToolUse = [object[]] @(
                    [pscustomobject] @{
                        matcher = 'Bash'
                        hooks   = [object[]] @(
                            [pscustomobject] @{
                                type    = 'command'
                                command = 'user-tool-handler.exe'
                            }
                        )
                    }
                )
            }
        }
        $original = ($document | ConvertTo-Json -Depth 20) + "`r`n"
        Write-TestFile -Path $hooksFile -Content $original

        $install = Install-CodexFinishShout `
            -TargetRoot $directory `
            -SourceDirectory (Join-Path $pluginRoot 'scripts')
        $installedContent = [IO.File]::ReadAllText($hooksFile)
        Assert-Contains $installedContent 'user-prompt-handler.exe' 'Install removed a user prompt handler.'
        Assert-Contains $installedContent 'user-stop-handler.exe' 'Install removed a user Stop handler.'
        Assert-Contains $installedContent 'user-tool-handler.exe' 'Install removed an unrelated PreToolUse handler.'
        $installedHooks = $installedContent | ConvertFrom-Json
        Assert-Contains $installedHooks.hooks.Stop[-1].hooks[0].command $install.RuntimeHookScript 'Managed lifecycle handlers are missing.'

        $uninstall = Uninstall-CodexFinishShout -TargetRoot $directory
        Assert-True $uninstall.HooksChanged 'Uninstall should remove managed lifecycle handlers.'
        Assert-True ([IO.File]::Exists($hooksFile)) 'Uninstall should preserve a user hooks.json.'
        $remaining = [IO.File]::ReadAllText($hooksFile)
        Assert-Contains $remaining 'user-prompt-handler.exe' 'Uninstall removed a user prompt handler.'
        Assert-Contains $remaining 'user-stop-handler.exe' 'Uninstall removed a user Stop handler.'
        Assert-Contains $remaining 'user-tool-handler.exe' 'Uninstall removed an unrelated PreToolUse handler.'
        Assert-Contains $remaining 'keep-this-metadata' 'Uninstall removed user metadata.'
        Assert-True ($remaining.IndexOf($install.RuntimeHookScript, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'Managed handler remains after uninstall.'
    }

    Invoke-TestCase 'Failed install restores the original hooks file' {
        $directory = New-TestDirectory
        $hooksFile = Join-Path $directory 'hooks.json'
        $original = "{`r`n  `"description`": `"keep exact hooks content`",`r`n  `"hooks`": {}`r`n}`r`n"
        Write-TestFile -Path $hooksFile -Content $original

        # A directory at the install-state file path forces the final atomic
        # state write to fail after config.toml and hooks.json were updated.
        $blockedStatePath = Join-Path $directory 'codex-finish-shout\install-state.json'
        $null = [IO.Directory]::CreateDirectory($blockedStatePath)
        $failed = $false
        try {
            $null = Install-CodexFinishShout `
                -TargetRoot $directory `
                -SourceDirectory (Join-Path $pluginRoot 'scripts')
        }
        catch {
            $failed = $true
        }

        Assert-True $failed 'Install should fail when install-state.json is a directory.'
        Assert-Equal $original ([IO.File]::ReadAllText($hooksFile)) 'Failed install must restore hooks.json byte-for-byte.'
        Assert-True (-not [IO.File]::Exists((Join-Path $directory 'config.toml'))) 'Failed install should remove its new config.toml.'
    }

    Invoke-TestCase 'Uninstall preserves a pre-existing empty hooks file' {
        $directory = New-TestDirectory
        $hooksFile = Join-Path $directory 'hooks.json'
        Write-TestFile -Path $hooksFile -Content "{`r`n  `"hooks`": {}`r`n}`r`n"

        $null = Install-CodexFinishShout `
            -TargetRoot $directory `
            -SourceDirectory (Join-Path $pluginRoot 'scripts')
        $null = Install-CodexFinishShout `
            -TargetRoot $directory `
            -SourceDirectory (Join-Path $pluginRoot 'scripts')
        $null = Uninstall-CodexFinishShout -TargetRoot $directory

        Assert-True ([IO.File]::Exists($hooksFile)) 'A pre-existing hooks.json should not be deleted.'
        $remaining = [IO.File]::ReadAllText($hooksFile) | ConvertFrom-Json
        Assert-Equal 0 (@($remaining.hooks.PSObject.Properties).Count) 'Only managed lifecycle handlers should have been removed.'
    }

    Invoke-TestCase 'Install migrates a single legacy handler' {
        $directory = New-TestDirectory
        $hooksFile = Join-Path $directory 'hooks.json'
        $legacyScript = Join-Path $directory 'hooks\codex-shout.ps1'
        $document = [pscustomobject] @{
            description = 'Codex Finish Shout user-level Stop hook'
            hooks = [pscustomobject] @{
                Stop = [object[]] @(
                    [pscustomobject] @{
                        hooks = [object[]] @(
                            [pscustomobject] @{
                                type = 'command'
                                command = 'powershell.exe -File "' + $legacyScript + '"'
                            }
                        )
                    }
                )
            }
        }
        Write-TestFile -Path $hooksFile -Content (($document | ConvertTo-Json -Depth 20) + "`r`n")

        $result = Install-CodexFinishShout `
            -TargetRoot $directory `
            -SourceDirectory (Join-Path $pluginRoot 'scripts')
        Assert-True $result.LegacyHookRemoved 'Single legacy handler should be migrated.'
        Assert-True ([IO.File]::Exists($hooksFile)) 'Lifecycle hooks.json should replace the legacy-only file.'
        $updatedHooks = [IO.File]::ReadAllText($hooksFile)
        Assert-True ($updatedHooks.IndexOf($legacyScript, [StringComparison]::OrdinalIgnoreCase) -lt 0) 'Legacy handler remains.'
        $updatedDocument = $updatedHooks | ConvertFrom-Json
        Assert-Contains $updatedDocument.hooks.Stop[0].hooks[0].command $result.RuntimeHookScript 'Lifecycle handler was not installed.'

        $null = Install-CodexFinishShout `
            -TargetRoot $directory `
            -SourceDirectory (Join-Path $pluginRoot 'scripts')
        $state = [IO.File]::ReadAllText(
            (Join-Path $directory 'codex-finish-shout\install-state.json')
        ) | ConvertFrom-Json
        Assert-True $state.legacyHookRemoved 'Migration history should survive an idempotent reinstall.'
    }

    Invoke-TestCase 'Uninstall removes only managed notify and preserves user data' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'config.toml'
        Write-TestFile -Path $config -Content "model = `"keep-me`"`r`n`r`n[windows]`r`nsandbox = `"read-only`"`r`n"
        $install = Install-CodexFinishShout `
            -TargetRoot $directory `
            -SourceDirectory (Join-Path $pluginRoot 'scripts')
        $settingsPath = $install.SettingsFile
        $uninstall = Uninstall-CodexFinishShout -TargetRoot $directory
        $content = [IO.File]::ReadAllText($config)

        Assert-True $uninstall.ConfigChanged 'Uninstall should change config.'
        Assert-True ($content.IndexOf('notify = [') -lt 0) 'Managed notify remains after uninstall.'
        Assert-Contains $content 'model = "keep-me"' 'User model setting was lost.'
        Assert-Contains $content '[windows]' 'User table was lost.'
        Assert-True ([IO.File]::Exists($settingsPath)) 'User reminder settings should be preserved.'
        Assert-True (-not [IO.File]::Exists($install.RuntimeScript)) 'Runtime script should be removed.'
        Assert-True (-not [IO.File]::Exists($install.HooksFile)) 'Plugin-owned hooks.json should be removed.'
    }

    Invoke-TestCase 'Status distinguishes configuration from observed Hook readiness' {
        $directory = New-TestDirectory
        $install = Install-CodexFinishShout -TargetRoot $directory -SourceDirectory (Join-Path $pluginRoot 'scripts')
        $status = Get-CodexFinishShoutStatus -TargetRoot $directory
        Assert-True $status.ConfigurationReady 'Installed notifier configuration should be complete.'
        Assert-True $status.AuthorizationPending 'A fresh install should wait for Hook authorization evidence.'
        Assert-True (-not $status.Ready) 'Configuration alone must not claim operational readiness.'
        Assert-True $status.NotifyConfigured 'Notify should be configured.'
        Assert-True $status.HooksConfigured 'Lifecycle Hooks should be configured.'
        Assert-Equal 'None' $status.RuntimeParameters 'Runtime must require no parameters.'
        Assert-True (-not $status.LegacyHookPresent) 'Legacy Hook should be absent.'

        $hookResult = Invoke-HookProcess `
            -HookEvent ([pscustomobject] @{
                session_id = 'status-session'; turn_id = 'status-turn'; cwd = $directory
                hook_event_name = 'SessionStart'; source = 'startup'; transcript_path = $null
            }) `
            -StateDirectory $install.StateDirectory
        Assert-Equal 0 $hookResult.ExitCode 'Readiness Hook fixture should succeed.'
        $observedStatus = Get-CodexFinishShoutStatus -TargetRoot $directory
        Assert-True $observedStatus.HookObserved 'Status should observe the trusted Hook marker.'
        Assert-True (-not $observedStatus.AuthorizationPending) 'Observed Hook should clear authorization pending.'
        Assert-True $observedStatus.Ready 'Configured notifier with observed Hook evidence should be ready.'
    }

    Invoke-TestCase 'Status is not ready when one lifecycle Hook is missing' {
        $directory = New-TestDirectory
        $install = Install-CodexFinishShout -TargetRoot $directory -SourceDirectory (Join-Path $pluginRoot 'scripts')
        $hooks = [IO.File]::ReadAllText($install.HooksFile) | ConvertFrom-Json
        $hooks.hooks.PSObject.Properties.Remove('Stop')
        Write-TestFile `
            -Path $install.HooksFile `
            -Content (($hooks | ConvertTo-Json -Depth 30) + "`r`n")

        $status = Get-CodexFinishShoutStatus -TargetRoot $directory
        Assert-True (-not $status.HooksConfigured) 'Missing Stop Hook should make HooksConfigured false.'
        Assert-True (-not $status.Ready) 'Missing lifecycle Hook should make Ready false.'
    }

    Invoke-TestCase 'Configure command writes local audio settings' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'settings.json'
        $audio = Join-Path $directory 'local-song.mp3'
        & $configureScript SetAudio `
            -AudioFile $audio `
            -ConfigPath $config `
            -BackupDirectory (Join-Path $directory 'backups') |
            Out-Null
        $settings = Get-CodexFinishSettings -ConfigPath $config
        Assert-Equal 'audioFile' $settings.mode 'Configure should select audio mode.'
        Assert-Equal $audio $settings.audioFile 'Configure should persist the full local path.'
    }

    Invoke-TestCase 'Configure command writes playback settings' {
        $directory = New-TestDirectory
        $config = Join-Path $directory 'settings.json'
        & $configureScript SetPlayback `
            -PlaybackMode seconds `
            -PlaybackSeconds 45 `
            -PlaybackMaximumSeconds 600 `
            -ConfigPath $config `
            -BackupDirectory (Join-Path $directory 'backups') |
            Out-Null
        $settings = Get-CodexFinishSettings -ConfigPath $config
        Assert-Equal 'seconds' $settings.playback.mode 'Configure should select seconds playback.'
        Assert-Equal 45 $settings.playback.seconds 'Configure should persist playback seconds.'
        Assert-Equal 600 $settings.playback.maximumSeconds 'Configure should persist playback maximum.'
    }
    }
}
finally {
    $fullTestRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
    $fullTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (
        $fullTestRoot.StartsWith($fullTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($fullTestRoot.TrimEnd('\')).StartsWith('codex-finish-shout-notify-tests-')
    ) {
        [IO.Directory]::Delete($fullTestRoot.TrimEnd('\'), $true)
    }
}

Write-Host ''
Write-Host "Passed: $script:Passed"
Write-Host "Failed: $script:Failed"
if ($script:Failed -gt 0) {
    exit 1
}
