const vscode = require('vscode');
const { getProjectMonitorWebviewHtml: renderProjectMonitorWebview } = require('./project-monitor-webview');
const { resolveAppearance, isAppearanceMessage } = require('./appearance');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { runBackendAction } = require('./backend-manager');
const extensionManifest = require('./package.json');
const {
    bundledTracks,
    supportedAudioExtensions,
    bundledAudioPath,
    trackFromAudioFile,
    syncCompletionAudio
} = require('./audio-settings');
const {
    filterStatesForWorkspace,
    isActiveState,
    readPlaybackStates,
    sortPlaybackStates
} = require('./state-store');
const {
    findBundledCodexExecutable,
    hookDefinitionId,
    hookDescription,
    hooksSettingsUri,
    readHookSetupStatus,
    supportsGraphicalHookReview
} = require('./hook-onboarding');
const {
    formatProjectMonitorStatusText,
    getProjectMonitorPath,
    readProjectMonitorState
} = require('./project-monitor-store');
const {
    createWorkspaceLeaseId,
    publishWorkspaceLeaseTransition,
    removeWorkspaceLease,
    startMonitorSyncWorker
} = require('./workspace-monitor');

const backendConfigName = 'codex-finish-shout.json';
const legacyInvalidStateDirectory = 'Codex Finish Shout Controls';
const playbackModes = ['once', 'loop', 'seconds'];
const authorizationPromptIntervalMs = 12 * 60 * 60 * 1000;
const projectMonitorPollIntervalMs = 750;
const workspaceLeaseHeartbeatIntervalMs = 5000;
const monitorSyncWorkerEnsureIntervalMs = 60 * 1000;
const extensionHostProcessStartedUtc = new Date(
    Date.now() - process.uptime() * 1000
).toISOString();

let statusItem;
let settingsItem;
let authorizationItem;
let projectMonitorItem;
let projectMonitorPanel;
let pollTimer;
let authorizationPollTimer;
let projectMonitorPollTimer;
let workspaceLeaseHeartbeatTimer;
let monitorSyncWorkerEnsureTimer;
let workspaceLeaseId;
let lastWorkspaceLeaseStateDirectory;
let lastPlaying = false;
let authorizationRefreshRunning = false;
let latestProjectMonitorState;
let latestProjectMonitorFingerprint = '';
let appearanceUpdatePromise = Promise.resolve();
let extensionContext;
const seenSessionIds = new Map();

function publishCurrentWorkspaceLease() {
    if (!workspaceLeaseId) {
        return false;
    }
    try {
        const publication = publishWorkspaceLeaseTransition({
            previousStateDirectory: lastWorkspaceLeaseStateDirectory,
            stateDirectory: getStateDirectory(),
            leaseId: workspaceLeaseId,
            processId: process.pid,
            processStartedUtc: extensionHostProcessStartedUtc,
            workspacePaths: getWorkspacePaths(),
            onPreviousRemoved(previousStateDirectory) {
                lastWorkspaceLeaseStateDirectory = undefined;
                launchMonitorSyncWorker(previousStateDirectory);
            }
        });
        lastWorkspaceLeaseStateDirectory = publication.stateDirectory;
        return true;
    } catch (_) {
        return false;
    }
}

function launchMonitorSyncWorker(
    stateDirectory = getStateDirectory(),
    configPath = getBackendConfigPath()
) {
    return startMonitorSyncWorker({
        codexHomeDirectory: getCodexHomeDirectory(),
        stateDirectory,
        configPath
    });
}

function ensureMonitorSyncWorker() {
    return startMonitorSyncWorker({
        codexHomeDirectory: getCodexHomeDirectory(),
        stateDirectory: getStateDirectory(),
        configPath: getBackendConfigPath(),
        skipIfActive: true
    });
}

function startWorkspaceMonitoring() {
    if (!workspaceLeaseId) {
        workspaceLeaseId = createWorkspaceLeaseId();
    }
    publishCurrentWorkspaceLease();
    launchMonitorSyncWorker();

    if (workspaceLeaseHeartbeatTimer) {
        clearInterval(workspaceLeaseHeartbeatTimer);
    }
    workspaceLeaseHeartbeatTimer = setInterval(
        publishCurrentWorkspaceLease,
        workspaceLeaseHeartbeatIntervalMs
    );

    if (monitorSyncWorkerEnsureTimer) {
        clearInterval(monitorSyncWorkerEnsureTimer);
    }
    monitorSyncWorkerEnsureTimer = setInterval(
        ensureMonitorSyncWorker,
        monitorSyncWorkerEnsureIntervalMs
    );
}

function stopWorkspaceMonitoring() {
    if (workspaceLeaseHeartbeatTimer) {
        clearInterval(workspaceLeaseHeartbeatTimer);
        workspaceLeaseHeartbeatTimer = undefined;
    }
    if (monitorSyncWorkerEnsureTimer) {
        clearInterval(monitorSyncWorkerEnsureTimer);
        monitorSyncWorkerEnsureTimer = undefined;
    }

    const leaseId = workspaceLeaseId;
    const leaseStateDirectory = lastWorkspaceLeaseStateDirectory || getStateDirectory();
    workspaceLeaseId = undefined;
    lastWorkspaceLeaseStateDirectory = undefined;
    if (!leaseId) {
        return;
    }
    try {
        removeWorkspaceLease({ stateDirectory: leaseStateDirectory, leaseId });
    } catch (_) {
        // Lease expiry in the worker remains the crash-safe cleanup path.
    }
    // Wake a detached reconciler after removing this window's lease so the
    // board does not wait for another Codex event before dropping the project.
    launchMonitorSyncWorker(leaseStateDirectory);
}

function expandEnvironmentVariables(value) {
    return value
        .replace(/%([^%]+)%/g, (_, name) => process.env[name] || `%${name}%`)
        .replace(/^~(?=$|[\\/])/, os.homedir());
}

function getExtensionSettings() {
    return vscode.workspace.getConfiguration('codexFinishShout');
}

function getProjectMonitorAppearance() {
    const configuration = vscode.workspace?.getConfiguration ? getExtensionSettings() : undefined;
    return resolveAppearance(
        configuration?.get('language', 'auto'),
        configuration?.get('projectMonitor.theme', 'auto'),
        vscode.env?.language
    );
}

function localize(chinese, english) {
    return getProjectMonitorAppearance().language === 'en' ? english : chinese;
}

