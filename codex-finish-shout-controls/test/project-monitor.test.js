const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
    formatProjectMonitorStatusText,
    getProjectMonitorPath,
    normalizeProjectMonitorSnapshot,
    readProjectMonitorState
} = require('../project-monitor-store');

function withTemporaryDirectory(body) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-project-monitor-'));
    try {
        return body(directory);
    } finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
}

function project(overrides = {}) {
    return {
        projectKey: 'project-a',
        name: '项目 A',
        path: 'D:\\work\\project-a',
        status: 'running',
        updatedAtUtc: '2026-08-19T08:10:00.000Z',
        ...overrides
    };
}

test('normalizes the v1 snapshot, counts all projects, and puts running first', () => {
    const state = normalizeProjectMonitorSnapshot(
        {
            schemaVersion: 1,
            projects: [
                project({
                    projectKey: 'done',
                    name: '完成项目',
                    status: 'completed',
                    updatedAtUtc: '2026-08-19T08:30:00.000Z'
                }),
                project({ projectKey: 'older', name: '较早运行', updatedAtUtc: '2026-08-19T08:00:00.000Z' }),
                project({
                    projectKey: 'newer',
                    name: '最近运行',
                    path: undefined,
                    projectPath: 'D:\\work\\newer',
                    message: '正在写测试'
                })
            ]
        },
        'C:\\state\\project-monitor.json'
    );

    assert.equal(state.kind, 'ready');
    assert.equal(state.totalCount, 3);
    assert.equal(state.runningCount, 2);
    assert.equal(state.completedCount, 1);
    assert.deepEqual(state.projects.map((item) => item.projectKey), ['newer', 'older', 'done']);
    assert.equal(state.projects[0].message, '正在写测试');
    assert.equal(state.projects[0].path, 'D:\\work\\newer');
    assert.equal(formatProjectMonitorStatusText(state), '$(pulse) Codex 2运行 · 1完成');
});

test('treats a missing snapshot and a valid empty snapshot as empty states', () => {
    withTemporaryDirectory((directory) => {
        const filePath = getProjectMonitorPath(directory);
        assert.equal(readProjectMonitorState(filePath).kind, 'empty');

        fs.writeFileSync(filePath, '{"schemaVersion":1,"projects":[]}\n', 'utf8');
        const state = readProjectMonitorState(filePath);
        assert.equal(state.kind, 'empty');
        assert.equal(state.totalCount, 0);
        assert.equal(formatProjectMonitorStatusText(state), '$(pulse) Codex 0运行 · 0完成');
    });
});

test('returns an error state for malformed JSON, unsupported schemas, and bad statuses', () => {
    withTemporaryDirectory((directory) => {
        const filePath = getProjectMonitorPath(directory);
        fs.writeFileSync(filePath, '{broken', 'utf8');
        assert.equal(readProjectMonitorState(filePath).kind, 'error');

        fs.writeFileSync(filePath, '{"schemaVersion":2,"projects":[]}\n', 'utf8');
        assert.match(readProjectMonitorState(filePath).error, /Unsupported project monitor schema/);

        fs.writeFileSync(
            filePath,
            JSON.stringify({ schemaVersion: 1, projects: [project({ status: 'queued' })] }),
            'utf8'
        );
        const state = readProjectMonitorState(filePath);
        assert.equal(state.kind, 'error');
        assert.match(state.error, /status must be running or completed/);
        assert.equal(formatProjectMonitorStatusText(state), '$(warning) Codex 监控异常');
    });
});

