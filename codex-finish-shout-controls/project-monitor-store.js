const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { enrichAgentTasks, toTaskTitle } = require('./agent-task-titles');

const projectMonitorSchemaVersion = 1;
const projectStatuses = new Set(['running', 'completed']);
const agentStatuses = new Set(['running', 'stopped', 'ended', 'unknown']);

function text(value) {
    return typeof value === 'string' ? value.trim() : '';
}

function utc(value) {
    return text(value) && Number.isFinite(Date.parse(value)) ? value : '';
}

function normalizeSessions(sessions) {
    if (!Array.isArray(sessions)) return [];
    const seenSessions = new Set();
    return sessions.flatMap((session) => {
        if (!session || typeof session !== 'object') return [];
        const threadHash = text(session.threadHash);
        const sessionId = text(session.sessionId) || threadHash;
        if (!sessionId || seenSessions.has(sessionId)) return [];
        seenSessions.add(sessionId);
        const seenAgents = new Set();
        const entries = Array.isArray(session.agents) ? session.agents : [];
        const agents = entries.flatMap((agent) => {
            if (!agent || typeof agent !== 'object') return [];
            const agentId = text(agent.agentId);
            if (!agentId || seenAgents.has(agentId)) return [];
            seenAgents.add(agentId);
            const role = agentId === sessionId ? 'main' : 'subagent';
            return [{
                agentId,
                shortId: crypto.createHash('sha256').update(sessionId + ':' + agentId).digest('hex').slice(0, 10),
                parentAgentId: role === 'main' ? '' : (text(agent.parentAgentId) || sessionId),
                role,
                agentType: toTaskTitle(agent.agentType),
                taskTitle: toTaskTitle(agent.taskTitle),
                titleSource: ['prompt', 'explicit', 'transcript'].includes(agent.titleSource) ? agent.titleSource : '',
                status: agentStatuses.has(agent.status) ? agent.status : 'unknown',
                turnId: text(agent.turnId),
                startedAtUtc: utc(agent.startedAtUtc),
                updatedAtUtc: utc(agent.updatedAtUtc),
                transcriptPath: text(agent.transcriptPath)
            }];
        });
        // Old snapshots identify sessions but cannot prove an individual agent's state.
        if (!agents.some((agent) => agent.role === 'main')) {
            agents.unshift({
                agentId: sessionId,
                shortId: crypto.createHash('sha256').update(sessionId + ':' + sessionId).digest('hex').slice(0, 10),
                parentAgentId: '', role: 'main', agentType: '', taskTitle: '', titleSource: '',
                status: 'unknown', turnId: '', startedAtUtc: '', updatedAtUtc: '', transcriptPath: ''
            });
        }
        agents.sort((left, right) => {
            if (left.role !== right.role) return left.role === 'main' ? -1 : 1;
            if ((left.status === 'running') !== (right.status === 'running')) return left.status === 'running' ? -1 : 1;
            return (Date.parse(right.updatedAtUtc) || 0) - (Date.parse(left.updatedAtUtc) || 0) || left.agentId.localeCompare(right.agentId);
        });
        return [{ threadHash, sessionId, sessionTitle: toTaskTitle(session.sessionTitle),
            transcriptPath: text(session.transcriptPath), agents }];
    });
}

function requireText(value, fieldName, index) {
    if (typeof value !== 'string' || !value.trim()) {
        throw new TypeError(`projects[${index}].${fieldName} must be a non-empty string`);
    }
    return value.trim();
}

