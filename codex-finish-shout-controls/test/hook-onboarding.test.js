const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
    evaluateHookSetup,
    findBundledCodexExecutable,
    hookDefinitionId,
    hookDescription,
    inspectHookConfiguration,
    inspectReadyMarker,
    requiredHookEvents,
    supportsGraphicalHookReview
} = require('../hook-onboarding');

function hookDocument({ definitionId = hookDefinitionId, omittedEvent } = {}) {
    const hooks = {};
    for (const eventName of requiredHookEvents) {
        if (eventName === omittedEvent) {
            continue;
        }
        hooks[eventName] = [
            {
                hooks: [
                    {
                        type: 'command',
                        command:
                            'powershell.exe -File "C:\\runtime\\codex-finish-shout-hook.ps1" ' +
                            `-StateDirectory "C:\\state" -DefinitionId "${definitionId}"`,
                        timeout: 3
                    }
                ]
            }
        ];
    }
    return { description: hookDescription, hooks };
}

function readyMarker(definitionId = hookDefinitionId) {
    return {
        schemaVersion: 1,
        guard: hookDescription,
        definitionId,
        eventName: 'SessionStart',
        observedUtc: '2026-08-15T01:02:03.000Z'
    };
}

test('requires all managed lifecycle events with the current definition id', () => {
    assert.equal(hookDefinitionId, 'lifecycle-v2');
    assert.equal(requiredHookEvents.includes('SessionEnd'), true);
    assert.deepEqual(inspectHookConfiguration(hookDocument()), {
        installed: true,
        configured: true,
        missingEvents: []
    });

    const missing = inspectHookConfiguration(hookDocument({ omittedEvent: 'Stop' }));
    assert.equal(missing.installed, true);
    assert.equal(missing.configured, false);
    assert.deepEqual(missing.missingEvents, ['Stop']);

    const oldDefinition = inspectHookConfiguration(hookDocument({ definitionId: 'lifecycle-v1' }));
    assert.equal(oldDefinition.installed, true);
    assert.equal(oldDefinition.configured, false);
    assert.deepEqual(oldDefinition.missingEvents, requiredHookEvents);
});

test('accepts only a readiness marker emitted by the current trusted hook definition', () => {
    assert.deepEqual(inspectReadyMarker(readyMarker()), {
        valid: true,
        eventName: 'SessionStart',
        observedUtc: '2026-08-15T01:02:03.000Z'
    });
    assert.equal(inspectReadyMarker(readyMarker('lifecycle-v1')).valid, false);
    assert.equal(inspectReadyMarker({ ...readyMarker(), observedUtc: 'invalid' }).valid, false);
});

test('distinguishes install, upgrade, authorization, and ready states', () => {
    assert.equal(evaluateHookSetup({ hooksContent: null, readyMarkerContent: null }).reason, 'not-installed');
    assert.equal(
        evaluateHookSetup({
            hooksContent: hookDocument({ definitionId: 'lifecycle-v1' }),
            readyMarkerContent: null
        }).reason,
        'upgrade-required'
    );
    assert.equal(
        evaluateHookSetup({ hooksContent: hookDocument(), readyMarkerContent: null }).reason,
        'authorization-required'
    );
    assert.equal(
        evaluateHookSetup({
            hooksContent: hookDocument(),
            readyMarkerContent: readyMarker()
        }).ready,
        true
    );
});

test('detects the graphical Hooks route and bundled Codex executable', (t) => {
    const extensionPath = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-hooks-ui-'));
    t.after(() => fs.rmSync(extensionPath, { recursive: true, force: true }));
    const assetsPath = path.join(extensionPath, 'webview', 'assets');
    const executableDirectory = path.join(extensionPath, 'bin', 'windows-x86_64');
    fs.mkdirSync(assetsPath, { recursive: true });
    fs.mkdirSync(executableDirectory, { recursive: true });
    fs.writeFileSync(path.join(assetsPath, 'hooks-settings-route-test.js'), '');
    const executablePath = path.join(executableDirectory, 'codex.exe');
    fs.writeFileSync(executablePath, '');

    assert.equal(supportsGraphicalHookReview(extensionPath), true);
    assert.equal(findBundledCodexExecutable(extensionPath, 'win32'), executablePath);
});
