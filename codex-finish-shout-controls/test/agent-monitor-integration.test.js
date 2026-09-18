const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');
const { readProjectMonitorState } = require('../project-monitor-store');

test('real lifecycle Hooks publish independent agent tasks consumed by the Controls store', { skip: process.platform !== 'win32' }, () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-agent-integration-'));
    try {
        const transcript = path.join(directory, 'root.jsonl');
        const timestamp = new Date().toISOString();
        const record = (type, payload) => ({ timestamp, type, payload });
        fs.writeFileSync(transcript, [
            record('session_meta', { id: 'root-integration', cwd: directory, source: 'vscode' }),
            record('turn_context', { turn_id: 'turn-integration' }),
            record('response_item', { type: 'function_call', name: 'spawn_agent', namespace: 'collaboration', call_id: 'call-child',
                arguments: JSON.stringify({ task_name: 'auth_audit', message: '排查认证接口超时\n不要把完整任务正文复制到总览。' }) }),
            record('event_msg', { type: 'sub_agent_activity', event_id: 'call-child', agent_thread_id: 'child-integration',
                agent_path: '/root/auth_audit', kind: 'started' }),
            record('response_item', { type: 'function_call_output', call_id: 'call-child', output: JSON.stringify({ task_name: '/root/auth_audit' }) })
        ].map((entry) => JSON.stringify(entry)).join('\n') + '\n', 'utf8');
        const literal = (text) => "'" + text.replace(/'/g, "''") + "'";
        const modulePath = path.resolve(__dirname, '../../codex-finish-shout/scripts/CodexFinishShout.psm1');
        const scriptPath = path.join(directory, 'fixture.ps1');
        const script = `$ErrorActionPreference = 'Stop'
Import-Module ${literal(modulePath)} -Force
$directory = ${literal(directory)}
$stateDirectory = Join-Path $directory 'state'
$event = [pscustomobject]@{ session_id = 'root-integration'; turn_id = 'turn-integration'; cwd = $directory; hook_event_name = 'UserPromptSubmit'; prompt = '修复登录超时'; transcript_path = ${literal(transcript)}; agent_id = '' }
foreach ($name in @('UserPromptSubmit', 'SubagentStart', 'Stop', 'SubagentStop')) {
    $event.hook_event_name = $name
    $event.agent_id = if ($name -like 'Subagent*') { 'child-integration' } else { '' }
    $result = Update-CodexFinishLifecycleState -HookEvent $event -StateDirectory $stateDirectory
    if (-not $result.Updated -or -not $result.ProjectMonitorUpdated) { throw 'Lifecycle fixture failed' }
}
`;
        fs.writeFileSync(scriptPath, '\uFEFF' + script, 'utf8');
        const result = spawnSync('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', scriptPath],
            { encoding: 'utf8', timeout: 30000, windowsHide: true });
        assert.equal(result.error, undefined);
        assert.equal(result.status, 0, result.stderr);
        // The fixture represents one turn, not PowerShell's variable cold-start
        // latency. Align its transcript clock with the actual child Hook time.
        const recorded = JSON.parse(fs.readFileSync(path.join(directory, 'state', 'project-monitor.json'), 'utf8'));
        const childTime = recorded.projects[0].sessions[0].agents.find(agent => agent.agentId === 'child-integration').startedAtUtc;
        const aligned = fs.readFileSync(transcript, 'utf8').trim().split('\n').map(line => ({ ...JSON.parse(line), timestamp: childTime }));
        fs.writeFileSync(transcript, aligned.map(record => JSON.stringify(record)).join('\n') + '\n');
        const snapshot = readProjectMonitorState(path.join(directory, 'state', 'project-monitor.json'));
        assert.equal(snapshot.kind, 'ready', snapshot.error);
        const project = snapshot.projects[0];
        assert.equal(project.status, 'running', 'Project still waits for its quiet window');
        assert.equal(project.agentCount, 2);
        assert.equal(project.runningAgentCount, 0);
        const [main, child] = project.sessions[0].agents;
        assert.equal(main.taskTitle, '修复登录超时');
        assert.equal(main.status, 'stopped');
        assert.equal(child.taskTitle, '排查认证接口超时');
        assert.equal(child.titleSource, 'transcript');
        assert.equal(child.status, 'stopped');
        assert.equal(child.parentAgentId, main.agentId);

        // A real follow-up can lack a fresh SubagentStart Hook. The child must
        // have its own NEW_TASK/turn evidence before the display says running.
        const assigned = new Date(Date.now() + 1000).toISOString();
        const started = new Date(Date.now() + 1500).toISOString();
        const taskRecord = (type, payload, at = started) => ({ timestamp: at, type, payload });
        const append = (file, entries) => fs.appendFileSync(file, entries.map((entry) => JSON.stringify(entry)).join('\n') + '\n', 'utf8');
        append(transcript, [
            taskRecord('response_item', { type: 'function_call', name: 'followup_task', namespace: 'collaboration', call_id: 'call-followup',
                arguments: JSON.stringify({ target: 'auth_audit', message: '验证认证修复结果' }) }, assigned),
            taskRecord('event_msg', { type: 'sub_agent_activity', event_id: 'call-followup', agent_thread_id: 'child-integration',
                agent_path: '/root/auth_audit', kind: 'interacted' }, assigned),
            taskRecord('response_item', { type: 'function_call_output', call_id: 'call-followup', output: '' }, assigned)
        ]);
        const snapshotPath = path.join(directory, 'state', 'project-monitor.json');
        assert.equal(readProjectMonitorState(snapshotPath).projects[0].sessions[0].agents[1].status, 'unknown');
        const childFile = path.join(directory, 'rollout-fixture-child-integration.jsonl');
        append(childFile, [
            taskRecord('session_meta', { id: 'child-integration', parent_thread_id: 'root-integration', agent_path: '/root/auth_audit',
                source: { subagent: { thread_spawn: { parent_thread_id: 'root-integration', agent_path: '/root/auth_audit' } } } }),
            taskRecord('event_msg', { type: 'task_started', turn_id: 'child-turn-two', started_at: Date.parse(started) / 1000 }),
            taskRecord('response_item', { type: 'agent_message', author: '/root', recipient: '/root/auth_audit',
                internal_chat_message_metadata_passthrough: { turn_id: 'child-turn-two' },
                content: [{ type: 'input_text', text: 'Message Type: NEW_TASK\nTask name: /root/auth_audit\nPayload:\n' }] })
        ]);
        const resumed = readProjectMonitorState(snapshotPath).projects[0];
        assert.equal(resumed.runningAgentCount, 1);
        assert.equal(resumed.sessions[0].agents[1].status, 'running');
        assert.equal(resumed.sessions[0].agents[1].taskTitle, '验证认证修复结果');
        const ended = new Date(Date.now() + 2000).toISOString();
        append(childFile, [taskRecord('event_msg', { type: 'task_complete', turn_id: 'child-turn-two',
            started_at: Date.parse(started) / 1000, completed_at: Date.parse(ended) / 1000 }, ended)]);
        const finished = readProjectMonitorState(snapshotPath).projects[0];
        assert.equal(finished.runningAgentCount, 0);
        assert.equal(finished.sessions[0].agents[1].status, 'stopped');
    } finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
});
