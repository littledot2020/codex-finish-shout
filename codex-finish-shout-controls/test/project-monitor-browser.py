"""Exercise the shipped Webview in Chromium: python test/project-monitor-browser.py.

Requires the Python Playwright package. Uses local Chrome on Windows, or the
Playwright Chromium installation elsewhere. --screenshots DIR exports direct
language/theme/music controls, compact projects, history and search views.
"""

import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess

from playwright.sync_api import sync_playwright


EXTENSION = Path(__file__).resolve().parents[1]


def snapshot():
    now = datetime.now(timezone.utc)

    def ago(minutes):
        return (now - timedelta(minutes=minutes)).isoformat().replace("+00:00", "Z")

    timestamp = ago(0)
    history = [
        {
            "threadHash": f"history-{index}",
            "sessionId": f"history-session-{index}",
            "sessionTitle": f"之前的工作 {index + 1}",
            "agents": [
                {"agentId": f"historical-main-{index}", "shortId": f"d5124eb{index}", "role": "main", "taskTitle": f"历史任务 {index + 1}：整理页面文案", "titleSource": "prompt", "status": "stopped", "updatedAtUtc": ago(1 if index == 0 else 10 + index)},
                {"agentId": f"historical-child-{index}", "shortId": f"f021bce{index}", "parentAgentId": f"historical-main-{index}", "role": "subagent", "taskTitle": f"归档验证 {index + 1}：检查会话恢复", "titleSource": "explicit", "status": "stopped", "updatedAtUtc": ago(10 + index)},
            ],
        }
        for index in range(6)
    ]
    return {
        "kind": "ready",
        "runningCount": 2,
        "completedCount": 1,
        "totalCount": 3,
        "sourcePath": "C:\\Users\\Developer\\.codex\\codex-finish-shout-state\\project-monitor.json",
        "projects": [
            {
                "projectKey": "branch",
                "name": "branch",
                "path": "D:\\Demo\\Projects\\Example\\ExampleAI\\branch",
                "status": "running",
                "updatedAtUtc": timestamp,
                "sessions": history + [{
                    "threadHash": "session-a",
                    "sessionId": "session-a-full",
                    "sessionTitle": "项目监控面板",
                    "agents": [
                        {"agentId": "main", "shortId": "a1b2c3d4", "role": "main", "taskTitle": "优化任务监控面板", "titleSource": "prompt", "status": "running", "updatedAtUtc": timestamp},
                    ],
                }],
            },
            {
                "projectKey": "controls",
                "name": "Demo Controls",
                "path": "D:\\Demo\\app\\controls",
                "status": "running",
                "updatedAtUtc": timestamp,
                "sessions": [{
                    "threadHash": "session-b",
                    "sessionTitle": "完成音乐设置",
                    "agents": [
                        {"agentId": "controls-main", "shortId": "c9d8e7f6", "role": "main", "taskTitle": "预置完成提示音乐并增加设置入口", "titleSource": "prompt", "status": "running", "updatedAtUtc": timestamp},
                        {"agentId": "child-active", "shortId": "b7c8d9e0", "parentAgentId": "controls-main", "role": "subagent", "taskTitle": "细化明暗主题与状态指示", "titleSource": "explicit", "status": "running", "updatedAtUtc": timestamp},
                    ],
                }],
            },
            {
                "projectKey": "docs",
                "name": "项目文档站",
                "path": "D:\\Demo\\docs\\website",
                "status": "completed",
                "updatedAtUtc": timestamp,
                "sessions": [{
                    "threadHash": "session-c",
                    "sessionTitle": "项目文档",
                    "agents": [{"agentId": "docs", "shortId": "e7b4d1c0", "role": "main", "taskTitle": "完善 README 与使用说明", "titleSource": "prompt", "status": "ended", "updatedAtUtc": ago(15)}],
                }],
            },
        ],
    }


