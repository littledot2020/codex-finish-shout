// Publish the already-tested release artifact, never rebuild it here.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const manifest = require('../codex-finish-shout-controls/package.json');
const vsce = require.resolve('@vscode/vsce/vsce');
const filename = `${manifest.name}-${manifest.version}-win32-x64.vsix`;
const artifact = path.join(root, 'dist', filename);
try {
    const expected = fs.readFileSync(path.join(root, 'dist', 'SHA256SUMS.txt'), 'utf8').trim().split(/\s+/);
    if (expected[1] !== filename || expected[0] !== crypto.createHash('sha256').update(fs.readFileSync(artifact)).digest('hex')) {
        throw new Error('Release checksum mismatch / 发布文件校验失败');
    }
    const publishers = execFileSync(process.execPath, [vsce, 'ls-publishers'], { encoding: 'utf8' });
    if (!publishers.split(/\r?\n/).some(line => line.trim() === manifest.publisher)) {
        throw new Error(`Marketplace login required / 请先完成本机认证: npx vsce login ${manifest.publisher}`);
    }
    execFileSync(process.execPath, [vsce, 'publish', '--packagePath', artifact, '--pre-release'],
        { cwd: path.join(root, 'codex-finish-shout-controls'), stdio: 'inherit' });
} catch (error) {
    console.error(error.message);
    process.exitCode = 1;
}
