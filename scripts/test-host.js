const path = require('node:path');
const { runTests } = require('@vscode/test-electron');
require('./build');
const root = path.resolve(__dirname, '..');
const version = process.argv[2] || 'stable';
const options = {
    version,
    timeout: 120000,
    extensionDevelopmentPath: path.join(root, 'codex-finish-shout-controls'),
    extensionTestsPath: path.join(__dirname, 'extension-host-test.js'),
    extensionTestsEnv: { CODEX_FINISH_SHOUT_DEV_ROOT: path.join(root, '.dev', 'host-' + version), ELECTRON_RUN_AS_NODE: undefined },
    launchArgs: ['--disable-extensions', '--disable-workspace-trust', '--skip-welcome', '--skip-release-notes',
        '--user-data-dir=' + path.join(root, '.dev', 'vscode-' + version), '--extensions-dir=' + path.join(root, '.dev', 'extensions-' + version)]
};
if (process.env.CODEX_TEST_EXECUTABLE) options.vscodeExecutablePath = process.env.CODEX_TEST_EXECUTABLE;
runTests(options).catch(error => { console.error(error.message); process.exitCode = 1; });
