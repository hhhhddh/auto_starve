import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const source = fs.readFileSync(path.join(project, ".pi/extensions/wilson-iteration.js"), "utf8");
const { default: register } = await import("data:text/javascript;base64," + Buffer.from(source).toString("base64"));
const temporary = fs.mkdtempSync(path.join(project, ".pi/runtime-recovery/notifier-check-"));
const privateRoot = path.join(temporary, "development-support/nbot-relay/private");
const statePath = path.join(privateRoot, "iteration-state.json");
const receiptsPath = path.join(privateRoot, "iteration-notifications.json");
const handlers = new Map();
const messages = [];
const originalSetInterval = globalThis.setInterval;
const originalClearInterval = globalThis.clearInterval;
let tick;
const write = (file, value) => fs.writeFileSync(file, JSON.stringify(value), "utf8");
const context = { cwd: temporary, sessionManager: { getSessionId: () => "test-session" } };
const run = (stage, pid, revision, updatedUtc) => write(statePath, {
    schema: "wilson-expedition/iteration-state@1", stage, pid, revision, updatedUtc,
});

try {
    globalThis.setInterval = (callback) => { tick = callback; return { unref() {} }; };
    globalThis.clearInterval = () => {};
    register({ on: (name, callback) => handlers.set(name, callback), sendMessage: (message) => messages.push(message) });
    await handlers.get("session_start")({}, context);
    assert.equal(messages.length, 0);

    run("world_ready", 101, "build-a", "2026-11-11T16:50:00Z");
    tick();
    assert.equal(messages.length, 0);
    run("blocked", 101, "build-a", "2026-11-11T16:51:00Z");
    tick();
    assert.equal(messages.length, 1);
    assert.ok(messages[0].content.includes("PID 101"));
    assert.ok(messages[0].content.includes("build-a"));
    assert.ok(messages[0].content.includes("2026-11-11T16:51:00Z"));
    assert.ok(messages[0].content.includes("若新的控制器已正常运行"));
    run("blocked", 101, "build-a", "2026-11-11T16:51:25Z");
    tick();
    assert.equal(messages.length, 1, "Exit cleanup must not notify twice for the same run");

    run("world_ready", 202, "build-b", "2026-11-11T16:54:00Z");
    tick();
    assert.equal(messages.length, 1, "A healthy replacement run must not report a failure");
    run("blocked", 202, "build-b", "2026-11-11T17:00:00Z");
    tick();
    assert.equal(messages.length, 2, "A distinct failed run must still notify");
    await handlers.get("session_shutdown")({}, context);
    await handlers.get("session_start")({}, context);
    assert.equal(messages.length, 2, "Reload must retain notification deduplication");

    await handlers.get("session_shutdown")({}, context);
    write(receiptsPath, { sessionId: "test-session", ids: ["runner:2026-11-11T17:01:00Z"] });
    run("blocked", 303, "build-c", "2026-11-11T17:01:00Z");
    await handlers.get("session_start")({}, context);
    assert.equal(messages.length, 2, "Existing notification receipts must remain valid");

    write(statePath, {
        schema: "wilson-expedition/iteration-state@1", stage: "death_captured", deathPolicy: "capture_only",
        death: "a".repeat(64), pid: 202, revision: "build-b", updatedUtc: "2026-11-11T17:10:00Z",
    });
    tick();
    assert.equal(messages.length, 3, "Capture-only deaths must notify the parent");
    assert.ok(messages[2].content.includes("本次不优化 Mod、不审批修复、不重新生成世界"));
    assert.ok(messages[2].content.includes("a".repeat(64) + ".json"));
    tick();
    assert.equal(messages.length, 3, "The captured death must notify only once");
    console.log("PASS: healthy runs, run identity, cleanup deduplication, new failures, reload persistence, legacy receipts, capture-only death notification");
} finally {
    await handlers.get("session_shutdown")?.({}, context);
    globalThis.setInterval = originalSetInterval;
    globalThis.clearInterval = originalClearInterval;
    fs.rmSync(temporary, { recursive: true, force: true });
}
