const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { enrichAgentTasks, toTaskTitle, readTranscript, findSiblingTranscript } = require('../agent-task-titles');

const stamp = (second = 0) => `2026-09-12T10:00:${String(second).padStart(2, '0')}.000Z`;
const record = (type, payload, second = 0) => ({ type, timestamp: stamp(second), payload });
const meta = (id = 'root-id', more = {}) => record('session_meta', { id, session_id: id, ...more });
const prompt = (message, second = 0, turn = 'turn-1') => record('event_msg', { type: 'user_message', message, turn_id: turn }, second);
const call = (name, args, id = 'call-1', second = 1) => record('response_item', {
    type: 'function_call', name, namespace: 'collaboration', arguments: JSON.stringify(args), call_id: id
}, second);
const output = (value, id = 'call-1', second = 2) => record('response_item', {
    type: 'function_call_output', call_id: id, output: value === '' ? '' : JSON.stringify(value)
}, second);
const activity = (id = 'call-1', kind = 'started', second = 2) => record('event_msg', {
    type: 'sub_agent_activity', event_id: id, agent_thread_id: 'child-id', agent_path: '/root/audit',
    kind, occurred_at_ms: Date.parse(stamp(second))
}, second);
const lines = (records) => records.map((value) => JSON.stringify(value) + '\n').join('');

function fixture(t, records = []) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-agent-titles-'));
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
    const file = path.join(directory, 'rollout-test-root-id.jsonl');
    fs.writeFileSync(file, lines(records));
    return { file, directory };
}

function snapshot(file, overrides = {}) {
    return { projects: [{ status: 'running', sessions: [{ sessionId: 'root-id', sessionTitle: '', transcriptPath: file,
        agents: [
            { agentId: 'root-id', role: 'main', status: 'running', taskTitle: '', titleSource: '', turnId: 'turn-1',
                updatedAtUtc: stamp(50), startedAtUtc: stamp() },
            { agentId: 'child-id', role: 'subagent', status: 'stopped', taskTitle: '', titleSource: '',
                parentAgentId: 'root-id', updatedAtUtc: stamp(50), startedAtUtc: stamp(2), ...overrides }
        ]
    }] }] };
}

test('task summaries exclude instruction wrappers and truncate by Unicode characters', () => {
    assert.equal(toTaskTitle('<environment_context>system metadata</environment_context>\n## 修复登录超时\n详细步骤'), '修复登录超时');
    assert.equal(toTaskTitle('<recommended_plugins>' + 'x'.repeat(40000)), '');
    assert.equal(toTaskTitle('# AGENTS.md instructions\nDo something'), '');
    assert.equal(Array.from(toTaskTitle('😀'.repeat(100))).length, 80);
    assert.equal(toTaskTitle('处理\u202e恶意方向\u0000字符'), '处理恶意方向字符');
});

test('legacy user messages and newer event messages follow the current root turn', (t) => {
    const { file } = fixture(t, [meta(), record('event_msg', { type: 'task_started', turn_id: 'turn-1' }),
        record('response_item', { type: 'message', role: 'user', content: [
            { type: 'input_text', text: '<environment_context>metadata</environment_context>' },
            { type: 'input_text', text: '最初任务\n更多内容' }
        ] })]);
    const state = snapshot(file);
    enrichAgentTasks(state);
    const session = state.projects[0].sessions[0];
    assert.equal(session.agents[0].taskTitle, '最初任务');
    assert.equal(session.sessionTitle, '最初任务');
    fs.appendFileSync(file, lines([record('event_msg', { type: 'task_started', turn_id: 'turn-2' }, 5), prompt('新的用户任务', 5, 'turn-2')]));
    const newerState = snapshot(file);
    enrichAgentTasks(newerState);
    assert.equal(newerState.projects[0].sessions[0].agents[0].taskTitle, '', 'mismatching Hook turn must not borrow a prompt');
    newerState.projects[0].sessions[0].agents[0].turnId = 'turn-2';
    enrichAgentTasks(newerState);
    assert.equal(newerState.projects[0].sessions[0].agents[0].taskTitle, '新的用户任务');
    assert.equal(newerState.projects[0].sessions[0].sessionTitle, '最初任务');
});

