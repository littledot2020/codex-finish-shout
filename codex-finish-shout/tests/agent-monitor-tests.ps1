# Uses the shared isolated fixtures in run-tests.ps1. No transcript is read.

function Send-TestAgentEvent {
    param([string] $Directory, [string] $Name, [string] $SessionId = 'agent-root',
        [string] $AgentId = '', [string] $TurnId = 'agent-turn', [hashtable] $Fields = @{})
    $event = [ordered]@{
        session_id = $SessionId; agent_id = $AgentId; turn_id = $TurnId
        cwd = $Directory; hook_event_name = $Name
    }
    foreach ($key in $Fields.Keys) { $event[$key] = $Fields[$key] }
    $result = Update-CodexFinishLifecycleState -HookEvent ([pscustomobject]$event) -StateDirectory (Join-Path $Directory 'state')
    Assert-True $result.Updated ('Agent Hook failed: ' + $result.Reason)
    Assert-True $result.ProjectMonitorUpdated ('Agent aggregate failed: ' + $result.ProjectMonitorReason)
    return $result.ProjectMonitorState
}

Invoke-TestCase 'Agent monitor keeps parallel children and root task identity separate' {
    $directory = New-TestDirectory
    $rootTranscript = Join-Path $directory 'root.jsonl'
    $childTranscript = Join-Path $directory 'child.jsonl'
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -Fields @{
        prompt = "<environment_context>`nprivate environment`n</environment_context>`n# 修复登录失败`n完整细节不保存"
        transcript_path = $rootTranscript
    }
    $monitor = Send-TestAgentEvent -Directory $directory -Name SubagentStart -AgentId child-a -Fields @{
        agent_type = 'worker'; transcript_path = $childTranscript
    }
    $monitor = Send-TestAgentEvent -Directory $directory -Name SubagentStart -AgentId child-b -Fields @{
        task_title = '检查登录接口'; agent_type = 'explorer'
    }
    $session = $monitor.projects[0].sessions[0]
    Assert-Equal 'agent-root' $session.sessionId 'Raw session identity missing.'
    Assert-Equal $rootTranscript $session.transcriptPath 'Child Hook replaced the root transcript.'
    Assert-Equal 3 @($session.agents).Count 'Parallel agents were collapsed.'
    $root = @($session.agents | Where-Object { $_.role -ceq 'main' })[0]
    $first = @($session.agents | Where-Object { $_.agentId -ceq 'child-a' })[0]
    $second = @($session.agents | Where-Object { $_.agentId -ceq 'child-b' })[0]
    Assert-Equal '修复登录失败' $root.taskTitle 'Prompt environment wrapper was used as title.'
    Assert-Equal 'prompt' $root.titleSource 'Root title provenance missing.'
    Assert-Equal '' $first.taskTitle 'Unknown child task inherited the root prompt.'
    Assert-Equal 'agent-root' $first.parentAgentId 'Parent identity was lost.'
    Assert-Equal $childTranscript $first.transcriptPath 'Observed child transcript was lost.'
    Assert-Equal '检查登录接口' $second.taskTitle 'Explicit child title was lost.'
    Assert-Equal 'explicit' $second.titleSource 'Explicit title provenance missing.'
    $raw = [IO.File]::ReadAllText((Join-Path $directory 'state/project-monitor.json'))
    Assert-True (-not $raw.Contains('完整细节不保存')) 'Full prompt was persisted.'
}

