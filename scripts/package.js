const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
require('./build');
const root = path.resolve(__dirname, '..');
const manifest = require('../codex-finish-shout-controls/package.json');
const output = path.join(root, 'dist');
fs.mkdirSync(output, { recursive: true });
const filename = `${manifest.name}-${manifest.version}-win32-x64.vsix`;
const vsce = require.resolve('@vscode/vsce/vsce');
execFileSync(process.execPath, [vsce, 'package', '--target', 'win32-x64', '--pre-release', '--out', path.join(output, filename)],
    { cwd: path.join(root, 'codex-finish-shout-controls'), stdio: 'inherit' });
const digest = crypto.createHash('sha256').update(fs.readFileSync(path.join(output, filename))).digest('hex');
fs.writeFileSync(path.join(output, 'SHA256SUMS.txt'), `${digest}  ${filename}\n`);
console.log(`Created dist/${filename}`);