test('spawn call activity maps task names to UUIDs; follow-ups replace titles independently of status activity', (t) => {
    const { file } = fixture(t, [meta(), prompt('主任务'), call('spawn_agent', { task_name: 'audit', message: '检查接口' }),
        activity(), output({ task_name: '/root/audit' })]);
    const state = snapshot(file);
    enrichAgentTasks(state);
    const agent = state.projects[0].sessions[0].agents[1];
    assert.equal(agent.taskTitle, '检查接口');
    assert.equal(agent.agentPath, '/root/audit');
    assert.equal(agent.taskName, 'audit');
    assert.equal(agent.status, 'stopped');
    assert.equal(agent.updatedAtUtc, stamp(50));
    fs.appendFileSync(file, lines([call('followup_task', { target: 'audit', message: '补充接口回归测试' }, 'call-2', 5),
        activity('call-2', 'interacted', 6), output('', 'call-2', 6)]));
    enrichAgentTasks(state);
    assert.equal(agent.taskTitle, '补充接口回归测试');
    assert.equal(agent.taskName, 'audit');
    assert.equal(agent.status, 'stopped');
    fs.appendFileSync(file, lines([call('send_message', { target: 'audit', message: '只是一条进度提示' }, 'call-3', 8),
        activity('call-3', 'interacted', 9), output('', 'call-3', 9)]));
    enrichAgentTasks(state);
    assert.equal(agent.taskTitle, '补充接口回归测试');
});

test('activity arriving after output migrates aliases and older events cannot replace a newer assignment', (t) => {
    const { file } = fixture(t, [meta(), call('spawn_agent', { task_name: 'audit', message: 'first' }),
        output({ task_name: '/root/audit' }), activity(),
        call('followup_task', { target: '/root/audit', message: 'latest' }, 'new', 9), output('', 'new', 10),
        call('followup_task', { target: 'child-id', message: 'late arrival of old assignment' }, 'old', 3), output('', 'old', 4)]);
    const state = snapshot(file);
    enrichAgentTasks(state);
    assert.equal(state.projects[0].sessions[0].agents[1].taskTitle, 'latest');
});

test('task_name is an explicit fallback and UUID-returning spawn/send_input variants work', (t) => {
    const { file } = fixture(t, [meta(), call('spawn_agent', { task_name: 'audit' }), output({ agent_id: 'child-id' })]);
    const state = snapshot(file);
    enrichAgentTasks(state);
    const agent = state.projects[0].sessions[0].agents[1];
    assert.equal(agent.taskTitle, 'audit');
    assert.equal(agent.titleSource, 'explicit');
    fs.appendFileSync(file, lines([call('send_input', { id: 'child-id', message: '新的执行任务' }, 'send', 7), output({ submission_id: 'submission' }, 'send', 8)]));
    enrichAgentTasks(state);
    assert.equal(agent.taskTitle, '新的执行任务');
    assert.equal(agent.titleSource, 'transcript');
});

test('failed assignments and source code in exec transcripts are never executed or treated as tasks', (t) => {
    const { file, directory } = fixture(t, [meta(), call('spawn_agent', { task_name: 'audit', message: 'not assigned' }),
        output({ error: 'spawn failed', agent_id: 'child-id' }), record('response_item', {
            type: 'custom_tool_call', name: 'exec', input: "require('fs').writeFileSync('should-not-exist','bad')"
        })]);
    const state = snapshot(file);
    enrichAgentTasks(state);
    assert.equal(state.projects[0].sessions[0].agents[1].taskTitle, '');
    assert.equal(fs.existsSync(path.join(directory, 'should-not-exist')), false);
});

test('only first session_meta.id defines identity and copied root messages never become child tasks', (t) => {
    for (const source of [
        { parent_thread_id: 'root-id', agent_path: '/root/audit' },
        { source: { subagent: { thread_spawn: { parent_thread_id: 'root-id', agent_path: '/root/audit' } } } },
        { source: { subagent: { spawn: { parent_thread_id: 'root-id', agent_path: '/root/audit' } } } }
    ]) {
        const { file } = fixture(t, [meta('child-id', { session_id: 'root-id', ...source }), meta(), prompt('根任务不属于子 agent'),
            record('response_item', { type: 'agent_message', author: '/root', recipient: '/root/audit', content: [
                { type: 'input_text', text: 'Message Type: NEW_TASK\nTask name: /root/audit\nSender: /root\nPayload:\n' },
                { type: 'encrypted_content', encrypted_content: 'opaque' }
            ] }), prompt('即使后面出现根提示词也不借用')]);
        assert.equal(readTranscript(file, 'root-id'), null);
        const child = readTranscript(file, 'child-id');
        assert.equal(child.sessionId, 'child-id');
        assert.equal(child.parentId, 'root-id');
        assert.equal(child.task, null);
        assert.equal(child.sessionTitle, '');
    }
});

