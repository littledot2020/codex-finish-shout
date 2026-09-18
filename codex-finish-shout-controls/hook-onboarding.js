const fs = require('fs');
const path = require('path');

// Keep this identifier stable across ordinary releases. Change it only when
// the installed Hook command changes and Codex must ask for trust again.
const hookDefinitionId = 'lifecycle-v2';
const hookDescription = 'Codex Finish Shout lifecycle state guard';
const hookScriptName = 'codex-finish-shout-hook.ps1';
const readyMarkerName = 'lifecycle-hook-ready.json';
const hooksSettingsUri = 'vscode://openai.chatgpt/settings/hooks-settings?source=user';
const requiredHookEvents = [
    'SessionStart',
    'SessionEnd',
    'UserPromptSubmit',
    'SubagentStart',
    'SubagentStop',
    'Stop'
];

function parseJson(value) {
    if (value && typeof value === 'object') {
        return value;
    }
    if (typeof value !== 'string' || !value.trim()) {
        return null;
    }
    try {
        return JSON.parse(value);
    } catch (_) {
        return null;
    }
}

function handlerCommand(handler) {
    if (!handler || typeof handler !== 'object') {
        return '';
    }
    return [handler.command, handler.commandWindows, handler.command_windows]
        .filter((value) => typeof value === 'string')
        .join('\n');
}

function isOwnedHookHandler(handler) {
    return handlerCommand(handler).toLocaleLowerCase('en-US').includes(hookScriptName);
}

function commandHasDefinitionId(command, definitionId = hookDefinitionId) {
    if (typeof command !== 'string') {
        return false;
    }
    const escaped = definitionId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return new RegExp(`-DefinitionId\\s+(?:"${escaped}"|'${escaped}'|${escaped})(?:\\s|$)`, 'i').test(
        command
    );
}

function eventHasOwnedHandler(hooks, eventName, definitionId) {
    const groups = hooks && Array.isArray(hooks[eventName]) ? hooks[eventName] : [];
    return groups.some((group) => {
        const handlers = group && Array.isArray(group.hooks) ? group.hooks : [];
        return handlers.some((handler) => {
            const command = handlerCommand(handler);
            return isOwnedHookHandler(handler) && commandHasDefinitionId(command, definitionId);
        });
    });
}

function inspectHookConfiguration(value, definitionId = hookDefinitionId) {
    const document = parseJson(value);
    const hooks = document && document.hooks && typeof document.hooks === 'object'
        ? document.hooks
        : null;
    const installed = Boolean(
        hooks &&
            requiredHookEvents.some((eventName) => {
                const groups = Array.isArray(hooks[eventName]) ? hooks[eventName] : [];
                return groups.some((group) =>
                    Array.isArray(group && group.hooks) && group.hooks.some(isOwnedHookHandler)
                );
            })
    );
    const missingEvents = hooks
        ? requiredHookEvents.filter(
              (eventName) => !eventHasOwnedHandler(hooks, eventName, definitionId)
          )
        : requiredHookEvents.slice();

    return {
        installed,
        configured: installed && missingEvents.length === 0,
        missingEvents
    };
}

function inspectReadyMarker(value, definitionId = hookDefinitionId) {
    const marker = parseJson(value);
    const valid = Boolean(
        marker &&
            marker.guard === hookDescription &&
            marker.definitionId === definitionId &&
            Number.isFinite(Date.parse(marker.observedUtc || ''))
    );
    return {
        valid,
        eventName: valid && typeof marker.eventName === 'string' ? marker.eventName : null,
        observedUtc: valid ? marker.observedUtc : null
    };
}

function evaluateHookSetup({ hooksContent, readyMarkerContent, definitionId = hookDefinitionId }) {
    const configuration = inspectHookConfiguration(hooksContent, definitionId);
    const marker = inspectReadyMarker(readyMarkerContent, definitionId);
    let reason = 'ready';
    if (!configuration.installed) {
        reason = 'not-installed';
    } else if (!configuration.configured) {
        reason = 'upgrade-required';
    } else if (!marker.valid) {
        reason = 'authorization-required';
    }
    return {
        ready: reason === 'ready',
        reason,
        configuration,
        marker,
        definitionId
    };
}

function readText(filePath) {
    try {
        return fs.readFileSync(filePath, 'utf8');
    } catch (_) {
        return null;
    }
}

function readHookSetupStatus({ hooksPath, stateDirectory, definitionId = hookDefinitionId }) {
    return evaluateHookSetup({
        hooksContent: readText(hooksPath),
        readyMarkerContent: readText(path.join(stateDirectory, readyMarkerName)),
        definitionId
    });
}

function supportsGraphicalHookReview(codexExtensionPath) {
    if (typeof codexExtensionPath !== 'string' || !codexExtensionPath) {
        return false;
    }
    try {
        return fs
            .readdirSync(path.join(codexExtensionPath, 'webview', 'assets'))
            .some((name) => /^hooks-settings-route-.*\.js$/i.test(name));
    } catch (_) {
        return false;
    }
}

function findBundledCodexExecutable(codexExtensionPath, platform = process.platform) {
    if (typeof codexExtensionPath !== 'string' || !codexExtensionPath) {
        return null;
    }
    const executableName = platform === 'win32' ? 'codex.exe' : 'codex';
    const binDirectory = path.join(codexExtensionPath, 'bin');
    try {
        const candidates = fs
            .readdirSync(binDirectory, { withFileTypes: true })
            .filter((entry) => entry.isDirectory())
            .map((entry) => path.join(binDirectory, entry.name, executableName))
            .filter((candidate) => fs.existsSync(candidate));
        return candidates[0] || null;
    } catch (_) {
        return null;
    }
}

module.exports = {
    evaluateHookSetup,
    findBundledCodexExecutable,
    hookDefinitionId,
    hookDescription,
    hooksSettingsUri,
    inspectHookConfiguration,
    inspectReadyMarker,
    isOwnedHookHandler,
    readHookSetupStatus,
    readyMarkerName,
    requiredHookEvents,
    supportsGraphicalHookReview
};