function normalizeProject(project, index) {
    if (!project || typeof project !== 'object' || Array.isArray(project)) {
        throw new TypeError(`projects[${index}] must be an object`);
    }

    const projectKey = requireText(project.projectKey, 'projectKey', index);
    // `projectPath` is the persisted v1 field. Accept `path` as a compatibility
    // alias and expose one stable `path` property to the Webview.
    const projectPath = requireText(project.projectPath || project.path, 'projectPath', index);
    const status = requireText(project.status, 'status', index);
    const updatedAtUtc = requireText(project.updatedAtUtc, 'updatedAtUtc', index);
    if (!projectStatuses.has(status)) {
        throw new TypeError(`projects[${index}].status must be running or completed`);
    }
    if (!Number.isFinite(Date.parse(updatedAtUtc))) {
        throw new TypeError(`projects[${index}].updatedAtUtc must be an ISO date`);
    }

    const sessions = normalizeSessions(project.sessions);
    return {
        projectKey,
        name: requireText(project.name, 'name', index),
        path: projectPath,
        status,
        updatedAtUtc,
        eventId: typeof project.eventId === 'string' ? project.eventId : '',
        message: typeof project.message === 'string' ? project.message : '',
        sessions,
        agentCount: sessions.reduce((sum, session) => sum + session.agents.length, 0),
        runningAgentCount: sessions.reduce((sum, session) => sum + session.agents.filter((agent) => agent.status === 'running').length, 0)
    };
}

function compareProjects(left, right) {
    if (left.status !== right.status) {
        return left.status === 'running' ? -1 : 1;
    }
    const updatedDifference = Date.parse(right.updatedAtUtc) - Date.parse(left.updatedAtUtc);
    return updatedDifference || left.name.localeCompare(right.name, 'zh-CN');
}

function normalizeProjectMonitorSnapshot(snapshot, sourcePath = '') {
    if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) {
        throw new TypeError('Project monitor snapshot must be an object');
    }
    if (snapshot.schemaVersion !== projectMonitorSchemaVersion) {
        throw new TypeError(`Unsupported project monitor schema: ${snapshot.schemaVersion}`);
    }
    if (!Array.isArray(snapshot.projects)) {
        throw new TypeError('Project monitor snapshot must contain a projects array');
    }

    const projects = snapshot.projects.map(normalizeProject).sort(compareProjects);
    const runningCount = projects.filter((project) => project.status === 'running').length;
    const completedCount = projects.length - runningCount;
    return {
        kind: projects.length > 0 ? 'ready' : 'empty',
        schemaVersion: projectMonitorSchemaVersion,
        sourcePath,
        projects,
        runningCount,
        completedCount,
        totalCount: projects.length,
        error: ''
    };
}

function emptyProjectMonitorState(sourcePath) {
    return {
        kind: 'empty',
        schemaVersion: projectMonitorSchemaVersion,
        sourcePath,
        projects: [],
        runningCount: 0,
        completedCount: 0,
        totalCount: 0,
        error: ''
    };
}

function errorProjectMonitorState(sourcePath, error) {
    return {
        kind: 'error',
        schemaVersion: projectMonitorSchemaVersion,
        sourcePath,
        projects: [],
        runningCount: 0,
        completedCount: 0,
        totalCount: 0,
        error: error && error.message ? error.message : String(error)
    };
}

function readProjectMonitorState(sourcePath) {
    try {
        const content = fs.readFileSync(sourcePath, 'utf8');
        const state = normalizeProjectMonitorSnapshot(JSON.parse(content.replace(/^\uFEFF/, '')), sourcePath);
        enrichAgentTasks(state);
        for (const project of state.projects) {
            project.runningAgentCount = project.sessions.reduce((sum, session) =>
                sum + session.agents.filter((agent) => agent.status === 'running').length, 0);
        }
        return state;
    } catch (error) {
        if (error && error.code === 'ENOENT') {
            return emptyProjectMonitorState(sourcePath);
        }
        return errorProjectMonitorState(sourcePath, error);
    }
}

function getProjectMonitorPath(stateDirectory) {
    return path.join(stateDirectory, 'project-monitor.json');
}

function formatProjectMonitorStatusText(state, language = 'zh') {
    if (state.kind === 'error') {
        return language === 'en' ? '$(warning) Codex monitor error' : '$(warning) Codex 监控异常';
    }
    if (language === 'en') return `$(pulse) Codex ${state.runningCount} running · ${state.completedCount} done`;
    return `$(pulse) Codex ${state.runningCount}运行 · ${state.completedCount}完成`;
}

module.exports = {
    formatProjectMonitorStatusText,
    getProjectMonitorPath,
    normalizeProjectMonitorSnapshot,
    projectMonitorSchemaVersion,
    readProjectMonitorState
};