Invoke-TestCase 'Agent stop history remains independent of project settlement and child start' {
    $directory = New-TestDirectory
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -Fields @{ prompt = 'main task' }
    $monitor = Send-TestAgentEvent -Directory $directory -Name SubagentStart -AgentId child-a
    $monitor = Send-TestAgentEvent -Directory $directory -Name Stop
    $monitor = Send-TestAgentEvent -Directory $directory -Name SubagentStart -AgentId child-b
    $root = @($monitor.projects[0].sessions[0].agents | Where-Object { $_.role -ceq 'main' })[0]
    Assert-Equal 'stopped' $root.status 'Child start resurrected display state of stopped root.'
    $monitor = Send-TestAgentEvent -Directory $directory -Name SubagentStop -AgentId child-a -Fields @{
        agent_transcript_path = (Join-Path $directory 'completed-child.jsonl')
    }
    $agents = @($monitor.projects[0].sessions[0].agents)
    Assert-Equal 3 $agents.Count 'Stopped child disappeared.'
    Assert-Equal 'stopped' @($agents | Where-Object { $_.agentId -ceq 'child-a' })[0].status 'Child stop was not retained.'
    Assert-Equal 'running' @($agents | Where-Object { $_.agentId -ceq 'child-b' })[0].status 'One child stop stopped its sibling.'
    $completed = Update-CodexFinishProjectMonitorState -Event ([pscustomobject]@{ session_id = 'agent-root'; cwd = $directory }) `
        -StateDirectory (Join-Path $directory 'state') -Status completed -CompleteProject
    Assert-True $completed.Updated 'Completion aggregation failed.'
    Assert-Equal 'completed' $completed.State.projects[0].sessions[0].status 'Fixture did not publish completed session.'
    Assert-Equal 'running' @($completed.State.projects[0].sessions[0].agents | Where-Object { $_.agentId -ceq 'child-b' })[0].status `
        'Project completion overwrote individually observed agent status.'
}

Invoke-TestCase 'New prompts refresh root title and safely truncate Unicode' {
    $directory = New-TestDirectory
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -Fields @{ prompt = 'old task' }
    $monitor = Send-TestAgentEvent -Directory $directory -Name Stop
    $emoji = [char]::ConvertFromUtf32(0x1F680)
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -TurnId second-turn -Fields @{ prompt = ($emoji * 100) }
    $root = $monitor.projects[0].sessions[0].agents[0]
    Assert-Equal 'running' $root.status 'New prompt did not resume root agent.'
    Assert-Equal 'second-turn' $root.turnId 'Current turn identity was not updated.'
    Assert-Equal (($emoji * 79) + '…') $root.taskTitle 'Unicode truncation split a surrogate or exceeded 80 characters.'
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -TurnId ''
    Assert-Equal '' $monitor.projects[0].sessions[0].agents[0].turnId 'Missing new turn identity retained the previous task turn.'
    Assert-Equal '' $monitor.projects[0].sessions[0].agents[0].taskTitle 'Missing new title retained an unrelated old task.'
    Assert-Equal '' $monitor.projects[0].sessions[0].agents[0].titleSource 'Empty title retained a stale provenance.'
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -Fields @{
        prompt = "# AGENTS.md instructions for workspace`n<INSTRUCTIONS>Repository instructions</INSTRUCTIONS>"
    }
    Assert-Equal '' $monitor.projects[0].sessions[0].agents[0].taskTitle 'AGENTS context was mistaken for a user task.'
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -Fields @{
        prompt = "<INSTRUCTIONS>Repository instructions</INSTRUCTIONS>`n<permissions_instructions>Host policy</permissions_instructions>`nActual user task"
    }
    Assert-Equal 'Actual user task' $monitor.projects[0].sessions[0].agents[0].taskTitle 'Instruction wrappers leaked into the title.'
}

