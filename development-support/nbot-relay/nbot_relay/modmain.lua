local G = GLOBAL
-- Keep our transport before later mods defer QueryServer on simulation time.
local query_server = G.TheSim.QueryServer
local Runtime = require("nbot_relay/runtime")
local load_config = G.kleiloadlua(MODROOT .. "relay_config.lua")
local config
if G.type(load_config) == "function" then
    local ok, value = G.pcall(load_config)
    if ok and G.type(value) == "table" then
        config = value
    end
end

if config == nil then
    G.print("[NBot Relay] relay_config.lua 无效，未启动")
    return
end

AddSimPostInit(function()
    if GetModConfigData("enabled") == false then
        return
    end
    local world = G.TheWorld
    if world == nil or world._nbot_relay ~= nil then
        return
    end
    local ok, runtime = G.pcall(Runtime.new, G, world, config, query_server)
    if not ok then
        -- 配置错误可能包含凭据，不打印原始异常。
        G.print("[NBot Relay] 配置或实例身份无效，未启动")
        return
    end
    world._nbot_relay = runtime
    world:ListenForEvent("onremove", function() runtime:Stop() end)
    runtime:Start()
end)
