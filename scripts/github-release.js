// Credentials stay in Git Credential Manager and process memory; never print them.
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const repo = 'littledot2020/codex-finish-shout';
async function main() {
    const result = spawnSync('git', ['credential', 'fill'], {
        input: 'protocol=https\nhost=github.com\nusername=littledot2020\n\n', encoding: 'utf8',
        env: { ...process.env, GCM_INTERACTIVE: 'Never', GIT_TERMINAL_PROMPT: '0' }
    });
    const values = Object.fromEntries(result.stdout.trim().split(/\r?\n/).map(line => {
        const index = line.indexOf('='); return [line.slice(0, index), line.slice(index + 1)];
    }));
    if (!values.password) throw new Error('GitHub credential unavailable. Run: git credential-manager github login --username littledot2020 --browser');
    const headers = { Authorization: `Bearer ${values.password}`, 'User-Agent': 'codex-finish-shout-release', Accept: 'application/vnd.github+json' };
    async function api(endpoint, options = {}) {
        const response = await fetch(endpoint.startsWith('https:') ? endpoint : `https://api.github.com${endpoint}`,
            { ...options, headers: { ...headers, ...options.headers }, signal: AbortSignal.timeout(60000) });
        if (!response.ok) throw new Error(`GitHub ${response.status}: ${(await response.text()).slice(0, 500)}`);
        return response.json();
    }
    const account = await api('/user');
    if (account.login !== 'littledot2020') throw new Error('Unexpected GitHub account');
    console.log(`Authenticated: ${account.login}`);
    const action = process.argv[2] || 'status';
    if (action === 'create') {
        let existing;
        try { existing = await api(`/repos/${repo}`); }
        catch (error) { if (!error.message.startsWith('GitHub 404:')) throw error; }
        const created = existing || await api('/user/repos', { method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name: 'codex-finish-shout', description: 'Codex project monitor and offline completion music for VS Code. English / 中文. Discover AI tools at ToolAI.io.',
                homepage: 'https://www.toolai.io/', private: false, auto_init: false }) });
        console.log(created.html_url);
    } else if (action === 'ci' || action === 'ci-failure') {
        const runs = await api(`/repos/${repo}/actions/runs?per_page=5`);
        for (const run of runs.workflow_runs) {
            console.log(JSON.stringify({ id: run.id, sha: run.head_sha.slice(0, 8), status: run.status, conclusion: run.conclusion, url: run.html_url }));
            const jobs = await api(`/repos/${repo}/actions/runs/${run.id}/jobs`);
            for (const job of jobs.jobs) console.log(JSON.stringify({ name: job.name, status: job.status, conclusion: job.conclusion,
                steps: job.steps.filter(step => step.status !== 'queued').map(step => ({ name: step.name, status: step.status, conclusion: step.conclusion })) }));
            if (action === 'ci-failure') {
                for (const job of jobs.jobs.filter(job => job.conclusion === 'failure')) {
                    const response = await fetch(`https://api.github.com/repos/${repo}/actions/jobs/${job.id}/logs`, { headers, signal: AbortSignal.timeout(60000) });
                    if (!response.ok) throw new Error('Unable to retrieve job log: ' + response.status);
                    const directory = path.join(__dirname, '../.dev');
                    fs.mkdirSync(directory, { recursive: true });
                    fs.writeFileSync(path.join(directory, `ci-${job.id}.log`), await response.text());
                    console.log(`Saved .dev/ci-${job.id}.log`);
                }
                break;
            }
        }
    } else if (action === 'release') {
        const version = require('../codex-finish-shout-controls/package.json').version;
        const release = await api(`/repos/${repo}/releases`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({
            tag_name: `v${version}`, name: `v${version} — Integrated preview / 一体化预览版`, prerelease: true,
            body: fs.readFileSync(path.join(__dirname, '../docs/RELEASE.md'), 'utf8')
        }) });
        for (const file of fs.readdirSync(path.join(__dirname, '../dist')).filter(name => /\.vsix$|^SHA256SUMS\.txt$/.test(name))) {
            await api(release.upload_url.replace(/\{.*$/, '') + '?name=' + encodeURIComponent(file), {
                method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: fs.readFileSync(path.join(__dirname, '../dist', file))
            });
            console.log('Uploaded: ' + file);
        }
        console.log(release.html_url);
    } else {
        console.log('GitHub publishing authentication is ready.');
    }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
