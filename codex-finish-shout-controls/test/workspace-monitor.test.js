const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
    createMonitorSyncWorkerLaunch,
    createWorkspaceLeaseRecord,
    createWorkspaceMonitorRecord,
    getMonitorSyncWorkerLockPath,
    getMonitorSyncWorkerPath,
    getWorkspaceLeasePath,
    getWorkspaceMonitorPath,
    normalizeWorkspacePaths,
    publishWorkspaceLease,
    publishWorkspaceLeaseTransition,
    removeWorkspaceLease,
    isMonitorSyncWorkerActive,
    startMonitorSyncWorker
} = require('../workspace-monitor');

const leaseId = '123e4567-e89b-42d3-a456-426614174000';
const now = new Date('2026-08-19T04:00:00.000Z');
const processStartedUtc = '2026-08-19T03:30:00.000Z';

function withTemporaryDirectory(body) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-workspace-monitor-'));
    try {
        return body(directory);
    } finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
}

test('creates versioned monitor and workspace lease records', () => {
    const projectA = path.join(os.tmpdir(), 'project-a');
    const projectB = path.join(os.tmpdir(), 'project-b');
    const monitor = createWorkspaceMonitorRecord(now);
    const lease = createWorkspaceLeaseRecord({
        leaseId,
        processId: 4321,
        processStartedUtc,
        workspacePaths: [projectA, '', projectA, projectB],
        now
    });

    assert.deepEqual(monitor, {
        schemaVersion: 1,
        enabled: true,
        updatedAtUtc: '2026-08-19T04:00:00.000Z'
    });
    assert.deepEqual(lease, {
        schemaVersion: 1,
        leaseId,
        processId: 4321,
        processStartedUtc,
        workspacePaths: [path.resolve(projectA), path.resolve(projectB)],
        updatedAtUtc: '2026-08-19T04:00:00.000Z'
    });
});

test('normalizes workspace paths and rejects unsafe lease ids', () => {
    const relative = path.join('.', 'fixture-workspace');
    assert.deepEqual(normalizeWorkspacePaths([relative, relative]), [path.resolve(relative)]);
    assert.deepEqual(normalizeWorkspacePaths([]), []);
    assert.deepEqual(normalizeWorkspacePaths([path.join(relative, '中文项目')]), [
        path.resolve(relative, '中文项目')
    ]);
    assert.throws(
        () => getWorkspaceLeasePath(os.tmpdir(), '..\\outside'),
        /UUID workspace lease id/
    );
});

test('publishes and replaces atomic lease files, then removes its own lease', () => {
    withTemporaryDirectory((stateDirectory) => {
        const otherLeaseId = '223e4567-e89b-42d3-a456-426614174001';
        const first = publishWorkspaceLease({
            stateDirectory,
            leaseId,
            processId: 1234,
            processStartedUtc,
            workspacePaths: [path.join(stateDirectory, 'one')],
            now
        });
        const later = new Date('2026-08-19T04:00:05.000Z');
        publishWorkspaceLease({
            stateDirectory,
            leaseId,
            processId: 1234,
            processStartedUtc,
            workspacePaths: [path.join(stateDirectory, 'two')],
            now: later
        });

        assert.equal(first.leasePath, getWorkspaceLeasePath(stateDirectory, leaseId));
        assert.equal(first.monitorPath, getWorkspaceMonitorPath(stateDirectory));
        assert.deepEqual(JSON.parse(fs.readFileSync(first.leasePath, 'utf8')), {
            schemaVersion: 1,
            leaseId,
            processId: 1234,
            processStartedUtc,
            workspacePaths: [path.resolve(stateDirectory, 'two')],
            updatedAtUtc: '2026-08-19T04:00:05.000Z'
        });
        assert.equal(
            JSON.parse(fs.readFileSync(first.monitorPath, 'utf8')).updatedAtUtc,
            '2026-08-19T04:00:05.000Z'
        );
        assert.deepEqual(
            fs.readdirSync(stateDirectory).filter((name) => name.includes('.tmp-')),
            []
        );

        const other = publishWorkspaceLease({
            stateDirectory,
            leaseId: otherLeaseId,
            processId: 5678,
            processStartedUtc,
            workspacePaths: [path.join(stateDirectory, 'other')],
            now: later
        });

        const removed = removeWorkspaceLease({
            stateDirectory,
            leaseId,
            now: new Date('2026-08-19T04:00:06.000Z')
        });
        assert.equal(removed.removed, true);
        assert.equal(fs.existsSync(first.leasePath), false);
        assert.equal(fs.existsSync(other.leasePath), true);
        assert.equal(JSON.parse(fs.readFileSync(other.leasePath, 'utf8')).leaseId, otherLeaseId);
        assert.equal(
            JSON.parse(fs.readFileSync(first.monitorPath, 'utf8')).updatedAtUtc,
            '2026-08-19T04:00:06.000Z'
        );
    });
});

