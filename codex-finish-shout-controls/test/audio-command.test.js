const assert = require('node:assert/strict');
const fs = require('node:fs');
const Module = require('node:module');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { bundledAudioPath } = require('../audio-settings');

function createAudioHost(t, selections, options = {}) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-audio-command-'));
    const configPath = path.join(directory, 'config.json');
    const initial = { mode: 'audioFile', audioFile: 'C:\\Music\\existing.mp3', volume: 42,
        playback: { mode: 'loop', seconds: 15, maximumSeconds: 600 }, ...options.backend };
    fs.writeFileSync(configPath, JSON.stringify(initial));
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
    const values = new Map(Object.entries({ configPath, stateDirectory: directory, ...options.values }));
    const updates = [];
    const errors = [];
    const information = [];
    const messages = [];
    const quickPicks = [];
    let receive;
    const vscode = {
        env: { language: 'en' },
        ConfigurationTarget: { Global: 1, Workspace: 2 },
        ViewColumn: { One: 1 },
        workspace: {
            workspaceFolders: (options.workspacePaths || []).map((fsPath) => ({ uri: { fsPath } })),
            getConfiguration() {
                return {
                    get: (key, fallback) => values.has(key) ? values.get(key) : fallback,
                    inspect: (key) => options.scopes?.[key] || {},
                    async update(key, value, target) {
                        if (options.failUpdate) throw new Error('Settings are read-only');
                        updates.push({ key, value, target });
                        values.set(key, value);
                    }
                };
            }
        },
        window: {
            createWebviewPanel() {
                return { title: '', onDidDispose() {}, webview: {
                    onDidReceiveMessage(callback) { receive = callback; },
                    postMessage(message) { messages.push(message); return Promise.resolve(true); }
                } };
            },
            async showQuickPick(items) {
                quickPicks.push(items);
                const choose = selections.shift();
                return choose ? choose(items) : undefined;
            },
            async showOpenDialog() { return options.files; },
            showInformationMessage(message) { information.push(message); },
            showErrorMessage(message) { errors.push(message); }
        }
    };
    const entry = require.resolve('../extension');
    delete require.cache[entry];
    const originalLoad = Module._load;
    let extension;
    try {
        Module._load = function(request, parent, isMain) {
            return request === 'vscode' ? vscode : originalLoad.call(this, request, parent, isMain);
        };
        extension = require('../extension');
    } finally { Module._load = originalLoad; }
    t.after(() => delete require.cache[entry]);
    return { extension, updates, errors, information, messages, quickPicks, initial, directory,
        send: (message) => receive(message),
        read: () => JSON.parse(fs.readFileSync(configPath, 'utf8')) };
}

test('monitor music preset button opens the sound picker directly and preserves playback settings', async (t) => {
    const host = createAudioHost(t, [
        (items) => items.find((item) => item.track?.id === 'gentle-rise')
    ], { scopes: { completionSound: { workspaceValue: 'custom' } } });
    host.extension.openProjectMonitor();
    await host.send({ type: 'chooseCompletionMusic' });
    assert.equal(host.quickPicks.length, 1);
    assert.deepEqual(host.quickPicks[0].filter((item) => item.track).map((item) => item.track.id),
        ['soft-chime', 'bright-finish', 'gentle-rise']);
    assert.ok(host.quickPicks[0].some((item) => item.custom));
    assert.deepEqual(host.updates, [
        { key: 'audioFile', value: '', target: 1 },
        { key: 'completionSound', value: 'gentle-rise', target: 2 }
    ]);
    assert.equal(host.read().audioFile, 'builtin:gentle-rise');
    assert.deepEqual(host.read().playback, host.initial.playback);
    assert.equal(host.read().volume, 42);
    assert.deepEqual(host.errors, []);
});

test('monitor playback settings still open the playback picker and reach completion music', async (t) => {
    const host = createAudioHost(t, [
        (items) => items.find((item) => item.music),
        (items) => items.find((item) => item.track?.id === 'soft-chime')
    ]);
    host.extension.openProjectMonitor();
    await host.send({ type: 'configurePlayback' });
    assert.equal(host.quickPicks.length, 2);
    assert.deepEqual(host.quickPicks[0].filter((item) => item.mode).map((item) => item.mode),
        ['once', 'loop', 'seconds']);
    assert.equal(host.read().audioFile, 'builtin:soft-chime');
    assert.deepEqual(host.read().playback, host.initial.playback);
    assert.deepEqual(host.errors, []);
});

test('cancelling the sound picker or file dialog leaves settings unchanged', async (t) => {
    for (const selections of [[], [(items) => items.find((item) => item.custom)]]) {
        const host = createAudioHost(t, selections);
        await host.extension.configureMusic();
        assert.deepEqual(host.read(), host.initial);
        assert.deepEqual(host.updates, []);
    }
});

