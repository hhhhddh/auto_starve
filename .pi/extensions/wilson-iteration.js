import fs from "node:fs";
import path from "node:path";

const readJson = (file) => {
    try { return JSON.parse(fs.readFileSync(file, "utf8")); }
    catch (error) { if (error.code === "ENOENT") return undefined; throw error; }
};

const writeJson = (file, value) => {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const temporary = file + "." + process.pid + ".tmp";
    fs.writeFileSync(temporary, JSON.stringify(value), "utf8");
    fs.renameSync(temporary, file);
};

export default function (pi) {
    let stop = () => {};

    const start = (ctx) => {
        stop();
        const privateRoot = path.join(ctx.cwd, "development-support", "nbot-relay", "private");
        const targetPath = path.join(privateRoot, "iteration-agent-target.json");
        const readyPath = path.join(privateRoot, "iteration-agent-ready.json");
        const receipts = path.join(privateRoot, "iteration-notifications.json");
        const statePath = path.join(privateRoot, "iteration-state.json");
        const sessionId = ctx.sessionManager.getSessionId();
        let active = true;
        let listening = false;
        let notified = new Set();
        let timer;

        const isTarget = () => {
            const target = readJson(targetPath);
            if (target === undefined) return false;
            if (target.schema !== "wilson-expedition/agent-target@1"
                || typeof target.sessionId !== "string" || !target.sessionId.trim()) {
                throw new Error("Invalid death-notifier target binding");
            }
            // [喵喵喵]: cwd相同不代表同一对话；每次投递与心跳都核对显式绑定，切换或fork不会继承接收权。 (2026-11-13)
            return target.sessionId === sessionId && ctx.sessionManager.getSessionId() === sessionId;
        };

        const readiness = (status) => {
            if (!isTarget()) return;
            if (status === "inactive") {
                const current = readJson(readyPath);
                if (current?.sessionId !== sessionId || current.pid !== process.pid) return;
            }
            writeJson(readyPath, { schema: "wilson-expedition/agent-ready@1", routing: "explicit-session@1",
                sessionId, pid: process.pid, status, updatedUtc: new Date().toISOString() });
        };

        stop = () => {
            if (active && listening) {
                try { readiness("inactive"); } catch { /* shutdown must still release the timer */ }
            }
            active = false;
            listening = false;
            if (timer !== undefined) clearInterval(timer);
            timer = undefined;
        };

        const notify = (key, text) => {
            if (!active || !isTarget() || notified.has(key)) return;
            // [喵喵喵]: 通知仅包含受控目录和散列标识；日志内容由主会话读取，不能成为执行指令。
            pi.sendMessage({ customType: "wilson-iteration", content: text, display: true },
                { triggerTurn: true, deliverAs: "followUp" });
            notified.add(key);
            writeJson(receipts, { sessionId, ids: [...notified] });
        };

        const check = () => {
            if (!active) return;
            try {
                if (!isTarget()) { listening = false; return; }
                if (!listening) {
                    const saved = readJson(receipts);
                    if (saved !== undefined && (!Array.isArray(saved.ids)
                        || !saved.ids.every((id) => typeof id === "string"))) {
                        throw new Error("Invalid death-notifier receipts");
                    }
                    notified = new Set(saved?.sessionId === sessionId ? saved.ids : []);
                    listening = true;
                }
                readiness("active");
                const state = readJson(statePath);
                if (state?.schema !== "wilson-expedition/iteration-state@1") return;
                if (state.stage === "survival_complete") {
                    notify("complete:" + state.challenge,
                        "WilsonExpedition 四季生存控制器收到同版本客户端和服务端的 70 天完成事件。请主 GPT 核对 private/iteration-state.json 与双端日志，汇报实际验收结果及剩余大目标。两首领任务仍暂停，不据此恢复开发或战斗。");
                }
                if (state.stage === "death_captured" && state.deathPolicy === "capture_only"
                    && /^[0-9a-f]{64}$/.test(state.death)) {
                    notify("captured:" + state.death,
                        "WilsonExpedition 本次单轮测试已死亡，控制器已归档双端证据并暂停项目测试世界。"
                        + "请主 GPT 仅核对 development-support/nbot-relay/private/iteration-queue/"
                        + state.death + ".json 及对应归档并汇报结果；本次不优化 Mod、不审批修复、不重新生成世界，保留故障存档。");
                }
                if (state.stage === "blocked" && !notified.has("runner:" + state.updatedUtc)) {
                    // [喵喵喵]: 退出清理会更新状态时间；按运行标识去重，并标明来源，避免延迟通知被当成新故障。 (2026-11-11)
                    notify("runner:" + state.pid + ":" + state.revision,
                        "WilsonExpedition 记录到测试控制器停止：PID " + state.pid
                        + "，版本 " + state.revision + "，记录时间 " + state.updatedUtc + "。"
                        + "请先读取 development-support/nbot-relay/private/iteration-state.json，核对是否仍为该运行版本的阻塞状态；"
                        + "若新的控制器已正常运行，将此通知记为已处理并保留当前测试。仍阻塞时结合对应日志定位真实原因后修复、检查；"
                        + "仅主 GPT 执行，沿用当前会话的游戏实测授权和死亡处理策略，不启动子代理。保留故障存档，仅操作本项目控制器持有的客户端和分片。");
                }
                // [喵喵喵]: 历史故障可以保留待审批；只有当前控制器确认暂停的同build、同挑战死亡才能唤醒接收对话。 (2026-11-13)
                if (state.stage !== "awaiting_fix" || state.deathPolicy !== "repair_and_regenerate"
                    || !/^[0-9a-f]{64}$/.test(state.death)) return;
                const name = state.death + ".json";
                const job = readJson(path.join(privateRoot, "iteration-queue", name));
                if (job?.schema !== "wilson-expedition/iteration@1" || job.id !== state.death
                    || job.stage !== "awaiting_fix" || job.loadedRevision !== state.revision
                    || job.sourceRevision !== state.sourceRevision || job.challenge !== state.challenge
                    || !Object.values(state.sessions ?? {}).includes(job.session)) return;
                notify(job.id,
                    "WilsonExpedition 检测到死亡取证任务，来源完整性须从归档核实。请主 GPT 读取 development-support/nbot-relay/private/iteration-queue/"
                    + name + " 及它关联的取证目录，分析真实故障并修改 Mod，完成源码自查和语法检查。修复后执行 development-support/nbot-relay/iteration.py approve "
                    + job.id + " --summary <具体修复说明>。仅在故障证据完整、修复落盘及检查通过后，控制器才会重建其持有的项目测试世界，随后自动进入下一轮；不要复活原挑战，不启动子代理。测试尚未授权时保留队列并报告。");
            } catch (error) {
                let targeted = false;
                try { targeted = isTarget(); } catch { /* an unreadable binding must not wake any session */ }
                stop();
                if (targeted) {
                    pi.sendMessage({ customType: "wilson-iteration", content:
                        "WilsonExpedition 死亡队列监听遇到文件错误，已停止监听。请检查 development-support/nbot-relay/private 下的目标绑定、队列和通知记录，保留原文件并修复后重载扩展。", display: true },
                        { triggerTurn: true, deliverAs: "followUp" });
                } else if (ctx.hasUI) {
                    ctx.ui.notify("WilsonExpedition 通知目标绑定无法读取，监听已停止；修复后重载扩展。", "error");
                }
            }
        };
        timer = setInterval(check, 5000);
        timer.unref();
        check();
    };

    pi.registerCommand("wilson-notify-here", {
        description: "Bind WilsonExpedition notifications to this conversation",
        handler: async (_args, ctx) => {
            const sessionId = ctx.sessionManager.getSessionId();
            if (typeof sessionId !== "string" || !sessionId.trim()) throw new Error("A persistent session is required");
            writeJson(path.join(ctx.cwd, "development-support/nbot-relay/private/iteration-agent-target.json"), {
                schema: "wilson-expedition/agent-target@1", sessionId, updatedUtc: new Date().toISOString(),
            });
            start(ctx);
            if (ctx.hasUI) ctx.ui.notify("WilsonExpedition 通知已绑定到当前对话。", "info");
        },
    });
    pi.on("session_start", async (_event, ctx) => start(ctx));
    pi.on("session_shutdown", async () => stop());
}