test('multiple extension-host processes can publish independent leases concurrently', async (t) => {
    const stateDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-workspace-race-'));
    t.after(() => fs.rmSync(stateDirectory, { recursive: true, force: true }));
    const modulePath = path.resolve(__dirname, '..', 'workspace-monitor.js');
    const leaseIds = [1, 2, 3, 4].map(
        (index) => `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`
    );
    const childSource = [
        "const monitor = require(process.argv[1]);",
        'const stateDirectory = process.argv[2];',
        'const leaseId = process.argv[3];',
        'const index = process.argv[4];',
        'for (let attempt = 0; attempt < 25; attempt += 1) {',
        '  monitor.publishWorkspaceLease({',
        '    stateDirectory, leaseId, processId: process.pid,',
        "    processStartedUtc: '2026-08-19T03:30:00.000Z',",
        "    workspacePaths: [require('node:path').join(stateDirectory, `项目 ${index}`)]",
        '  });',
        '}'
    ].join('\n');

    const completions = leaseIds.map(
        (childLeaseId, index) =>
            new Promise((resolve, reject) => {
                const child = spawn(
                    process.execPath,
                    ['-e', childSource, modulePath, stateDirectory, childLeaseId, String(index)],
                    { encoding: 'utf8', shell: false, windowsHide: true }
                );
                let standardError = '';
                child.stderr.on('data', (chunk) => {
                    standardError += chunk.toString();
                });
                child.once('error', reject);
                child.once('close', (code) => {
                    if (code === 0) {
                        resolve();
                    } else {
                        reject(new Error(`Concurrent lease publisher exited ${code}: ${standardError}`));
                    }
                });
            })
    );
    await Promise.all(completions);

    assert.equal(JSON.parse(fs.readFileSync(getWorkspaceMonitorPath(stateDirectory), 'utf8')).enabled, true);
    for (const childLeaseId of leaseIds) {
        const lease = JSON.parse(
            fs.readFileSync(getWorkspaceLeasePath(stateDirectory, childLeaseId), 'utf8')
        );
        assert.equal(lease.leaseId, childLeaseId);
        assert.equal(lease.workspacePaths.length, 1);
    }
    assert.deepEqual(
        fs.readdirSync(stateDirectory).filter((name) => name.includes('.tmp-')),
        []
    );
});

test('moves only its own live lease when the configured state directory changes', () => {
    withTemporaryDirectory((directory) => {
        const previousStateDirectory = path.join(directory, 'previous state');
        const stateDirectory = path.join(directory, 'next 状态');
        const otherLeaseId = '323e4567-e89b-42d3-a456-426614174002';
        publishWorkspaceLease({
            stateDirectory: previousStateDirectory,
            leaseId,
            processId: 1234,
            processStartedUtc,
            workspacePaths: [path.join(directory, 'old project')],
            now
        });
        const other = publishWorkspaceLease({
            stateDirectory: previousStateDirectory,
            leaseId: otherLeaseId,
            processId: 5678,
            processStartedUtc,
            workspacePaths: [path.join(directory, 'other project')],
            now
        });

        let callbackObserved = false;
        const transition = publishWorkspaceLeaseTransition({
            previousStateDirectory,
            stateDirectory,
            leaseId,
            processId: 1234,
            processStartedUtc,
            workspacePaths: [path.join(directory, 'new project')],
            now: new Date('2026-08-19T04:00:05.000Z'),
            onPreviousRemoved(removedDirectory) {
                callbackObserved = true;
                assert.equal(removedDirectory, path.resolve(previousStateDirectory));
                assert.equal(
                    fs.existsSync(getWorkspaceLeasePath(previousStateDirectory, leaseId)),
                    false
                );
                assert.equal(fs.existsSync(getWorkspaceLeasePath(stateDirectory, leaseId)), false);
            }
        });

        assert.equal(callbackObserved, true);
        assert.equal(transition.previousRemoved, true);
        assert.equal(transition.stateDirectory, path.resolve(stateDirectory));
        assert.equal(fs.existsSync(other.leasePath), true);
        assert.equal(fs.existsSync(getWorkspaceLeasePath(previousStateDirectory, leaseId)), false);
        assert.equal(fs.existsSync(getWorkspaceLeasePath(stateDirectory, leaseId)), true);
    });
});

