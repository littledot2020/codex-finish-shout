const fs = require('fs');
const path = require('path');

// Pure state-discovery helpers live outside extension.js so PID freshness,
// rolling-schema compatibility, and workspace matching can be tested in Node.

const legacyStateFileName = 'audio-player.json';
const sessionStateFilePattern = /^audio-player-[^.]+\.json$/;

function readJson(filePath) {
    try {
        return JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch (_) {
        return null;
    }
}

function getStateFilePaths(stateDirectory) {
    try {
        return fs
            .readdirSync(stateDirectory, { withFileTypes: true })
            .filter(
                (entry) =>
                    entry.isFile() &&
                    (entry.name === legacyStateFileName || sessionStateFilePattern.test(entry.name))
            )
            .map((entry) => path.join(stateDirectory, entry.name))
            .sort((left, right) => {
                const leftLegacy = path.basename(left) === legacyStateFileName;
                const rightLegacy = path.basename(right) === legacyStateFileName;
                if (leftLegacy !== rightLegacy) {
                    return leftLegacy ? -1 : 1;
                }
                return left.localeCompare(right);
            });
    } catch (_) {
        return [];
    }
}

function readPlaybackStates(stateDirectory) {
    const bySession = new Map();
    for (const stateFilePath of getStateFilePaths(stateDirectory)) {
        const state = readJson(stateFilePath);
        if (!state || !state.sessionId || !state.pid) {
            continue;
        }
        bySession.set(String(state.sessionId), { ...state, stateFilePath });
    }
    return Array.from(bySession.values());
}

function defaultIsProcessAlive(pid) {
    try {
        process.kill(Number(pid), 0);
        return true;
    } catch (_) {
        return false;
    }
}

function isRecentEnough(state, now = Date.now()) {
    const reference = Date.parse(state.playbackStartedUtc || state.startedUtc || '');
    if (!Number.isFinite(reference)) {
        return true;
    }

    if (state.status === 'queued') {
        // A queued player owns a live process and may legitimately wait behind a
        // long loop. This age check only protects against stale PID reuse.
        return now - reference <= 7 * 24 * 60 * 60 * 1000;
    }

    const maximumSeconds = Number(state.maximumPlaybackSeconds) || 3600;
    return now - reference <= (maximumSeconds + 30) * 1000;
}

function isActiveState(state, isProcessAlive = defaultIsProcessAlive, now = Date.now()) {
    const pid = Number(state && state.pid);
    return (
        Boolean(state && state.sessionId) &&
        Number.isInteger(pid) &&
        pid > 0 &&
        isRecentEnough(state, now) &&
        isProcessAlive(pid)
    );
}

function normalizeComparablePath(value) {
    if (typeof value !== 'string' || !value.trim()) {
        return null;
    }
    try {
        let normalized = path.resolve(value);
        const root = path.parse(normalized).root;
        if (normalized.length > root.length) {
            normalized = normalized.replace(/[\\/]+$/, '');
        }
        return process.platform === 'win32' ? normalized.toLocaleLowerCase('en-US') : normalized;
    } catch (_) {
        return null;
    }
}

function isSameOrInside(candidatePath, rootPath) {
    const candidate = normalizeComparablePath(candidatePath);
    const root = normalizeComparablePath(rootPath);
    if (!candidate || !root) {
        return false;
    }
    const relative = path.relative(root, candidate);
    return (
        relative === '' ||
        (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative))
    );
}

function projectMatchesWorkspace(projectPath, workspacePath) {
    // Match both directions: a task may run in a workspace subfolder, while a
    // VS Code root may itself be a child of the task's reported repository cwd.
    return (
        isSameOrInside(projectPath, workspacePath) ||
        isSameOrInside(workspacePath, projectPath)
    );
}

function filterStatesForWorkspace(states, workspacePaths) {
    const roots = (workspacePaths || []).filter((value) => normalizeComparablePath(value));
    if (roots.length === 0) {
        return states.slice();
    }

    return states.filter((state) => {
        // Schema v1 did not publish projectPath. Keep it visible during rolling
        // upgrades instead of making the stop control disappear.
        if (!normalizeComparablePath(state.projectPath)) {
            return true;
        }
        return roots.some((root) => projectMatchesWorkspace(state.projectPath, root));
    });
}

function stateTimestamp(state) {
    const parsed = Date.parse(
        state.playbackStartedUtc || state.queuedUtc || state.startedUtc || state.updatedUtc || ''
    );
    return Number.isFinite(parsed) ? parsed : 0;
}

function sortPlaybackStates(states) {
    const statusRank = { playing: 0, queued: 1 };
    return states.slice().sort((left, right) => {
        const leftRank = statusRank[left.status] ?? 2;
        const rightRank = statusRank[right.status] ?? 2;
        return leftRank - rightRank || stateTimestamp(right) - stateTimestamp(left);
    });
}

module.exports = {
    filterStatesForWorkspace,
    getStateFilePaths,
    isActiveState,
    isRecentEnough,
    normalizeComparablePath,
    projectMatchesWorkspace,
    readPlaybackStates,
    sortPlaybackStates
};
