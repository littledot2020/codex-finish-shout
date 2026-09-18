const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vscode = require('vscode');

exports.run = async () => {
    const extension = vscode.extensions.getExtension('littledot2020.codex-finish-shout-controls');
    assert.ok(extension, 'Development extension is discoverable');
    await extension.activate();
    assert.equal(extension.isActive, true);
    const commands = await vscode.commands.getCommands(true);
    for (const name of ['initializeBackend', 'repairBackend', 'checkBackend', 'uninstallBackend', 'openProjectMonitor']) {
        assert.ok(commands.includes('codexFinishShout.' + name), name + ' registered');
    }
    const configuration = vscode.workspace.getConfiguration('codexFinishShout');
    await configuration.update('promotion.showToolAI', false, vscode.ConfigurationTarget.Global);
    assert.equal(vscode.workspace.getConfiguration('codexFinishShout').get('promotion.showToolAI'), false);
    await vscode.commands.executeCommand('codexFinishShout.openProjectMonitor');
    await configuration.update('language', 'zh', vscode.ConfigurationTarget.Global);
    await configuration.update('promotion.showToolAI', true, vscode.ConfigurationTarget.Global);
    assert.equal(vscode.workspace.getConfiguration('codexFinishShout').get('promotion.showToolAI'), true);
    await vscode.commands.executeCommand('codexFinishShout.openProjectMonitor');
    const devRoot = process.env.CODEX_FINISH_SHOUT_DEV_ROOT;
    assert.ok(devRoot, 'Host smoke tests require isolated storage');
    assert.ok(fs.existsSync(path.join(devRoot, 'codex-finish-shout.json')), 'Development configuration is isolated');
    const evidence = { vscode: vscode.version, activated: true, commands: true, localizedOverview: true, promotionPreference: true };
    fs.writeFileSync(path.join(devRoot, 'host-validation.json'), JSON.stringify(evidence, null, 2));
    console.log('EXTENSION_HOST_PASS ' + JSON.stringify(evidence));
};
