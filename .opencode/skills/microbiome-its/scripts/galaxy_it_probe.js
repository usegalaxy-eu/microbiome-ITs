#!/usr/bin/env node
/**
 * Open a Galaxy Interactive Tool inside the real Galaxy UI and report what the
 * embedded iframe actually rendered.
 *
 * Usage:
 *   node galaxy_it_probe.js [galaxy-url] [tool-name-filter]
 *
 * Env overrides:
 *   GALAXY_URL          default http://127.0.0.1:8080
 *   GXY_IT_PROBE_PORT   CDP port for the spawned Chrome (default 9222)
 *   CHROME              Chrome binary (default google-chrome)
 *
 * Requires Node 22+ (global fetch + WebSocket), no npm dependencies.
 * Exit code 0 = iframe rendered content, 1 = failure (details on stderr/stdout).
 *
 * Why: /interactivetool_entry_points/<id>/display is a client-side route, so it
 * cannot be opened directly (server returns 404). This navigates to
 * /interactivetool_entry_points/list, clicks the IT row link like a user, then
 * attaches to the resulting iframe target over CDP.
 */

const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const galaxyUrl = (process.argv[2] || process.env.GALAXY_URL || "http://127.0.0.1:8080").replace(/\/+$/, "");
const toolFilter = process.argv[3] || "";
const port = Number(process.env.GXY_IT_PROBE_PORT || 9222);
const chromeBin = process.env.CHROME || "google-chrome";
const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), "gxy-it-probe-"));

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function targets() {
    const res = await fetch(`http://127.0.0.1:${port}/json/list`);
    return res.json();
}

function connect(wsUrl) {
    const ws = new WebSocket(wsUrl);
    const ready = new Promise((resolve, reject) => {
        ws.onopen = resolve;
        ws.onerror = reject;
    });
    let nextId = 1;
    const pending = new Map();

    ws.onmessage = (msg) => {
        const data = JSON.parse(msg.data);
        const entry = data.id && pending.get(data.id);
        if (!entry) return;
        pending.delete(data.id);
        data.error ? entry.reject(new Error(JSON.stringify(data.error))) : entry.resolve(data.result);
    };

    const send = async (method, params = {}) => {
        await ready;
        const id = nextId++;
        return new Promise((resolve, reject) => {
            pending.set(id, { resolve, reject });
            ws.send(JSON.stringify({ id, method, params }));
        });
    };

    const evaluate = async (expression) => {
        const result = await send("Runtime.evaluate", {
            expression,
            returnByValue: true,
            awaitPromise: true,
        });
        if (result.exceptionDetails) {
            throw new Error(result.exceptionDetails.text || "evaluation failed");
        }
        return result.result && result.result.value;
    };

    return { send, evaluate, close: () => ws.close() };
}

async function waitFor(label, fn, timeoutMs, intervalMs = 500) {
    const deadline = Date.now() + timeoutMs;
    let lastError = null;
    while (Date.now() < deadline) {
        try {
            const value = await fn();
            if (value) return value;
        } catch (err) {
            lastError = err;
        }
        await sleep(intervalMs);
    }
    throw new Error(`${label} timed out after ${Math.round(timeoutMs / 1000)}s${lastError ? ` (${lastError.message})` : ""}`);
}

async function main() {
    const chrome = spawn(
        chromeBin,
        [
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            `--user-data-dir=${profileDir}`,
            `--remote-debugging-port=${port}`,
            "about:blank",
        ],
        { stdio: "ignore" },
    );

    let ui = null;
    let frame = null;
    try {
        const page = await waitFor(
            "chrome devtools endpoint",
            async () => {
                const list = await targets();
                return list.find((t) => t.type === "page") || null;
            },
            20000,
        );

        ui = connect(page.webSocketDebuggerUrl);
        await ui.send("Page.navigate", { url: `${galaxyUrl}/interactivetool_entry_points/list` });

        let clicked;
        try {
            clicked = await waitFor(
                "interactive tool row link",
                () =>
                    ui.evaluate(`(() => {
                        const filter = ${JSON.stringify(toolFilter)};
                        const links = Array.from(document.querySelectorAll('a[id^="link-"]'));
                        const el = filter ? links.find((a) => a.textContent.includes(filter)) : links[0];
                        if (!el) return null;
                        el.click();
                        return el.id + " " + el.textContent.trim();
                    })()`),
                45000,
            );
        } catch (err) {
            const text = await ui.evaluate('(document.body ? document.body.innerText : "").slice(0, 600)');
            throw new Error(`${err.message}; page text: ${JSON.stringify(text)}`);
        }
        console.log("clicked:", clicked);

        const displayUrl = await waitFor(
            "display route",
            async () => {
                const href = await ui.evaluate("location.href");
                return href && href.includes("/display") ? href : null;
            },
            20000,
        );
        console.log("display route:", displayUrl);

        const iframe = await waitFor(
            "tool iframe target",
            async () => {
                const list = await targets();
                return (
                    list.find(
                        (t) =>
                            t.type === "iframe" &&
                            // domain-based entry points get their own host
                            // (<ep>-<job>.ep.interactivetool.<host>:<port>),
                            // path-based ones are proxied under /interactivetool/ep/
                            (t.url.includes(".ep.interactivetool.") ||
                                t.url.includes("/interactivetool/ep/") ||
                                t.url.startsWith("chrome-error://")),
                    ) || null
                );
            },
            60000,
        );
        console.log("iframe target:", iframe.url);

        if (iframe.url.startsWith("chrome-error://")) {
            throw new Error("iframe target is a Chrome error page (frame blocked or navigation failed)");
        }

        frame = connect(iframe.webSocketDebuggerUrl);
        const raw = await waitFor(
            "iframe document",
            () =>
                frame.evaluate(
                    `JSON.stringify({
                        title: document.title,
                        href: location.href,
                        body: (document.body ? document.body.innerText : "").slice(0, 500),
                    })`,
                ),
            30000,
        );

        const report = JSON.parse(raw);
        const ok = Boolean(report.title) && !report.href.startsWith("chrome-error://") && report.body.trim().length > 0;
        console.log(JSON.stringify({ ok, ...report }, null, 2));
        process.exitCode = ok ? 0 : 1;
    } finally {
        if (frame) frame.close();
        if (ui) ui.close();
        chrome.kill("SIGKILL");
        try {
            fs.rmSync(profileDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
        } catch (err) {
            // Chrome can still be flushing its profile. Cleanup must never mask the
            // probe result (an ENOTEMPTY here used to turn a passing run into a failure).
            console.error("cleanup warning:", err.message);
        }
    }
}

main().catch((err) => {
    console.error("probe failed:", err.message);
    process.exitCode = 1;
});