function refreshProjectMonitorAppearance() {
    if (!projectMonitorPanel) return;
    projectMonitorPanel.title = localize('Codex 项目总览', 'Codex Project Overview');
    void projectMonitorPanel.webview.postMessage({
        type: 'projectMonitorAppearance',
        appearance: getProjectMonitorAppearance(),
        showToolAI: getExtensionSettings().get('promotion.showToolAI', true) !== false
    });
}

async function updateProjectMonitorAppearance(message) {
    if (!isAppearanceMessage(message)) return;
    const configuration = getExtensionSettings();
    try {
        for (const [key, value] of [
            ['language', message.languagePreference],
            ['projectMonitor.theme', message.theme]
        ]) {
            if (configuration.get(key, 'auto') === value) continue;
            const inspected = configuration.inspect(key);
            // Appearance belongs to the VS Code window. Folder-scoped updates
            // require a resource-bound configuration and do not apply here.
            const target = inspected?.workspaceValue !== undefined
                ? vscode.ConfigurationTarget.Workspace
                : vscode.ConfigurationTarget.Global;
            await configuration.update(key, value, target);
        }
    } catch (error) {
        void vscode.window.showErrorMessage(localize(
            `无法保存界面设置：${error.message}`,
            `Unable to save display settings: ${error.message}`
        ));
    }
    refreshProjectMonitorAppearance();
    refreshProjectMonitor(true);
}

function isLegacyInvalidStateDirectory(value) {
    return value === legacyInvalidStateDirectory;
}

function selectStateDirectorySetting(inspected, effectiveValue) {
    // Re-evaluate VS Code's precedence ourselves so one obsolete high-priority
    // sentinel does not hide a valid workspace/global path below it.
    if (inspected) {
        for (const field of [
            'workspaceFolderValue',
            'workspaceValue',
            'globalValue',
            'defaultValue'
        ]) {
            const value = inspected[field];
            if (value !== undefined && !isLegacyInvalidStateDirectory(value)) {
                return value;
            }
        }
    }
    return isLegacyInvalidStateDirectory(effectiveValue) ? undefined : effectiveValue;
}

async function repairLegacyStateDirectorySettings(configuration = getExtensionSettings()) {
    const inspected = configuration.inspect('stateDirectory');
    if (!inspected) {
        return [];
    }

    const repairedTargets = [];
    for (const entry of [
        { field: 'globalValue', target: vscode.ConfigurationTarget.Global },
        { field: 'workspaceValue', target: vscode.ConfigurationTarget.Workspace },
        { field: 'workspaceFolderValue', target: vscode.ConfigurationTarget.WorkspaceFolder }
    ]) {
        if (isLegacyInvalidStateDirectory(inspected[entry.field])) {
            await configuration.update('stateDirectory', undefined, entry.target);
            repairedTargets.push(entry.field);
        }
    }
    return repairedTargets;
}

function getStateDirectory() {
    if (process.env.CODEX_FINISH_SHOUT_DEV_ROOT) return path.join(process.env.CODEX_FINISH_SHOUT_DEV_ROOT, 'codex-finish-shout-state');
    const configuration = getExtensionSettings();
    const configured = selectStateDirectorySetting(
        configuration.inspect('stateDirectory'),
        configuration.get('stateDirectory')
    );
    const value = configured || process.env.CODEX_FINISH_SHOUT_STATE;
    if (value) {
        return path.resolve(expandEnvironmentVariables(value));
    }
    return path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'codex-finish-shout-state');
}

function isProjectMonitorStatusBarVisible() {
    return getExtensionSettings().get('projectMonitor.showStatusBar', true) !== false;
}

function getProjectMonitorWebviewHtml(webview, options) {
    return renderProjectMonitorWebview(webview, options || { ...getProjectMonitorAppearance(),
        showToolAI: vscode.workspace?.getConfiguration ? getExtensionSettings().get('promotion.showToolAI', true) !== false : true });
}
function updateProjectMonitorStatusItem(state) {
    if (!projectMonitorItem) {
        return;
    }
    projectMonitorItem.name = localize('Codex 项目监控', 'Codex Project Monitor');
    if (!isProjectMonitorStatusBarVisible()) {
        projectMonitorItem.hide();
        return;
    }
    projectMonitorItem.text = formatProjectMonitorStatusText(state, getProjectMonitorAppearance().language);
    projectMonitorItem.command = 'codexFinishShout.openProjectMonitor';
    projectMonitorItem.tooltip =
        state.kind === 'error'
            ? localize(`项目监控快照读取失败：${state.error}\n点击打开总览`, `Unable to read project status: ${state.error}\nOpen overview`)
            : localize(
                `全部 ${state.totalCount} 个项目：${state.runningCount} 个运行中，${state.completedCount} 个已完成\n点击打开总览`,
                `${state.totalCount} projects: ${state.runningCount} running, ${state.completedCount} completed\nOpen overview`
            );
    projectMonitorItem.show();
}

function refreshProjectMonitor(force = false) {
    const state = readProjectMonitorState(getProjectMonitorPath(getStateDirectory()));
    const fingerprint = JSON.stringify(state);
    latestProjectMonitorState = state;
    updateProjectMonitorStatusItem(state);
    if (projectMonitorPanel && (force || fingerprint !== latestProjectMonitorFingerprint)) {
        void projectMonitorPanel.webview.postMessage({
            type: 'projectMonitorSnapshot',
            state
        });
    }
    latestProjectMonitorFingerprint = fingerprint;
    return state;
}

function openProjectMonitor() {
    if (projectMonitorPanel) {
        projectMonitorPanel.reveal(vscode.ViewColumn.One);
        refreshProjectMonitor(true);
        return projectMonitorPanel;
    }

    projectMonitorPanel = vscode.window.createWebviewPanel(
        'codexFinishShout.projectMonitor',
        localize('Codex 项目总览', 'Codex Project Overview'),
        vscode.ViewColumn.One,
        {
            enableScripts: true,
            retainContextWhenHidden: true,
            localResourceRoots: []
        }
    );
    projectMonitorPanel.onDidDispose(() => {
        projectMonitorPanel = undefined;
    });
    projectMonitorPanel.webview.onDidReceiveMessage((message) => {
        if (message && (message.type === 'ready' || message.type === 'refresh')) {
            refreshProjectMonitorAppearance();
            refreshProjectMonitor(true);
        } else if (isAppearanceMessage(message)) {
            appearanceUpdatePromise = appearanceUpdatePromise.then(() => updateProjectMonitorAppearance(message));
            return appearanceUpdatePromise;
        } else if (message?.type === 'chooseCompletionMusic') {
            return configureMusic();
        } else if (message?.type === 'configurePlayback') {
            return configurePlayback();
        } else if (message?.type === 'stopMusic') {
            return stopMonitorMusic(projectMonitorPanel.webview);
        } else if (message?.type === 'openToolAI') {
            return vscode.env.openExternal(vscode.Uri.parse('https://www.toolai.io/'));
        } else if (message?.type === 'dismissToolAI') {
            return getExtensionSettings().update('promotion.showToolAI', false, vscode.ConfigurationTarget.Global)
                .then(refreshProjectMonitorAppearance).catch(error => {
                    refreshProjectMonitorAppearance();
                    void vscode.window.showErrorMessage(localize(`无法保存推广设置：${error.message}`, `Unable to save promotion preference: ${error.message}`));
                });
        }
    });
    // Register the message receiver before loading HTML so the initial ready
    // message cannot race with listener setup.
    projectMonitorPanel.webview.html = getProjectMonitorWebviewHtml(projectMonitorPanel.webview);
    return projectMonitorPanel;
}