Invoke-TestCase 'Authoritative same-turn notify stops only its observed root agent' {
    $directory = New-TestDirectory
    $state = Join-Path $directory 'state'
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -Fields @{ prompt = 'notify task' }
    $monitor = Send-TestAgentEvent -Directory $directory -Name SubagentStart -AgentId reusable-child
    $event = New-VSCodeCompleteEvent -ThreadId 'agent-root' -TurnId 'agent-turn' -Cwd $directory
    $candidate = Register-CodexFinishPendingTurn -Event $event -StateDirectory $state -LifecycleMode require
    Assert-True $candidate.Recorded 'Same-turn root notify was rejected.'
    Assert-True $candidate.AuthoritativeRootNotify 'Notify fixture was not authoritative.'
    $claim = Confirm-CodexFinishPendingTurn -Event $event -StateDirectory $state -CandidateId $candidate.CandidateId
    Assert-True $claim.Claimed 'Matching notify did not complete the project.'
    $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
    $agents = @($monitor.projects[0].sessions[0].agents)
    $root = @($agents | Where-Object { $_.role -ceq 'main' })[0]
    Assert-Equal 'stopped' $root.status 'Accepted root notify left its agent executing.'
    Assert-Equal 'notify task' $root.taskTitle 'Accepted root notify erased the task title.'
    Assert-Equal 'running' @($agents | Where-Object { $_.agentId -ceq 'reusable-child' })[0].status `
        'Root notify invented child stop evidence.'
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -TurnId new-turn -Fields @{ prompt = 'new task' }
    $oldCandidate = Register-CodexFinishPendingTurn -Event $event -StateDirectory $state -LifecycleMode require
    Assert-True (-not $oldCandidate.Recorded) 'Old notify was accepted after a newer task started.'
    $monitor = Get-CodexFinishProjectMonitorState -StateDirectory $state
    Assert-Equal 'running' $monitor.projects[0].sessions[0].agents[0].status 'Old notify stopped a new root task.'
    Assert-Equal 'new task' $monitor.projects[0].sessions[0].agents[0].taskTitle 'Old notify replaced a new task title.'
}

Invoke-TestCase 'Compact retains active details and resume marks uncertain execution unknown' {
    $directory = New-TestDirectory
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -Fields @{ prompt = 'root title' }
    $monitor = Send-TestAgentEvent -Directory $directory -Name SubagentStart -AgentId child-a -Fields @{ title = 'child title' }
    $monitor = Send-TestAgentEvent -Directory $directory -Name SessionStart -Fields @{ source = 'compact' }
    Assert-Equal 'running' @($monitor.projects[0].sessions[0].agents | Where-Object { $_.agentId -ceq 'child-a' })[0].status `
        'Compaction erased active child state.'
    $monitor = Send-TestAgentEvent -Directory $directory -Name SessionStart -Fields @{ source = 'resume' }
    Assert-Equal 2 @($monitor.projects[0].sessions[0].agents).Count 'Resume discarded known identities.'
    foreach ($agent in $monitor.projects[0].sessions[0].agents) {
        Assert-Equal 'unknown' $agent.status 'Resume advertised unverified running work.'
    }
    $monitor = Send-TestAgentEvent -Directory $directory -Name SessionEnd
    Assert-Equal 0 $monitor.total 'Ended session remained visible.'
}

Invoke-TestCase 'Legacy lifecycle identities migrate without invented child work' {
    $directory = New-TestDirectory
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -Fields @{ prompt = 'old title' }
    $state = Join-Path $directory 'state'
    $lifecyclePath = @(Get-ChildItem -LiteralPath $state -Filter '*.lifecycle.json')[0].FullName
    $lifecycle = [IO.File]::ReadAllText($lifecyclePath) | ConvertFrom-Json
    $lifecycle.PSObject.Properties.Remove('agentDetails')
    $lifecycle.activeSubagentIds = @('legacy-child')
    $lifecycle.lastEventName = 'SubagentStart'
    Write-TestFile -Path $lifecyclePath -Content ($lifecycle | ConvertTo-Json -Depth 8)
    $monitor = Send-TestAgentEvent -Directory $directory -Name SubagentStop -AgentId another-child
    $agents = $monitor.projects[0].sessions[0].agents
    Assert-Equal 'unknown' @($agents | Where-Object { $_.agentId -ceq 'legacy-child' })[0].status 'Legacy active ID invented live execution.'
    Assert-Equal '' @($agents | Where-Object { $_.agentId -ceq 'legacy-child' })[0].taskTitle 'Legacy child invented a task title.'
    Assert-Equal 'stopped' @($agents | Where-Object { $_.agentId -ceq 'another-child' })[0].status 'Previously unseen stopped child was omitted.'
}

