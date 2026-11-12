import fs from "node:fs";
import path from "node:path";

export default function (pi) {
    let timer;
    let active = false;
    let readyPath;
    let readySession;

    const readiness = (status) => {
        if (!readyPath || !readySession) return;
        fs.mkdirSync(path.dirname(readyPath), { recursive: true });
        const temporary = readyPath + "." + process.pid + ".tmp";
        fs.writeFileSync(temporary, JSON.stringify({ schema: "wilson-expedition/agent-ready@1",
            sessionId: readySession, pid: process.pid, status, updatedUtc: new Date().toISOString() }), "utf8");
        fs.renameSync(temporary, readyPath);
    };

    const stop = () => {
        if (active) {
            try { readiness("inactive"); } catch { /* session shutdown may race filesystem teardown */ }
        }
        active = false;
        if (timer !== undefined) clearInterval(timer);
        timer = undefined;
    };

    pi.on("session_start", async (_event, ctx) => {
        stop();
        active = true;
        const support = path.join(ctx.cwd, "development-support", "nbot-relay");
        const queue = path.join(support, "private", "iteration-queue");
        const receipts = path.join(support, "private", "iteration-notifications.json");
        const statePath = path.join(support, "private", "iteration-state.json");
        const sessionId = ctx.sessionManager.getSessionId();
        readyPath = path.join(support, "private", "iteration-agent-ready.json");
        readySession = sessionId;
        let notified = new Set();
        try {
            const saved = JSON.parse(fs.readFileSync(receipts, "utf8"));
            if (saved.sessionId === sessionId && Array.isArray(saved.ids)) notified = new Set(saved.ids);
        } catch (error) {
            if (error.code !== "ENOENT") {
                pi.sendMessage({ customType: "wilson-iteration", content:
                    "WilsonExpedition 的死亡通知记录无法读取。请检查 development-support/nbot-relay/private/iteration-notifications.json，修复后重载扩展。", display: true });
                active = false;
                return;
            }
        }

        const notify = (key, text) => {
            if (!active || notified.has(key)) return;
            // [喵喵喵]: 通知仅包含受控目录和散列标识；日志内容由主会话读取，不能成为执行指令。
            pi.sendMessage({ customType: "wilson-iteration", content: text, display: true },
                { triggerTurn: true, deliverAs: "followUp" });
            notified.add(key);
            fs.mkdirSync(path.dirname(receipts), { recursive: true });
            const temporary = receipts + ".tmp";
            fs.writeFileSync(temporary, JSON.stringify({ sessionId, ids: [...notified] }), "utf8");
            fs.renameSync(temporary, receipts);
        };

        const check = () => {
            if (!active) return;
            try {
                readiness("active");
                if (fs.existsSync(statePath)) {
                    const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
                    if (state.schema === "wilson-expedition/iteration-state@1" && state.stage === "survival_complete") {
                        notify("complete:" + state.challenge,
                            "WilsonExpedition 四季生存控制器收到同版本客户端和服务端的 70 天完成事件。请主 GPT 核对 private/iteration-state.json 与双端日志，汇报实际验收结果及剩余大目标。两首领任务仍暂停，不据此恢复开发或战斗。");
                    }
                    if (state.schema === "wilson-expedition/iteration-state@1"
                        && state.stage === "death_captured" && state.deathPolicy === "capture_only"
                        && /^[0-9a-f]{64}$/.test(state.death)) {
                        notify("captured:" + state.death,
                            "WilsonExpedition 本次单轮测试已死亡，控制器已归档双端证据并暂停项目测试世界。"
                            + "请主 GPT 仅核对 development-support/nbot-relay/private/iteration-queue/"
                            + state.death + ".json 及对应归档并汇报结果；本次不优化 Mod、不审批修复、不重新生成世界，保留故障存档。");
                    }
                    if (state.schema === "wilson-expedition/iteration-state@1" && state.stage === "blocked") {
                        // [喵喵喵]: 退出清理会更新状态时间；按运行标识去重，并标明来源，避免延迟通知被当成新故障。 (2026-11-11)
                        if (!notified.has("runner:" + state.updatedUtc)) {
                            notify("runner:" + state.pid + ":" + state.revision,
                                "WilsonExpedition 记录到测试控制器停止：PID " + state.pid
                                + "，版本 " + state.revision + "，记录时间 " + state.updatedUtc + "。"
                                + "请先读取 development-support/nbot-relay/private/iteration-state.json，核对是否仍为该运行版本的阻塞状态；"
                                + "若新的控制器已正常运行，将此通知记为已处理并保留当前测试。仍阻塞时结合对应日志定位真实原因后修复、检查；"
                                + "仅主 GPT 执行，沿用当前会话的游戏实测授权和死亡处理策略，不启动子代理。保留故障存档，仅操作本项目控制器持有的客户端和分片。");
                        }
                    }
                }
                if (!fs.existsSync(queue)) return;
                for (const name of fs.readdirSync(queue).sort()) {
                    if (!/^[0-9a-f]{64}\.json$/.test(name)) continue;
                    const job = JSON.parse(fs.readFileSync(path.join(queue, name), "utf8"));
                    if (job.schema !== "wilson-expedition/iteration@1" || job.id + ".json" !== name
                        || job.stage !== "awaiting_fix") continue;
                    notify(job.id,
                        "WilsonExpedition 检测到死亡取证任务，来源完整性须从归档核实。请主 GPT 读取 development-support/nbot-relay/private/iteration-queue/"
                        + name + " 及它关联的取证目录，分析真实故障并修改 Mod，完成源码自查和语法检查。修复后执行 development-support/nbot-relay/iteration.py approve "
                        + job.id + " --summary <具体修复说明>。仅在故障证据完整、修复落盘及检查通过后，控制器才会重建其持有的项目测试世界，随后自动进入下一轮；不要复活原挑战，不启动子代理。测试尚未授权时保留队列并报告。");
                }
            } catch (error) {
                stop();
                pi.sendMessage({ customType: "wilson-iteration", content:
                    "WilsonExpedition 死亡队列监听遇到文件错误，已停止监听。请检查 development-support/nbot-relay/private 下的队列和通知记录，保留原文件并修复后重载扩展。", display: true },
                    { triggerTurn: true, deliverAs: "followUp" });
            }
        };
        timer = setInterval(check, 5000);
        timer.unref();
        check();
    });
    pi.on("session_shutdown", async () => stop());
}