test('builds a hidden detached PowerShell worker launch with explicit paths', () => {
    const workerPath = path.join(os.tmpdir(), 'codex', 'monitor-sync-worker.ps1');
    const stateDirectory = path.join(os.tmpdir(), 'state');
    const configPath = path.join(os.tmpdir(), 'settings.json');
    const launch = createMonitorSyncWorkerLaunch({ workerPath, stateDirectory, configPath });

    assert.equal(launch.command, 'cmd.exe');
    assert.deepEqual(launch.args.slice(0, 4), ['/d', '/s', '/v:off', '/c']);
    assert.match(
        launch.args[4],
        /^powershell\.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand /
    );
    const encodedCommand = launch.args[4].split(' -EncodedCommand ')[1];
    assert.equal(
        Buffer.from(encodedCommand, 'base64').toString('utf16le'),
        '& $env:CODEX_FINISH_SHOUT_WORKER_PATH ' +
            '-StateDirectory $env:CODEX_FINISH_SHOUT_STATE_DIRECTORY ' +
            '-ConfigPath $env:CODEX_FINISH_SHOUT_CONFIG_PATH'
    );
    assert.deepEqual(
        {
            detached: launch.options.detached,
            shell: launch.options.shell,
            stdio: launch.options.stdio,
            windowsHide: launch.options.windowsHide
        },
        {
        detached: true,
        shell: false,
        stdio: 'ignore',
        windowsHide: true
        }
    );
    assert.equal(launch.options.env.CODEX_FINISH_SHOUT_WORKER_PATH, path.resolve(workerPath));
    assert.equal(
        launch.options.env.CODEX_FINISH_SHOUT_STATE_DIRECTORY,
        path.resolve(stateDirectory)
    );
    assert.equal(launch.options.env.CODEX_FINISH_SHOUT_CONFIG_PATH, path.resolve(configPath));
});

test('detects the worker exclusive lock and skips a redundant ensure launch', () => {
    const codexHomeDirectory = path.join(os.tmpdir(), '.codex');
    const stateDirectory = path.join(os.tmpdir(), 'state');
    const configPath = path.join(os.tmpdir(), 'settings.json');
    const expectedLockPath = getMonitorSyncWorkerLockPath(stateDirectory);
    let spawnCalled = false;
    let closeCalled = false;
    const openSync = (candidate, flags) => {
        assert.equal(candidate, expectedLockPath);
        assert.equal(flags, 'r+');
        const error = new Error('resource busy or locked');
        error.code = 'EBUSY';
        throw error;
    };

    assert.equal(isMonitorSyncWorkerActive({ stateDirectory, openSync }), true);
    assert.equal(
        startMonitorSyncWorker({
            codexHomeDirectory,
            stateDirectory,
            configPath,
            existsSync: () => true,
            skipIfActive: true,
            openSync,
            closeSync() {
                closeCalled = true;
            },
            spawnProcess() {
                spawnCalled = true;
            }
        }),
        false
    );
    assert.equal(spawnCalled, false);
    assert.equal(closeCalled, false);
});

test('keeps an unconditional launch available for the worker handoff path', () => {
    const codexHomeDirectory = path.join(os.tmpdir(), '.codex');
    const stateDirectory = path.join(os.tmpdir(), 'state');
    const configPath = path.join(os.tmpdir(), 'settings.json');
    let openCalled = false;
    let spawnCalled = false;
    assert.equal(
        startMonitorSyncWorker({
            codexHomeDirectory,
            stateDirectory,
            configPath,
            existsSync: () => true,
            openSync() {
                openCalled = true;
                const error = new Error('resource busy or locked');
                error.code = 'EBUSY';
                throw error;
            },
            spawnProcess() {
                spawnCalled = true;
                return { on() {}, unref() {} };
            }
        }),
        true
    );
    assert.equal(openCalled, false);
    assert.equal(spawnCalled, true);
});

test('treats an unlocked stale worker lock as inactive and closes the probe handle', () => {
    const stateDirectory = path.join(os.tmpdir(), 'state');
    let closedDescriptor;
    assert.equal(
        isMonitorSyncWorkerActive({
            stateDirectory,
            openSync(candidate, flags) {
                assert.equal(candidate, getMonitorSyncWorkerLockPath(stateDirectory));
                assert.equal(flags, 'r+');
                return 42;
            },
            closeSync(descriptor) {
                closedDescriptor = descriptor;
            }
        }),
        false
    );
    assert.equal(closedDescriptor, 42);
});

