const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

function getProjectMonitorWebviewHtml(_webview, options = {}) {
    const nonce = crypto.randomBytes(18).toString('hex');
    const appearance = {
        language: options.language === 'en' ? 'en' : 'zh',
        languagePreference: ['auto', 'zh', 'en'].includes(options.languagePreference) ? options.languagePreference : 'auto',
        theme: ['auto', 'dark', 'light'].includes(options.theme) ? options.theme : 'auto',
        showToolAI: options.showToolAI !== false
    };
    const media = path.join(__dirname, 'media');
    const css = fs.readFileSync(path.join(media, 'project-monitor.css'), 'utf8');
    const script = fs.readFileSync(path.join(media, 'project-monitor.js'), 'utf8')
        .replace('__INITIAL_APPEARANCE__', JSON.stringify(appearance));
    const icon = (paths) => `<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
    const close = icon('<path d="m6 6 12 12M6 18 18 6"/>');
    return `<!doctype html>
<html lang="${appearance.language === 'zh' ? 'zh-CN' : 'en'}" data-theme="${appearance.theme}">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}';">
    <title>Codex · ${appearance.language === 'zh' ? '项目总览' : 'Project overview'}</title>
    <style nonce="${nonce}">${css}</style>
</head>
<body>
    <a class="skip-link" href="#main" data-i18n="skip"></a>
    <div class="monitor">
        <header class="app-header">
            <div class="brand"><span class="brand-icon">${icon('<path d="m12 3 9 5-9 5-9-5 9-5ZM3 12l9 5 9-5M3 16l9 5 9-5"/>')}</span><strong>Codex</strong><span class="brand-caption" data-i18n="title"></span></div>
            <div class="header-actions">
                <button type="button" class="icon-button quick-toggle language-toggle" id="language-toggle"></button>
                <button type="button" class="icon-button quick-toggle" id="theme-toggle"><span id="theme-dark-icon">${icon('<path d="M20.5 13A8.5 8.5 0 0 1 11 3.5 8.5 8.5 0 1 0 20.5 13Z"/>')}</span><span id="theme-light-icon" hidden>${icon('<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/>')}</span><span id="theme-label"></span></button>
                <span class="action-divider" aria-hidden="true"></span>
                <button type="button" class="icon-button" id="refresh" data-label="refresh">${icon('<path d="M18.4 8A7 7 0 1 0 19 14M19 3v5h-5"/>')}</button>
                <button type="button" class="icon-button" id="info-toggle" data-label="info" aria-controls="info-panel" aria-expanded="false">${icon('<circle cx="12" cy="12" r="8"/><path d="M12 11v5M12 7.5v.1"/>')}</button>
            </div>
        </header>
        <div class="audio-toolbar" role="group" data-label="audioControls">
            <button type="button" class="icon-button audio-button music-presets-button" id="music-settings" data-label="music">${icon('<path d="M9 18V5l11-2v13M9 9l11-2"/><ellipse cx="6" cy="18" rx="3" ry="2"/><ellipse cx="17" cy="16" rx="3" ry="2"/>')}<span data-i18n="musicPresets"></span></button>
            <button type="button" class="icon-button audio-button" id="playback-settings" data-label="playbackSettings"><span data-i18n="playbackSettings"></span></button>
            <button type="button" class="icon-button audio-button stop-music-button" id="stop-music" data-label="stopMusic">${icon('<path d="M11 5 6 9H3v6h3l5 4V5ZM16 9l6 6m0-6-6 6"/>')}<span id="stop-music-label" data-i18n="stopMusicShort"></span></button>
        </div>
        <section class="overview" data-label="statistics">
            <h1 class="sr-only" data-i18n="title"></h1>
            <div class="stats">
                <span class="stat active-projects"><span class="lamp running" aria-hidden="true"></span><strong id="running-count">—</strong><span data-i18n="runningProjects"></span></span>
                <span class="stat total"><strong id="total-count">—</strong><span data-i18n="projects"></span></span>
                <span class="stat"><span class="lamp completed" aria-hidden="true"></span><strong id="completed-count">—</strong><span data-i18n="completed"></span></span>
            </div>
        </section>
        <main id="main" class="workspace-body" tabindex="-1">
            <div class="filter-bar">
                <div class="search-field">${icon('<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/>')}<input type="search" id="search" autocomplete="off" spellcheck="false" data-label="search"><kbd aria-hidden="true">/</kbd></div>
                <div class="filter-tabs" role="group" data-label="filter">
                    <button type="button" id="filter-all" class="filter-button selected" aria-pressed="true" data-i18n="all"></button>
                    <button type="button" id="filter-running" class="filter-button" aria-pressed="false" data-i18n="running"></button>
                    <button type="button" id="filter-completed" class="filter-button" aria-pressed="false" data-i18n="completed"></button>
                </div>
            </div>
            <div id="content" data-label="title"></div>
        </main>
        <footer class="monitor-footer">
            <span class="updated-label"><span class="connection-dot" aria-hidden="true"></span><span id="snapshot-status" role="status" aria-live="polite"></span></span>
            <span id="visible-count"></span>
        </footer>
        <aside id="toolai-promotion" class="toolai-promotion" data-label="promotion"${appearance.showToolAI ? '' : ' hidden'}>
            <div class="toolai-copy"><span class="promotion-label" data-i18n="promotion"></span><strong data-i18n="toolaiTitle"></strong><p data-i18n="toolaiDescription"></p><button type="button" id="toolai-open" class="toolai-link" data-i18n="toolaiVisit"></button></div>
            <button type="button" id="toolai-dismiss" class="icon-button" data-label="dismissPromotion">${close}</button>
        </aside>
        <aside id="info-panel" class="popover info-panel" aria-labelledby="info-title" hidden>
            <div class="popover-heading"><h2 id="info-title" data-i18n="infoTitle"></h2><button type="button" id="info-close" class="icon-button" data-label="close">${close}</button></div>
            <div class="legend-grid">
                <span class="status running"><span class="lamp running" aria-hidden="true"></span><span data-i18n="running"></span></span>
                <span class="status unknown"><span class="lamp unknown" aria-hidden="true"></span><span data-i18n="unknown"></span></span>
                <span class="status completed"><span class="lamp completed" aria-hidden="true"></span><span data-i18n="completed"></span></span>
                <span class="status stopped"><span class="lamp stopped" aria-hidden="true"></span><span data-i18n="stopped"></span></span>
                <span class="status ended"><span class="lamp ended" aria-hidden="true"></span><span data-i18n="ended"></span></span>
            </div>
            <p data-i18n="infoHint"></p><p data-i18n="unknownHint"></p>
            <div class="info-source"><span data-i18n="source"></span><code id="source"></code></div>
            <small data-i18n="motion"></small>
        </aside>
    </div>
    <div id="announcement" class="sr-only" aria-live="polite"></div>
    <script nonce="${nonce}">${script}</script>
</body>
</html>`;
}

module.exports = { getProjectMonitorWebviewHtml };
