require('./build');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..', '.dev', 'codex');
fs.mkdirSync(path.join(root, 'codex-finish-shout-state'), { recursive: true });
const settingsPath = path.join(root, 'codex-finish-shout.json');
if (!fs.existsSync(settingsPath)) fs.copyFileSync(path.resolve(__dirname, '../codex-finish-shout/config/default-settings.json'), settingsPath);
console.log('Development root: ' + root + '\nUse npm run dev:simulate to create a local demo snapshot.');
