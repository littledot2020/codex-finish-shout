const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const workspaceMonitorFileName = 'workspace-monitor.json';
const workspaceLeasePrefix = 'workspace-lease-';
const workspaceLeaseSuffix = '.json';
const monitorSyncWorkerLockFileName = 'monitor-sync-worker.lock';
const atomicRenameRetryCodes = new Set(['EACCES', 'EBUSY', 'EEXIST', 'EPERM']);
const activeWorkerLockErrorCodes = new Set(['EACCES', 'EBUSY', 'EPERM']);
const atomicRenameWaitBuffer = new Int32Array(new SharedArrayBuffer(4));

function toUtcText(now = new Date()) {
    const value = now instanceof Date ? now : new Date(now);
    if (!Number.isFinite(value.getTime())) {
        throw new TypeError('A valid timestamp is required.');
    }
    return value.toISOString();
}

function createWorkspaceLeaseId() {
    return crypto.randomUUID();
}

function assertLeaseId(leaseId) {
    const value = String(leaseId || '');
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
        throw new TypeError('A UUID workspace lease id is required.');
    }
    return value;
}

function normalizeWorkspacePaths(workspacePaths) {
    const normalized = [];
    const seen = new Set();
    for (const workspacePath of workspacePaths || []) {
        if (typeof workspacePath !== 'string' || !workspacePath.trim()) {
            continue;
        }
        const resolved = path.resolve(workspacePath);
        const comparable = process.platform === 'win32' ? resolved.toLocaleLowerCase('en-US') : resolved;
        if (seen.has(comparable)) {
            continue;
        }
        seen.add(comparable);
        normalized.push(resolved);
    }
    return normalized;
}

function getWorkspaceMonitorPath(stateDirectory) {
    return path.join(path.resolve(stateDirectory), workspaceMonitorFileName);
}

function getWorkspaceLeasePath(stateDirectory, leaseId) {
    return path.join(
        path.resolve(stateDirectory),
        `${workspaceLeasePrefix}${assertLeaseId(leaseId)}${workspaceLeaseSuffix}`
    );
}

function areSameStateDirectories(left, right) {
    if (!left || !right) {
        return false;
    }
    const resolvedLeft = path.resolve(left);
    const resolvedRight = path.resolve(right);
    return process.platform === 'win32'
        ? resolvedLeft.toLocaleLowerCase('en-US') === resolvedRight.toLocaleLowerCase('en-US')
        : resolvedLeft === resolvedRight;
}

function createWorkspaceMonitorRecord(now = new Date()) {
    return {
        schemaVersion: 1,
        enabled: true,
        updatedAtUtc: toUtcText(now)
    };
}

function createWorkspaceLeaseRecord({
    leaseId,
    processId = process.pid,
    processStartedUtc = new Date(Date.now() - process.uptime() * 1000),
    workspacePaths = [],
    now = new Date()
}) {
    const normalizedProcessId = Number(processId);
    if (!Number.isInteger(normalizedProcessId) || normalizedProcessId <= 0) {
        throw new TypeError('A positive process id is required.');
    }
    return {
        schemaVersion: 1,
        leaseId: assertLeaseId(leaseId),
        processId: normalizedProcessId,
        processStartedUtc: toUtcText(processStartedUtc),
        workspacePaths: normalizeWorkspacePaths(workspacePaths),
        updatedAtUtc: toUtcText(now)
    };
}

function writeJsonAtomic(filePath, value) {
    const parent = path.dirname(filePath);
    fs.mkdirSync(parent, { recursive: true });
    const temporaryPath = `${filePath}.tmp-${process.pid}-${crypto.randomUUID()}`;
    try {
        fs.writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
        // Several extension hosts can refresh the shared monitor marker at the
        // same instant. Windows may transiently reject one atomic replacement
        // while another process has the destination open for rename. Keep the
        // unique temp file and retry briefly; never fall back to a partial copy.
        for (let attempt = 0; ; attempt += 1) {
            try {
                fs.renameSync(temporaryPath, filePath);
                break;
            } catch (error) {
                if (
                    attempt >= 9 ||
                    !error ||
                    !atomicRenameRetryCodes.has(error.code)
                ) {
                    throw error;
                }
                Atomics.wait(
                    atomicRenameWaitBuffer,
                    0,
                    0,
                    Math.min(50, 2 ** attempt)
                );
            }
        }
    } finally {
        try {
            fs.unlinkSync(temporaryPath);
        } catch (error) {
            if (!error || error.code !== 'ENOENT') {
                throw error;
            }
        }
    }
}

