const path = require('node:path');
const { execFile } = require('node:child_process');

function runBackendAction(action, targetRoot, extensionRoot = __dirname) {
    if (!['Install', 'Uninstall', 'Status'].includes(action)) throw new Error('Unsupported backend action');
    if (!path.isAbsolute(targetRoot)) throw new Error('Backend root must be absolute');
    return new Promise((resolve, reject) => {
        execFile('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', path.join(extensionRoot, 'backend', 'scripts', 'extension-manage.ps1'),
            '-Action', action, '-TargetRoot', targetRoot],
        { windowsHide: true, encoding: 'utf8', timeout: 120000, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
            if (error) return reject(new Error((stderr || stdout || error.message).trim()));
            try { resolve(JSON.parse(stdout.replace(/^\uFEFF/, '').trim())); }
            catch { reject(new Error('Invalid backend response: ' + stdout.slice(0, 300))); }
        });
    });
}

module.exports = { runBackendAction };