test('enrichment repairs a root path overwritten by a sibling child transcript', (t) => {
    const { file, directory } = fixture(t, [meta(), prompt('正确的根任务')]);
    const childFile = path.join(directory, 'rollout-test-child-id.jsonl');
    fs.writeFileSync(childFile, lines([meta('child-id', { session_id: 'root-id', parent_thread_id: 'root-id' }), meta(), prompt('错误的继承标题')]));
    assert.equal(findSiblingTranscript(childFile, 'root-id'), file);
    const state = snapshot(childFile);
    enrichAgentTasks(state);
    assert.equal(state.projects[0].sessions[0].agents[0].taskTitle, '正确的根任务');
});

test('split JSON and split UTF-8 survive bounded incremental reads and append operations', (t) => {
    const { file } = fixture(t);
    const complete = Buffer.from(lines([meta(), prompt('检查中文😀分片')]), 'utf8');
    const split = complete.indexOf(Buffer.from('中')) + 1;
    fs.writeFileSync(file, complete.subarray(0, split));
    assert.equal(readTranscript(file, 'root-id'), null);
    fs.appendFileSync(file, complete.subarray(split));
    assert.equal(readTranscript(file, 'root-id').task.title, '检查中文😀分片');
    const tail = Buffer.from(lines([prompt('分片后新任务', 3)]));
    fs.appendFileSync(file, tail.subarray(0, tail.length - 3));
    assert.equal(readTranscript(file, 'root-id'), null, 'do not expose a potentially stale title while a newer record is incomplete');
    fs.appendFileSync(file, tail.subarray(tail.length - 3));
    assert.equal(readTranscript(file, 'root-id').task.title, '分片后新任务');
});

test('large cold scans retain early active assignments but publish only once caught up', (t) => {
    const records = [meta(), prompt('old prompt'), call('spawn_agent', { task_name: 'audit', message: 'early still-active task' }), activity(), output({ task_name: '/root/audit' })];
    for (let i = 0; i < 12; i += 1) records.push(record('response_item', { type: 'reasoning', encrypted_content: 'x'.repeat(100000) }));
    records.push(prompt('latest prompt', 20));
    const { file } = fixture(t, records);
    let transcript;
    for (let count = 0; count < 4; count += 1) {
        const budget = { remaining: 2 * 1024 * 1024 };
        transcript = readTranscript(file, 'root-id', budget);
        assert.ok(2 * 1024 * 1024 - budget.remaining <= 512 * 1024);
        if (count < 2) assert.equal(transcript, null);
        if (transcript) break;
    }
    assert.equal(transcript.task.title, 'latest prompt');
    assert.equal(transcript.tasks.get('child-id').title, 'early still-active task');
    assert.ok([...transcript.calls.values()].every((entry) => !entry.args && entry.title.length <= 80));
    const noReadBudget = { remaining: 0 };
    assert.equal(readTranscript(file, 'root-id', noReadBudget).task.title, 'latest prompt');
});

test('oversized unrelated lines are skipped and truncate/replace/same-size rewrites reset cached titles', (t) => {
    const { file, directory } = fixture(t, [meta(), record('response_item', { type: 'reasoning', encrypted_content: 'x'.repeat(600000) }), prompt('old task')]);
    assert.equal(readTranscript(file, 'root-id'), null);
    assert.equal(readTranscript(file, 'root-id').task.title, 'old task');
    fs.writeFileSync(file, lines([meta(), prompt('new task')]));
    assert.equal(readTranscript(file, 'root-id').task.title, 'new task');
    const next = path.join(directory, 'replacement.jsonl');
    fs.writeFileSync(next, lines([meta(), prompt('replace!')]));
    fs.rmSync(file);
    fs.renameSync(next, file);
    assert.equal(readTranscript(file, 'root-id').task.title, 'replace!');
    fs.writeFileSync(file, lines([meta(), prompt('rewrite!')]));
    const future = new Date(Date.now() + 2000);
    fs.utimesSync(file, future, future);
    assert.equal(readTranscript(file, 'root-id').task.title, 'rewrite!');
});