Invoke-TestCase 'Workspace publication and reconciliation retain per-agent details' {
    $directory = New-TestDirectory
    $state = Join-Path $directory 'state'
    Enable-TestWorkspaceMonitor -StateDirectory $state
    Write-TestWorkspaceLease -StateDirectory $state -WorkspacePaths @($directory)
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -Fields @{ prompt = 'workspace title' }
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -SessionId peer-root -Fields @{ prompt = 'peer title' }
    $sync = Sync-CodexFinishProjectMonitorWithWorkspaceLeases -StateDirectory $state
    Assert-True $sync.Updated 'Workspace reconciliation failed.'
    Assert-Equal 2 @($sync.State.projects[0].sessions).Count 'Peer session was dropped.'
    foreach ($session in $sync.State.projects[0].sessions) {
        Assert-Equal 1 @($session.agents).Count 'Reconciliation stripped root detail.'
        Assert-True (-not [string]::IsNullOrWhiteSpace($session.agents[0].taskTitle)) 'Reconciliation stripped task title.'
    }
    $history = [IO.File]::ReadAllText((Join-Path $state 'project-monitor-history.json')) | ConvertFrom-Json
    Assert-Equal 1 @($history.projects[0].sessions[0].agents).Count 'History serialization stripped detail.'
    $monitor = Send-TestAgentEvent -Directory $directory -Name SessionEnd -SessionId peer-root
    Assert-Equal 1 @($monitor.projects[0].sessions).Count 'Removing a peer removed the root session.'
    Assert-Equal 'workspace title' $monitor.projects[0].sessions[0].agents[0].taskTitle 'Peer removal stripped surviving title.'
}

Invoke-TestCase 'Agent history bounds retain active work before stopped records' {
    $directory = New-TestDirectory
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit
    $state = Join-Path $directory 'state'
    $lifecyclePath = @(Get-ChildItem -LiteralPath $state -Filter '*.lifecycle.json')[0].FullName
    $lifecycle = [IO.File]::ReadAllText($lifecyclePath) | ConvertFrom-Json
    $details = @($lifecycle.agentDetails)
    for ($index = 0; $index -lt 105; $index++) {
        $details += [pscustomobject]@{
            agentId = ('history-' + $index); role = 'subagent'; status = 'stopped'
            updatedAtUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        }
    }
    $details += [pscustomobject]@{ agentId = 'old-running'; role = 'subagent'; status = 'running'; updatedAtUtc = [DateTime]::UtcNow.AddDays(-1).ToString('o') }
    $lifecycle.agentDetails = $details
    Write-TestFile -Path $lifecyclePath -Content ($lifecycle | ConvertTo-Json -Depth 8)
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit -Fields @{ prompt = 'next task' }
    $agents = @($monitor.projects[0].sessions[0].agents)
    Assert-Equal 100 $agents.Count 'History was not bounded.'
    Assert-Equal 1 @($agents | Where-Object { $_.agentId -ceq 'old-running' }).Count 'History trimming discarded active work first.'
    Assert-Equal 'main' $agents[0].role 'History trimming displaced the root.'

    $lifecycle = [IO.File]::ReadAllText($lifecyclePath) | ConvertFrom-Json
    $details = @($lifecycle.agentDetails | Where-Object { $_.role -ceq 'main' })
    for ($index = 0; $index -lt 105; $index++) {
        $details += [pscustomobject]@{
            agentId = ('active-' + $index); role = 'subagent'; status = 'running'
            updatedAtUtc = [DateTime]::UtcNow.AddDays(-1).ToString('o')
        }
    }
    $details += [pscustomobject]@{
        agentId = 'recent-stopped'; role = 'subagent'; status = 'stopped'
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $lifecycle.agentDetails = $details
    Write-TestFile -Path $lifecyclePath -Content ($lifecycle | ConvertTo-Json -Depth 8)
    $monitor = Send-TestAgentEvent -Directory $directory -Name UserPromptSubmit
    $agents = @($monitor.projects[0].sessions[0].agents)
    Assert-Equal 106 $agents.Count 'History budget hid running agents above the 100-row threshold.'
    Assert-Equal 105 @($agents | Where-Object { $_.role -ceq 'subagent' -and $_.status -ceq 'running' }).Count `
        'Published details omitted observed running children.'
    Assert-Equal 0 @($agents | Where-Object { $_.agentId -ceq 'recent-stopped' }).Count 'History used unavailable quota.'
    $persisted = [IO.File]::ReadAllText($lifecyclePath) | ConvertFrom-Json
    Assert-Equal 106 @($persisted.agentDetails).Count 'Lifecycle persistence dropped active agents.'
}