async function toggleProjectMonitorStatusBar() {
    const configuration = getExtensionSettings();
    const visible = !isProjectMonitorStatusBarVisible();
    const inspected = configuration.inspect('projectMonitor.showStatusBar');
    const target =
        inspected && inspected.workspaceFolderValue !== undefined
            ? vscode.ConfigurationTarget.WorkspaceFolder
            : inspected && inspected.workspaceValue !== undefined
              ? vscode.ConfigurationTarget.Workspace
              : vscode.ConfigurationTarget.Global;
    await configuration.update(
        'projectMonitor.showStatusBar',
        visible,
        target
    );
    refreshProjectMonitor(true);
    void vscode.window.showInformationMessage(
        visible
            ? localize('Codex 项目监控摘要已显示在状态栏。', 'Codex project summary is now visible in the status bar.')
            : localize('Codex 项目监控摘要已隐藏；后台监控仍在运行。', 'Codex project summary is hidden. Monitoring continues in the background.')
    );
}

function getBackendConfigPath() {
    if (process.env.CODEX_FINISH_SHOUT_DEV_ROOT) return path.join(process.env.CODEX_FINISH_SHOUT_DEV_ROOT, backendConfigName);
    const configured = getExtensionSettings().get('configPath');
    const value = configured || process.env.CODEX_FINISH_SHOUT_CONFIG;
    if (value) {
        return path.resolve(expandEnvironmentVariables(value));
    }
    return path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), backendConfigName);
}

function getCodexHomeDirectory() {
    if (process.env.CODEX_FINISH_SHOUT_DEV_ROOT) return path.resolve(process.env.CODEX_FINISH_SHOUT_DEV_ROOT);
    const configured = process.env.CODEX_HOME;
    if (configured) {
        return path.resolve(expandEnvironmentVariables(configured));
    }
    return path.dirname(getBackendConfigPath());
}

function getHookSetupStatus() {
    return readHookSetupStatus({
        hooksPath: path.join(getCodexHomeDirectory(), 'hooks.json'),
        stateDirectory: getStateDirectory(),
        definitionId: hookDefinitionId
    });
}

function getCodexExtension() {
    return vscode.extensions && vscode.extensions.getExtension
        ? vscode.extensions.getExtension('openai.chatgpt')
        : undefined;
}

function getTerminalWorkingDirectory() {
    const workspace = getWorkspacePaths()[0];
    return workspace || os.homedir();
}

async function openHookReviewInTerminal(codexExtension) {
    const executable = findBundledCodexExecutable(codexExtension && codexExtension.extensionPath);
    let terminal;
    if (executable) {
        terminal = vscode.window.createTerminal({
            name: localize('Codex Hooks 安全授权', 'Codex Hooks Authorization'),
            shellPath: executable,
            cwd: getTerminalWorkingDirectory()
        });
    } else {
        terminal = vscode.window.createTerminal({
            name: localize('Codex Hooks 安全授权', 'Codex Hooks Authorization'),
            cwd: getTerminalWorkingDirectory()
        });
        terminal.sendText('codex', true);
    }
    terminal.show(true);

    // Terminal input is buffered by VS Code, but a short delay also works with
    // older Codex builds that initialize their interactive screen more slowly.
    setTimeout(() => terminal.sendText('/hooks', true), executable ? 800 : 1500);
    return 'terminal';
}

async function openHookAuthorization() {
    if (process.env.CODEX_FINISH_SHOUT_DEV_ROOT) {
        void vscode.window.showInformationMessage(localize('开发环境使用模拟事件；真实 Hook 联调请使用独立 Windows 测试账户。', 'Development uses simulated events. Use a separate Windows account for real hook testing.'));
        return 'development';
    }
    const setup = getHookSetupStatus();
    if (setup.reason === 'not-installed' || setup.reason === 'upgrade-required') {
        const initialize = localize('初始化／修复后端', 'Initialize / Repair Backend');
        const selection = await vscode.window.showWarningMessage(
            setup.reason === 'not-installed'
                ? localize('初始化将安装内置播放器，并备份和更新 Codex notify 与 Hook 配置。', 'Initialize the bundled player and back up and update Codex notify and hook settings.')
                : localize('后端需要更新。更新将保留已有设置。', 'The backend needs an update. Existing settings will be preserved.'),
            initialize
        );
        if (selection === initialize) await manageBackend('Install');
        return setup.reason;
    }

    const codexExtension = getCodexExtension();
    if (codexExtension && supportsGraphicalHookReview(codexExtension.extensionPath)) {
        try {
            await vscode.commands.executeCommand('chatgpt.openSidebar');
            const opened = await vscode.env.openExternal(vscode.Uri.parse(hooksSettingsUri));
            if (opened) {
                void vscode.window.showInformationMessage(
                    localize(`请在打开的 Codex Hooks 页面中信任“${hookDescription}”。这项安全确认只需一次。`, `Trust “${hookDescription}” in the Codex Hooks page. This authorization is required once.`)
                );
                return 'graphical';
            }
        } catch (error) {
            console.warn('Codex Finish Shout could not open the graphical Hooks page.', error);
        }
    }

    void vscode.window.showInformationMessage(
        localize(`当前 Codex 版本不支持直接打开 Hooks 页面，已为你打开安全审核终端。请信任“${hookDescription}”。`, `This Codex version cannot open the Hooks page directly. Use the review terminal to trust “${hookDescription}”.`)
    );
    return openHookReviewInTerminal(codexExtension);
}