test('missing transcripts preserve state and child titles cannot be borrowed from an older execution', (t) => {
    const { file } = fixture(t, [meta(), call('spawn_agent', { task_name: 'audit', message: 'old task' }), activity(), output({ task_name: '/root/audit' })]);
    const state = snapshot(file, { startedAtUtc: stamp(30) });
    enrichAgentTasks(state);
    assert.equal(state.projects[0].sessions[0].agents[1].taskTitle, '');
    fs.rmSync(file);
    const before = JSON.stringify(state);
    enrichAgentTasks(state);
    assert.equal(JSON.stringify(state), before);
    assert.equal(readTranscript('https://example.invalid/session.jsonl', 'root-id'), null);
});

function childTurn(turnId, second, complete = false) {
    const records = [record('event_msg', { type: 'task_started', turn_id: turnId }, second),
        record('response_item', { type: 'agent_message', author: '/root', recipient: '/root/audit',
            content: [{ type: 'input_text', text: 'Message Type: NEW_TASK\nTask name: /root/audit\nSender: /root\nPayload:\n' },
                { type: 'encrypted_content', encrypted_content: 'opaque' }],
            internal_chat_message_metadata_passthrough: { turn_id: turnId }
        }, second + 1)];
    if (complete) records.push(record('event_msg', { type: 'task_complete', turn_id: turnId }, second + 2));
    return records;
}

function childFixture(directory, records) {
    const file = path.join(directory, 'rollout-test-child-id.jsonl');
    fs.writeFileSync(file, lines([meta('child-id', { session_id: 'root-id', parent_thread_id: 'root-id', agent_path: '/root/audit' }), ...records]));
    return file;
}

test('reused child display follows its verified current turn from running to completion', (t) => {
    const { file, directory } = fixture(t, [meta(), call('spawn_agent', { task_name: 'audit', message: 'initial' }), activity(), output({ task_name: '/root/audit' }),
        call('followup_task', { target: 'audit', message: 'reused task' }, 'follow', 10), activity('follow', 'interacted', 10), output('', 'follow', 10)]);
    const childFile = childFixture(directory, [...childTurn('child-turn-1', 2, true), ...childTurn('child-turn-2', 10)]);
    const state = snapshot(file, { status: 'stopped', updatedAtUtc: stamp(4) });
    const project = state.projects[0];
    const root = project.sessions[0].agents[0];
    const agent = project.sessions[0].agents[1];
    enrichAgentTasks(state);
    assert.equal(agent.taskTitle, 'reused task');
    assert.equal(agent.status, 'running');
    assert.equal(agent.statusSource, 'transcript');
    assert.equal(agent.updatedAtUtc, stamp(11));
    assert.equal(project.status, 'running');
    assert.equal(root.status, 'running');
    assert.equal(root.updatedAtUtc, stamp(50));
    fs.appendFileSync(childFile, lines([record('event_msg', { type: 'task_complete', turn_id: 'child-turn-2' }, 20)]));
    enrichAgentTasks(state);
    assert.equal(agent.status, 'stopped');
    assert.equal(agent.updatedAtUtc, stamp(20));
    assert.equal(project.status, 'running', 'display correction never changes the project completion guard');
});

test('older child completion and missing or incomplete child logs cannot retain stopped after reassignment', (t) => {
    const { file, directory } = fixture(t, [meta(), call('spawn_agent', { task_name: 'audit', message: 'initial' }), activity(), output({ task_name: '/root/audit' }),
        call('followup_task', { target: 'audit', message: 'new assignment' }, 'follow', 10), activity('follow', 'interacted', 10), output('', 'follow', 10)]);
    const state = snapshot(file, { status: 'stopped', updatedAtUtc: stamp(4) });
    childFixture(directory, childTurn('old-turn', 2, true));
    enrichAgentTasks(state);
    assert.equal(state.projects[0].sessions[0].agents[1].status, 'unknown');
    fs.rmSync(path.join(directory, 'rollout-test-child-id.jsonl'));
    const missing = snapshot(file, { status: 'stopped', updatedAtUtc: stamp(4) });
    enrichAgentTasks(missing);
    assert.equal(missing.projects[0].sessions[0].agents[1].status, 'unknown');
    const childFile = childFixture(directory, childTurn('new-turn', 10));
    fs.appendFileSync(childFile, '{"type":"event_msg","payload":');
    const incomplete = snapshot(file, { status: 'stopped', updatedAtUtc: stamp(4) });
    enrichAgentTasks(incomplete);
    assert.equal(incomplete.projects[0].sessions[0].agents[1].status, 'unknown');
});