test('local MP3 selection is saved while unsupported files are rejected', async (t) => {
    const host = createAudioHost(t, [(items) => items.find((item) => item.custom)], { files: [] });
    const filename = path.join(host.directory, 'personal.mp3');
    fs.copyFileSync(bundledAudioPath('soft-chime'), filename);
    // Exercise the same save operation used after the native local-file picker.
    await host.extension.saveCompletionSound('custom', filename);
    assert.equal(host.read().audioFile, filename);
    assert.equal(host.updates.at(-1).value, 'custom');

    const invalid = createAudioHost(t, [(items) => items.find((item) => item.custom)], {
        files: [{ scheme: 'file', fsPath: __filename }]
    });
    await invalid.extension.configureMusic();
    assert.equal(invalid.errors.length, 1);
    assert.deepEqual(invalid.read(), invalid.initial);
    assert.deepEqual(invalid.updates, []);
});

test('a configuration write failure is reported without replacing the backend audio', async (t) => {
    const host = createAudioHost(t, [(items) => items.find((item) => item.track?.id === 'bright-finish')], { failUpdate: true });
    await host.extension.configureMusic();
    assert.match(host.errors[0], /Unable to save completion music/);
    assert.deepEqual(host.read(), host.initial);
});

function writePlaybackState(host, name, values = {}) {
    fs.writeFileSync(path.join(host.directory, `audio-player-${name}.json`), JSON.stringify({
        sessionId: name,
        pid: process.pid,
        status: 'playing',
        startedUtc: new Date().toISOString(),
        ...values
    }));
}

test('overview stops playing and queued audio across workspaces without opening a picker', async (t) => {
    const host = createAudioHost(t, [], { workspacePaths: [path.join(os.tmpdir(), 'workspace-one')] });
    writePlaybackState(host, 'current', { projectPath: path.join(os.tmpdir(), 'workspace-one') });
    writePlaybackState(host, 'other', { projectPath: path.join(os.tmpdir(), 'workspace-two') });
    writePlaybackState(host, 'queued', { projectPath: path.join(os.tmpdir(), 'workspace-three'), status: 'queued',
        startedUtc: new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString() });
    host.extension.openProjectMonitor();

    await host.send({ type: 'stopMusic' });

    for (const sessionId of ['current', 'other', 'queued']) {
        const signal = JSON.parse(fs.readFileSync(path.join(host.directory, `audio-stop-${sessionId}.signal`), 'utf8'));
        assert.equal(signal.sessionId, sessionId);
        assert.ok(Number.isFinite(Date.parse(signal.requestedUtc)));
    }
    assert.deepEqual(host.messages.at(-1), { type: 'musicStopResult', ok: true, count: 3 });
    assert.match(host.information.at(-1), /Sent stop requests to 3 audio sessions/);
    assert.deepEqual(host.quickPicks, []);
    assert.deepEqual(host.errors, []);
    assert.deepEqual(host.read(), host.initial);
});

test('overview reports no music when playback states are absent or expired', async (t) => {
    const host = createAudioHost(t, []);
    host.extension.openProjectMonitor();
    await host.send({ type: 'stopMusic' });
    assert.deepEqual(host.messages.at(-1), { type: 'musicStopResult', ok: true, count: 0 });
    writePlaybackState(host, 'expired', { startedUtc: '2000-01-01T00:00:00Z' });
    writePlaybackState(host, 'invalid-pid', { pid: -1 });
    await host.send({ type: 'stopMusic' });
    assert.deepEqual(host.messages.at(-1), { type: 'musicStopResult', ok: true, count: 0 });
    assert.match(host.information.at(-1), /No Codex completion audio is playing or queued/);
    assert.equal(fs.readdirSync(host.directory).some((name) => name.endsWith('.signal')), false);
    assert.deepEqual(host.errors, []);
});

test('overview reports partial signal write failure and still requests the other sessions to stop', async (t) => {
    const host = createAudioHost(t, []);
    writePlaybackState(host, 'a-blocked');
    writePlaybackState(host, 'b-working');
    fs.mkdirSync(path.join(host.directory, 'audio-stop-a-blocked.signal'));
    host.extension.openProjectMonitor();

    await host.send({ type: 'stopMusic' });

    assert.ok(fs.existsSync(path.join(host.directory, 'audio-stop-b-working.signal')));
    assert.deepEqual(host.messages.at(-1), { type: 'musicStopResult', ok: false, count: 1 });
    assert.match(host.errors.at(-1), /Sent stop requests to 1 audio sessions; 1 failed/);
    assert.deepEqual(host.information, []);
});

test('overview rejects malformed session IDs before creating stop paths', async (t) => {
    const host = createAudioHost(t, []);
    const unsafeIds = ['x/../../outside', 'x\\..\\..\\outside', 'x:stream', 42, 'x'.repeat(121)];
    unsafeIds.forEach((sessionId, index) => writePlaybackState(host, `unsafe-${index}`, { sessionId }));
    host.extension.openProjectMonitor();

    await host.send({ type: 'stopMusic' });

    assert.deepEqual(host.messages.at(-1), { type: 'musicStopResult', ok: false, count: 0 });
    assert.match(host.errors.at(-1), /5 failed: Invalid audio session ID/);
    assert.equal(fs.readdirSync(host.directory).some((name) => name.startsWith('audio-stop-')), false);
    assert.deepEqual(host.information, []);
});
