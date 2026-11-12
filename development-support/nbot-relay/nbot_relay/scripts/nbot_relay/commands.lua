-- [喵喵喵] WilsonExpedition 本地开发档位副本，来源：不可变归档 mod.zip 内的
-- mod/scripts/nbot_relay/commands.lua（原作者 NBot，见 modinfo）。未获得任何授权再分发，
-- 仅作本机开发支持使用。
-- 与归档原件的唯一差异：本副本只保留只读动作 world_info / players；
-- lua / announce / save / rollback 的处理实现已从本副本删除，
-- 未受限的原件只能从不可变归档恢复，不随本目录流通。
local Json = require("nbot_relay/json")
local M = {}

-- [喵喵喵] 开发档位的命令入口白名单（默认拒绝）。不在此表的动作在命令分发边界
-- 就拿不到处理函数，因此无论中转请求如何构造都不会执行；runtime 的分发断言会先失败，
-- 结果按失败（code 4001 / ok=false）上报，不会被当成成功。
local ALLOWED_ACTIONS = {
    world_info = true,
    players = true,
}

function M.create(G, target)
    local commands = {}

    commands.world_info = function()
        local world = assert(G.TheWorld, "当前没有世界")
        local state = world.state or {}
        return {
            world_id = target.world_id,
            cluster_id = target.cluster_id or "default",
            dedicated = G.TheNet:IsDedicated(),
            ismastersim = world.ismastersim == true,
            name = G.TheNet:GetServerName(),
            prefab = world.prefab,
            cycles = state.cycles,
            season = state.season,
            phase = state.phase,
            time = state.time,
            temperature = state.temperature,
            israining = state.israining,
            issnowing = state.issnowing,
        }
    end

    commands.players = function()
        local players = Json.array()
        for _, player in ipairs(G.AllPlayers or {}) do
            local x, y, z = player.Transform:GetWorldPosition()
            players[#players + 1] = {
                ku_id = player.userid,
                name = player:GetDisplayName(),
                prefab = player.prefab,
                position = { x = x, y = y, z = z },
                is_ghost = player:HasTag("playerghost"),
            }
        end
        return players
    end

    -- [喵喵喵] 白名单收口：只在这一处筛选动作，不建立通用插件/权限框架。
    local gated = {}
    for action, handler in pairs(commands) do
        if ALLOWED_ACTIONS[action] == true then
            gated[action] = handler
        end
    end
    return gated
end

return M
