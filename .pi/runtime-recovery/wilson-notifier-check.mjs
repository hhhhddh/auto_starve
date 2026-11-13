import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const source = fs.readFileSync(process.argv[2] ?? path.join(project, ".pi/extensions/wilson-iteration.js"), "utf8");
const { default: register } = await import("data:text/javascript;base64," + Buffer.from(source).toString("base64"));
const temporary = fs.mkdtempSync(path.join(project, ".pi/runtime-recovery/notifier-check-"));
const originalSetInterval = globalThis.setInterval;
const originalClearInterval = globalThis.clearInterval;
const timers = new Set();
let sequence = 0;
const write = (file, value) => fs.writeFileSync(file, JSON.stringify(value), "utf8");
const read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));

function fixture() {
    const cwd = path.join(temporary, String(++sequence));
    const root = path.join(cwd, "development-support/nbot-relay/private");
    fs.mkdirSync(path.join(root, "iteration-queue"), { recursive: true });
    const target = path.join(root, "iteration-agent-target.json");
    const ready = path.join(root, "iteration-agent-ready.json");
    const receipts = path.join(root, "iteration-notifications.json");
    const state = path.join(root, "iteration-state.json");
    const clients = [];
    const bind = (id) => write(target, { schema: "wilson-expedition/agent-target@1", sessionId: id });
    const run = (stage, extra = {}) => write(state, {
        schema: "wilson-expedition/iteration-state@1", stage, pid: 101, revision: "build-a",
        sourceRevision: "source-a", challenge: "challenge-a", sessions: { Master: "surface-a", Caves: "caves-a" },
        deathPolicy: "repair_and_regenerate", updatedUtc: "2026-11-13T01:00:00Z", ...extra,
    });
    const job = (id = "a".repeat(64), extra = {}) => {
        const value = { schema: "wilson-expedition/iteration@1", id, stage: "awaiting_fix",
            loadedRevision: "build-a", sourceRevision: "source-a", challenge: "challenge-a", session: "surface-a", ...extra };
        write(path.join(root, "iteration-queue", id + ".json"), value);
        return value;
    };
    const start = async (id) => {
        const handlers = new Map();
        const commands = new Map();
        const messages = [];
        const client = { id, handlers, commands, messages };
        client.ctx = { cwd, hasUI: false, sessionManager: { getSessionId: () => client.id } };
        register({ on: (name, callback) => handlers.set(name, callback),
            registerCommand: (name, command) => commands.set(name, command),
            sendMessage: (message, options) => messages.push({ ...message, options }) });
        clients.push(client);
        await handlers.get("session_start")({}, client.ctx);
        return client;
    };
    const close = async () => {
        for (const client of clients) await client.handlers.get("session_shutdown")({}, client.ctx);
    };
    return { root, target, ready, receipts, state, bind, run, job, start, close };
}

function tick() { for (const timer of [...timers]) timer.callback(); }

async function unbound_and_foreign_sessions() {
    const f = fixture();
    const pending = f.job();
    f.run("awaiting_fix", { death: pending.id });
    const foreign = await f.start("foreign");
    assert.equal(foreign.messages.length, 0, "An unbound project must not wake a conversation");
    assert.equal(fs.existsSync(f.ready), false, "No session may claim readiness by opening the project");
    f.bind("owner"); tick();
    assert.equal(foreign.messages.length, 0, "A foreign session must not deliver the target's job");
    assert.equal(fs.existsSync(f.ready), false);
    assert.equal(fs.existsSync(f.receipts), false);
    await f.close();
}

async function designated_session_and_concurrent_listeners() {
    const f = fixture(); f.bind("owner"); const job = f.job(); f.run("awaiting_fix", { death: job.id });
    const foreign = await f.start("foreign");
    const owner = await f.start("owner");
    assert.equal(owner.messages.length, 1);
    assert.ok(owner.messages[0].content.includes(job.id + ".json"));
    assert.deepEqual(owner.messages[0].options, { triggerTurn: true, deliverAs: "followUp" },
        "The designated session must still start a turn, including when it is idle");
    assert.equal(foreign.messages.length, 0);
    tick(); tick();
    assert.equal(owner.messages.length, 1);
    assert.equal(read(f.ready).sessionId, "owner");
    assert.equal(read(f.ready).routing, "explicit-session@1", "Heartbeat must identify the loaded routing implementation");
    assert.equal(read(f.receipts).sessionId, "owner");
    const before = fs.readFileSync(f.ready, "utf8");
    await foreign.handlers.get("session_shutdown")({}, foreign.ctx);
    assert.equal(fs.readFileSync(f.ready, "utf8"), before, "Foreign shutdown must not revoke target readiness");
    await owner.handlers.get("session_shutdown")({}, owner.ctx);
    await owner.handlers.get("session_start")({}, owner.ctx);
    assert.equal(owner.messages.length, 1, "Reload must retain target notification receipts");
    await f.close();
}