test('ordinary messages and delayed FINAL_ANSWER delivery do not create execution evidence', (t) => {
    const { file, directory } = fixture(t, [meta(), call('spawn_agent', { task_name: 'audit', message: 'initial' }), activity(), output({ task_name: '/root/audit' }),
        call('send_message', { target: 'audit', message: 'context only' }, 'message', 10), activity('message', 'interacted', 10), output('', 'message', 10),
        record('response_item', { type: 'agent_message', author: '/root/audit', recipient: '/root',
            content: [{ type: 'input_text', text: 'Message Type: FINAL_ANSWER\nTask name: /root/audit\nSender: /root/audit\nPayload:\ndelayed result' }] }, 30)]);
    childFixture(directory, childTurn('child-turn', 2, true));
    const state = snapshot(file, { status: 'stopped', updatedAtUtc: stamp(4) });
    enrichAgentTasks(state);
    const agent = state.projects[0].sessions[0].agents[1];
    assert.equal(agent.status, 'stopped');
    assert.equal(agent.updatedAtUtc, stamp(4));
});

test('forked ancestor events and an old turn completion cannot override the child current turn', (t) => {
    const { file, directory } = fixture(t, [meta()]);
    childFixture(directory, [meta(), record('event_msg', { type: 'task_started', turn_id: 'ancestor-turn' }, 1),
        record('event_msg', { type: 'task_complete', turn_id: 'ancestor-turn' }, 2),
        ...childTurn('child-turn', 10), record('event_msg', { type: 'task_complete', turn_id: 'ancestor-turn' }, 40)]);
    const state = snapshot(file, { status: 'unknown', updatedAtUtc: stamp(4) });
    enrichAgentTasks(state);
    assert.equal(state.projects[0].sessions[0].agents[1].status, 'running');
    assert.equal(state.projects[0].sessions[0].agents[1].taskTitle, '', 'status enrichment does not require a title');
    assert.equal(state.projects[0].sessions[0].agents[1].updatedAtUtc, stamp(11));
});

test('newer Hook evidence wins over older child execution and unrelated child identities are rejected', (t) => {
    const { file, directory } = fixture(t, [meta()]);
    childFixture(directory, childTurn('child-turn', 10));
    const state = snapshot(file, { status: 'stopped', updatedAtUtc: stamp(20) });
    enrichAgentTasks(state);
    assert.equal(state.projects[0].sessions[0].agents[1].status, 'stopped');
    assert.equal(state.projects[0].sessions[0].agents[1].updatedAtUtc, stamp(20));
    const wrong = path.join(directory, 'rollout-wrong.jsonl');
    fs.writeFileSync(wrong, lines([meta('wrong-child', { parent_thread_id: 'root-id', agent_path: '/root/audit' }), ...childTurn('wrong-turn', 30)]));
    const mismatched = snapshot(file, { status: 'stopped', updatedAtUtc: stamp(20), transcriptPath: wrong });
    enrichAgentTasks(mismatched);
    assert.equal(mismatched.projects[0].sessions[0].agents[1].status, 'stopped');
});

test('an old child turn completing after a queued follow-up does not complete the new assignment', (t) => {
    const { file, directory } = fixture(t, [meta(), call('spawn_agent', { task_name: 'audit', message: 'initial' }), activity(), output({ task_name: '/root/audit' }),
        call('followup_task', { target: 'audit', message: 'queued next task' }, 'follow', 10), activity('follow', 'interacted', 10), output('', 'follow', 10)]);
    const childFile = childFixture(directory, [...childTurn('old-turn', 2), record('event_msg', { type: 'task_complete', turn_id: 'old-turn' }, 15)]);
    const state = snapshot(file, { status: 'stopped', updatedAtUtc: stamp(4) });
    enrichAgentTasks(state);
    const agent = state.projects[0].sessions[0].agents[1];
    assert.equal(agent.status, 'unknown');
    assert.equal(agent.taskTitle, 'queued next task');
    fs.appendFileSync(childFile, lines(childTurn('new-turn', 20)));
    enrichAgentTasks(state);
    assert.equal(agent.status, 'running');
    assert.equal(agent.updatedAtUtc, stamp(21));
});

