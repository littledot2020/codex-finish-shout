const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Module = require('node:module');
const test = require('node:test');
const { resolveAppearance, resolveLanguage, isAppearanceMessage } = require('../appearance');

test('automatic language follows VS Code, explicit choices override it, and invalid values fall back', () => {
    for (const locale of ['zh', 'zh-CN', 'zh-tw', 'zh_Hans']) assert.equal(resolveLanguage('auto', locale), 'zh');
    for (const locale of ['en', 'en-US', 'de', 'ja']) assert.equal(resolveLanguage('auto', locale), 'en');
    assert.equal(resolveLanguage('en', 'zh-cn'), 'en');
    assert.equal(resolveLanguage('zh', 'en'), 'zh');
    assert.deepEqual(resolveAppearance('unexpected', 'unexpected', 'en-US'), {
        language: 'en', languagePreference: 'auto', theme: 'auto'
    });
    assert.deepEqual(resolveAppearance('zh', 'light', 'en'), {
        language: 'zh', languagePreference: 'zh', theme: 'light'
    });
});

test('appearance messages only accept the exact preferences exposed by the extension', () => {
    for (const languagePreference of ['auto', 'zh', 'en']) {
        for (const theme of ['auto', 'dark', 'light']) assert.equal(isAppearanceMessage({ type: 'setAppearance', languagePreference, theme }), true);
    }
    for (const value of [null, {}, { type: 'other', languagePreference: 'zh', theme: 'dark' },
        { type: 'setAppearance', languagePreference: 'zh' },
        { type: 'setAppearance', languagePreference: '<script>', theme: 'dark' },
        { type: 'setAppearance', languagePreference: 'en', theme: {} }]) {
        assert.equal(isAppearanceMessage(value), false);
    }
});

function createHost(t, options = {}) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-appearance-'));
    t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
    const values = new Map(Object.entries({ stateDirectory: directory, ...options.values }));
    const updates = [];
    const messages = [];
    const errors = [];
    const configuration = {
        get(key, fallback) { return values.has(key) ? values.get(key) : fallback; },
        inspect(key) { return options.scopes?.[key] || {}; },
        async update(key, value, target) {
            if (options.failUpdate) throw new Error('Settings are read-only');
            updates.push({ key, value, target });
            values.set(key, value);
        }
    };
    let receive;
    const panel = {
        title: '', reveal() {}, onDidDispose() {},
        webview: {
            cspSource: 'https://webview.example', html: '',
            onDidReceiveMessage(fn) { receive = fn; },
            postMessage(value) { messages.push(value); return Promise.resolve(true); }
        }
    };
    const vscode = {
        env: { language: options.locale || 'en-US' },
        ConfigurationTarget: { Global: 1, Workspace: 2, WorkspaceFolder: 3 },
        ViewColumn: { One: 1 },
        workspace: { getConfiguration: () => configuration, workspaceFolders: [] },
        window: {
            createWebviewPanel(type, title, column, settings) {
                panel.title = title;
                assert.equal(type, 'codexFinishShout.projectMonitor');
                assert.equal(settings.enableScripts, true);
                assert.deepEqual(settings.localResourceRoots, []);
                return panel;
            },
            showErrorMessage(message) { errors.push(message); }
        }
    };
    const extensionPath = require.resolve('../extension');
    const originalLoad = Module._load;
    delete require.cache[extensionPath];
    let extension;
    try {
        Module._load = function(request, parent, isMain) {
            return request === 'vscode' ? vscode : originalLoad.call(this, request, parent, isMain);
        };
        extension = require('../extension');
    } finally { Module._load = originalLoad; }
    t.after(() => { delete require.cache[extensionPath]; });
    return { extension, panel, messages, updates, errors, send: message => receive(message) };
}

