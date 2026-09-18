const assert = require('node:assert/strict');
const Module = require('node:module');
const test = require('node:test');

const vscodeMock = {
    ConfigurationTarget: {
        Global: 'global',
        Workspace: 'workspace',
        WorkspaceFolder: 'workspace-folder'
    },
    workspace: {
        getConfiguration() {
            throw new Error('A configuration must be supplied directly in these tests.');
        }
    }
};

const originalLoad = Module._load;
Module._load = function loadWithVscodeMock(request, parent, isMain) {
    if (request === 'vscode') {
        return vscodeMock;
    }
    return originalLoad.call(this, request, parent, isMain);
};

let configurationHelpers;
try {
    configurationHelpers = require('../extension');
} finally {
    Module._load = originalLoad;
}

const {
    isLegacyInvalidStateDirectory,
    repairLegacyStateDirectorySettings,
    selectStateDirectorySetting
} = configurationHelpers;

test('recognizes only the exact legacy state directory sentinel', () => {
    assert.equal(isLegacyInvalidStateDirectory('Codex Finish Shout Controls'), true);
    assert.equal(isLegacyInvalidStateDirectory(' Codex Finish Shout Controls '), false);
    assert.equal(isLegacyInvalidStateDirectory('codex finish shout controls'), false);
});

test('ignores a legacy value while preserving a valid lower-precedence path', () => {
    const selected = selectStateDirectorySetting(
        {
            workspaceFolderValue: 'Codex Finish Shout Controls',
            workspaceValue: 'C:\\valid-state',
            globalValue: 'D:\\other-state',
            defaultValue: ''
        },
        'Codex Finish Shout Controls'
    );

    assert.equal(selected, 'C:\\valid-state');
    assert.equal(
        selectStateDirectorySetting(undefined, 'E:\\custom-state'),
        'E:\\custom-state'
    );
});

test('clears the legacy value only from the explicit scopes that contain it', async () => {
    const updates = [];
    const configuration = {
        inspect() {
            return {
                globalValue: 'Codex Finish Shout Controls',
                workspaceValue: 'C:\\valid-state',
                workspaceFolderValue: 'Codex Finish Shout Controls'
            };
        },
        async update(key, value, target) {
            updates.push({ key, value, target });
        }
    };

    const repaired = await repairLegacyStateDirectorySettings(configuration);

    assert.deepEqual(repaired, ['globalValue', 'workspaceFolderValue']);
    assert.deepEqual(updates, [
        { key: 'stateDirectory', value: undefined, target: 'global' },
        { key: 'stateDirectory', value: undefined, target: 'workspace-folder' }
    ]);
});

test('does not update configuration when every explicit path is valid', async () => {
    const configuration = {
        inspect() {
            return {
                globalValue: 'C:\\global-state',
                workspaceValue: 'C:\\workspace-state'
            };
        },
        async update() {
            assert.fail('Valid settings must not be changed.');
        }
    };

    assert.deepEqual(await repairLegacyStateDirectorySettings(configuration), []);
});
