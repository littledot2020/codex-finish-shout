(() => {
    'use strict';
    const vscode = acquireVsCodeApi();
    const initialAppearance = __INITIAL_APPEARANCE__;
    const copy = {
        zh: {
            promotion: '推广', toolaiTitle: '发现更多 AI 工具 · ToolAI',
            toolaiDescription: '探索 AI 工具、模型与开源项目，为编程、写作和创作寻找合适的工具。',
            toolaiVisit: '访问 www.toolai.io →', dismissPromotion: '关闭 ToolAI 推广，可在设置中重新开启',
            title: '项目总览', skip: '跳到项目列表', statistics: '项目统计', projects: '个项目', runningProjects: '个项目运行中', music: '音乐预置 · 选择内置曲目或本地音乐',
            musicPresets: '音乐预置', playbackSettings: '播放设置', audioControls: '完成提示音乐',
            stopMusic: '停止所有项目的当前音乐和待播队列', stopMusicShort: '停止音乐', stoppingMusic: '正在停止…',
            musicStopSent: '已发送停止音乐请求', noMusic: '当前没有正在播放或排队的音乐', musicStopFailed: '停止音乐失败，请重试', musicStopTimeout: '未收到停止结果，可再次点击停止音乐',
            running: '运行中', completed: '已完成', unknown: '状态待确认', stopped: '本轮已结束', ended: '会话已结束',
            all: '全部', filter: '按项目状态筛选', priority: '运行优先', search: '查找项目或任务',
            refresh: '刷新项目状态', refreshing: '刷新中…', live: '实时监控', connecting: '正在连接监控…',
            themeDark: '深色', themeLight: '浅色', switchToDark: '切换为深色', switchToLight: '切换为浅色',
            info: '查看状态说明', infoTitle: '状态说明', close: '关闭',
            infoHint: '运行项目优先显示。默认显示运行中的 Agent，以及最近 5 分钟结束的最多 2 个 Agent；必要时保留父 Agent 作为上下文。其他记录点击「展开其他」查看，搜索会自动展开匹配项目的全部记录。',
            unknownHint: '状态待确认表示尚无足够执行证据，不代表正在等待用户操作。',
            source: '数据源', sourceUnknown: '尚未读取', motion: '遵循系统「减少动态效果」设置',
            main: '主 Agent', sub: '子 Agent', agentRunning: '执行中', noTitle: '未获取任务标题',
            summarized: '提示词摘要', session: '会话', timeUnknown: '时间未知', activity: '最近活动',
            noAgents: '尚未采集到 Agent 明细', defaultRunning: 'Codex 正在执行', defaultCompleted: 'Codex 已完成',
            loading: '正在读取监控快照', loadingHint: '后台监控已启动。', empty: '尚无项目记录',
            emptyHint: 'Codex 项目开始活动后，会自动出现在这里。', ready: '监控已就绪',
            error: '监控快照读取失败', errorHint: '后台监控仍在运行，恢复后会自动更新。', readError: '读取异常',
            noResults: '没有匹配的项目', noResultsHint: '试试其他关键词，或切换到全部项目。', retry: '重新读取',
            refreshed: '项目状态已更新',
            recent: '刚刚结束', historyShow: (count) => `展开其他 ${count} 个 Agent`, historyHide: (count) => `收起其他 ${count} 个 Agent`,
            focusEmpty: '暂无运行中或刚结束的 Agent', compactCount: (agents, running) => `${running} 执行中 · ${agents} Agent`,
            count: (sessions, agents, running) => `${sessions} 个会话 · ${agents} 个 Agent · ${running} 个执行中`,
            shown: (visible, total) => visible === total ? `${total} 个项目` : `${visible} / ${total} 个项目`
        },
        en: {
            promotion: 'Promotion', toolaiTitle: 'Discover more AI tools · ToolAI',
            toolaiDescription: 'Explore AI tools, models, and open-source projects for coding, writing, and creative work.',
            toolaiVisit: 'Visit www.toolai.io →', dismissPromotion: 'Hide ToolAI promotion; re-enable it in Settings',
            title: 'Project overview', skip: 'Skip to projects', statistics: 'Project statistics', projects: 'projects', runningProjects: 'projects running', music: 'Music presets · Choose a built-in or local track',
            musicPresets: 'Music presets', playbackSettings: 'Playback settings', audioControls: 'Completion music',
            stopMusic: 'Stop playing and queued music for all projects', stopMusicShort: 'Stop music', stoppingMusic: 'Stopping…',
            musicStopSent: 'Audio stop requested', noMusic: 'No music is playing or queued', musicStopFailed: 'Unable to stop music. Try again.', musicStopTimeout: 'No stop response received. You can try again.',
            running: 'Running', completed: 'Completed', unknown: 'Unconfirmed', stopped: 'Turn ended', ended: 'Session ended',
            all: 'All', filter: 'Filter by project status', priority: 'Running first', search: 'Find a project or task',
            refresh: 'Refresh project status', refreshing: 'Refreshing…', live: 'Live monitor', connecting: 'Connecting to monitor…',
            themeDark: 'Dark', themeLight: 'Light', switchToDark: 'Switch to dark', switchToLight: 'Switch to light',
            info: 'View status guide', infoTitle: 'Status guide', close: 'Close',
            infoHint: 'Running projects come first. Running agents and up to 2 agents whose turns ended in the last 5 minutes are shown, with parents for context. Expand other agents to see older records. Search automatically reveals all records in matching projects.',
            unknownHint: 'Unconfirmed means execution evidence is missing; it does not mean user input is needed.',
            source: 'Data source', sourceUnknown: 'Not read yet', motion: 'Respects your reduced motion preference',
            main: 'Main agent', sub: 'Subagent', agentRunning: 'Running', noTitle: 'Task title unavailable',
            summarized: 'Prompt summary', session: 'Session', timeUnknown: 'Time unknown', activity: 'Last active',
            noAgents: 'Agent details have not been collected yet', defaultRunning: 'Codex is running', defaultCompleted: 'Codex has completed',
            loading: 'Reading monitor snapshot', loadingHint: 'The monitor is starting.', empty: 'No projects yet',
            emptyHint: 'Projects appear here automatically when Codex starts working.', ready: 'Monitor ready',
            error: 'Unable to read monitor snapshot', errorHint: 'Monitoring continues. This view updates automatically when the source recovers.', readError: 'Read error',
            noResults: 'No matching projects', noResultsHint: 'Try another keyword or switch to all projects.', retry: 'Try again',
            refreshed: 'Project status updated',
            recent: 'Just ended', historyShow: (count) => `Show ${count} other agents`, historyHide: (count) => `Hide ${count} other agents`,
            focusEmpty: 'No running or recently ended agents', compactCount: (agents, running) => `${running} running · ${agents} agents`,
            count: (sessions, agents, running) => `${sessions} ${sessions === 1 ? 'session' : 'sessions'} · ${agents} ${agents === 1 ? 'agent' : 'agents'} · ${running} running`,
            shown: (visible, total) => visible === total ? `${total} ${total === 1 ? 'project' : 'projects'}` : `${visible} / ${total} projects`
        }
    };
    const byId = (id) => document.getElementById(id);
    const content = byId('content');
    const source = byId('source');
    const snapshotStatus = byId('snapshot-status');
    const searchInput = byId('search');
    const savedState = vscode.getState() || {};
    const expansion = new Map(Array.isArray(savedState.expandedDetails) ? savedState.expandedDetails : []);
    const historyExpansion = new Map(Array.isArray(savedState.expandedHistory) ? savedState.expandedHistory : []);
    const automaticExpansion = new WeakMap();
    const RECENT_WINDOW_MS = 5 * 60 * 1000;
    const RECENT_LIMIT = 2;
    const projectViews = new Map();
    const projectList = element('ul', 'project-list');
    projectList.setAttribute('role', 'list');
    let appearance = { ...initialAppearance };
    let filter = ['all', 'running', 'completed'].includes(savedState.filter) ? savedState.filter : 'all';
    let search = typeof savedState.search === 'string' ? savedState.search : '';
    let latestState = null;
    let stateCardFingerprint = '';
    let refreshing = false;
    let stoppingMusic = false;
    let musicStopTimer;

    function t() { return copy[appearance.language]; }
    function element(tag, className) {
        const node = document.createElement(tag);
        if (className) node.className = className;
        return node;
    }
    function setText(node, value) {
        const text = value == null ? '' : String(value);
        if (node.textContent !== text) node.textContent = text;
    }
    function saveState() {
        vscode.setState({ ...savedState, expandedDetails: Array.from(expansion), expandedHistory: Array.from(historyExpansion), filter, search });
    }
    function lamp(status) {
        const node = element('span', 'lamp ' + status);
        node.setAttribute('aria-hidden', 'true');
        return node;
    }
    function createStatus() {
        const row = element('span', 'status');
        const light = lamp('unknown');
        const label = element('span', 'status-label');
        row.append(light, label);
        return { row, light, label };
    }
    function updateStatus(view, status, agent = false) {
        view.row.className = 'status ' + status;
        view.light.className = 'lamp ' + status;
        setText(view.label, agent && status === 'running' ? t().agentRunning : t()[status]);
    }
    function updateTime(node, value) {
        const date = value ? new Date(value) : null;
        const valid = date && Number.isFinite(date.getTime());
        node.dateTime = valid ? value : '';
        setText(node, valid ? new Intl.DateTimeFormat(appearance.language === 'zh' ? 'zh-CN' : 'en-GB', {
            hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
        }).format(date) : t().timeUnknown);
        node.title = t().activity + ' · ' + (valid ? new Intl.DateTimeFormat(appearance.language === 'zh' ? 'zh-CN' : 'en-GB', {
            year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
        }).format(date) : t().timeUnknown);
        node.setAttribute('aria-label', node.title);
    }
    function disclosure() {
        const node = element('span', 'disclosure');
        node.setAttribute('aria-hidden', 'true');
        return node;
    }
    function rememberExpansion(details, key, defaultOpen) {
        setAutomaticExpansion(details, key, defaultOpen);
        details.addEventListener('toggle', () => {
            // Native details also fires toggle for programmatic opens. Only save user choices.
            if (details.open === automaticExpansion.get(details)) return;
            expansion.set(key, details.open);
            automaticExpansion.set(details, details.open);
            // Bound retained history while keeping choices across temporary filtering.
            if (expansion.size > 500) expansion.delete(expansion.keys().next().value);
            saveState();
        });
    }
    function setAutomaticExpansion(details, key, defaultOpen, revealSearch = false) {
        const open = revealSearch || (expansion.has(key) ? expansion.get(key) === true : defaultOpen);
        automaticExpansion.set(details, open);
        if (details.open !== open) details.open = open;
    }
    function syncChildren(parent, nodes) {
        const wanted = new Set(nodes);
        for (const child of Array.from(parent.children)) {
            if (!wanted.has(child)) child.remove();
        }
        for (let index = 0; index < nodes.length; index += 1) {
            if (parent.children[index] !== nodes[index]) {
                parent.insertBefore(nodes[index], parent.children[index] || null);
            }
        }
    }
    function createStateCard(kind, detail) {
        const card = element('div', 'state-card' + (kind === 'error' ? ' error' : ''));
        const symbol = element('span', 'empty-icon');
        symbol.setAttribute('aria-hidden', 'true');
        setText(symbol, kind === 'error' ? '!' : kind === 'noResults' ? '⌕' : '◇');
        const heading = element('h2');
        setText(heading, t()[kind]);
        const description = element('p');
        setText(description, t()[kind + 'Hint']);
        card.append(symbol, heading, description);
        if (detail) {
            const code = element('code');
            setText(code, detail);
            card.append(code);
        }
        if (kind === 'error') {
            const retry = element('button', 'retry-button');
            retry.type = 'button';
            setText(retry, t().retry);
            retry.addEventListener('click', refresh);
            card.append(retry);
        }
        return card;
    }
    function showStateCard(kind, detail = '') {
        const fingerprint = JSON.stringify([appearance.language, kind, detail]);
        if (stateCardFingerprint !== fingerprint) content.replaceChildren(createStateCard(kind, detail));
        stateCardFingerprint = fingerprint;
    }
    function createAgentRow() {
        const row = element('div', 'agent-row');
        const identity = element('div', 'agent-identity');
        const title = element('p', 'agent-title');
        const meta = element('div', 'agent-meta');
        const role = element('span', 'agent-role');
        const type = element('span', 'agent-type');
        const titleSource = element('span', 'agent-title-source');
        const sessionName = element('span', 'agent-session');
        meta.append(role, type, titleSource, sessionName);
        identity.append(title, meta);
        const status = element('div', 'agent-state');
        const badge = createStatus();
        const time = element('time');
        status.append(badge.row, time);
        row.append(identity, status);
        return { row, title, role, type, titleSource, sessionName, badge, time };
    }
    function updateAgentRow(view, agent, sessionTitle, recent = false) {
        const status = ['running', 'completed', 'stopped', 'ended', 'unknown'].includes(agent.status) ? agent.status : 'unknown';
        view.row.className = 'agent-row ' + status;
        setText(view.title, agent.taskTitle || t().noTitle);
        view.title.title = view.title.textContent;
        setText(view.role, agent.role === 'main' ? t().main : t().sub);
        view.role.title = [agent.shortId ? '#' + agent.shortId : '', agent.agentId].filter(Boolean).join('\n');
        setText(view.type, agent.agentType || '');
        view.type.hidden = !agent.agentType;
        const summarized = agent.titleSource === 'prompt' || agent.titleSource === 'transcript';
        setText(view.titleSource, summarized ? t().summarized : '');
        view.titleSource.hidden = !summarized;
        setText(view.sessionName, sessionTitle ? t().session + ' · ' + sessionTitle : '');
        view.sessionName.hidden = !sessionTitle;
        view.row.title = [view.title.textContent, view.role.textContent, agent.agentId, summarized ? t().summarized : '', view.sessionName.textContent].filter(Boolean).join('\n');
        updateStatus(view.badge, status, true);
        if (recent) {
            setText(view.badge.label, t().recent);
            view.badge.row.title = t()[status];
        } else view.badge.row.title = '';
        updateTime(view.time, agent.updatedAtUtc || agent.startedAtUtc);
    }
    function createSessionView(key) {
        const item = element('li');
        const details = element('details', 'session');
        const summary = element('summary');
        const main = createAgentRow();
        const children = element('ul', 'agent-list');
        children.setAttribute('role', 'list');
        summary.append(disclosure(), main.row);
        details.append(summary, children);
        item.append(details);
        rememberExpansion(details, key, true);
        return { item, details, summary, main, children, agents: new Map() };
    }
    function compareAgents(left, right) {
        return Number(right.status === 'running') - Number(left.status === 'running') ||
            String(right.updatedAtUtc || '').localeCompare(String(left.updatedAtUtc || '')) ||
            String(left.agentId).localeCompare(String(right.agentId));
    }
    function updateSessionView(view, session, focusAgents, recentAgents, showHistory) {
        const agents = Array.isArray(session.agents) ? session.agents : [];
        const main = agents.find((agent) => agent.role === 'main') || {
            agentId: session.sessionId || session.threadHash, shortId: session.shortId,
            role: 'main', status: 'unknown', taskTitle: '', updatedAtUtc: ''
        };
        updateAgentRow(view.main, main, session.sessionTitle, recentAgents.has(main));
        const children = agents.filter((agent) => agent !== main).sort(compareAgents);
        const byId = new Map(children.map((agent) => [agent.agentId, agent]));
        const visited = new Set();
        const byParent = new Map();
        for (const agent of children) {
            const parentId = byId.has(agent.parentAgentId) && agent.parentAgentId !== agent.agentId ? agent.parentAgentId : main.agentId;
            if (!byParent.has(parentId)) byParent.set(parentId, []);
            byParent.get(parentId).push(agent);
        }
        function updateChild(agent) {
            if (visited.has(agent.agentId)) return null;
            visited.add(agent.agentId);
            let childView = view.agents.get(agent.agentId);
            if (!childView) {
                childView = createAgentRow();
                childView.item = element('li');
                childView.children = element('ul', 'agent-list');
                childView.children.setAttribute('role', 'list');
                childView.item.append(childView.row, childView.children);
                view.agents.set(agent.agentId, childView);
            }
            updateAgentRow(childView, agent, '', recentAgents.has(agent));
            childView.item.hidden = !showHistory && !focusAgents.has(agent);
            syncChildren(childView.children, (byParent.get(agent.agentId) || []).map(updateChild).filter(Boolean));
            return childView.item;
        }
        const roots = (byParent.get(main.agentId) || []).map(updateChild).filter(Boolean);
        // Missing parents and malformed cycles still leave every collected agent visible.
        for (const agent of children) {
            if (!visited.has(agent.agentId)) roots.push(updateChild(agent));
        }
        syncChildren(view.children, roots);
        for (const id of view.agents.keys()) {
            if (!byId.has(id)) view.agents.delete(id);
        }
        view.item.hidden = !showHistory && !agents.some((agent) => focusAgents.has(agent));
    }
    function projectFocus(sessions) {
        const agents = sessions.flatMap((session) => Array.isArray(session.agents) ? session.agents : []);
        const now = Date.now();
        const recent = new Set(agents.filter((agent) => {
            const age = now - Date.parse(agent.updatedAtUtc);
            return ['stopped', 'completed'].includes(agent.status) && age >= 0 && age <= RECENT_WINDOW_MS;
        }).sort(compareAgents).slice(0, RECENT_LIMIT));
        const visible = new Set(agents.filter((agent) => agent.status === 'running' || recent.has(agent)));
        // Keep the parent chain for a working child, even when the parent turn has ended.
        for (const session of sessions) {
            const entries = Array.isArray(session.agents) ? session.agents : [];
            const main = entries.find((agent) => agent.role === 'main');
            const byId = new Map(entries.map((agent) => [agent.agentId, agent]));
            for (const agent of entries.filter((entry) => visible.has(entry))) {
                const visited = new Set([agent]);
                let parent = byId.get(agent.parentAgentId);
                while (parent && !visited.has(parent)) {
                    visited.add(parent);
                    visible.add(parent);
                    parent = byId.get(parent.parentAgentId);
                }
                if (main) visible.add(main);
            }
        }
        return { recent, visible, hiddenCount: agents.length - visible.size };
    }
    function compareSessions(left, right) {
        const leader = (session) => (Array.isArray(session.agents) ? [...session.agents] : []).sort(compareAgents)[0] || {};
        return compareAgents(leader(left), leader(right));
    }
    function createProjectView(key, initiallyOpen) {
        const item = element('li');
        const details = element('details', 'project');
        const row = element('summary', 'project-row');
        const leading = element('span', 'project-leading');
        const light = lamp('unknown');
        leading.append(light);
        const identity = element('div', 'project-identity');
        const name = element('h3', 'project-name');
        const message = element('p', 'project-message');
        identity.append(name, message);
        const status = element('div', 'status-block');
        const badge = createStatus();
        const time = element('time');
        status.append(badge.row, time);
        const count = element('p', 'agent-count');
        row.append(leading, identity, status, disclosure(), count);
        const body = element('div', 'project-agents');
        const pathLine = element('div', 'path-line');
        const pathSymbol = element('span', 'path-symbol');
        setText(pathSymbol, '⌁');
        pathSymbol.setAttribute('aria-hidden', 'true');
        const projectPath = element('p', 'project-path');
        pathLine.append(pathSymbol, projectPath);
        const sessions = element('ul', 'session-list');
        sessions.setAttribute('role', 'list');
        const empty = element('p', 'agents-empty');
        const history = element('button', 'history-toggle');
        history.type = 'button';
        const historyIcon = element('span', 'history-icon');
        historyIcon.setAttribute('aria-hidden', 'true');
        const historyLabel = element('span');
        history.append(historyIcon, historyLabel);
        history.addEventListener('click', () => {
            historyExpansion.set(key, history.getAttribute('aria-expanded') !== 'true');
            if (historyExpansion.size > 500) historyExpansion.delete(historyExpansion.keys().next().value);
            saveState();
            render(latestState);
        });
        body.append(pathLine, empty, sessions, history);
        details.append(row, body);
        item.append(details);
        rememberExpansion(details, key, initiallyOpen);
        return { item, details, row, light, name, pathLine, projectPath, message, count, badge, time, empty, sessions, history, historyIcon, historyLabel, sessionViews: new Map() };
    }
    function projectMessage(project, sessions) {
        const mainAgents = sessions.flatMap((session) => Array.isArray(session.agents) ? session.agents.filter((agent) => agent.role === 'main' && agent.taskTitle) : []).sort(compareAgents);
        if (mainAgents.length) return mainAgents[0].taskTitle;
        const defaultMessage = project.status === 'running' ? t().defaultRunning : t().defaultCompleted;
        // Localize monitor-generated fallbacks; user-authored tasks stay verbatim.
        return !project.message || ['Codex 正在执行', 'Codex 已完成', 'Codex is running', 'Codex has completed'].includes(project.message) ? defaultMessage : project.message;
    }
    function updateProjectView(view, project, projectKey) {
        const status = ['running', 'completed', 'unknown', 'stopped', 'ended'].includes(project.status) ? project.status : 'unknown';
        view.row.className = 'project-row ' + status;
        view.details.className = 'project ' + status;
        view.light.className = 'lamp ' + status;
        setText(view.name, project.name);
        view.name.title = project.name + '\n' + project.path;
        setText(view.projectPath, project.path);
        view.projectPath.title = project.path;
        const sessions = Array.isArray(project.sessions) ? [...project.sessions].sort(compareSessions) : [];
        const focus = projectFocus(sessions);
        const searching = Boolean(search.trim());
        const showHistory = searching || historyExpansion.get(projectKey) === true;
        setAutomaticExpansion(view.details, projectKey, status === 'running' || focus.recent.size > 0 || historyExpansion.get(projectKey) === true, searching && matchesProject(project));
        setText(view.message, projectMessage(project, sessions));
        view.message.title = view.message.textContent;
        updateStatus(view.badge, status);
        updateTime(view.time, project.updatedAtUtc);
        const agents = sessions.flatMap((session) => Array.isArray(session.agents) ? session.agents : []);
        const count = Number.isFinite(project.agentCount) ? project.agentCount : agents.length;
        const running = Number.isFinite(project.runningAgentCount) ? project.runningAgentCount : agents.filter((agent) => agent.status === 'running').length;
        setText(view.count, t().compactCount(count, running));
        view.count.title = t().count(sessions.length, count, running);
        setText(view.empty, agents.length ? t().focusEmpty : t().noAgents);
        view.empty.hidden = agents.length > 0 && (showHistory || focus.visible.size > 0);
        view.pathLine.hidden = !showHistory;
        view.history.hidden = focus.hiddenCount === 0;
        view.history.disabled = searching;
        view.history.setAttribute('aria-expanded', String(showHistory));
        setText(view.historyIcon, showHistory ? '«' : '»');
        setText(view.historyLabel, showHistory ? t().historyHide(focus.hiddenCount) : t().historyShow(focus.hiddenCount));
        const activeKeys = new Set();
        const nodes = sessions.map((session) => {
            const key = JSON.stringify([projectKey, session.threadHash || session.sessionId]);
            activeKeys.add(key);
            if (!view.sessionViews.has(key)) view.sessionViews.set(key, createSessionView(key));
            const sessionView = view.sessionViews.get(key);
            updateSessionView(sessionView, session, focus.visible, focus.recent, showHistory);
            setAutomaticExpansion(sessionView.details, key, true, searching);
            return sessionView.item;
        });
        syncChildren(view.sessions, nodes);
        for (const key of view.sessionViews.keys()) {
            if (!activeKeys.has(key)) view.sessionViews.delete(key);
        }
    }
    function matchesProject(project) {
        if (filter !== 'all' && project.status !== filter) return false;
        const term = search.trim().toLocaleLowerCase();
        if (!term) return true;
        const sessions = Array.isArray(project.sessions) ? project.sessions : [];
        const fields = [project.name, project.path, project.message, ...sessions.flatMap((session) => [
            session.sessionTitle, session.sessionId, ...(Array.isArray(session.agents) ? session.agents : []).flatMap((agent) => [agent.taskTitle, agent.agentId, agent.shortId, agent.agentType])
        ])];
        return fields.filter(Boolean).join(' ').toLocaleLowerCase().includes(term);
    }
    function render(state) {
        if (!state || typeof state !== 'object') return;
        latestState = state;
        const focused = document.activeElement;
        const projects = Array.isArray(state.projects) ? state.projects : [];
        document.body.dataset.state = state.kind || 'loading';
        const valid = state.kind === 'ready' || state.kind === 'empty';
        setText(byId('total-count'), valid ? state.totalCount ?? projects.length : '—');
        setText(byId('running-count'), valid ? state.runningCount ?? projects.filter((project) => project.status === 'running').length : '—');
        setText(byId('completed-count'), valid ? state.completedCount ?? projects.filter((project) => project.status === 'completed').length : '—');
        setText(source, state.sourcePath || t().sourceUnknown);
        source.title = state.sourcePath || '';
        if (state.kind === 'error') {
            setText(snapshotStatus, refreshing ? t().refreshing : t().readError);
            setText(byId('visible-count'), '—');
            showStateCard('error', state.error);
            return;
        }
        if (state.kind === 'empty') {
            setText(snapshotStatus, refreshing ? t().refreshing : t().ready);
            setText(byId('visible-count'), t().shown(0, 0));
            showStateCard('empty');
            return;
        }
        if (state.kind !== 'ready') {
            setText(snapshotStatus, t().connecting);
            setText(byId('visible-count'), '—');
            showStateCard('loading');
            return;
        }
        setText(snapshotStatus, refreshing ? t().refreshing : t().live);
        const activeKeys = new Set();
        const nodes = [];
        // The host supplies stable running-first project order; never reorder it here.
        for (const project of projects) {
            const key = JSON.stringify(['project', project.projectKey || project.path]);
            activeKeys.add(key);
            if (!projectViews.has(key)) projectViews.set(key, createProjectView(key, project.status === 'running'));
            const view = projectViews.get(key);
            updateProjectView(view, project, key);
            if (matchesProject(project)) nodes.push(view.item);
        }
        syncChildren(projectList, nodes);
        for (const key of projectViews.keys()) {
            if (!activeKeys.has(key)) projectViews.delete(key);
        }
        setText(byId('visible-count'), t().shown(nodes.length, projects.length));
        if (!nodes.length) showStateCard(projects.length ? 'noResults' : 'empty');
        else {
            stateCardFingerprint = '';
            if (content.firstElementChild !== projectList) content.replaceChildren(projectList);
        }
        // Moving an existing summary during priority sorting may blur it in Chromium.
        if (focused && focused !== document.activeElement && content.contains(focused)) focused.focus({ preventScroll: true });
    }
    function updateFilters() {
        for (const key of ['all', 'running', 'completed']) {
            const button = byId('filter-' + key);
            button.className = 'filter-button' + (filter === key ? ' selected' : '');
            button.setAttribute('aria-pressed', String(filter === key));
        }
    }
    function updateMusicButton() {
        byId('stop-music').disabled = stoppingMusic;
        byId('stop-music').setAttribute('aria-busy', String(stoppingMusic));
        setText(byId('stop-music-label'), stoppingMusic ? t().stoppingMusic : t().stopMusicShort);
    }
    function stopMusic() {
        stoppingMusic = true;
        updateMusicButton();
        setText(byId('announcement'), t().stoppingMusic);
        clearTimeout(musicStopTimer);
        musicStopTimer = setTimeout(() => {
            stoppingMusic = false;
            updateMusicButton();
            setText(byId('announcement'), t().musicStopTimeout);
        }, 5000);
        vscode.postMessage({ type: 'stopMusic' });
    }
    function applyAppearance(next) {
        if (!next || typeof next !== 'object') return;
        const language = ['zh', 'en'].includes(next.language) ? next.language : appearance.language;
        const languagePreference = ['auto', 'zh', 'en'].includes(next.languagePreference) ? next.languagePreference : appearance.languagePreference;
        const theme = ['auto', 'dark', 'light'].includes(next.theme) ? next.theme : appearance.theme;
        appearance = { language, languagePreference, theme };
        document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
        document.documentElement.dataset.theme = theme;
        document.title = 'Codex · ' + t().title;
        for (const node of document.querySelectorAll('[data-i18n]')) setText(node, t()[node.dataset.i18n]);
        for (const node of document.querySelectorAll('[data-label]')) {
            const label = t()[node.dataset.label];
            node.setAttribute('aria-label', label);
            node.title = label;
        }
        searchInput.placeholder = t().search;
        updateAppearanceButtons();
        updateFilters();
        updateMusicButton();
        render(latestState || { kind: 'loading' });
    }
    function effectiveTheme() {
        if (appearance.theme !== 'auto') return appearance.theme;
        return document.body.classList.contains('vscode-light') || document.body.classList.contains('vscode-high-contrast-light') ? 'light' : 'dark';
    }
    function updateAppearanceButtons() {
        const languageButton = byId('language-toggle');
        setText(languageButton, appearance.language === 'en' ? 'EN' : '中文');
        languageButton.title = appearance.language === 'en' ? 'EN · 切换为中文' : '中文 · Switch to English';
        languageButton.setAttribute('aria-label', languageButton.title);
        const dark = effectiveTheme() === 'dark';
        const themeLabel = dark ? t().themeDark : t().themeLight;
        setText(byId('theme-label'), themeLabel);
        byId('theme-dark-icon').hidden = !dark;
        byId('theme-light-icon').hidden = dark;
        byId('theme-toggle').title = themeLabel + ' · ' + (dark ? t().switchToLight : t().switchToDark);
        byId('theme-toggle').setAttribute('aria-label', byId('theme-toggle').title);
    }
    function setInfoPopover(open, restoreFocus = true) {
        byId('info-panel').hidden = !open;
        byId('info-toggle').setAttribute('aria-expanded', String(open));
        if (open) byId('info-close').focus();
        else if (restoreFocus) byId('info-toggle').focus();
    }
    function refresh() {
        refreshing = true;
        setText(snapshotStatus, t().refreshing);
        byId('refresh').className = 'icon-button refreshing';
        byId('refresh').setAttribute('aria-busy', 'true');
        vscode.postMessage({ type: 'refresh' });
    }
    function requestAppearance(next) {
        applyAppearance(next);
        vscode.postMessage({ type: 'setAppearance', languagePreference: appearance.languagePreference, theme: appearance.theme });
    }
    searchInput.value = search;
    searchInput.addEventListener('input', () => {
        search = searchInput.value;
        saveState();
        render(latestState);
    });
    for (const key of ['all', 'running', 'completed']) {
        byId('filter-' + key).addEventListener('click', () => {
            filter = key;
            saveState();
            updateFilters();
            render(latestState);
        });
    }
    byId('info-toggle').addEventListener('click', () => setInfoPopover(byId('info-panel').hidden));
    byId('info-close').addEventListener('click', () => setInfoPopover(false));
    byId('language-toggle').addEventListener('click', () => {
        const language = appearance.language === 'en' ? 'zh' : 'en';
        requestAppearance({ language, languagePreference: language });
    });
    byId('theme-toggle').addEventListener('click', () => requestAppearance({ theme: effectiveTheme() === 'dark' ? 'light' : 'dark' }));
    // VS Code updates the body class when its color theme changes.
    new MutationObserver(updateAppearanceButtons).observe(document.body, { attributes: true, attributeFilter: ['class'] });
    byId('refresh').addEventListener('click', refresh);
    byId('music-settings').addEventListener('click', () => vscode.postMessage({ type: 'chooseCompletionMusic' }));
    byId('playback-settings').addEventListener('click', () => vscode.postMessage({ type: 'configurePlayback' }));
    byId('stop-music').addEventListener('click', stopMusic);
    byId('toolai-open').addEventListener('click', () => vscode.postMessage({ type: 'openToolAI' }));
    byId('toolai-dismiss').addEventListener('click', () => {
        byId('toolai-promotion').hidden = true;
        byId('info-toggle').focus();
        vscode.postMessage({ type: 'dismissToolAI' });
    });
    document.addEventListener('click', (event) => {
        const panel = byId('info-panel');
        if (!panel.hidden && !panel.contains(event.target) && !byId('info-toggle').contains(event.target)) setInfoPopover(false, false);
    });
    document.addEventListener('keydown', (event) => {
        if (event.key === '/' && !event.ctrlKey && !event.metaKey && !event.altKey && !['INPUT', 'SELECT', 'TEXTAREA'].includes(document.activeElement?.tagName)) {
            event.preventDefault();
            searchInput.focus();
        }
        if (event.key === 'Escape' && !byId('info-panel').hidden) {
            event.preventDefault();
            setInfoPopover(false);
        }
    });
    window.addEventListener('message', (event) => {
        const message = event.data;
        if (!message || typeof message !== 'object') return;
        if (message.type === 'projectMonitorAppearance') {
            applyAppearance(message.appearance);
            if (typeof message.showToolAI === 'boolean') byId('toolai-promotion').hidden = !message.showToolAI;
        }
        if (message.type === 'musicStopResult') {
            clearTimeout(musicStopTimer);
            stoppingMusic = false;
            updateMusicButton();
            setText(byId('announcement'), message.ok ? (message.count ? t().musicStopSent : t().noMusic) : t().musicStopFailed);
        }
        if (message.type === 'projectMonitorSnapshot') {
            const wasRefreshing = refreshing;
            refreshing = false;
            byId('refresh').className = 'icon-button';
            byId('refresh').setAttribute('aria-busy', 'false');
            render(message.state);
            if (wasRefreshing) setText(byId('announcement'), message.state?.kind === 'error' ? t().readError : t().refreshed);
        }
    });
    applyAppearance(appearance);
    // Age recent completions even when the host deduplicates identical snapshots.
    function ageRecentAgents() {
        if (latestState?.kind === 'ready') render(latestState);
        setTimeout(ageRecentAgents, 15000);
    }
    setTimeout(ageRecentAgents, 15000);
    vscode.postMessage({ type: 'ready' });
})();