test('root Hook prompt titles win even if the turn ID is reused and empty new turns cannot resurrect old labels', (t) => {
    const { file } = fixture(t, [meta(), prompt('older transcript title', 1)]);
    for (const titleSource of ['prompt', 'explicit']) {
        const state = snapshot(file);
        const main = state.projects[0].sessions[0].agents[0];
        Object.assign(main, { taskTitle: 'new Hook title', titleSource, startedAtUtc: stamp(20) });
        enrichAgentTasks(state);
        assert.equal(main.taskTitle, 'new Hook title');
        assert.equal(main.titleSource, titleSource);
        assert.equal(state.projects[0].sessions[0].sessionTitle, 'older transcript title');
    }
    const state = snapshot(file);
    const main = state.projects[0].sessions[0].agents[0];
    Object.assign(main, { taskTitle: '', turnId: '', startedAtUtc: stamp(20) });
    enrichAgentTasks(state);
    assert.equal(main.taskTitle, '');
});

test('more than 64 monitored large transcripts converge without eviction and stop rereading when warm', (t) => {
    const { directory } = fixture(t);
    const padding = record('response_item', { type: 'reasoning', encrypted_content: 'x'.repeat(600 * 1024) });
    const sessions = [];
    for (let index = 0; index < 65; index += 1) {
        const id = `root-${index}`;
        const file = path.join(directory, `rollout-test-${id}.jsonl`);
        fs.writeFileSync(file, lines([meta(id), padding, prompt(`task ${index}`, 10)]));
        sessions.push({ sessionId: id, transcriptPath: file, sessionTitle: '', agents: [
            { agentId: id, role: 'main', taskTitle: '', status: 'running', turnId: 'turn-1' }
        ] });
    }
    // Include both a wrong root path and a child discovered by sibling UUID.
    const childId = 'pinned-child';
    const childFile = path.join(directory, `rollout-test-${childId}.jsonl`);
    fs.writeFileSync(childFile, lines([meta(childId, { parent_thread_id: 'root-0', agent_path: '/root/audit' }),
        padding, ...childTurn('pinned-child-turn', 10)]));
    sessions[0].transcriptPath = childFile;
    sessions[0].agents.push({ agentId: childId, role: 'subagent', parentAgentId: 'root-0', status: 'unknown', taskTitle: '' });
    const freshState = () => ({ projects: [{ sessions: structuredClone(sessions) }] });
    const originalRead = fs.readSync;
    let bytesRead = 0;
    let readCalls = 0;
    t.mock.method(fs, 'readSync', function (...args) {
        const count = originalRead.apply(this, args);
        bytesRead += count;
        readCalls += 1;
        return count;
    });
    let ready = false;
    for (let poll = 0; poll < 45; poll += 1) {
        bytesRead = 0;
        const state = freshState();
        enrichAgentTasks(state);
        assert.ok(bytesRead <= 2 * 1024 * 1024, 'total read budget remains bounded');
        ready = state.projects[0].sessions.every((session) => session.agents[0].taskTitle)
            && state.projects[0].sessions[0].agents[1].status === 'running';
        if (ready) break;
    }
    assert.equal(ready, true, 'all 65 roots plus the child must become ready');
    for (let poll = 0; poll < 3; poll += 1) {
        readCalls = 0;
        const state = freshState();
        enrichAgentTasks(state);
        assert.ok(state.projects[0].sessions.every((session) => session.agents[0].taskTitle));
        assert.equal(state.projects[0].sessions[0].agents[1].status, 'running');
        assert.equal(readCalls, 0, 'warm current references must not be evicted and rescanned');
    }
    enrichAgentTasks({ projects: [] });
    readCalls = 0;
    const reintroduced = { projects: [{ sessions: [structuredClone(sessions[1])] }] };
    enrichAgentTasks(reintroduced);
    assert.ok(readCalls > 0, 'files no longer monitored must have been released');
    assert.equal(reintroduced.projects[0].sessions[0].agents[0].taskTitle, '', 'a released large file starts a fresh bounded scan');
});