function publishWorkspaceLease({
    stateDirectory,
    leaseId,
    processId = process.pid,
    processStartedUtc,
    workspacePaths = [],
    now = new Date()
}) {
    const monitor = createWorkspaceMonitorRecord(now);
    const lease = createWorkspaceLeaseRecord({
        leaseId,
        processId,
        processStartedUtc,
        workspacePaths,
        now
    });
    const leasePath = getWorkspaceLeasePath(stateDirectory, leaseId);
    const monitorPath = getWorkspaceMonitorPath(stateDirectory);

    // Publish the lease first. A worker that observes the enabled marker will
    // therefore always have this window's complete lease available to scan.
    writeJsonAtomic(leasePath, lease);
    writeJsonAtomic(monitorPath, monitor);
    return { lease, leasePath, monitor, monitorPath };
}

function publishWorkspaceLeaseTransition({
    previousStateDirectory,
    stateDirectory,
    leaseId,
    processId = process.pid,
    processStartedUtc,
    workspacePaths = [],
    now = new Date(),
    onPreviousRemoved = () => {}
}) {
    const resolvedStateDirectory = path.resolve(stateDirectory);
    const resolvedPreviousStateDirectory = previousStateDirectory
        ? path.resolve(previousStateDirectory)
        : undefined;
    let previousRemoved = false;

    // A lease with a still-running PID remains valid even after its heartbeat
    // ages out. Remove it before publishing to a newly configured state
    // directory, otherwise the old board view can remain alive indefinitely.
    if (
        resolvedPreviousStateDirectory &&
        !areSameStateDirectories(resolvedPreviousStateDirectory, resolvedStateDirectory)
    ) {
        removeWorkspaceLease({
            stateDirectory: resolvedPreviousStateDirectory,
            leaseId,
            now
        });
        previousRemoved = true;
        onPreviousRemoved(resolvedPreviousStateDirectory);
    }

    const publication = publishWorkspaceLease({
        stateDirectory: resolvedStateDirectory,
        leaseId,
        processId,
        processStartedUtc,
        workspacePaths,
        now
    });
    return {
        ...publication,
        stateDirectory: resolvedStateDirectory,
        previousStateDirectory: resolvedPreviousStateDirectory,
        previousRemoved
    };
}

function removeWorkspaceLease({ stateDirectory, leaseId, now = new Date() }) {
    const leasePath = getWorkspaceLeasePath(stateDirectory, leaseId);
    try {
        fs.unlinkSync(leasePath);
    } catch (error) {
        if (!error || error.code !== 'ENOENT') {
            throw error;
        }
    }

    const monitor = createWorkspaceMonitorRecord(now);
    const monitorPath = getWorkspaceMonitorPath(stateDirectory);
    writeJsonAtomic(monitorPath, monitor);
    return { leasePath, monitor, monitorPath, removed: !fs.existsSync(leasePath) };
}

function getMonitorSyncWorkerPath(codexHomeDirectory) {
    return path.join(
        path.resolve(codexHomeDirectory),
        'codex-finish-shout',
        'monitor-sync-worker.ps1'
    );
}

function getMonitorSyncWorkerLockPath(stateDirectory) {
    return path.join(path.resolve(stateDirectory), monitorSyncWorkerLockFileName);
}