function updateAuthorizationStatusItem(setup) {
    if (!authorizationItem) {
        return;
    }
    authorizationItem.name = localize('Codex Finish Shout 授权', 'Codex Finish Shout Authorization');
    if (setup.ready) {
        authorizationItem.hide();
        return;
    }

    authorizationItem.command = 'codexFinishShout.openHookAuthorization';
    if (setup.reason === 'authorization-required') {
        authorizationItem.text = localize('$(shield) 完成 Codex 授权', '$(shield) Authorize Codex hooks');
        authorizationItem.tooltip =
            localize('需要一次安全确认，才能准确识别 Codex 是否真正完成。', 'Authorize the hook once to detect when Codex has finished.');
    } else {
        authorizationItem.text = localize('$(warning) 完成提醒待安装', '$(warning) Set up completion alerts');
        authorizationItem.tooltip =
            setup.reason === 'not-installed'
                ? localize('Codex Finish Shout 后端尚未安装。', 'The Codex Finish Shout backend is not installed.')
                : localize('Codex Finish Shout 后端需要升级。', 'The Codex Finish Shout backend needs an update.');
    }
    authorizationItem.show();
}

async function refreshHookAuthorization(context, showPrompt = false) {
    if (authorizationRefreshRunning) {
        return null;
    }
    authorizationRefreshRunning = true;
    try {
        const setup = getHookSetupStatus();
        updateAuthorizationStatusItem(setup);

        const pendingKey = `hookAuthorizationPending.${hookDefinitionId}`;
        if (setup.ready) {
            if (context.globalState.get(pendingKey, false)) {
                await context.globalState.update(pendingKey, false);
                void vscode.window.showInformationMessage(
                    localize('Codex Finish Shout 安全授权已生效，完成检测现在已就绪。', 'Codex Finish Shout is authorized. Completion detection is ready.')
                );
            }
            return setup;
        }

        if (!showPrompt || setup.reason !== 'authorization-required') {
            return setup;
        }
        const promptKey = `hookAuthorizationPromptedAt.${hookDefinitionId}`;
        const lastPromptedAt = Number(context.globalState.get(promptKey, 0));
        if (Date.now() - lastPromptedAt < authorizationPromptIntervalMs) {
            return setup;
        }
        await context.globalState.update(promptKey, Date.now());
        const authorizeLabel = localize('打开授权', 'Open authorization');
        const selection = await vscode.window.showInformationMessage(
            localize('Codex Finish Shout 还需一次安全授权，完成后才能准确判断 Codex 是否真正结束。', 'Authorize Codex Finish Shout once to enable reliable completion detection.'),
            authorizeLabel,
            localize('稍后', 'Later')
        );
        if (selection === authorizeLabel) {
            await context.globalState.update(pendingKey, true);
            await openHookAuthorization();
        }
        return setup;
    } finally {
        authorizationRefreshRunning = false;
    }
}

