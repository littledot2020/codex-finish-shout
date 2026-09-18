const assert = require('node:assert/strict');
const Module = require('node:module');
const test = require('node:test');
const vm = require('node:vm');

const originalLoad = Module._load;
let getProjectMonitorWebviewHtml;
try {
    Module._load = function loadWithVscodeMock(request, parent, isMain) {
        return request === 'vscode' ? {} : originalLoad.call(this, request, parent, isMain);
    };
    ({ getProjectMonitorWebviewHtml } = require('../extension'));
} finally {
    Module._load = originalLoad;
}

// A deliberately small DOM harness executes the exact script shipped in the Webview.
// It models node identity and focus loss on removal, which string snapshots cannot test.
function createWebview(savedState = {}, options = {}) {
    const nodes = new Map();
    const document = {
        activeElement: null,
        createElement(tag) { return new Element(tag); },
        getElementById(id) { return nodes.get(id); },
        querySelectorAll(selector) { return this.documentElement.querySelectorAll(selector); },
        querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
        addEventListener(name, callback) { this.documentElement.addEventListener(name, callback); }
    };
    class Element {
        constructor(tag) {
            this.tagName = tag.toUpperCase();
            this.children = [];
            this.parentElement = null;
            this.attributes = new Map();
            this.listeners = new Map();
            this.className = '';
            this._text = '';
            this.open = false;
            this.hidden = false;
            this.value = '';
            this.style = { setProperty(name, value) { this[name] = String(value); } };
            this.dataset = new Proxy({}, {
                get: (_, name) => this.getAttribute('data-' + name.replace(/[A-Z]/g, (letter) => '-' + letter.toLowerCase())),
                set: (_, name, value) => {
                    this.setAttribute('data-' + name.replace(/[A-Z]/g, (letter) => '-' + letter.toLowerCase()), value);
                    return true;
                }
            });
            this.classList = {
                contains: (name) => this.className.split(/\s+/).includes(name),
                add: (...names) => { this.className = [...new Set([...this.className.split(/\s+/).filter(Boolean), ...names])].join(' '); },
                remove: (...names) => { this.className = this.className.split(/\s+/).filter((name) => !names.includes(name)).join(' '); },
                toggle: (name, force) => {
                    const include = force === undefined ? !this.classList.contains(name) : force;
                    this.classList[include ? 'add' : 'remove'](name);
                    return include;
                }
            };
        }
        get firstElementChild() { return this.children[0] || null; }
        get lang() { return this.getAttribute('lang') || ''; }
        set lang(value) { this.setAttribute('lang', value); }
        get textContent() { return this._text + this.children.map((child) => child.textContent).join(''); }
        set textContent(value) {
            this.replaceChildren();
            this._text = String(value);
        }
        set innerHTML(_) { assert.fail('Untrusted monitor text must never be assigned to innerHTML'); }
        setAttribute(name, value) {
            this.attributes.set(name, String(value));
            if (name === 'id') { this.id = String(value); nodes.set(this.id, this); }
            if (name === 'class') this.className = String(value);
            if (name === 'value') this.value = String(value);
            if (name === 'hidden') this.hidden = true;
        }
        getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
        hasAttribute(name) { return this.attributes.has(name); }
        removeAttribute(name) { this.attributes.delete(name); if (name === 'hidden') this.hidden = false; }
        matches(selector) {
            return selector.split(',').some((part) => {
                const text = part.trim();
                if (text.startsWith('#')) return this.id === text.slice(1);
                if (text.startsWith('.')) return this.classList.contains(text.slice(1));
                const attribute = text.match(/^\[([\w-]+)(?:=["']?([^"'\]]+)["']?)?\]$/);
                if (attribute) return this.hasAttribute(attribute[1]) && (attribute[2] === undefined || this.getAttribute(attribute[1]) === attribute[2]);
                return text === '*' || this.tagName.toLowerCase() === text.toLowerCase();
            });
        }
        querySelectorAll(selector) {
            return this.children.flatMap((child) => [...(child.matches(selector) ? [child] : []), ...child.querySelectorAll(selector)]);
        }
        querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
        closest(selector) { return this.matches(selector) ? this : this.parentElement?.closest(selector) || null; }
        append(...children) { children.forEach((child) => this.insertBefore(child, null)); }
        insertBefore(child, next) {
            child.remove();
            const index = next ? this.children.indexOf(next) : this.children.length;
            assert.notEqual(index, -1, 'Reference node must belong to this parent');
            this.children.splice(index, 0, child);
            child.parentElement = this;
            return child;
        }
        remove() {
            if (!this.parentElement) return;
            if (this.contains(document.activeElement)) document.activeElement = null;
            const siblings = this.parentElement.children;
            siblings.splice(siblings.indexOf(this), 1);
            this.parentElement = null;
        }
        replaceChildren(...children) {
            [...this.children].forEach((child) => child.remove());
            this._text = '';
            this.append(...children);
        }
        contains(node) { return this === node || this.children.some((child) => child.contains(node)); }
        focus() { document.activeElement = this; }
        addEventListener(name, callback) {
            if (!this.listeners.has(name)) this.listeners.set(name, []);
            this.listeners.get(name).push(callback);
        }
        dispatch(name, detail = {}) {
            for (const callback of this.listeners.get(name) || []) callback({ target: this, currentTarget: this, preventDefault() {}, stopPropagation() {}, ...detail });
        }
    }
    const html = getProjectMonitorWebviewHtml({ cspSource: 'https://webview.example' }, options);
    const root = new Element('document');
    const stack = [root];
    const decode = (value) => value.replace(/&(amp|lt|gt|quot|#39);/g, (_, entity) => ({ amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'" })[entity]);
    const markup = html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '').replace(/<!--[\s\S]*?-->/g, '');
    for (const token of markup.match(/<[^>]+>|[^<]+/g) || []) {
        if (/^<!/.test(token)) continue;
        if (/^<\//.test(token)) { stack.pop(); continue; }
        const opening = token.match(/^<([\w-]+)/);
        if (opening) {
            const node = new Element(opening[1]);
            const attributes = token.slice(opening[0].length).replace(/\/?\s*>$/, '');
            for (const match of attributes.matchAll(/([\w:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
                node.setAttribute(match[1], decode(match[2] ?? match[3] ?? match[4] ?? ''));
            }
            stack.at(-1).append(node);
            if (!/^(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)$/i.test(opening[1]) && !/\/>$/.test(token)) stack.push(node);
        } else {
            const value = decode(token).trim();
            if (value) stack.at(-1)._text += value;
        }
    }
    document.documentElement = root.querySelector('html');
    document.body = root.querySelector('body');
    const messages = [];
    let state = savedState;
    let receive;
    let currentTime = Date.parse(options.now || '2026-09-12T08:01:00Z');
    let timerId = 0;
    const timers = new Map();
    class MonitorDate extends Date {
        constructor(...values) { super(...(values.length ? values : [currentTime])); }
        static now() { return currentTime; }
    }
    const context = vm.createContext({
        document,
        MutationObserver: class { observe() {} },
        Date: MonitorDate,
        window: {
            addEventListener(name, callback) { if (name === 'message') receive = callback; },
            matchMedia: () => ({ matches: false, addEventListener() {} })
        },
        setTimeout(callback, delay) { const id = ++timerId; timers.set(id, { callback, due: currentTime + delay }); return id; },
        clearTimeout(id) { timers.delete(id); },
        acquireVsCodeApi: () => ({
            getState: () => state,
            setState: (value) => { state = value; },
            postMessage: (message) => messages.push(message)
        })
    });
    for (const match of html.matchAll(/<script\b[^>]*nonce="[^"]+"[^>]*>([\s\S]*?)<\/script>/g)) vm.runInContext(match[1], context);
    return {
        html, document, nodes, messages,
        get savedState() { return state; },
        advanceTime(milliseconds) {
            currentTime += milliseconds;
            for (const [id, timer] of timers) {
                if (timer.due <= currentTime) { timers.delete(id); timer.callback(); }
            }
        },
        render(snapshot) { receive({ data: { type: 'projectMonitorSnapshot', state: snapshot } }); },
        appearance(appearance) { receive({ data: { type: 'projectMonitorAppearance', appearance } }); },
        change(id, value) { const node = nodes.get(id); node.value = value; node.dispatch(node.tagName === 'INPUT' ? 'input' : 'change'); }
    };
}

test('ToolAI promotion switches language and only requests explicit navigation or dismissal', () => {
    const view = createWebview({}, { language: 'en' });
    assert.equal(view.nodes.get('toolai-promotion').hidden, false);
    assert.match(view.nodes.get('toolai-promotion').textContent, /Discover more AI tools/);
    assert.equal(view.messages.some(item => item.type === 'openToolAI'), false);
    view.nodes.get('toolai-open').dispatch('click');
    assert.equal(view.messages.at(-1).type, 'openToolAI');
    view.appearance({ language: 'zh', languagePreference: 'zh', theme: 'light' });
    assert.match(view.nodes.get('toolai-promotion').textContent, /发现更多 AI 工具/);
    view.nodes.get('toolai-dismiss').dispatch('click');
    assert.equal(view.nodes.get('toolai-promotion').hidden, true);
    assert.equal(view.messages.at(-1).type, 'dismissToolAI');
    const hidden = createWebview({}, { language: 'en', showToolAI: false });
    assert.equal(hidden.nodes.get('toolai-promotion').hidden, true);
});

function findAll(root, className) {
    const matches = root.className.split(' ').includes(className) ? [root] : [];
    return matches.concat(root.children.flatMap((child) => findAll(child, className)));
}

function visibleProjectNames(view) {
    return findAll(view.nodes.get('content'), 'project-name').filter((node) => {
        for (let current = node; current; current = current.parentElement) if (current.hidden) return false;
        return true;
    }).map((node) => node.textContent);
}

function visibleAgentTitles(view) {
    return findAll(view.nodes.get('content'), 'agent-title').filter((node) => {
        let child = node;
        for (let current = node; current; current = current.parentElement) {
            if (current.hidden) return false;
            if (current.tagName === 'DETAILS' && !current.open && child !== current.firstElementChild) return false;
            child = current;
        }
        return true;
    }).map((node) => node.textContent);
}

function agent(overrides = {}) {
    return {
        agentId: 'main-full-id', shortId: 'a1b2c3d4e5', parentAgentId: '',
        role: 'main', taskTitle: '修复登录超时', titleSource: 'prompt', status: 'running',
        updatedAtUtc: '2026-09-12T08:00:00Z', ...overrides
    };
}

function session(overrides = {}) {
    return {
        threadHash: 'session-a', sessionId: 'session-a-full', sessionTitle: '登录问题',
        agents: [
            agent(),
            agent({ agentId: 'done-child', shortId: 'c1', parentAgentId: 'main-full-id', role: 'subagent', taskTitle: '补充回归测试', titleSource: 'explicit', status: 'stopped' }),
            agent({ agentId: 'active-child', shortId: 'c2', parentAgentId: 'main-full-id', role: 'subagent', taskTitle: '排查认证接口', titleSource: 'explicit', status: 'running' })
        ],
        ...overrides
    };
}

function project(overrides = {}) {
    return {
        projectKey: 'project-a', name: '项目 A', path: 'D:\\work\\project-a', status: 'running',
        updatedAtUtc: '2026-09-12T08:00:00Z', sessions: [session()], ...overrides
    };
}

function snapshot(projects = [project()]) {
    return {
        kind: 'ready', totalCount: projects.length,
        runningCount: projects.filter((item) => item.status === 'running').length,
        completedCount: projects.filter((item) => item.status === 'completed').length,
        sourcePath: 'C:\\state\\project-monitor.json', projects
    };
}

test('renders each session with its main task first, running children first and independent agent status', () => {
    const view = createWebview();
    view.render(snapshot([project({ status: 'completed' })]));
    const content = view.nodes.get('content');
    assert.deepEqual(findAll(content, 'agent-title').map((node) => node.textContent), [
        '修复登录超时', '排查认证接口', '补充回归测试'
    ]);
    assert.deepEqual(findAll(content, 'status-label').map((node) => node.textContent), [
        '已完成', '执行中', '执行中', '刚刚结束'
    ]);
    assert.match(content.textContent, /主 Agent提示词摘要会话 · 登录问题/);
    assert.match(content.textContent, /2 执行中 · 3 Agent/);
    assert.match(findAll(content, 'agent-count')[0].title, /1 个会话 · 3 个 Agent · 2 个执行中/);
    assert.equal(findAll(content, 'project-row')[0].tagName, 'SUMMARY');
    assert.equal(findAll(content, 'session')[0].firstElementChild.tagName, 'SUMMARY');
});

test('preserves focus, node identity and disclosure state when tasks update and projects reorder', () => {
    const view = createWebview();
    const second = project({ projectKey: 'project-b', name: '项目 B', sessions: [] });
    view.render(snapshot([project(), second]));
    const content = view.nodes.get('content');
    const summary = findAll(content, 'project-row')[0];
    const disclosure = summary.parentElement;
    const sessionDisclosure = findAll(content, 'session')[0];
    disclosure.open = true;
    disclosure.dispatch('toggle');
    sessionDisclosure.open = false;
    sessionDisclosure.dispatch('toggle');
    summary.focus();
    const changedSession = session();
    changedSession.agents[0].taskTitle = '下一轮：修复会话恢复';
    view.render(snapshot([second, project({ sessions: [changedSession] })]));
    assert.equal(findAll(content, 'project-row')[1], summary);
    assert.equal(view.document.activeElement, summary);
    assert.equal(disclosure.open, true);
    assert.equal(sessionDisclosure.open, false);
    assert.match(content.textContent, /下一轮：修复会话恢复/);

    const reopened = createWebview(view.savedState);
    reopened.render(snapshot());
    assert.equal(findAll(reopened.nodes.get('content'), 'project-row')[0].parentElement.open, true);
    assert.equal(findAll(reopened.nodes.get('content'), 'session')[0].open, false);
});

test('retains every session and follows parent relationships without losing or duplicating cyclic agents', () => {
    const view = createWebview();
    const firstSession = session();
    firstSession.agents.push(
        agent({ agentId: 'grandchild', role: 'subagent', parentAgentId: 'active-child', taskTitle: '验证接口响应' }),
        agent({ agentId: 'cycle-one', role: 'subagent', parentAgentId: 'cycle-two', taskTitle: '循环记录一' }),
        agent({ agentId: 'cycle-two', role: 'subagent', parentAgentId: 'cycle-one', taskTitle: '循环记录二' })
    );
    view.render(snapshot([project({ sessions: [firstSession, session({ threadHash: 'session-b', agents: [agent({ taskTitle: '优化首页', status: 'ended' })] })] })]));
    const content = view.nodes.get('content');
    assert.equal(findAll(content, 'session').length, 2);
    assert.equal(findAll(content, 'agent-title').length, 7);
    const grandchild = findAll(content, 'agent-title').find((node) => node.textContent === '验证接口响应');
    const parentItem = grandchild.parentElement.parentElement.parentElement.parentElement.parentElement;
    assert.equal(findAll(parentItem.children[0], 'agent-title')[0].textContent, '排查认证接口');
    assert.match(content.textContent, /会话已结束/);
});

test('renders unknown and missing fields honestly and never treats prompt text as HTML', () => {
    const view = createWebview();
    const payload = '<img src=x onerror="alert(1)"> 中文任务';
    view.render(snapshot([project({ name: payload, sessions: [session({
        sessionTitle: payload,
        agents: [agent({ taskTitle: payload, titleSource: 'transcript', agentType: payload }), agent({ agentId: 'unknown', role: 'subagent', taskTitle: '', status: 'unexpected', updatedAtUtc: '', startedAtUtc: '' })]
    })] })]));
    const content = view.nodes.get('content');
    assert.equal(findAll(content, 'agent-title')[0].textContent, payload);
    assert.match(content.textContent, /未获取任务标题/);
    assert.match(content.textContent, /状态待确认/);
    assert.match(content.textContent, /时间未知/);
    assert.equal(content.textContent.includes('1970'), false);
});

test('handles legacy projects, empty/error recovery and removes agents missing from a later snapshot', () => {
    const view = createWebview();
    view.render(snapshot([project({ sessions: undefined })]));
    assert.match(view.nodes.get('content').textContent, /尚未采集到 Agent 明细/);
    view.render({ kind: 'empty' });
    assert.match(view.nodes.get('content').textContent, /尚无项目记录/);
    view.render({ kind: 'error', error: 'broken snapshot' });
    assert.match(view.nodes.get('content').textContent, /broken snapshot/);
    view.render(snapshot());
    assert.equal(findAll(view.nodes.get('content'), 'agent-title').length, 3);
    view.render(snapshot([project({ sessions: [session({ agents: [agent()] })] })]));
    assert.equal(findAll(view.nodes.get('content'), 'agent-title').length, 1);
    assert.equal(view.nodes.get('content').textContent.includes('排查认证接口'), false);
});

test('uses restrictive CSP and retains ready/refresh messaging', () => {
    const view = createWebview();
    assert.match(view.html, /default-src 'none'/);
    assert.match(view.html, /script-src 'nonce-[A-Za-z0-9]+'/);
    assert.equal(view.messages[0].type, 'ready');
    view.nodes.get('refresh').dispatch('click');
    assert.equal(view.messages.at(-1).type, 'refresh');
});

test('searches project paths and nested agent tasks, combines filters and keeps snapshot totals', () => {
    const view = createWebview();
    view.render(snapshot([
        project(),
        project({ projectKey: 'project-b', name: 'Documentation', path: 'D:\\docs\\GUIDE', status: 'completed', sessions: [] })
    ]));
    view.change('search', '认证接口');
    assert.deepEqual(visibleProjectNames(view), ['项目 A']);
    assert.equal(findAll(view.nodes.get('content'), 'agent-title').length, 3, 'A matched task must retain its session and sibling context');
    view.nodes.get('filter-completed').dispatch('click');
    assert.deepEqual(visibleProjectNames(view), []);
    assert.equal(view.nodes.get('total-count').textContent, '2', 'Filtering must not change the actual monitored total');
    view.change('search', 'guide');
    assert.deepEqual(visibleProjectNames(view), ['Documentation'], 'Project path search is case insensitive');
    view.nodes.get('filter-running').dispatch('click');
    assert.deepEqual(visibleProjectNames(view), []);
    view.change('search', '');
    assert.deepEqual(visibleProjectNames(view), ['项目 A']);
    view.nodes.get('filter-all').dispatch('click');
    assert.deepEqual(visibleProjectNames(view), ['项目 A', 'Documentation']);
});

test('changing appearance translates live task metadata without changing source text or losing focus and expansion', () => {
    const view = createWebview();
    view.render(snapshot());
    const content = view.nodes.get('content');
    const summary = findAll(content, 'project-row')[0];
    const disclosure = summary.parentElement;
    disclosure.open = true;
    disclosure.dispatch('toggle');
    summary.focus();
    view.appearance({ language: 'en', languagePreference: 'en', theme: 'light' });
    assert.equal(view.document.documentElement.getAttribute('lang'), 'en');
    assert.equal(view.document.documentElement.dataset.theme, 'light');
    assert.equal(findAll(content, 'project-row')[0], summary);
    assert.equal(view.document.activeElement, summary);
    assert.equal(disclosure.open, true);
    assert.equal(findAll(content, 'agent-title')[0].textContent, '修复登录超时');
    assert.match(content.textContent, /Main agent/);
    assert.match(content.textContent, /Session/);
    assert.doesNotMatch(content.textContent, /主 Agent|执行中|本轮已结束|提示词摘要/);
    view.appearance({ language: 'zh', languagePreference: 'auto', theme: 'dark' });
    assert.equal(view.document.documentElement.dataset.theme, 'dark');
    assert.match(content.textContent, /主 Agent/);
});

test('one-click appearance toggles persist preferences while reopening retains search, filters and disclosures', () => {
    const view = createWebview();
    view.render(snapshot());
    view.nodes.get('language-toggle').dispatch('click');
    let update = view.messages.at(-1);
    assert.equal(update.type, 'setAppearance');
    assert.equal(update.languagePreference, 'en');
    view.nodes.get('theme-toggle').dispatch('click');
    update = view.messages.at(-1);
    assert.equal(update.type, 'setAppearance');
    assert.equal(update.languagePreference, 'en');
    assert.equal(update.theme, 'light');
    const disclosure = findAll(view.nodes.get('content'), 'project-row')[0].parentElement;
    disclosure.open = false;
    disclosure.dispatch('toggle');
    view.change('search', '认证接口');
    view.nodes.get('filter-running').dispatch('click');
    const reopened = createWebview(view.savedState, { language: 'en', languagePreference: 'en', theme: 'light' });
    reopened.render(snapshot());
    assert.equal(reopened.nodes.get('search').value, '认证接口');
    assert.equal(reopened.nodes.get('filter-running').getAttribute('aria-pressed'), 'true');
    assert.equal(findAll(reopened.nodes.get('content'), 'project-row')[0].parentElement.open, true, 'A saved search temporarily expands its matching project');
    reopened.change('search', '');
    assert.equal(findAll(reopened.nodes.get('content'), 'project-row')[0].parentElement.open, false, 'Clearing search restores the explicit disclosure state');
    assert.equal(reopened.document.documentElement.dataset.theme, 'light');
    assert.equal(reopened.nodes.get('language-toggle').textContent, 'EN');
    assert.equal(reopened.nodes.get('theme-label').textContent, 'Light');
    reopened.nodes.get('language-toggle').dispatch('click');
    assert.equal(reopened.nodes.get('language-toggle').textContent, '中文');
    assert.equal(reopened.document.documentElement.lang, 'zh-CN');
    reopened.nodes.get('theme-toggle').dispatch('click');
    assert.equal(reopened.nodes.get('theme-label').textContent, '深色');
    assert.equal(reopened.messages.at(-1).theme, 'dark');
});

test('theme toggle flips the effective editor theme without changing automatic language preference', () => {
    for (const editorTheme of ['vscode-dark', 'vscode-light', 'vscode-high-contrast-light']) {
        const view = createWebview({}, { language: 'en', languagePreference: 'auto', theme: 'auto' });
        view.document.body.classList.add(editorTheme);
        view.nodes.get('theme-toggle').dispatch('click');
        const expected = editorTheme === 'vscode-dark' ? 'light' : 'dark';
        assert.equal(view.messages.at(-1).theme, expected);
        assert.equal(view.messages.at(-1).languagePreference, 'auto');
        assert.equal(view.document.documentElement.dataset.theme, expected);
        assert.equal(view.nodes.get('language-toggle').textContent, 'EN');
        view.nodes.get('language-toggle').dispatch('click');
        assert.equal(view.messages.at(-1).languagePreference, 'zh');
        assert.equal(view.messages.at(-1).theme, expected);
    }
});

test('error snapshots remain visible under filters, translate immediately and recover the selected view', () => {
    const view = createWebview();
    view.render(snapshot());
    view.change('search', '认证接口');
    view.nodes.get('filter-running').dispatch('click');
    view.render({ kind: 'error', error: '<script>broken snapshot</script>', sourcePath: 'D:\\state\\monitor.json' });
    assert.match(view.nodes.get('content').textContent, /<script>broken snapshot<\/script>/);
    view.appearance({ language: 'en', languagePreference: 'en', theme: 'light' });
    assert.match(view.nodes.get('content').textContent, /<script>broken snapshot<\/script>/);
    assert.doesNotMatch(view.nodes.get('content').textContent, /快照读取失败|后台轮询/);
    view.render(snapshot());
    assert.deepEqual(visibleProjectNames(view), ['项目 A']);
    assert.equal(view.nodes.get('search').value, '认证接口');
    assert.equal(view.nodes.get('filter-running').getAttribute('aria-pressed'), 'true');
    assert.equal(findAll(view.nodes.get('content'), 'agent-title').length, 3);
});

test('focuses every running agent and only the two newest completions across a whole project', () => {
    const view = createWebview();
    const state = snapshot([project({ sessions: [
        session({ threadHash: 'old-session', agents: [agent({ agentId: 'old-main', taskTitle: '昨天的历史任务', status: 'ended', updatedAtUtc: '2026-09-11T08:00:00Z' })] }),
        session({ threadHash: 'active-session', agents: [
            agent({ taskTitle: '仍在执行的主任务' }),
            agent({ agentId: 'recent-child', role: 'subagent', parentAgentId: 'main-full-id', taskTitle: '第二个刚完成任务', status: 'stopped', updatedAtUtc: '2026-09-12T08:00:50Z' }),
            agent({ agentId: 'other-recent-child', role: 'subagent', parentAgentId: 'main-full-id', taskTitle: '第三个刚完成任务', status: 'completed', updatedAtUtc: '2026-09-12T08:00:40Z' }),
            agent({ agentId: 'running-old', role: 'subagent', parentAgentId: 'main-full-id', taskTitle: '较早启动的执行任务', updatedAtUtc: '2026-09-12T07:00:00Z' }),
            agent({ agentId: 'running-new', role: 'subagent', parentAgentId: 'main-full-id', taskTitle: '最近活动的执行任务', updatedAtUtc: '2026-09-12T08:00:55Z' })
        ] }),
        session({ threadHash: 'recent-session', agents: [agent({ agentId: 'recent-main', taskTitle: '最新刚完成任务', status: 'completed', updatedAtUtc: '2026-09-12T08:00:58Z' })] })
    ] })]);
    view.render(state);
    assert.deepEqual(visibleAgentTitles(view), [
        '仍在执行的主任务', '最近活动的执行任务', '较早启动的执行任务', '第二个刚完成任务', '最新刚完成任务'
    ]);
    assert.equal(findAll(view.nodes.get('content'), 'agent-title').length, 7, 'Historical data remains in the DOM');
    const toggle = findAll(view.nodes.get('content'), 'history-toggle')[0];
    assert.equal(toggle.hidden, false);
    assert.equal(toggle.getAttribute('aria-expanded'), 'false');
    toggle.dispatch('click');
    assert.equal(toggle.getAttribute('aria-expanded'), 'true');
    assert.equal(visibleAgentTitles(view).length, 7);
    toggle.dispatch('click');
    assert.equal(toggle.getAttribute('aria-expanded'), 'false');
    assert.equal(visibleAgentTitles(view).length, 5);
    view.advanceTime(6 * 60 * 1000);
    assert.deepEqual(visibleAgentTitles(view), ['仍在执行的主任务', '最近活动的执行任务', '较早启动的执行任务'], 'Completions leave focus after five minutes without a new host snapshot; long-running agents remain');
});

test('retains stopped ancestors around an active descendant while folding unrelated historical siblings', () => {
    const view = createWebview();
    const historical = { status: 'stopped', updatedAtUtc: '2026-09-11T08:00:00Z' };
    view.render(snapshot([project({ sessions: [session({ agents: [
        agent({ ...historical, taskTitle: '已结束主任务' }),
        agent({ ...historical, agentId: 'parent', role: 'subagent', parentAgentId: 'main-full-id', taskTitle: '已结束中间任务' }),
        agent({ agentId: 'active-grandchild', role: 'subagent', parentAgentId: 'parent', taskTitle: '仍在执行的孙任务' }),
        agent({ ...historical, agentId: 'old-sibling', role: 'subagent', parentAgentId: 'parent', taskTitle: '无关历史子任务' })
    ] })] })]));
    assert.deepEqual(visibleAgentTitles(view), ['已结束主任务', '已结束中间任务', '仍在执行的孙任务']);
    const hiddenSibling = findAll(view.nodes.get('content'), 'agent-title').find((node) => node.textContent === '无关历史子任务');
    assert.equal(hiddenSibling.closest('li').hidden, true);
    findAll(view.nodes.get('content'), 'history-toggle')[0].dispatch('click');
    assert.equal(visibleAgentTitles(view).length, 4);
});

test('restores each project history preference after reopening and only temporarily reveals search results', () => {
    const state = snapshot([project({ sessions: [
        session({ threadHash: 'active', agents: [agent()] }),
        session({ threadHash: 'history', agents: [
            agent({ agentId: 'historical-main', taskTitle: '归档主任务', status: 'ended', updatedAtUtc: '2026-09-11T08:00:00Z' }),
            agent({ agentId: 'historical-child', parentAgentId: 'historical-main', role: 'subagent', taskTitle: '隐藏的数据库迁移', status: 'completed', updatedAtUtc: '2026-09-11T08:00:00Z' })
        ] })
    ] }), project({ projectKey: 'project-b', name: '项目 B', sessions: [session({ agents: [agent({ taskTitle: '第二个项目历史任务', status: 'ended', updatedAtUtc: '2026-09-11T08:00:00Z' })] })] })]);
    const view = createWebview();
    view.render(state);
    assert.deepEqual(visibleAgentTitles(view), ['修复登录超时']);
    const toggles = findAll(view.nodes.get('content'), 'history-toggle');
    toggles[0].dispatch('click');
    assert.equal(toggles[1].getAttribute('aria-expanded'), 'false', 'Expanding one project does not expand another');
    const reopened = createWebview(view.savedState);
    reopened.render(state);
    assert.equal(findAll(reopened.nodes.get('content'), 'history-toggle')[0].getAttribute('aria-expanded'), 'true');
    assert.equal(visibleAgentTitles(reopened).length, 3);
    toggles[0].dispatch('click');
    view.change('search', '数据库迁移');
    assert.deepEqual(visibleProjectNames(view), ['项目 A']);
    assert.equal(visibleAgentTitles(view).includes('隐藏的数据库迁移'), true, 'Search reveals a matched historical agent and its ancestors');
    assert.equal(view.nodes.get('total-count').textContent, '2');
    view.change('search', '');
    assert.deepEqual(visibleAgentTitles(view), ['修复登录超时']);
    assert.equal(toggles[0].getAttribute('aria-expanded'), 'false', 'Search must not overwrite explicit history preference');
});

test('visible music preset and playback controls open their separate commands', () => {
    const view = createWebview();
    view.nodes.get('music-settings').dispatch('click');
    assert.equal(view.messages.at(-1).type, 'chooseCompletionMusic');
    assert.match(view.nodes.get('music-settings').textContent, /音乐预置/);
    assert.ok(view.nodes.get('music-settings').getAttribute('aria-label'));
    view.nodes.get('playback-settings').dispatch('click');
    assert.equal(view.messages.at(-1).type, 'configurePlayback');
    assert.match(view.nodes.get('playback-settings').textContent, /播放设置/);
    view.appearance({ language: 'en', languagePreference: 'en', theme: 'dark' });
    assert.match(view.nodes.get('music-settings').getAttribute('aria-label'), /music|sound|playback/i);
    assert.match(view.nodes.get('music-settings').textContent, /Music presets/);
    assert.equal(view.nodes.get('playback-settings').textContent, 'Playback settings');
});

test('keeps explicitly expanded completed-project history open after recent agents age out', () => {
    const view = createWebview();
    const state = snapshot([project({ status: 'completed', sessions: [session({ agents: [
        agent({ taskTitle: '刚完成主任务', status: 'completed' }),
        agent({ agentId: 'history-child', role: 'subagent', parentAgentId: 'main-full-id', taskTitle: '先前的历史子任务', status: 'stopped', updatedAtUtc: '2026-09-11T08:00:00Z' })
    ] })] })]);
    view.render(state);
    const details = findAll(view.nodes.get('content'), 'project')[0];
    assert.equal(details.open, true);
    assert.deepEqual(visibleAgentTitles(view), ['刚完成主任务']);
    findAll(view.nodes.get('content'), 'history-toggle')[0].dispatch('click');
    view.advanceTime(6 * 60 * 1000);
    assert.equal(details.open, true, 'Aging must not close a project while the user is reading its expanded history');
    assert.deepEqual(visibleAgentTitles(view), ['刚完成主任务', '先前的历史子任务']);
    details.open = false;
    details.dispatch('toggle');
    view.render(state);
    assert.equal(details.open, false, 'The explicit project disclosure choice still takes priority');
    assert.deepEqual(visibleAgentTitles(view), []);
});