function isMonitorSyncWorkerActive({
    stateDirectory,
    openSync = fs.openSync,
    closeSync = fs.closeSync
}) {
    let descriptor;
    try {
        // The PowerShell worker keeps this file open with FileShare.None for
        // its whole lifetime.  Probing it before the 60-second ensure launch
        // avoids creating a redundant PowerShell process just to discover the
        // same lock.  An unlocked stale file is deliberately treated as dead.
        descriptor = openSync(getMonitorSyncWorkerLockPath(stateDirectory), 'r+');
        return false;
    } catch (error) {
        return Boolean(error && activeWorkerLockErrorCodes.has(error.code));
    } finally {
        if (descriptor !== undefined) {
            try {
                closeSync(descriptor);
            } catch (_) {
                // A failed read-only liveness probe must not affect startup.
            }
        }
    }
}

function createMonitorSyncWorkerLaunch({ workerPath, stateDirectory, configPath }) {
    const resolvedWorkerPath = path.resolve(workerPath);
    const resolvedStateDirectory = path.resolve(stateDirectory);
    const resolvedConfigPath = path.resolve(configPath);
    const workerEnvironmentName = 'CODEX_FINISH_SHOUT_WORKER_PATH';
    const stateEnvironmentName = 'CODEX_FINISH_SHOUT_STATE_DIRECTORY';
    const configEnvironmentName = 'CODEX_FINISH_SHOUT_CONFIG_PATH';
    const encodedWorkerCommand = Buffer.from(
        `& $env:${workerEnvironmentName} ` +
            `-StateDirectory $env:${stateEnvironmentName} ` +
            `-ConfigPath $env:${configEnvironmentName}`,
        'utf16le'
    ).toString('base64');
    return {
        // Windows PowerShell can exit before evaluating -File when it is
        // created directly with DETACHED_PROCESS. A detached cmd proxy avoids
        // that host quirk. Paths travel in child-only environment variables so
        // cmd never reparses path metacharacters such as &, ^, !, or %NAME%.
        command: 'cmd.exe',
        args: [
            '/d',
            '/s',
            '/v:off',
            '/c',
            'powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden ' +
                '-ExecutionPolicy Bypass ' +
                `-EncodedCommand ${encodedWorkerCommand}`
        ],
        options: {
            detached: true,
            env: {
                ...process.env,
                [workerEnvironmentName]: resolvedWorkerPath,
                [stateEnvironmentName]: resolvedStateDirectory,
                [configEnvironmentName]: resolvedConfigPath
            },
            shell: false,
            stdio: 'ignore',
            windowsHide: true
        }
    };
}

function startMonitorSyncWorker({
    codexHomeDirectory,
    stateDirectory,
    configPath,
    existsSync = fs.existsSync,
    skipIfActive = false,
    openSync = fs.openSync,
    closeSync = fs.closeSync,
    spawnProcess = spawn
}) {
    const workerPath = getMonitorSyncWorkerPath(codexHomeDirectory);
    if (!existsSync(workerPath)) {
        return false;
    }
    if (
        skipIfActive &&
        isMonitorSyncWorkerActive({ stateDirectory, openSync, closeSync })
    ) {
        return false;
    }

    try {
        const launch = createMonitorSyncWorkerLaunch({ workerPath, stateDirectory, configPath });
        const child = spawnProcess(launch.command, launch.args, launch.options);
        // A missing executable can report asynchronously. Consume that event so
        // background synchronization can never destabilize the extension host.
        if (child && typeof child.on === 'function') {
            child.on('error', () => {});
        }
        if (child && typeof child.unref === 'function') {
            child.unref();
        }
        return true;
    } catch (_) {
        return false;
    }
}

module.exports = {
    areSameStateDirectories,
    createMonitorSyncWorkerLaunch,
    createWorkspaceLeaseId,
    createWorkspaceLeaseRecord,
    createWorkspaceMonitorRecord,
    getMonitorSyncWorkerPath,
    getMonitorSyncWorkerLockPath,
    getWorkspaceLeasePath,
    getWorkspaceMonitorPath,
    isMonitorSyncWorkerActive,
    normalizeWorkspacePaths,
    publishWorkspaceLease,
    publishWorkspaceLeaseTransition,
    removeWorkspaceLease,
    startMonitorSyncWorker,
    writeJsonAtomic,
    workspaceLeasePrefix,
    workspaceMonitorFileName
};
