const fs = require('node:fs');
const path = require('node:path');

// Hooks own the completion guard. These bounded local reads enrich labels and
// can correct display state when a reused child's Hooks omit its new turn.
const maxReadBytes = 512 * 1024;
const maxPollBytes = 2 * 1024 * 1024;
const maxLineBytes = 256 * 1024;
const maxCacheEntries = 64;
const transcriptCache = new Map();

function toTaskTitle(value) {
    if (typeof value !== 'string') return '';
    let text = value.slice(0, 32768).replace(/\r/g, '');
    if (/^\s*#\s*(?:AGENTS\.md instructions|Skill instructions)/i.test(text)) return '';
    for (const tag of ['environment_context', 'INSTRUCTIONS', 'permissions_instructions',
        'skills_instructions', 'recommended_plugins', 'user_instructions', 'system_instructions']) {
        text = text.replace(new RegExp('<' + tag + '(?:\\s[^>]*)?>[\\s\\S]*?(?:<\\/' + tag + '>|$)', 'gi'), '');
    }
    for (let line of text.split('\n')) {
        line = line.replace(/^\s*(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+)/, '')
            .replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, '')
            .replace(/\s+/g, ' ').trim();
        if (!line || /^<[^>]+>\s*$/.test(line) || /^```/.test(line)) continue;
        const chars = Array.from(line);
        return chars.length > 80 ? chars.slice(0, 79).join('') + '…' : line;
    }
    return '';
}

function parseJson(value) {
    if (typeof value !== 'string') return value;
    try { return JSON.parse(value); } catch { return null; }
}

function messageText(content) {
    if (typeof content === 'string') return content;
    return Array.isArray(content) ? content.filter((part) => part
        && ['input_text', 'text'].includes(part.type) && typeof part.text === 'string')
        .map((part) => part.text).join('\n') : '';
}

function localTranscriptPath(filePath) {
    if (typeof filePath !== 'string') return false;
    // Windows extended local paths are valid; network/device paths are not.
    const local = filePath.replace(/^\\\\\?\\(?=[a-z]:\\)/i, '');
    return path.isAbsolute(local) && !/^(?:\\\\|\/\/)/.test(local)
        && path.extname(local).toLowerCase() === '.jsonl';
}

function boundedSet(map, key, value, maximum = 256) {
    map.delete(key);
    map.set(key, value);
    while (map.size > maximum) map.delete(map.keys().next().value);
}

function newer(left, right) {
    if (!left) return right;
    if (!right) return left;
    const difference = (Date.parse(right.timestamp) || 0) - (Date.parse(left.timestamp) || 0);
    return difference > 0 || (difference === 0 && right.order >= left.order) ? right : left;
}

function taskPath(state, target) {
    if (typeof target !== 'string' || !target || target.length > 240) return '';
    if (target.startsWith('/')) return target;
    return (state.agentPath || '/root') + '/' + target;
}

function linkAgent(state, id, agentPath = '', taskName = '') {
    const aliases = [id, agentPath, taskName, taskName && taskPath(state, taskName)].filter(Boolean);
    const key = id || state.aliases.get(agentPath) || state.aliases.get(taskName) || agentPath || taskName;
    if (!key) return '';
    let task = state.tasks.get(key);
    for (const alias of aliases) {
        const oldKey = state.aliases.get(alias) || alias;
        task = newer(task, state.tasks.get(oldKey));
        if (oldKey !== key) state.tasks.delete(oldKey);
        boundedSet(state.aliases, alias, key, 512);
    }
    if (task) {
        task = { ...task, agentPath: agentPath || task.agentPath, taskName: taskName || task.taskName };
        boundedSet(state.tasks, key, task);
    }
    return key;
}

function rememberTask(state, id, task) {
    if (!id || !task.title) return;
    const key = state.aliases.get(id) || id;
    const previous = state.tasks.get(key);
    boundedSet(state.tasks, key, newer(previous, { ...task,
        agentPath: task.agentPath || previous?.agentPath || '',
        taskName: task.taskName || previous?.taskName || '' }));
}

function applyCall(state, call, id = '', agentPath = '') {
    const target = id || call.target;
    const canonicalPath = agentPath || (target.startsWith('/') ? target : '')
        || (call.name === 'spawn_agent' ? taskPath(state, call.taskName) : '');
    const key = linkAgent(state, id, canonicalPath, call.taskName || call.target);
    if (!key && !target) return;
    rememberTask(state, key || target, {
        title: call.title || call.taskName,
        timestamp: call.timestamp, turnId: '', order: call.order,
        explicit: !call.title, agentPath: canonicalPath, taskName: call.taskName
    });
}

function consumeRecord(state, record) {
    if (!record || typeof record !== 'object' || !record.payload || typeof record.payload !== 'object') return;
    const payload = record.payload;
    const timestamp = typeof record.timestamp === 'string' ? record.timestamp : '';
    state.order += 1;
    if (!state.identitySeen) {
        state.identitySeen = true;
        if (record.type !== 'session_meta' || typeof payload.id !== 'string' || !payload.id) {
            state.invalid = true;
            return;
        }
        state.sessionId = payload.id;
        const source = payload.source && typeof payload.source === 'object' ? payload.source.subagent : null;
        state.parentId = payload.parent_thread_id || source?.thread_spawn?.parent_thread_id
            || source?.spawn?.parent_thread_id || source?.parent_thread_id || '';
        state.isChild = Boolean(state.parentId || source || payload.thread_source === 'subagent');
        state.agentPath = payload.agent_path || source?.thread_spawn?.agent_path || source?.spawn?.agent_path || '';
        state.sessionTitle = toTaskTitle(payload.title || payload.session_title);
        state.ownHistory = !state.isChild;
        return;
    }
    // Child task delivery identifies the real turn even when its preceding
    // task_started is interleaved with copied ancestor history.
    if (record.type === 'session_meta' || state.invalid) return;
    if (state.isChild && record.type === 'event_msg' && payload.type === 'task_started' && payload.turn_id) {
        boundedSet(state.turnStarts, payload.turn_id, { timestamp, order: state.order }, 64);
    }
    if (state.isChild && record.type === 'response_item' && payload.type === 'agent_message'
        && state.agentPath && payload.recipient === state.agentPath
        && /^Message Type: NEW_TASK\b/.test(messageText(payload.content))) {
        state.ownHistory = true;
        state.ownTurnId = payload.internal_chat_message_metadata_passthrough?.turn_id || '';
        const started = state.turnStarts.get(state.ownTurnId);
        state.execution = started ? { status: 'running', timestamp, turnId: state.ownTurnId,
            startedAtUtc: started.timestamp, taskReceivedAtUtc: timestamp, order: state.order } : null;
    }
    if (state.isChild && !state.ownHistory) {
        return;
    }
    if (state.isChild && record.type === 'event_msg' && payload.type === 'task_complete'
        && payload.turn_id && payload.turn_id === state.ownTurnId && state.execution) {
        state.execution = newer(state.execution, { ...state.execution, status: 'stopped', timestamp, order: state.order });
    }
    if (record.type === 'turn_context' || (record.type === 'event_msg' && payload.type === 'task_started')) {
        state.currentTurnId = payload.turn_id || '';
        return;
    }
    let prompt = '';
    if (!state.isChild && record.type === 'event_msg' && payload.type === 'user_message') prompt = payload.message;
    if (!state.isChild && record.type === 'response_item' && payload.type === 'message' && payload.role === 'user') {
        prompt = messageText(payload.content);
    }
    const title = toTaskTitle(prompt);
    if (title) {
        const turnId = payload.turn_id || payload.internal_chat_message_metadata_passthrough?.turn_id || state.currentTurnId;
        state.task = newer(state.task, { title, timestamp, turnId, order: state.order, explicit: false });
        if (!state.sessionTitle) state.sessionTitle = title;
    }
    if (record.type === 'response_item' && payload.type === 'function_call') {
        const name = String(payload.name || '').split('.').pop();
        // send_message only supplies context; it does not assign a new task.
        if (!['spawn_agent', 'send_input', 'followup_task'].includes(name) || !payload.call_id) return;
        const args = parseJson(payload.arguments);
        if (!args || typeof args !== 'object') return;
        const target = typeof (args.id || args.target || args.agent_id) === 'string' ? (args.id || args.target || args.agent_id) : '';
        boundedSet(state.calls, payload.call_id, {
            name, target: target.slice(0, 240), title: toTaskTitle(args.message || args.prompt || args.task || messageText(args.items)),
            taskName: toTaskTitle(args.task_name || args.name), timestamp, order: state.order
        });
    }
    if (record.type === 'event_msg' && payload.type === 'sub_agent_activity') {
        const id = typeof payload.agent_thread_id === 'string' ? payload.agent_thread_id : '';
        const agentPath = typeof payload.agent_path === 'string' ? payload.agent_path : '';
        if (!id) return;
        linkAgent(state, id, agentPath, agentPath.split('/').pop());
        const call = state.calls.get(payload.event_id);
        if (call && ['started', 'interacted'].includes(payload.kind)) applyCall(state, call, id, agentPath);
    }
    if (record.type === 'response_item' && payload.type === 'function_call_output') {
        const call = state.calls.get(payload.call_id);
        if (!call) return;
        const result = parseJson(payload.output);
        if ((result && (result.error || result.isError)) || (payload.output && !result)) {
            state.calls.delete(payload.call_id);
            return;
        }
        const id = result?.agent_id || result?.agent_thread_id || '';
        const agentPath = result?.task_name || result?.agent_path || '';
        // Empty output is the normal successful followup_task response.
        if (id || agentPath || call.name !== 'spawn_agent') applyCall(state, call, id, agentPath);
    }
}

function consumeBytes(state, buffer) {
    let start = 0;
    for (let newline = buffer.indexOf(10); newline >= 0; newline = buffer.indexOf(10, start)) {
        const part = buffer.subarray(start, newline);
        if (!state.skippingLine && state.pending.length + part.length <= maxLineBytes) {
            const line = state.pending.length ? Buffer.concat([state.pending, part]) : part;
            const text = line.toString('utf8').replace(/^\uFEFF/, '');
            const record = parseJson(text);
            if (!state.identitySeen && text.trim() && !record) state.invalid = true;
            else consumeRecord(state, record);
        } else if (!state.identitySeen) {
            state.invalid = true;
        }
        state.pending = Buffer.alloc(0);
        state.skippingLine = false;
        start = newline + 1;
        if (state.invalid) return;
    }
    const tail = buffer.subarray(start);
    if (state.skippingLine || state.pending.length + tail.length > maxLineBytes) {
        state.pending = Buffer.alloc(0);
        state.skippingLine = true;
    } else if (tail.length) {
        // Only a bounded unfinished JSON line survives a poll, never a complete prompt.
        state.pending = Buffer.concat([state.pending, tail]);
    }
}

function readTranscript(filePath, expectedId, budget = { remaining: maxReadBytes }) {
    if (!localTranscriptPath(filePath) || !expectedId) return null;
    let fd;
    try {
        const stat = fs.statSync(filePath);
        if (!stat.isFile()) return null;
        let state = transcriptCache.get(filePath);
        if (state && (stat.size < state.size
            || stat.ino !== state.ino || state.birthtimeMs !== stat.birthtimeMs
            || (stat.size === state.size && stat.mtimeMs !== state.mtimeMs))) state = null;
        if (!state) {
            state = { filePath, sessionId: '', parentId: '', agentPath: '', sessionTitle: '', task: null,
                tasks: new Map(), calls: new Map(), aliases: new Map(), currentTurnId: '', order: 0,
                turnStarts: new Map(), ownTurnId: '', execution: null,
                offset: 0, size: 0, mtimeMs: 0, birthtimeMs: stat.birthtimeMs, ino: stat.ino,
                pending: Buffer.alloc(0), skippingLine: false, identitySeen: false, invalid: false, complete: false };
        }
        state.complete = false;
        if (!state.invalid && state.offset < stat.size) {
            if (!budget.bytesByPath) budget.bytesByPath = new Map();
            const alreadyRead = budget.bytesByPath.get(filePath) || 0;
            const available = Math.min(maxReadBytes - alreadyRead, Math.max(0, budget.remaining), stat.size - state.offset);
            if (!available) return null;
            fd = fs.openSync(filePath, 'r');
            const buffer = Buffer.alloc(available);
            const count = fs.readSync(fd, buffer, 0, available, state.offset);
            budget.remaining -= count;
            budget.bytesByPath.set(filePath, alreadyRead + count);
            consumeBytes(state, buffer.subarray(0, count));
            state.offset += count;
        }
        state.size = stat.size;
        state.mtimeMs = stat.mtimeMs;
        state.complete = state.offset === stat.size && !state.pending.length && !state.skippingLine;
        if (budget.monitoredPaths) budget.monitoredPaths.add(filePath);
        boundedSet(transcriptCache, filePath, state, budget.monitoredPaths ? budget.monitoredPaths.size : maxCacheEntries);
        // Progressive cold reads must catch up before exposing labels: a later
        // unseen turn may have replaced any title found in the current chunk.
        return state.complete && state.identitySeen && !state.invalid && state.sessionId === expectedId ? state : null;
    } catch {
        transcriptCache.delete(filePath);
        return null;
    } finally {
        if (fd !== undefined) fs.closeSync(fd);
    }
}

function findSiblingTranscript(filePath, sessionId, directoryCache) {
    if (!localTranscriptPath(filePath) || !/^[a-zA-Z0-9_-]{1,120}$/.test(sessionId)) return '';
    try {
        const directory = path.dirname(filePath);
        let entries = directoryCache?.get(directory);
        if (!entries) {
            entries = fs.readdirSync(directory);
            if (directoryCache) directoryCache.set(directory, entries);
        }
        const name = entries.find((entry) => entry.startsWith('rollout-') && entry.endsWith('-' + sessionId + '.jsonl'));
        return name ? path.join(directory, name) : '';
    } catch { return ''; }
}

function agentTask(transcript, agent) {
    if (agent.role === 'main') return transcript.sessionId === agent.agentId ? transcript.task : null;
    for (const id of [agent.agentId, agent.agentPath, agent.taskName].filter(Boolean)) {
        const task = transcript.tasks.get(transcript.aliases.get(id) || id);
        if (task) return task;
    }
    return null;
}

function enrichChildStatus(agent, task, transcript, session, budget) {
    const assignmentTime = Date.parse(task?.timestamp);
    const hookTime = Date.parse(agent.updatedAtUtc);
    const newAssignment = Number.isFinite(assignmentTime) && (!Number.isFinite(hookTime) || assignmentTime > hookTime);
    let child = readTranscript(agent.transcriptPath, agent.agentId, budget);
    if (!child) {
        const sibling = findSiblingTranscript(transcript.filePath, agent.agentId, budget.directoryCache);
        if (sibling && sibling !== agent.transcriptPath) child = readTranscript(sibling, agent.agentId, budget);
    }
    const execution = child?.isChild && child.parentId === (agent.parentAgentId || session.sessionId) ? child.execution : null;
    const executionTime = Date.parse(execution?.timestamp);
    const receivedTime = Date.parse(execution?.taskReceivedAtUtc);
    // A previous turn's completion is not evidence that a new assignment ended.
    const currentExecution = Number.isFinite(executionTime)
        && (!Number.isFinite(assignmentTime) || (Number.isFinite(receivedTime) && receivedTime >= assignmentTime));
    if (currentExecution && (!Number.isFinite(hookTime) || executionTime > hookTime)) {
        agent.status = execution.status;
        agent.statusSource = 'transcript';
        agent.updatedAtUtc = execution.timestamp;
    } else if (newAssignment && ['stopped', 'ended', 'unknown'].includes(agent.status)) {
        // A successfully submitted task disproves the old stopped label, but
        // execution remains unknown until this child's own turn is readable.
        agent.status = 'unknown';
        agent.statusSource = 'transcript';
        agent.updatedAtUtc = task.timestamp;
    }
}

function enrichAgentTasks(state) {
    const budget = { remaining: maxPollBytes, monitoredPaths: new Set(), directoryCache: new Map() };
    const retain = (filePath) => {
        if (localTranscriptPath(filePath)) budget.monitoredPaths.add(filePath);
    };
    // Pin every current reference before reading any file. A fixed LRU would
    // repeatedly evict unfinished scans when more than 64 agents are monitored.
    for (const project of state.projects || []) {
        for (const session of project.sessions || []) {
            retain(session.transcriptPath);
            const sibling = findSiblingTranscript(session.transcriptPath, session.sessionId, budget.directoryCache);
            retain(sibling);
            for (const agent of session.agents || []) {
                if (agent.role !== 'subagent') continue;
                retain(agent.transcriptPath);
                for (const parentPath of new Set([session.transcriptPath, sibling].filter(Boolean))) {
                    retain(findSiblingTranscript(parentPath, agent.agentId, budget.directoryCache));
                }
            }
        }
    }
    for (const filePath of transcriptCache.keys()) {
        if (!budget.monitoredPaths.has(filePath)) transcriptCache.delete(filePath);
    }
    for (const project of state.projects || []) {
        for (const session of project.sessions || []) {
            let transcript = readTranscript(session.transcriptPath, session.sessionId, budget);
            if (!transcript) {
                const sibling = findSiblingTranscript(session.transcriptPath, session.sessionId, budget.directoryCache);
                if (sibling && sibling !== session.transcriptPath) transcript = readTranscript(sibling, session.sessionId, budget);
            }
            if (!transcript || transcript.isChild) continue;
            if (!session.sessionTitle) session.sessionTitle = transcript.sessionTitle;
            for (const agent of session.agents || []) {
                const task = agentTask(transcript, agent);
                if (agent.role === 'subagent') enrichChildStatus(agent, task, transcript, session, budget);
                if (!task) continue;
                if (agent.role === 'main' && agent.turnId && task.turnId !== agent.turnId) continue;
                const taskTime = Date.parse(task.timestamp);
                const startedTime = Date.parse(agent.startedAtUtc);
                if (agent.role === 'main' && agent.taskTitle && ['prompt', 'explicit'].includes(agent.titleSource)) continue;
                if (agent.role === 'main' && Number.isFinite(startedTime) && Number.isFinite(taskTime)
                    && taskTime < startedTime - 5000) continue;
                if (agent.role === 'subagent' && Number.isFinite(startedTime) && Number.isFinite(taskTime)
                    && taskTime < startedTime - 5000) continue;
                if (task.agentPath) agent.agentPath = task.agentPath;
                if (task.taskName) agent.taskName = task.taskName;
                // Activity timestamps are not title timestamps. A later tool
                // event must not prevent a follow-up assignment replacing a label.
                const titleTime = Date.parse(agent.taskTitleUpdatedAtUtc);
                if (Number.isFinite(titleTime) && Number.isFinite(taskTime) && taskTime < titleTime) continue;
                if (agent.taskTitle && agent.titleSource === 'explicit' && (!Number.isFinite(taskTime)
                    || !Number.isFinite(startedTime) || taskTime <= startedTime)) continue;
                agent.taskTitle = task.title;
                agent.titleSource = task.explicit ? 'explicit' : 'transcript';
                agent.taskTitleUpdatedAtUtc = task.timestamp;
            }
        }
    }
}

module.exports = { enrichAgentTasks, toTaskTitle, readTranscript, findSiblingTranscript };