test('webview receives resolved appearance and real snapshots; preferences persist at their existing scope', async (t) => {
    const host = createHost(t, { scopes: { language: { workspaceValue: 'auto' } } });
    host.extension.openProjectMonitor();
    assert.equal(host.panel.title, 'Codex Project Overview');
    assert.match(host.panel.webview.html, /lang="en"/);
    await host.send({ type: 'ready' });
    assert.deepEqual(host.messages[0], { type: 'projectMonitorAppearance', appearance: { language: 'en', languagePreference: 'auto', theme: 'auto' }, showToolAI: true });
    assert.equal(host.messages[1].type, 'projectMonitorSnapshot');
    assert.equal(host.messages[1].state.kind, 'empty');
    await host.send({ type: 'setAppearance', languagePreference: 'zh', theme: 'light' });
    assert.deepEqual(host.updates, [
        { key: 'language', value: 'zh', target: 2 }, { key: 'projectMonitor.theme', value: 'light', target: 1 }
    ]);
    assert.equal(host.panel.title, 'Codex 项目总览');
    assert.deepEqual(host.messages.at(-2).appearance, { language: 'zh', languagePreference: 'zh', theme: 'light' });
    assert.equal(host.messages.at(-1).type, 'projectMonitorSnapshot');
    await host.send({ type: 'setAppearance', languagePreference: 'zh', theme: 'light' });
    assert.equal(host.updates.length, 2, 'Unchanged choices do not rewrite settings');
});

test('invalid messages do not mutate settings; failures restore the effective appearance', async (t) => {
    const host = createHost(t, { failUpdate: true, values: { language: 'en', 'projectMonitor.theme': 'dark' } });
    host.extension.openProjectMonitor();
    await host.send({ type: 'setAppearance', languagePreference: 'zh', theme: 'unsafe' });
    assert.equal(host.errors.length, 0);
    assert.equal(host.messages.length, 0);
    await host.send({ type: 'setAppearance', languagePreference: 'zh', theme: 'light' });
    assert.match(host.errors[0], /Unable to save display settings/);
    assert.deepEqual(host.messages.at(-2).appearance, { language: 'en', languagePreference: 'en', theme: 'dark' });
    assert.equal(host.updates.length, 0);
});

test('promotion dismissal persists globally and returns the saved preference to the webview', async (t) => {
    const host = createHost(t);
    host.extension.openProjectMonitor();
    await host.send({ type: 'dismissToolAI' });
    assert.deepEqual(host.updates, [{ key: 'promotion.showToolAI', value: false, target: 1 }]);
    assert.equal(host.messages.at(-1).showToolAI, false);
    const reloaded = createHost(t, { values: { 'promotion.showToolAI': false } });
    reloaded.extension.openProjectMonitor();
    await reloaded.send({ type: 'ready' });
    assert.equal(reloaded.messages[0].showToolAI, false);
    assert.match(reloaded.panel.webview.html, /id="toolai-promotion"[^>]* hidden/);
});

test('failed promotion preference writes restore visibility and report the error', async (t) => {
    const host = createHost(t, { failUpdate: true });
    host.extension.openProjectMonitor();
    await host.send({ type: 'dismissToolAI' });
    assert.equal(host.messages.at(-1).showToolAI, true);
    assert.match(host.errors[0], /Unable to save promotion preference/);
});

test('all localized manifest placeholders have complete English and Chinese translations', () => {
    const manifest = require('../package.json');
    const english = require('../package.nls.json');
    const chinese = require('../package.nls.zh-cn.json');
    for (const [, key] of JSON.stringify(manifest).matchAll(/%([^%]+)%/g)) {
        assert.equal(typeof english[key], 'string', 'Missing English key: ' + key);
        assert.equal(typeof chinese[key], 'string', 'Missing Chinese key: ' + key);
        assert.ok(english[key].trim());
        assert.ok(chinese[key].trim());
        assert.doesNotMatch(chinese[key], /\?{3}/, 'Chinese text must not be corrupted');
    }
});