test('starts and unreferences the installed worker, and silently skips a missing worker', () => {
    const codexHomeDirectory = path.join(os.tmpdir(), '.codex');
    const stateDirectory = path.join(os.tmpdir(), 'state');
    const configPath = path.join(os.tmpdir(), 'settings.json');
    const expectedWorker = getMonitorSyncWorkerPath(codexHomeDirectory);
    let captured;
    let unreferenced = false;
    let errorHandlerAttached = false;
    const started = startMonitorSyncWorker({
        codexHomeDirectory,
        stateDirectory,
        configPath,
        existsSync(candidate) {
            assert.equal(candidate, expectedWorker);
            return true;
        },
        spawnProcess(command, args, options) {
            captured = { command, args, options };
            return {
                on(eventName) {
                    if (eventName === 'error') errorHandlerAttached = true;
                },
                unref() {
                    unreferenced = true;
                }
            };
        }
    });

    assert.equal(started, true);
    assert.equal(captured.command, 'cmd.exe');
    assert.match(captured.args.at(-1), /powershell\.exe.+-EncodedCommand/);
    assert.equal(captured.options.env.CODEX_FINISH_SHOUT_WORKER_PATH, expectedWorker);
    assert.equal(captured.options.detached, true);
    assert.equal(captured.options.windowsHide, true);
    assert.equal(unreferenced, true);
    assert.equal(errorHandlerAttached, true);

    let spawnCalled = false;
    const missing = startMonitorSyncWorker({
        codexHomeDirectory,
        stateDirectory,
        configPath,
        existsSync: () => false,
        spawnProcess() {
            spawnCalled = true;
        }
    });
    assert.equal(missing, false);
    assert.equal(spawnCalled, false);
});

test(
    'launches a real detached PowerShell worker with Unicode and cmd metacharacter paths',
    { skip: process.platform !== 'win32' },
    async (t) => {
        const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-worker-launch-'));
        t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
        const codexHomeDirectory = path.join(directory, '用户 & 配置 %TEMP%');
        const workerDirectory = path.join(codexHomeDirectory, 'codex-finish-shout');
        const workerPath = path.join(workerDirectory, 'monitor-sync-worker.ps1');
        const stateDirectory = path.join(directory, '状态 & 目录 %TEMP%');
        const configPath = path.join(directory, '配置 ^!& 文件 %TEMP%.json');
        const markerPath = path.join(stateDirectory, 'worker-started.json');
        const entryPath = path.join(directory, 'worker-entered.txt');
        fs.mkdirSync(workerDirectory, { recursive: true });
        fs.mkdirSync(stateDirectory, { recursive: true });
        fs.writeFileSync(configPath, '{}\n', 'utf8');
        fs.writeFileSync(
            workerPath,
            [
                'param([string] $StateDirectory, [string] $ConfigPath)',
                `[IO.File]::WriteAllText('${entryPath.replaceAll("'", "''")}', 'entered')`,
                '$record = [ordered]@{ stateDirectory = $StateDirectory; configPath = $ConfigPath }',
                "$marker = Join-Path $StateDirectory 'worker-started.json'",
                '[IO.File]::WriteAllText($marker, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine))'
            ].join('\r\n'),
            'utf8'
        );

        let workerError;
        let workerExitCode;
        assert.equal(
            startMonitorSyncWorker({
                codexHomeDirectory,
                stateDirectory,
                configPath,
                spawnProcess(command, args, options) {
                    const child = spawn(command, args, options);
                    child.on('error', (error) => {
                        workerError = error;
                    });
                    child.on('exit', (code) => {
                        workerExitCode = code;
                    });
                    return child;
                }
            }),
            true
        );
        // A first powershell.exe launch can be slow on a cold Windows host.
        // The production path is deliberately non-blocking, so allow the test
        // enough time to observe the detached worker without treating startup
        // latency as a launch failure.
        const deadline = Date.now() + 15000;
        while (!fs.existsSync(markerPath) && Date.now() < deadline) {
            await new Promise((resolve) => setTimeout(resolve, 25));
        }
        if (!fs.existsSync(markerPath)) {
            assert.fail(
                `Detached PowerShell worker did not run (error=${workerError || ''}, ` +
                    `exit=${workerExitCode}, ` +
                    `entered=${fs.existsSync(entryPath)}, ` +
                    `files=${JSON.stringify(fs.readdirSync(directory, { recursive: true }))}).`
            );
        }
        const received = JSON.parse(fs.readFileSync(markerPath, 'utf8'));
        assert.equal(received.stateDirectory, path.resolve(stateDirectory));
        assert.equal(received.configPath, path.resolve(configPath));
    }
);
