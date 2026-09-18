const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
    filterStatesForWorkspace,
    isActiveState,
    projectMatchesWorkspace,
    readPlaybackStates,
    sortPlaybackStates
} = require('../state-store');

function withTemporaryDirectory(body) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-finish-shout-controls-'));
    try {
        return body(directory);
    } finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
}

function writeJson(filePath, value) {
    fs.writeFileSync(filePath, `${JSON.stringify(value)}\n`, 'utf8');
}

test('discovers legacy and per-session state files without duplicates', () => {
    withTemporaryDirectory((directory) => {
        writeJson(path.join(directory, 'audio-player.json'), {
            sessionId: 'shared',
            pid: 10,
            schemaVersion: 1
        });
        writeJson(path.join(directory, 'audio-player-shared.json'), {
            sessionId: 'shared',
            pid: 11,
            schemaVersion: 2
        });
        writeJson(path.join(directory, 'audio-player-other.json'), {
            sessionId: 'other',
            pid: 12,
            schemaVersion: 2
        });
        writeJson(path.join(directory, 'unrelated.json'), { sessionId: 'ignored', pid: 13 });
        fs.writeFileSync(path.join(directory, 'audio-player-broken.json'), '{broken', 'utf8');

        const states = readPlaybackStates(directory);
        assert.equal(states.length, 2);
        assert.equal(states.find((state) => state.sessionId === 'shared').pid, 11);
        assert.equal(states.find((state) => state.sessionId === 'other').pid, 12);
    });
});

test('matches one project, nested folders, and multi-root workspaces', () => {
    withTemporaryDirectory((directory) => {
        const projectA = path.join(directory, 'project-a');
        const projectASubfolder = path.join(projectA, 'packages', 'web');
        const projectB = path.join(directory, 'project-b');
        const projectC = path.join(directory, 'project-c');
        const states = [
            { sessionId: 'a', projectPath: projectA },
            { sessionId: 'b', projectPath: projectB },
            { sessionId: 'c', projectPath: projectC },
            { sessionId: 'legacy' }
        ];

        assert.equal(projectMatchesWorkspace(projectA, projectASubfolder), true);
        assert.deepEqual(
            filterStatesForWorkspace(states, [projectASubfolder, projectB]).map(
                (state) => state.sessionId
            ),
            ['a', 'b', 'legacy']
        );
        assert.equal(filterStatesForWorkspace(states, []).length, 4);
    });
});

test('keeps live queued sessions active and sorts playing before queued', () => {
    const now = Date.parse('2026-08-01T10:00:00.000Z');
    const queued = {
        sessionId: 'queued',
        pid: 101,
        status: 'queued',
        startedUtc: '2026-08-01T09:00:00.000Z'
    };
    const playing = {
        sessionId: 'playing',
        pid: 102,
        status: 'playing',
        playbackStartedUtc: '2026-08-01T09:59:30.000Z',
        maximumPlaybackSeconds: 60
    };

    assert.equal(isActiveState(queued, (pid) => pid === 101, now), true);
    assert.equal(isActiveState(playing, (pid) => pid === 102, now), true);
    assert.deepEqual(
        sortPlaybackStates([queued, playing]).map((state) => state.sessionId),
        ['playing', 'queued']
    );
});