test('declares the monitor commands and the display-only setting', () => {
    const manifest = JSON.parse(
        fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8')
    );
    const commands = new Set(manifest.contributes.commands.map((entry) => entry.command));
    const setting =
        manifest.contributes.configuration.properties[
            'codexFinishShout.projectMonitor.showStatusBar'
        ];

    assert.match(manifest.version, /^\d+\.\d+\.\d+$/);
    assert.equal(commands.has('codexFinishShout.openProjectMonitor'), true);
    assert.equal(commands.has('codexFinishShout.toggleProjectMonitorStatusBar'), true);
    assert.equal(setting.type, 'boolean');
    assert.equal(setting.default, true);
    const translations = require('../package.nls.json');
    assert.match(translations[setting.description.slice(1, -1)], /Monitoring continues when hidden/);
    for (const [key, values] of [
        ['codexFinishShout.language', ['auto', 'zh', 'en']],
        ['codexFinishShout.projectMonitor.theme', ['auto', 'dark', 'light']]
    ]) {
        const appearanceSetting = manifest.contributes.configuration.properties[key];
        assert.deepEqual(appearanceSetting.enum, values);
        assert.equal(appearanceSetting.default, 'auto');
    }
});

test('formats the project status bar in the selected language', () => {
    assert.equal(formatProjectMonitorStatusText({ kind: 'ready', runningCount: 2, completedCount: 1 }, 'en'), '$(pulse) Codex 2 running · 1 done');
    assert.equal(formatProjectMonitorStatusText({ kind: 'error' }, 'en'), '$(warning) Codex monitor error');
});

test('preserves independent agent states, identity and task titles across a project completion', () => {
    const sessions = [{
        threadHash: 'thread-a', sessionId: 'main-a', sessionTitle: '登录优化',
        agents: [
            { agentId: 'child-done', role: 'subagent', taskTitle: '补充登录测试', status: 'stopped' },
            { agentId: 'main-a', role: 'main', taskTitle: '修复登录超时', status: 'stopped' },
            { agentId: 'child-running', role: 'subagent', taskTitle: '检查认证接口', status: 'running' }
        ]
    }, {
        threadHash: 'thread-b', sessionId: 'main-b',
        agents: [{ agentId: 'main-b', taskTitle: '优化首页', status: 'running' }]
    }];
    const normalize = (status) => normalizeProjectMonitorSnapshot({ schemaVersion: 1, projects: [project({ sessions, status })] }).projects[0];
    const running = normalize('running');
    const completed = normalize('completed');
    assert.equal(running.agentCount, 4);
    assert.equal(running.runningAgentCount, 2);
    assert.deepEqual(running.sessions[0].agents.map((agent) => agent.agentId), ['main-a', 'child-running', 'child-done']);
    assert.equal(running.sessions[0].agents[0].status, 'stopped');
    assert.equal(running.sessions[0].agents[1].parentAgentId, 'main-a');
    assert.equal(running.sessions[0].agents[2].taskTitle, '补充登录测试');
    assert.deepEqual(completed.sessions, running.sessions);
    assert.equal(new Set(running.sessions.flatMap((session) => session.agents.map((agent) => agent.shortId))).size, 4);
});

test('old session snapshots expose unknown execution state without borrowing project completion', () => {
    const state = normalizeProjectMonitorSnapshot({ schemaVersion: 1, projects: [project({ status: 'completed', sessions: [
        { threadHash: 'legacy-hash', status: 'completed', updatedAtUtc: '2026-08-19T08:30:00.000Z' }
    ] })] });
    const agent = state.projects[0].sessions[0].agents[0];
    assert.equal(agent.role, 'main');
    assert.equal(agent.status, 'unknown');
    assert.equal(agent.taskTitle, '');
    assert.equal(state.projects[0].runningAgentCount, 0);
});

test('malformed optional agent rows do not hide valid projects or create duplicate identities', () => {
    const state = normalizeProjectMonitorSnapshot({ schemaVersion: 1, projects: [project({ sessions: [
        null, {}, { sessionId: 'one', agents: [null, {},
            { agentId: 'one', status: 'invalid', updatedAtUtc: 'bad-date' },
            { agentId: 'one', status: 'running' }
        ] }, { sessionId: 'one' }
    ] })] });
    assert.equal(state.kind, 'ready');
    assert.equal(state.projects[0].sessions.length, 1);
    assert.equal(state.projects[0].agentCount, 1);
    assert.equal(state.projects[0].sessions[0].agents[0].status, 'unknown');
    assert.equal(state.projects[0].sessions[0].agents[0].updatedAtUtc, '');
});
