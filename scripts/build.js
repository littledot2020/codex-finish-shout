const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const extension = path.join(root, 'codex-finish-shout-controls');
const backend = path.join(root, 'codex-finish-shout');
const manifest = JSON.parse(fs.readFileSync(path.join(extension, 'package.json'), 'utf8'));
function cleanGenerated(relative) {
    const target = path.resolve(extension, relative);
    if (!['backend', 'assets/music'].includes(relative) || !target.startsWith(extension + path.sep)) {
        throw new Error('Refusing to clean outside the generated extension directories');
    }
    fs.rmSync(target, { recursive: true, force: true });
}
function copyTree(source, target) {
    fs.mkdirSync(target, { recursive: true });
    for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
        if (entry.isDirectory()) copyTree(path.join(source, entry.name), path.join(target, entry.name));
        else if (entry.isFile()) fs.copyFileSync(path.join(source, entry.name), path.join(target, entry.name));
        else throw new Error('Unexpected runtime source: ' + entry.name);
    }
}
// Copy only audited runtime sources. Generated directories are ignored by Git.
cleanGenerated('backend');
cleanGenerated('assets/music');
for (const directory of ['scripts', 'config', 'assets']) {
    copyTree(path.join(backend, directory), path.join(extension, 'backend', directory));
}
fs.mkdirSync(path.join(extension, 'backend', '.codex-plugin'), { recursive: true });
fs.writeFileSync(path.join(extension, 'backend', '.codex-plugin', 'plugin.json'),
    JSON.stringify({ name: 'codex-finish-shout', version: manifest.version }, null, 2) + '\n');
copyTree(path.join(backend, 'assets', 'music'), path.join(extension, 'assets', 'music'));
function marketplaceSection(filename) {
    return fs.readFileSync(path.join(root, filename), 'utf8')
        .replace(/^# Codex Finish Shout\r?\n/, '')
        .replace(/^\[English\].*\r?\n/m, '')
        .replace(/^## /gm, '### ')
        .replace(/!\[([^\]]*)\]\((?!https?:|#)([^)]+)\)/g, '![$1](https://raw.githubusercontent.com/littledot2020/codex-finish-shout/main/$2)')
        .replace(/\]\((?!https?:|#)([^)]+)\)/g, ']\(https://github.com/littledot2020/codex-finish-shout/blob/main/$1)');
}
fs.writeFileSync(path.join(extension, 'README.md'), '# Codex Finish Shout\n\n[English](#english) | [简体中文](#简体中文)\n\n## English\n' +
    marketplaceSection('README.md') + '\n## 简体中文\n' + marketplaceSection('README.zh-CN.md'));
fs.copyFileSync(path.join(root, 'CHANGELOG.md'), path.join(extension, 'CHANGELOG.md'));
fs.copyFileSync(path.join(root, 'docs', 'PRIVACY.md'), path.join(extension, 'PRIVACY.md'));
console.log(`Assembled ${manifest.version}: backend, player and three offline music cues.`);
