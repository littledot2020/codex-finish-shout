require('./dev-prepare');
const fs = require('node:fs');
const path = require('node:path');
const directory = path.resolve(__dirname, '../.dev/codex/codex-finish-shout-state');
const now = new Date().toISOString();
const projects = [
    { projectKey: 'demo-running', name: 'Demo · 演示项目', path: 'C:\\Demo\\Running', status: 'running', updatedAtUtc: now, sessions: [] },
    { projectKey: 'demo-complete', name: 'Completed · 已完成', path: 'C:\\Demo\\Completed', status: 'completed', updatedAtUtc: now, sessions: [] }
];
fs.writeFileSync(path.join(directory, 'project-monitor.json'), JSON.stringify({ schemaVersion: 1, updatedAtUtc: now, projects }, null, 2));
console.log('Created two synthetic projects. No real Codex configuration or audio was used.');
