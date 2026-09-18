const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { runBackendAction } = require('../backend-manager');

test('backend bridge rejects unsupported operations and non-absolute paths', () => {
    assert.throws(() => runBackendAction('ForceDelete', os.tmpdir()), /Unsupported/);
    assert.throws(() => runBackendAction('Install', '../relative'), /absolute/);
});

test('concurrent initialization with Unicode, spaces and shell metacharacters is serialized', { skip: process.platform !== 'win32' }, async (t) => {
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-backend-'));
    t.after(() => {
        const resolved = path.resolve(temporary);
        assert.ok(resolved.startsWith(path.resolve(os.tmpdir()) + path.sep));
        assert.ok(path.basename(resolved).startsWith('codex-backend-'));
        fs.rmSync(resolved, { recursive: true, force: true });
    });
    const target = path.join(temporary, '中文 profile & test');
    const results = await Promise.all([runBackendAction('Install', target), runBackendAction('Install', target)]);
    assert.ok(results.every(result => result.Installed));
    const config = fs.readFileSync(path.join(target, 'config.toml'), 'utf8');
    assert.equal(config.match(/# BEGIN codex-finish-shout/g).length, 1);
    const status = await runBackendAction('Status', target);
    assert.equal(status.ConfigurationReady, true);
    assert.equal(status.AudioExists, true);
    assert.equal(status.Ready, false, 'Installation must not claim user trust');
    await runBackendAction('Uninstall', target);
    assert.equal(fs.existsSync(path.join(target, 'codex-finish-shout.json')), true);
    assert.equal(fs.existsSync(status.RuntimeScript), false);
});