def run(screenshot_directory=None):
    html = subprocess.check_output(
        ["node", "-e", "process.stdout.write(require('./project-monitor-webview').getProjectMonitorWebviewHtml({cspSource:'https://webview.example'},{language:'zh',languagePreference:'auto',theme:'dark'}))"],
        cwd=EXTENSION,
    ).decode("utf-8")
    evidence = {"checks": [], "screenshots": []}
    with sync_playwright() as playwright:
        chrome = Path("C:/Program Files/Google/Chrome/Application/chrome.exe")
        browser = playwright.chromium.launch(headless=True, **({"executable_path": str(chrome)} if chrome.is_file() else {}))
        page = browser.new_page(viewport={"width": 520, "height": 605}, device_scale_factor=1)
        errors = []
        violations = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.on("console", lambda message: violations.append(message.text) if "Content Security Policy" in message.text else None)
        page.evaluate("""() => {
            window.__monitorMessages = [];
            window.__monitorState = {};
            window.acquireVsCodeApi = () => ({
                getState: () => window.__monitorState,
                setState: value => { window.__monitorState = value; },
                postMessage: message => window.__monitorMessages.push(message)
            });
        }""")
        page.set_content(html, wait_until="load")
        page.wait_for_function("window.__monitorMessages.some(message => message.type === 'ready')")

        def render(state):
            page.evaluate("state => window.postMessage({type: 'projectMonitorSnapshot', state}, '*')", state)
            page.wait_for_timeout(25)

        def appearance(language, theme):
            page.evaluate("appearance => window.postMessage({type: 'projectMonitorAppearance', appearance}, '*')", {"language": language, "languagePreference": language, "theme": theme})
            page.wait_for_timeout(25)

        def visible_names():
            return page.locator(".project-name:visible").all_text_contents()

        def capture(name, full_page=False):
            if screenshot_directory:
                directory = Path(screenshot_directory).resolve()
                directory.mkdir(parents=True, exist_ok=True)
                path = directory / name
                page.screenshot(path=str(path), full_page=full_page)
                evidence["screenshots"].append(str(path))

        state = snapshot()
        render(state)
        project_names = ["branch", "Demo Controls", "项目文档站"]
        assert visible_names() == project_names
        first_project = page.locator(".project").first
        assert first_project.locator(".session").count() == 7
        assert first_project.locator(".agent-title").count() == 13
        assert first_project.locator(".agent-title:visible").all_text_contents() == ["优化任务监控面板", "历史任务 1：整理页面文案"]
        assert page.locator(".agent-row.running:visible").count() == 3
        bounds = page.locator(".project-row").evaluate_all("rows => rows.map(row => ({name: row.querySelector('.project-name').textContent, bottom: row.getBoundingClientRect().bottom}))")
        assert all(row["bottom"] <= 605 for row in bounds), bounds
        evidence["firstScreen"] = {"width": 520, "height": 605, "projectHeaders": bounds, "runningProjects": 2, "firstProjectTotalAgents": 13, "firstProjectVisibleAgents": 2}
        assert abs(page.locator(".search-field").bounding_box()["y"] - page.locator(".filter-tabs").bounding_box()["y"]) <= 4
        evidence["checks"].append("CSP permits the shipped script; real project/session/agent data renders")
        evidence["checks"].append("All three project headers fit the 520×605 first screen; the seven-session/13-agent project shows its running agent and one recent completion")

        history_toggle = first_project.locator(".history-toggle")
        assert history_toggle.get_attribute("aria-expanded") == "false"
        history_toggle.click()
        assert history_toggle.get_attribute("aria-expanded") == "true"
        assert first_project.locator(".agent-title:visible").count() == 13
        capture("implemented-project-focus-history.png", full_page=True)
        history_toggle.click()
        assert first_project.locator(".agent-title:visible").count() == 2
        page.locator("#search").fill("归档验证 4")
        assert visible_names() == ["branch"]
        assert "归档验证 4：检查会话恢复" in page.locator(".agent-title:visible").all_text_contents()
        capture("implemented-project-focus-search.png")
        page.locator("#search").fill("")
        assert first_project.locator(".agent-title:visible").count() == 2
        assert history_toggle.get_attribute("aria-expanded") == "false"
        evidence["checks"].append("History expands all 13 retained agents, search reveals a folded historical child, and clearing search restores the compact view")

        history_toggle.click()
        historical_session = first_project.locator(".session").filter(has_text="归档验证 4：检查会话恢复")
        historical_session.locator("summary").click()
        page.wait_for_timeout(25)
        assert not historical_session.evaluate("element => element.open")
        history_toggle.click()
        first_project.locator(".project-row").click()
        page.wait_for_timeout(25)
        choices = page.evaluate("JSON.stringify(window.__monitorState.expandedDetails)")
        page.locator("#search").fill("归档验证 4")
        assert first_project.evaluate("element => element.open")
        assert historical_session.evaluate("element => element.open")
        assert history_toggle.is_disabled()
        page.locator("#search").fill("")
        page.wait_for_timeout(25)
        assert not first_project.evaluate("element => element.open")
        assert not historical_session.evaluate("element => element.open")
        assert page.evaluate("JSON.stringify(window.__monitorState.expandedDetails)") == choices
        first_project.locator(".project-row").click()
        evidence["checks"].append("Native details toggle events preserve manually closed project/session choices while search temporarily opens both")

        page.locator("#music-settings").click()
        assert page.evaluate("window.__monitorMessages.at(-1).type") == "chooseCompletionMusic"
        page.locator("#playback-settings").click()
        assert page.evaluate("window.__monitorMessages.at(-1).type") == "configurePlayback"
        evidence["checks"].append("Separate visible music preset and playback settings buttons send their own extension commands")

        assert page.locator("#toolai-promotion").is_visible()
        assert "发现更多 AI 工具" in page.locator("#toolai-promotion").inner_text()
        assert not page.evaluate("window.__monitorMessages.some(m => m.type === 'openToolAI')")
        page.locator("#toolai-open").focus()
        page.keyboard.press("Enter")
        assert page.evaluate("window.__monitorMessages.at(-1).type") == "openToolAI"
        page.locator("#toolai-dismiss").focus()
        page.keyboard.press("Space")
        assert page.locator("#toolai-promotion").is_hidden()
        assert page.evaluate("window.__monitorMessages.at(-1).type") == "dismissToolAI"
        page.evaluate("window.postMessage({type:'projectMonitorAppearance',appearance:{language:'zh',theme:'dark'},showToolAI:true}, '*')")
        page.wait_for_function("() => !document.getElementById('toolai-promotion').hidden")
        evidence["checks"].append("ToolAI uses explicit keyboard activation, dismisses accessibly, and responds to persisted visibility preferences")

        page.locator("#stop-music").click()
        assert page.evaluate("window.__monitorMessages.at(-1).type") == "stopMusic"
        assert page.locator("#stop-music").is_disabled()
        page.evaluate("window.postMessage({type:'musicStopResult',ok:true,count:2}, '*')")
        page.wait_for_function("() => !document.getElementById('stop-music').disabled")
        assert "已发送停止音乐请求" in page.locator("#announcement").text_content()
        page.locator("#stop-music").click()
        page.evaluate("window.postMessage({type:'musicStopResult',ok:false,count:0}, '*')")
        page.wait_for_function("() => !document.getElementById('stop-music').disabled")
        assert "失败" in page.locator("#announcement").text_content()
        evidence["checks"].append("One-click music stop sends the request, shows pending state, and recovers after success or failure")

        page.locator("#search").fill("主题")
        assert visible_names() == ["Demo Controls"]
        page.locator("#filter-completed").click()
        assert visible_names() == []
        assert page.locator("#total-count").text_content() == "3"
        page.locator("#search").fill("README")
        assert visible_names() == ["项目文档站"]
        page.locator("#filter-all").click()
        page.locator("#search").fill("")
        evidence["checks"].append("Nested task search and status filters compose without changing snapshot totals")

        assert page.locator("#appearance-toggle, #appearance-panel, select#language, select#theme").count() == 0
        assert page.locator("button#language-toggle").inner_text().strip() == "中文"
        assert page.locator("#theme-label").inner_text() == "深色"
        assert "音乐预置" in page.locator("#music-settings").inner_text()
        assert "播放设置" in page.locator("#playback-settings").inner_text()
        page.locator("#language-toggle").click()
        assert page.locator("#language-toggle").inner_text().strip() == "EN"
        assert page.locator("#theme-label").inner_text() == "Dark"
        assert "Music presets" in page.locator("#music-settings").inner_text()
        assert "Playback settings" in page.locator("#playback-settings").inner_text()
        assert page.locator("html").get_attribute("lang") == "en"
        assert "Main agent" in page.locator("#content").text_content()
        page.locator("#theme-toggle").click()
        assert page.locator("#theme-label").inner_text() == "Light"
        assert page.locator("html").get_attribute("data-theme") == "light"
        messages = page.evaluate("window.__monitorMessages.filter(message => message.type === 'setAppearance')")
        assert messages[-1]["languagePreference"] == "en"
        assert messages[-1]["theme"] == "light"
        assert len(messages) == 2
        page.locator("#language-toggle").focus()
        page.keyboard.press("Enter")
        assert page.locator("#language-toggle").inner_text().strip() == "中文"
        assert page.locator("#theme-label").inner_text() == "浅色"
        assert page.evaluate("document.activeElement.id") == "language-toggle"
        page.keyboard.press("Space")
        assert page.locator("#language-toggle").inner_text().strip() == "EN"
        page.keyboard.press("Tab")
        assert page.evaluate("document.activeElement.id") == "theme-toggle"
        page.keyboard.press("Space")
        assert page.locator("#theme-label").inner_text() == "Dark"
        page.keyboard.press("Enter")
        assert page.locator("#theme-label").inner_text() == "Light"
        for target in ("refresh", "info-toggle", "music-settings", "playback-settings", "stop-music"):
            page.keyboard.press("Tab")
            assert page.evaluate("document.activeElement.id") == target
        for target, command in (("music-settings", "chooseCompletionMusic"), ("playback-settings", "configurePlayback")):
            page.locator("#" + target).focus()
            page.keyboard.press("Enter")
            assert page.evaluate("window.__monitorMessages.at(-1).type") == command
        render(state)
        assert page.locator("#language-toggle").inner_text().strip() == "EN"
        assert page.locator("#theme-label").inner_text() == "Light"
        evidence["checks"].append("Language and theme switch in one click, persist explicit settings, survive refresh, and support Enter/Space with logical keyboard order")

        page.locator("#info-toggle").click()
        assert page.locator("#info-panel").is_visible()
        page.keyboard.press("Escape")
        assert not page.locator("#info-panel").is_visible()
        assert page.evaluate("document.activeElement.id") == "info-toggle"
        page.keyboard.press("/")
        assert page.evaluate("document.activeElement.id") == "search"
        page.locator("#refresh").click()
        assert page.locator("#refresh").get_attribute("aria-busy") == "true"
        render(state)
        assert page.locator("#refresh").get_attribute("aria-busy") == "false"
        assert page.locator("#announcement").text_content()
        evidence["checks"].append("Keyboard shortcuts restore focus and refresh exposes its loading and completion state")

        first = page.locator(".project-row").first
        first.focus()
        page.evaluate("window.__firstProjectSummary = document.activeElement")
        changed = snapshot()
        changed["projects"] = list(reversed(changed["projects"]))
        render(changed)
        assert page.evaluate("document.activeElement === window.__firstProjectSummary")
        assert page.evaluate("[...document.querySelectorAll('.project-row')].includes(window.__firstProjectSummary)")
        render(state)
        evidence["checks"].append("Snapshot reordering retains the focused summary and DOM identity")

        payload = '<img src=x onerror="window.__injected = true"> 测试任务'
        unsafe = snapshot()
        unsafe["projects"][0]["name"] = payload
        unsafe["projects"][0]["sessions"][0]["agents"][0]["taskTitle"] = payload
        render(unsafe)
        assert page.locator(".project-name").first.text_content() == payload
        assert page.locator("#content img").count() == 0
        assert page.evaluate("window.__injected === undefined")
        render({"kind": "error", "error": "broken snapshot"})
        assert "broken snapshot" in page.locator("#content").text_content()
        appearance("zh", "dark")
        render(state)
        assert visible_names() == project_names
        evidence["checks"].append("Untrusted text stays text and an error snapshot recovers automatically")

        colors = {}
        for language in ("zh", "en"):
            for theme in ("dark", "light"):
                appearance(language, theme)
                for width in (260, 320, 380, 520, 1080):
                    page.set_viewport_size({"width": width, "height": 605})
                    assert page.evaluate("document.documentElement.scrollWidth <= innerWidth"), f"Horizontal overflow: {language}/{theme}/{width}"
                    for target in ("language-toggle", "theme-toggle", "music-settings", "playback-settings", "stop-music", "refresh", "info-toggle"):
                        control = page.locator("#" + target)
                        assert control.is_visible(), f"Hidden control: {target}/{language}/{theme}/{width}"
                        rect = control.bounding_box()
                        assert rect["x"] >= 0 and rect["x"] + rect["width"] <= width, f"Clipped control: {target}/{language}/{theme}/{width}"
                        assert control.evaluate("element => element.scrollWidth <= element.clientWidth"), f"Clipped label: {target}/{language}/{theme}/{width}"
                    controls = page.locator(".audio-toolbar button").evaluate_all("buttons => buttons.map(button => ({left:button.getBoundingClientRect().left,right:button.getBoundingClientRect().right,top:button.getBoundingClientRect().top,bottom:button.getBoundingClientRect().bottom}))")
                    assert len(controls) == 3
                    for index, left in enumerate(controls):
                        for right in controls[index + 1:]:
                            assert left["right"] <= right["left"] or left["bottom"] <= right["top"] or right["bottom"] <= left["top"], f"Overlapping music controls: {language}/{theme}/{width}"
                    if width >= 320:
                        assert abs(page.locator(".search-field").bounding_box()["y"] - page.locator(".filter-tabs").bounding_box()["y"]) <= 4, f"Search and filters split at {language}/{width}"
                    if width in (260, 320, 380) and language == "en" and theme == "light":
                        capture(f"quick-controls-{width}-light-en.png")
                page.set_viewport_size({"width": 520, "height": 605})
                colors[theme] = page.locator("body").evaluate("element => getComputedStyle(element).backgroundColor")
                capture(f"quick-controls-{theme}-{language}.png")
        assert colors["dark"] != colors["light"], colors
        evidence["checks"].append("Chinese/English × light/dark layouts fit 260, 320, 380, 520 and 1080 px with visible, unclipped language/theme/music controls; search and status filters share one row from 320 px")
        appearance("en", "auto")
        for theme in ("light", "dark"):
            page.locator("body").evaluate("(element, theme) => { element.className = 'vscode-' + theme; }", theme)
            assert page.locator("body").evaluate("element => getComputedStyle(element).backgroundColor") == colors[theme]
            page.wait_for_function("label => document.getElementById('theme-label').textContent === label", arg=theme.title())
        for language in ("zh", "en"):
            for host_class, effective_theme in (("vscode-light", "light"), ("vscode-dark", "dark"), ("vscode-high-contrast-light", "light"), ("vscode-high-contrast", "dark")):
                appearance(language, "auto")
                page.locator("body").evaluate("(element, hostClass) => { element.className = hostClass; }", host_class)
                label = ("浅色" if effective_theme == "light" else "深色") if language == "zh" else effective_theme.title()
                page.wait_for_function("label => document.getElementById('theme-label').textContent === label", arg=label)
                page.locator("#theme-toggle").click()
                requested_theme = "dark" if effective_theme == "light" else "light"
                assert page.evaluate("window.__monitorMessages.at(-1)") == {"type": "setAppearance", "languagePreference": language, "theme": requested_theme}
                assert page.locator("html").get_attribute("data-theme") == requested_theme
        evidence["checks"].append("Auto theme labels follow live VS Code class changes; one click persists the opposite explicit theme for light, dark and both high-contrast hosts in either language")
        page.locator("body").evaluate("element => { element.className = 'vscode-dark'; }")
        page.emulate_media(reduced_motion="reduce")
        assert page.locator(".lamp.running").first.evaluate("element => getComputedStyle(element, '::after').animationName") == "none"
        evidence["checks"].append("Auto appearance follows VS Code theme classes and reduced-motion disables the breathing animation")
        appearance("en", "light")
        page.evaluate("""() => {
            const sheet = document.createElement('style');
            sheet.nonce = document.querySelector('style').nonce;
            sheet.textContent = ':root { --vscode-editor-background: #fefffe; --vscode-foreground: #010203; }';
            document.head.append(sheet);
            document.body.className = 'vscode-high-contrast-light';
        }""")
        assert page.locator("body").evaluate("element => getComputedStyle(element).backgroundColor") == "rgb(254, 255, 254)"
        assert page.locator("body").evaluate("element => getComputedStyle(element).color") == "rgb(1, 2, 3)"
        evidence["checks"].append("High-contrast VS Code colors take priority over the selected appearance palette")
        page.locator("body").evaluate("element => { element.className = 'vscode-dark'; }")
        page.set_viewport_size({"width": 520, "height": 860})
        render(snapshot())
        for language in ("en", "zh"):
            appearance(language, "dark")
            assert page.locator("#toolai-promotion").is_visible()
            capture(f"release-{language}.png", full_page=True)
        page.set_viewport_size({"width": 260, "height": 605})
        appearance("en", "light")
        page.locator("#toolai-promotion").scroll_into_view_if_needed()
        assert page.locator("#toolai-promotion").evaluate("e => e.scrollWidth <= e.clientWidth")
        capture("promotion-narrow.png")
        assert not errors, errors
        assert not violations, violations
        browser.close()
    if screenshot_directory:
        directory = Path(screenshot_directory).resolve()
        cards = "\n".join(
            f'<figure><figcaption>{"中文" if language == "zh" else "English"} · {"深色 / Dark" if theme == "dark" else "浅色 / Light"} · 520 × 605</figcaption><img src="quick-controls-{theme}-{language}.png" alt="{language} {theme} project monitor"></figure>'
            for language in ("zh", "en") for theme in ("dark", "light")
        )
        cards += "".join(f'<figure style="max-width:{width}px"><figcaption>English · 浅色 · {width} × 605</figcaption><img src="quick-controls-{width}-light-en.png" alt="Compact {width} px monitor"></figure>' for width in (260, 320, 380))
        cards += '<figure><figcaption>搜索命中历史子 Agent</figcaption><img src="implemented-project-focus-search.png" alt="Historical task search"></figure><figure><figcaption>用户展开全部历史 · 完整页面</figcaption><img src="implemented-project-focus-history.png" alt="Expanded historical agents"></figure>'
        comparison = directory / "quick-controls.html"
        comparison.write_text('<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>语言、主题与音乐快捷入口 · 界面验证</title><style>body{margin:0;padding:32px;background:#e9edec;color:#253630;font:14px/1.5 system-ui,sans-serif}h1{margin:0;font-size:24px}p{color:#566760}main{display:grid;grid-template-columns:repeat(2,minmax(0,520px));gap:24px;max-width:1064px;margin:24px auto}header{max-width:1064px;margin:auto}figure{margin:0}figcaption{padding:0 0 8px;font-weight:600}img{display:block;width:100%;border:1px solid #bdc8c3;border-radius:12px}@media(max-width:720px){body{padding:16px}main{grid-template-columns:1fr}}</style><header><h1>语言、主题与音乐快捷入口</h1><p>正式扩展 Webview 的 Chromium 实测画面。语言与主题直接点击切换；音乐预置、播放设置和停止音乐作为独立文字按钮展示。验证中英文、明暗主题、260–520 像素窄屏、历史展开与搜索。</p></header><main>' + cards + '</main></html>', encoding="utf-8")
        evidence["comparison"] = str(comparison)
        (directory / "quick-controls-evidence.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
    return evidence


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--screenshots", metavar="DIR")
    arguments = parser.parse_args()
    print(json.dumps(run(arguments.screenshots), ensure_ascii=False, indent=2))