function readJson(filePath) {
    try {
        return JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch (_) {
        return null;
    }
}

function writeJson(filePath, value) {
    const parent = path.dirname(filePath);
    fs.mkdirSync(parent, { recursive: true });
    const temporaryPath = `${filePath}.tmp-${process.pid}-${Date.now()}`;
    fs.writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
    try {
        try {
            fs.renameSync(temporaryPath, filePath);
        } catch (_) {
            // Windows cannot rename over an existing file in some configurations.
            fs.copyFileSync(temporaryPath, filePath);
            fs.unlinkSync(temporaryPath);
        }
    } finally {
        if (fs.existsSync(temporaryPath)) {
            fs.unlinkSync(temporaryPath);
        }
    }
}

function readBackendSettings() {
    return readJson(getBackendConfigPath()) || {};
}

function ensurePlaybackSettings(settings) {
    if (!settings.playback || typeof settings.playback !== 'object') {
        settings.playback = {};
    }
    if (!playbackModes.includes(settings.playback.mode)) {
        settings.playback.mode = 'once';
    }
    if (!Number.isFinite(Number(settings.playback.seconds)) || Number(settings.playback.seconds) < 1) {
        settings.playback.seconds = 30;
    }
    if (
        !Number.isFinite(Number(settings.playback.maximumSeconds)) ||
        Number(settings.playback.maximumSeconds) < 1
    ) {
        settings.playback.maximumSeconds = 3600;
    }
}

function ensureAnnouncementSettings(settings) {
    if (!settings.announcement || typeof settings.announcement !== 'object') {
        settings.announcement = {};
    }
    if (typeof settings.announcement.enabled !== 'boolean') {
        settings.announcement.enabled = true;
    }
}

function updateBackendSettings(mutator) {
    const settings = readBackendSettings();
    ensurePlaybackSettings(settings);
    ensureAnnouncementSettings(settings);
    mutator(settings);
    writeJson(getBackendConfigPath(), settings);
}

function getExplicitSetting(configuration, key) {
    const inspected = configuration.inspect(key);
    if (!inspected) {
        return { present: false, value: undefined };
    }
    for (const field of ['workspaceFolderValue', 'workspaceValue', 'globalValue']) {
        if (inspected[field] !== undefined) {
            return { present: true, value: inspected[field] };
        }
    }
    return { present: false, value: undefined };
}

function syncConfiguredSettings() {
    const configuration = getExtensionSettings();
    const settings = readBackendSettings();
    let changed = false;
    ensurePlaybackSettings(settings);
    ensureAnnouncementSettings(settings);

    changed = syncCompletionAudio(settings, {
        preset: configuration.get('completionSound', ''),
        customFile: configuration.get('audioFile', '')
    }) || changed;

    const playbackMode = getExplicitSetting(configuration, 'playbackMode');
    if (playbackMode.present && playbackModes.includes(playbackMode.value)) {
        settings.playback.mode = playbackMode.value;
        changed = true;
    }
    const playbackSeconds = getExplicitSetting(configuration, 'playbackSeconds');
    if (playbackSeconds.present && Number(playbackSeconds.value) >= 1) {
        settings.playback.seconds = Math.min(86400, Math.round(Number(playbackSeconds.value)));
        changed = true;
    }
    const maximumSeconds = getExplicitSetting(configuration, 'maximumPlaybackSeconds');
    if (maximumSeconds.present && Number(maximumSeconds.value) >= 1) {
        settings.playback.maximumSeconds = Math.min(86400, Math.round(Number(maximumSeconds.value)));
        changed = true;
    }
    const volume = getExplicitSetting(configuration, 'volume');
    if (volume.present && Number(volume.value) >= 0) {
        settings.volume = Math.min(100, Math.round(Number(volume.value)));
        changed = true;
    }
    const announcementEnabled = getExplicitSetting(configuration, 'announcementEnabled');
    if (announcementEnabled.present && typeof announcementEnabled.value === 'boolean') {
        settings.announcement.enabled = announcementEnabled.value;
        changed = true;
    }
    const announcementTemplate = getExplicitSetting(configuration, 'announcementTemplate');
    if (announcementTemplate.present && typeof announcementTemplate.value === 'string') {
        if (announcementTemplate.value.trim()) {
            settings.announcement.template = announcementTemplate.value;
        }
        changed = true;
    }
    const announcementRate = getExplicitSetting(configuration, 'announcementRate');
    if (announcementRate.present && Number.isFinite(Number(announcementRate.value))) {
        settings.rate = Math.max(-10, Math.min(10, Math.round(Number(announcementRate.value))));
        changed = true;
    }

    if (changed) {
        writeJson(getBackendConfigPath(), settings);
    }
}

function getWorkspacePaths() {
    return (vscode.workspace.workspaceFolders || [])
        .map((folder) => folder && folder.uri && folder.uri.fsPath)
        .filter(Boolean);
}

function getRelevantActiveStates() {
    const states = readPlaybackStates(getStateDirectory()).filter((state) => isActiveState(state));
    return sortPlaybackStates(filterStatesForWorkspace(states, getWorkspacePaths()));
}

function setPlayingContext(value) {
    if (lastPlaying === value) {
        return;
    }
    lastPlaying = value;
    void vscode.commands.executeCommand('setContext', 'codexFinishShout.playing', value);
}

function signalStop(stateDirectory, state) {
    // Player IDs are GUIDs; retain simple legacy IDs without allowing a state
    // file to redirect the stop signal outside its configured directory.
    if (typeof state.sessionId !== 'string' || !/^[a-zA-Z0-9_-]{1,120}$/.test(state.sessionId)) {
        throw new Error(localize('无效的音乐会话编号。', 'Invalid audio session ID.'));
    }
    fs.mkdirSync(stateDirectory, { recursive: true });
    const signalPath = path.join(stateDirectory, `audio-stop-${state.sessionId}.signal`);
    const payload = {
        sessionId: state.sessionId,
        requestedUtc: new Date().toISOString(),
        requestedBy: 'Codex Finish Shout Controls'
    };
    fs.writeFileSync(signalPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

async function stopMonitorMusic(webview) {
    const stateDirectory = getStateDirectory();
    const states = readPlaybackStates(stateDirectory).filter((state) => isActiveState(state));
    let count = 0;
    const failures = [];
    // The overview covers every project, including audio waiting in the queue
    // and projects outside this VS Code window's workspace.
    for (const state of states) {
        try {
            signalStop(stateDirectory, state);
            count += 1;
        } catch (error) {
            failures.push(error.message);
        }
    }
    const result = { type: 'musicStopResult', ok: failures.length === 0, count };
    if (failures.length > 0) {
        void vscode.window.showErrorMessage(localize(
            `已向 ${count} 个音乐会话发送停止请求，${failures.length} 个失败：${failures[0]}`,
            `Sent stop requests to ${count} audio sessions; ${failures.length} failed: ${failures[0]}`
        ));
    } else {
        void vscode.window.showInformationMessage(count === 0 ? localize(
            '当前没有正在播放或排队的 Codex 音乐。',
            'No Codex completion audio is playing or queued.'
        ) : localize(
            `已向 ${count} 个音乐会话发送停止请求（包括排队音乐）。`,
            `Sent stop requests to ${count} audio sessions, including queued audio.`
        ));
    }
    await webview.postMessage(result);
    return result;
}

function playbackDescription(state) {
    if (state.playbackMode === 'loop') {
        return localize('循环播放（最多 ' + (state.maximumPlaybackSeconds || 3600) + ' 秒）', 'loop playback (up to ' + (state.maximumPlaybackSeconds || 3600) + ' seconds)');
    }
    if (state.playbackMode === 'seconds') {
        return localize('播放 ' + (state.playbackSeconds || 30) + ' 秒', 'play for ' + (state.playbackSeconds || 30) + ' seconds');
    }
    return localize('播放一次', 'play once');
}

function activityDescription(state) {
    const description = playbackDescription(state);
    return state.status === 'queued' ? localize(`等待${description}`, `Queued: ${description}`) : description;
}

function rememberSession(sessionId) {
    seenSessionIds.set(sessionId, Date.now());
    const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000;
    for (const [knownSessionId, seenAt] of seenSessionIds) {
        if (seenAt < cutoff || seenSessionIds.size > 500) {
            seenSessionIds.delete(knownSessionId);
        }
    }
}

async function stopMusic(requestedSessionId) {
    const stateDirectory = getStateDirectory();
    const states = getRelevantActiveStates();
    if (states.length === 0) {
        statusItem.hide();
        settingsItem.hide();
        setPlayingContext(false);
        void vscode.window.showInformationMessage(localize('当前没有正在播放的 Codex 音乐。', 'No Codex completion audio is playing.'));
        return;
    }

    let targets;
    if (typeof requestedSessionId === 'string' && requestedSessionId) {
        const requested = states.find((state) => state.sessionId === requestedSessionId);
        targets = requested ? [requested] : [];
    } else if (states.length === 1) {
        targets = states;
    } else {
        const items = [
            {
                label: localize('$(stop) 停止当前工作区的全部音乐', '$(stop) Stop all audio in this workspace'),
                description: localize(`${states.length} 个项目任务`, `${states.length} project tasks`),
                targets: states
            },
            ...states.map((state) => ({
                label: `$(mute) ${state.projectName || localize('当前项目', 'Current project')}`,
                description: activityDescription(state),
                targets: [state]
            }))
        ];
        const selected = await vscode.window.showQuickPick(items, {
            title: localize('Codex Finish Shout：选择要停止的项目', 'Codex Finish Shout: Select audio to stop'),
            placeHolder: localize('检测到多个项目的完成音乐', 'Completion audio is active for several projects')
        });
        if (!selected) {
            return;
        }
        targets = selected.targets;
    }

    if (targets.length === 0) {
        void vscode.window.showInformationMessage(localize('对应项目的音乐已经停止。', 'Audio for this project has already stopped.'));
        return;
    }

    try {
        for (const state of targets) {
            signalStop(stateDirectory, state);
        }
        statusItem.text = localize('$(sync~spin) 正在停止音乐…', '$(sync~spin) Stopping audio…');
        statusItem.tooltip = localize('已发送停止请求', 'Stop request sent');
        const targetText =
            targets.length === 1
                ? localize(`项目“${targets[0].projectName || '当前项目'}”`, `“${targets[0].projectName || 'Current project'}”`)
                : localize(`${targets.length} 个项目`, `${targets.length} projects`);
        void vscode.window.showInformationMessage(localize(`已请求停止${targetText}的 Codex 音乐。`, `Requested to stop Codex audio for ${targetText}.`));
    } catch (error) {
        void vscode.window.showErrorMessage(localize(`停止 Codex 音乐失败：${error.message}`, `Unable to stop Codex audio: ${error.message}`));
    }
}

function completionSoundLabel(settings) {
    const track = trackFromAudioFile(settings.audioFile);
    if (track) return localize(track.zh, track.en);
    if (settings.mode === 'tts') return localize('语音提醒', 'Speech');
    if (settings.mode === 'beep') return localize('系统提示音', 'System beep');
    return settings.audioFile ? path.basename(settings.audioFile) : localize('轻柔风铃', 'Soft chime');
}

async function saveCompletionSound(preset, audioFile) {
    const configuration = getExtensionSettings();
    // Match the effective scope so an existing workspace choice cannot silently
    // override the newly selected sound on the next configuration event.
    for (const [key, value] of [['audioFile', audioFile || ''], ['completionSound', preset]]) {
        const inspected = configuration.inspect(key);
        const target = inspected?.workspaceValue !== undefined
            ? vscode.ConfigurationTarget.Workspace : vscode.ConfigurationTarget.Global;
        await configuration.update(key, value, target);
    }
    updateBackendSettings((settings) => {
        syncCompletionAudio(settings, { preset, customFile: audioFile || '' });
    });
}

async function configureMusic() {
    const settings = readBackendSettings();
    const current = trackFromAudioFile(settings.audioFile);
    const items = bundledTracks.map((track) => ({
        label: `${current?.id === track.id ? '$(check)' : '$(music)'} ${localize(track.zh, track.en)}`,
        description: localize(`内置 MP3 · ${track.seconds} 秒`, `Bundled MP3 · ${track.seconds} sec`),
        track
    }));
    items.push({
        label: localize('$(folder-opened) 选择本地音乐…', '$(folder-opened) Choose local audio…'),
        description: 'MP3 / WAV / WMA / M4A / AAC',
        custom: true
    });
    const selected = await vscode.window.showQuickPick(items, {
        title: localize('任务完成后播放的音乐', 'Completion music'),
        placeHolder: localize(`当前：${completionSoundLabel(settings)}`, `Current: ${completionSoundLabel(settings)}`)
    });
    if (!selected) return;
    try {
        let audioFile;
        if (selected.custom) {
            const files = await vscode.window.showOpenDialog({
                title: localize('选择任务完成后的音乐', 'Choose completion audio'),
                canSelectMany: false,
                canSelectFolders: false,
                filters: { [localize('音频文件', 'Audio files')]: supportedAudioExtensions }
            });
            if (!files?.length) return;
            audioFile = files[0].fsPath;
            if (files[0].scheme !== 'file' || !fs.statSync(audioFile).isFile() ||
                !supportedAudioExtensions.includes(path.extname(audioFile).slice(1).toLowerCase())) {
                throw new Error(localize('请选择支持的本地音频文件。', 'Choose a supported local audio file.'));
            }
        } else if (!fs.existsSync(bundledAudioPath(selected.track.id))) {
            throw new Error(localize('内置音乐文件缺失，请重新安装扩展。', 'The bundled audio is missing. Reinstall the extension.'));
        }
        await saveCompletionSound(selected.custom ? 'custom' : selected.track.id, audioFile);
        const label = selected.custom ? path.basename(audioFile) : localize(selected.track.zh, selected.track.en);
        void vscode.window.showInformationMessage(localize(`完成音乐已设置为：${label}。`, `Completion music set to ${label}.`));
    } catch (error) {
        void vscode.window.showErrorMessage(localize(`无法保存完成音乐：${error.message}`, `Unable to save completion music: ${error.message}`));
    }
}

async function configurePlayback() {
    const settings = readBackendSettings();
    ensurePlaybackSettings(settings);
    const items = [
        { label: localize('$(music) 选择完成音乐…', '$(music) Choose completion music…'), description: completionSoundLabel(settings), music: true },
        { label: localize('播放一次', 'Play once'), description: localize('完整播放一遍音乐', 'Play the entire audio once'), mode: 'once' },
        { label: localize('循环播放', 'Loop'), description: localize(`循环播放，最多 ${settings.playback.maximumSeconds} 秒`, `Repeat for up to ${settings.playback.maximumSeconds} seconds`), mode: 'loop' },
        { label: localize('播放指定秒数', 'Play for a duration'), description: localize(`当前为 ${settings.playback.seconds} 秒`, `Currently ${settings.playback.seconds} seconds`), mode: 'seconds' }
    ];
    const selected = await vscode.window.showQuickPick(items, {
        title: localize('Codex Finish Shout：完成音乐设置', 'Codex Finish Shout: Completion audio'),
        placeHolder: localize('选择音乐，或调整完成后的播放方式', 'Choose music or change how completion audio plays')
    });
    if (!selected) {
        return;
    }
    if (selected.music) return configureMusic();

    let seconds = settings.playback.seconds;
    if (selected.mode === 'seconds') {
        const value = await vscode.window.showInputBox({
            title: localize('播放时长', 'Playback duration'),
            prompt: localize('输入播放多少秒后自动停止（1-86400）', 'Seconds before audio stops automatically (1–86400)'),
            value: String(seconds),
            validateInput(input) {
                const parsed = Number(input);
                return Number.isInteger(parsed) && parsed >= 1 && parsed <= 86400
                    ? undefined
                    : localize('请输入 1 到 86400 之间的整数。', 'Enter a whole number from 1 to 86400.');
            }
        });
        if (value === undefined) {
            return;
        }
        seconds = Number(value);
    }

    updateBackendSettings((next) => {
        next.playback.mode = selected.mode;
        next.playback.seconds = seconds;
    });
    void vscode.window.showInformationMessage(localize(`播放方式已设置为：${selected.label}。`, `Playback mode set to ${selected.label}.`));
}

async function togglePlaybackMode() {
    const settings = readBackendSettings();
    ensurePlaybackSettings(settings);
    const index = playbackModes.indexOf(settings.playback.mode);
    const nextMode = playbackModes[(index + 1) % playbackModes.length];
    updateBackendSettings((next) => {
        next.playback.mode = nextMode;
    });
    const labels = { once: localize('播放一次', 'Play once'), loop: localize('循环播放', 'Loop'), seconds: localize('播放指定秒数', 'Play for a duration') };
    void vscode.window.showInformationMessage(localize(`播放方式已切换为：${labels[nextMode]}。`, `Playback mode changed to ${labels[nextMode]}.`));
}

async function toggleAnnouncement() {
    const settings = readBackendSettings();
    ensureAnnouncementSettings(settings);
    const enabled = !settings.announcement.enabled;
    updateBackendSettings((next) => {
        next.announcement.enabled = enabled;
    });
    void vscode.window.showInformationMessage(localize(`完成语音播报已${enabled ? '开启' : '关闭'}。`, `Spoken completion announcements ${enabled ? 'enabled' : 'disabled'}.`));
}

async function openSettings() {
    await vscode.commands.executeCommand(
        'workbench.action.openSettings',
        `@ext:${extensionManifest.publisher}.${extensionManifest.name}`
    );
}

function updateUi() {
    settingsItem.name = localize('Codex Finish Shout 设置', 'Codex Finish Shout Settings');
    const states = getRelevantActiveStates();
    const active = states.length > 0;
    setPlayingContext(active);

    if (!active) {
        statusItem.hide();
        settingsItem.hide();
        return;
    }

    const playingCount = states.filter((state) => state.status !== 'queued').length;
    const queuedCount = states.length - playingCount;
    if (states.length === 1) {
        statusItem.text = queuedCount === 1 ? localize('$(clock) 音乐排队中', '$(clock) Audio queued') : localize('$(mute) 停止音乐', '$(mute) Stop audio');
    } else {
        statusItem.text = localize(`$(mute) 管理音乐 (${states.length})`, `$(mute) Manage audio (${states.length})`);
    }
    statusItem.tooltip = states
        .map(
            (state) =>
                localize(`项目“${state.projectName || '当前项目'}”：${activityDescription(state)}`, `${state.projectName || 'Current project'}: ${activityDescription(state)}`)
        )
        .concat(queuedCount > 0 ? [localize(`${queuedCount} 个任务正在等待串行播放`, `${queuedCount} tasks waiting in the audio queue`)] : [])
        .join('\n');
    statusItem.show();
    settingsItem.text = localize('$(settings-gear) 音乐设置', '$(settings-gear) Audio settings');
    settingsItem.tooltip = localize('配置 Codex 完成音乐的播放方式', 'Configure Codex completion audio');
    settingsItem.show();

    for (const state of states) {
        if (seenSessionIds.has(state.sessionId)) {
            continue;
        }
        rememberSession(state.sessionId);
        const projectName = state.projectName || localize('当前项目', 'Current project');
        const description =
            state.status === 'queued'
                ? localize(`音乐已排队，稍后${playbackDescription(state)}`, `audio queued to ${playbackDescription(state)}`)
                : playbackDescription(state);
        const stopLabel = localize('停止音乐', 'Stop audio');
        const settingsLabel = localize('播放设置', 'Playback settings');
        void vscode.window
            .showInformationMessage(
                localize(`项目“${projectName}”的 Codex 任务已经执行结束，${description}。`, `Codex finished “${projectName}”; ${description}.`),
                stopLabel,
                settingsLabel
            )
            .then((selection) => {
                if (selection === stopLabel) {
                    return stopMusic(state.sessionId);
                }
                if (selection === settingsLabel) {
                    return configurePlayback();
                }
                return undefined;
            });
    }
}

async function manageBackend(action) {
    if (process.platform !== 'win32' || vscode.env.remoteName || vscode.workspace.isTrusted === false) return;
    if (action === 'Uninstall') {
        const remove = localize('卸载后端', 'Uninstall backend');
        if (await vscode.window.showWarningMessage(localize('移除本插件的 Hook 和运行文件，保留个人设置。随后请卸载或禁用扩展。', 'Remove this plugin’s hooks and runtime files, keeping your preferences. Then uninstall or disable the extension.'), { modal: true }, remove) !== remove) return;
        stopWorkspaceMonitoring();
    }
    try {
        const result = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification,
            title: localize('Codex 后端管理', 'Codex backend management') },
        () => runBackendAction(action, getCodexHomeDirectory(), extensionContext?.extensionPath || __dirname));
        if (action === 'Status') {
            const document = await vscode.workspace.openTextDocument({ language: 'json', content: JSON.stringify(result, null, 2) });
            await vscode.window.showTextDocument(document);
        } else if (action === 'Install') {
            syncConfiguredSettings();
            startWorkspaceMonitoring();
            updateAuthorizationStatusItem(getHookSetupStatus());
            const authorize = localize('打开授权', 'Open authorization');
            const selected = await vscode.window.showInformationMessage(localize('后端已安装。完成 Hook 授权后重新加载 VS Code。', 'Backend installed. Authorize the hooks, then reload VS Code.'), authorize);
            if (selected === authorize) await openHookAuthorization();
        } else {
            void vscode.window.showInformationMessage(localize('后端已卸载，个人设置已保留。请禁用或卸载此扩展。', 'Backend removed; preferences retained. Disable or uninstall this extension.'));
        }
        return result;
    } catch (error) {
        if (action === 'Uninstall') startWorkspaceMonitoring();
        void vscode.window.showErrorMessage(localize(`后端操作失败：${error.message}`, `Backend operation failed: ${error.message}`));
    }
}

async function activate(context) {
    extensionContext = context;
    if (process.platform !== 'win32' || vscode.env.remoteName || vscode.workspace.isTrusted === false) {
        void vscode.window.showWarningMessage(localize('此版本仅支持受信任的 Windows 本机工作区。', 'This release supports trusted local Windows workspaces only.'));
        return;
    }
    const legacy = vscode.extensions?.getExtension('local-developer.codex-finish-shout-controls');
    if (legacy?.isActive && extensionManifest.publisher !== 'local-developer') {
        void vscode.window.showWarningMessage(localize('请先禁用旧的 local-developer 版本并重新加载窗口，避免重复运行。', 'Disable the old local-developer extension and reload this window to avoid duplicate monitoring.'));
        return;
    }
    // Version 0.2 accidentally persisted the extension display name as a path.
    // Repair only that exact sentinel; user-selected paths are never rewritten.
    try {
        await repairLegacyStateDirectorySettings();
    } catch (error) {
        // The invalid value is still ignored even if VS Code cannot persist the cleanup.
        console.warn('Codex Finish Shout could not clear the legacy state directory setting.', error);
    }

    // Presence collection is independent of the optional status-bar UI. The
    // lease is published synchronously before the first detached reconciliation.
    startWorkspaceMonitoring();

    statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 1000);
    statusItem.command = 'codexFinishShout.stopMusic';
    statusItem.name = 'Codex Finish Shout';
    settingsItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 999);
    settingsItem.command = 'codexFinishShout.configurePlayback';
    settingsItem.name = localize('Codex Finish Shout 设置', 'Codex Finish Shout Settings');
    authorizationItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 1001);
    authorizationItem.command = 'codexFinishShout.openHookAuthorization';
    authorizationItem.name = localize('Codex Finish Shout 授权', 'Codex Finish Shout Authorization');
    projectMonitorItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 998);
    projectMonitorItem.command = 'codexFinishShout.openProjectMonitor';
    projectMonitorItem.name = localize('Codex 项目监控', 'Codex Project Monitor');
    context.subscriptions.push(statusItem, settingsItem, authorizationItem, projectMonitorItem);
    context.subscriptions.push(
        vscode.commands.registerCommand('codexFinishShout.initializeBackend', () => manageBackend('Install')),
        vscode.commands.registerCommand('codexFinishShout.repairBackend', () => manageBackend('Install')),
        vscode.commands.registerCommand('codexFinishShout.checkBackend', () => manageBackend('Status')),
        vscode.commands.registerCommand('codexFinishShout.uninstallBackend', () => manageBackend('Uninstall')),
        vscode.commands.registerCommand('codexFinishShout.stopMusic', stopMusic),
        vscode.commands.registerCommand('codexFinishShout.configurePlayback', configurePlayback),
        vscode.commands.registerCommand('codexFinishShout.chooseCompletionMusic', configureMusic),
        vscode.commands.registerCommand('codexFinishShout.togglePlaybackMode', togglePlaybackMode),
        vscode.commands.registerCommand('codexFinishShout.toggleAnnouncement', toggleAnnouncement),
        vscode.commands.registerCommand('codexFinishShout.openProjectMonitor', openProjectMonitor),
        vscode.commands.registerCommand(
            'codexFinishShout.toggleProjectMonitorStatusBar',
            toggleProjectMonitorStatusBar
        ),
        vscode.commands.registerCommand('codexFinishShout.openSettings', openSettings),
        vscode.commands.registerCommand(
            'codexFinishShout.openHookAuthorization',
            openHookAuthorization
        )
    );
    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration((event) => {
            if (event.affectsConfiguration('codexFinishShout')) {
                refreshProjectMonitorAppearance();
                if (['configPath', 'completionSound', 'audioFile', 'playbackMode', 'playbackSeconds', 'maximumPlaybackSeconds',
                    'volume', 'announcementEnabled', 'announcementTemplate', 'announcementRate']
                    .some((key) => event.affectsConfiguration(`codexFinishShout.${key}`))) {
                    syncConfiguredSettings();
                }
                updateUi();
                updateAuthorizationStatusItem(getHookSetupStatus());
                refreshProjectMonitor(true);
                if (
                    event.affectsConfiguration('codexFinishShout.stateDirectory') ||
                    event.affectsConfiguration('codexFinishShout.configPath')
                ) {
                    publishCurrentWorkspaceLease();
                    launchMonitorSyncWorker();
                }
            }
        }),
        vscode.workspace.onDidChangeWorkspaceFolders(() => {
            updateUi();
            publishCurrentWorkspaceLease();
            // A no-folder window has no valid workspace lease, so its worker
            // can legitimately exit. Wake it immediately when a folder is
            // opened instead of waiting for the 60-second ensure interval.
            launchMonitorSyncWorker();
        })
    );

    syncConfiguredSettings();
    updateUi();
    refreshProjectMonitor(true);
    await refreshHookAuthorization(context, true);
    const installed = readJson(path.join(getCodexHomeDirectory(), 'codex-finish-shout', 'install-state.json'));
    if (!process.env.CODEX_FINISH_SHOUT_DEV_ROOT && installed?.pluginVersion !== extensionManifest.version) {
        const initialize = localize('初始化／修复后端', 'Initialize / Repair Backend');
        void vscode.window.showInformationMessage(localize('安装或更新内置后端以启用完成音乐。已有配置会备份并保留。', 'Install or update the bundled backend to enable completion music. Existing settings will be backed up and preserved.'), initialize)
            .then(selection => { if (selection === initialize) return manageBackend('Install'); });
    }
    pollTimer = setInterval(updateUi, 500);
    // Monitoring is intentionally independent from the optional status-bar display.
    projectMonitorPollTimer = setInterval(refreshProjectMonitor, projectMonitorPollIntervalMs);
    authorizationPollTimer = setInterval(
        () => void refreshHookAuthorization(context, false),
        2000
    );
    context.subscriptions.push({
        dispose() {
            clearInterval(pollTimer);
            pollTimer = undefined;
            clearInterval(authorizationPollTimer);
            authorizationPollTimer = undefined;
            clearInterval(projectMonitorPollTimer);
            projectMonitorPollTimer = undefined;
            stopWorkspaceMonitoring();
            setPlayingContext(false);
        }
    });
}

function deactivate() {
    stopWorkspaceMonitoring();
    if (pollTimer) {
        clearInterval(pollTimer);
        pollTimer = undefined;
    }
    if (authorizationPollTimer) {
        clearInterval(authorizationPollTimer);
        authorizationPollTimer = undefined;
    }
    if (projectMonitorPollTimer) {
        clearInterval(projectMonitorPollTimer);
        projectMonitorPollTimer = undefined;
    }
    if (statusItem) {
        statusItem.dispose();
    }
    if (settingsItem) {
        settingsItem.dispose();
    }
    if (authorizationItem) {
        authorizationItem.dispose();
    }
    if (projectMonitorItem) {
        projectMonitorItem.dispose();
    }
    if (projectMonitorPanel) {
        projectMonitorPanel.dispose();
        projectMonitorPanel = undefined;
    }
}

module.exports = {
    activate,
    deactivate,
    getProjectMonitorWebviewHtml,
    getProjectMonitorAppearance,
    openProjectMonitor,
    updateProjectMonitorAppearance,
    configurePlayback,
    configureMusic,
    saveCompletionSound,
    isLegacyInvalidStateDirectory,
    repairLegacyStateDirectorySettings,
    selectStateDirectorySetting
};