async function explicit_rebinding_and_session_switch() {
    const f = fixture(); f.bind("owner"); f.run("running");
    const owner = await f.start("owner"); const foreign = await f.start("foreign");
    const job = f.job("b".repeat(64)); f.run("awaiting_fix", { death: job.id });
    await foreign.commands.get("wilson-notify-here").handler("", foreign.ctx);
    assert.equal(read(f.target).sessionId, "foreign", "Only an explicit command changes the target");
    assert.equal(foreign.messages.length, 1);
    tick(); assert.equal(owner.messages.length, 0);
    const ready = fs.readFileSync(f.ready, "utf8");
    await owner.handlers.get("session_shutdown")({}, owner.ctx);
    assert.equal(fs.readFileSync(f.ready, "utf8"), ready);
    foreign.id = "new-session";
    const next = f.job("c".repeat(64)); f.run("awaiting_fix", { death: next.id }); tick();
    assert.equal(foreign.messages.length, 1, "A switched session must not inherit delivery rights");
    assert.deepEqual(read(f.receipts).ids, [job.id]);
    await f.close();
}

async function current_run_identity_and_old_queue() {
    const f = fixture(); f.bind("owner"); const job = f.job(); f.job("d".repeat(64)); f.run("running");
    const owner = await f.start("owner");
    assert.equal(owner.messages.length, 0, "Old awaiting-fix jobs must not wake a healthy run");
    for (const mismatch of [{ challenge: "other-challenge" }, { revision: "other-build" },
        { sourceRevision: "other-source" }, { sessions: { Master: "other-surface" } }]) {
        f.run("awaiting_fix", { death: job.id, ...mismatch }); tick();
        assert.equal(owner.messages.length, 0, "Mismatched run identity must not notify");
    }
    f.run("awaiting_fix", { death: job.id }); tick();
    assert.equal(owner.messages.length, 1);
    f.run("running"); tick();
    assert.equal(owner.messages.length, 1, "A retained historical queue must stay dormant");
    await f.close();
}

async function blocked_run_deduplication() {
    const f = fixture(); f.bind("owner"); f.run("world_ready"); const owner = await f.start("owner");
    assert.equal(owner.messages.length, 0);
    f.run("blocked"); tick();
    assert.equal(owner.messages.length, 1);
    assert.ok(owner.messages[0].content.includes("PID 101"));
    assert.ok(owner.messages[0].content.includes("build-a"));
    assert.ok(owner.messages[0].content.includes("2026-11-13T01:00:00Z"));
    assert.ok(owner.messages[0].content.includes("若新的控制器已正常运行"));
    f.run("blocked", { updatedUtc: "2026-11-13T01:00:25Z" }); tick();
    assert.equal(owner.messages.length, 1, "Exit cleanup must not notify twice for one run");
    f.run("blocked", { pid: 202, revision: "build-b" }); tick();
    assert.equal(owner.messages.length, 2);
    await owner.handlers.get("session_shutdown")({}, owner.ctx);
    write(f.receipts, { sessionId: "owner", ids: ["runner:2026-11-13T01:02:00Z"] });
    f.run("blocked", { pid: 303, revision: "build-c", updatedUtc: "2026-11-13T01:02:00Z" });
    await owner.handlers.get("session_start")({}, owner.ctx);
    assert.equal(owner.messages.length, 2, "Legacy timestamp receipts must retain their meaning");
    await f.close();
}

async function capture_only_and_survival_completion() {
    const f = fixture(); f.bind("owner"); f.job();
    f.run("death_captured", { deathPolicy: "capture_only", death: "a".repeat(64) });
    const owner = await f.start("owner"); const foreign = await f.start("foreign"); tick();
    assert.equal(owner.messages.length, 1);
    assert.ok(owner.messages[0].content.includes("本次不优化 Mod、不审批修复、不重新生成世界"));
    assert.equal(foreign.messages.length, 0);
    f.run("survival_complete"); tick(); tick();
    assert.equal(owner.messages.length, 2);
    assert.ok(owner.messages[1].content.includes("70 天完成事件"));
    assert.equal(foreign.messages.length, 0);
    await f.close();
}

async function errors_remain_target_scoped() {
    const f = fixture(); f.bind("owner"); fs.writeFileSync(f.state, "{", "utf8");
    const foreign = await f.start("foreign"); const owner = await f.start("owner");
    assert.equal(foreign.messages.length, 0, "Queue errors must not wake unrelated sessions");
    assert.equal(owner.messages.length, 1);
    assert.equal(owner.messages[0].options.triggerTurn, true);
    tick(); assert.equal(owner.messages.length, 1, "An error stops the failing watcher");
    await f.close();
    const malformed = fixture(); fs.writeFileSync(malformed.target, "{", "utf8");
    const unknown = await malformed.start("owner"); tick();
    assert.equal(unknown.messages.length, 0, "An unreadable binding cannot authorize any model turn");
    assert.equal(fs.existsSync(malformed.ready), false);
    assert.equal(fs.existsSync(malformed.receipts), false);
    await malformed.close();
}

try {
    globalThis.setInterval = (callback) => {
        const timer = { callback, unref() {} }; timers.add(timer); return timer;
    };
    globalThis.clearInterval = (timer) => timers.delete(timer);
    for (const check of [unbound_and_foreign_sessions, designated_session_and_concurrent_listeners,
        explicit_rebinding_and_session_switch, current_run_identity_and_old_queue,
        blocked_run_deduplication, capture_only_and_survival_completion, errors_remain_target_scoped]) {
        await check();
        assert.equal(timers.size, 0, "Shutdown must release every session timer");
        console.log("PASS:", check.name);
    }
} finally {
    globalThis.setInterval = originalSetInterval;
    globalThis.clearInterval = originalClearInterval;
    fs.rmSync(temporary, { recursive: true, force: true });
}
