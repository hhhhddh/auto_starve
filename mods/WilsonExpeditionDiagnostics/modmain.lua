local G = GLOBAL
local json = require("json")
local NAMESPACE = "WilsonExpeditionDiagnostics"
local Revision = require("wilsonexpeditiondiagnosticsrevision")

AddSimPostInit(function()
    local world = G.TheWorld
    if world == nil or not world.ismastersim then return end
    print("[WilsonExpeditionDiagnostics] " .. json.encode({
        schema = "wilson-expedition/server-event@1", event = "world_loaded",
        session = G.TheNet:GetSessionIdentifier(), shard = G.tostring(G.TheShard:GetShardId()),
        revision = Revision,
    }))
    if GetModConfigData("auto_iteration") == true then
        world:ListenForEvent("serverpauseddirty", function(_, data)
            print("[WilsonExpeditionDiagnostics] " .. json.encode({
                schema = "wilson-expedition/server-event@1", event = "test_pause_state",
                session = G.TheNet:GetSessionIdentifier(), shard = G.tostring(G.TheShard:GetShardId()),
                revision = Revision, tick = G.GetTime(),
                detail = { paused = data.pause == true and G.TheNet:IsServerPaused(true), source = data.source },
            }))
        end)
    end
end)

AddClientModRPCHandler(NAMESPACE, "pause_test", function(expected, challenge, paused)
    local player = G.ThePlayer
    local receipt = player ~= nil and player._wilsonexpedition_server or nil
    if GetModConfigData("auto_iteration") ~= true or expected ~= Revision or G.type(paused) ~= "boolean" or receipt == nil
        or receipt.revision ~= expected or receipt.challenge ~= challenge
        or not (receipt.failed or (receipt.elapsed_days ~= nil and receipt.elapsed_days >= 70)) then
        return
    end
    -- [喵喵喵]: 原版手动暂停由管理员客户端发起；专服调用同名接口没有暂停回执。 (2026-11-12)
    if G.TheNet:GetIsServerAdmin() then G.SetServerPaused(paused) end
end)

G.WilsonExpeditionPauseTest = function(expected, challenge, paused)
    if GetModConfigData("auto_iteration") ~= true or expected ~= Revision or G.type(paused) ~= "boolean"
        or G.TheWorld == nil or not G.TheWorld.ismastersim then
        return
    end
    for _, player in ipairs(G.AllPlayers) do
        local record = player.components.wilsonexpeditionrecord
        if record ~= nil and record.challenge == challenge and (record.failed or record.completion_logged) then
            record:Publish()
            SendModRPCToClient(GetClientModRPC(NAMESPACE, "pause_test"), player.userid, expected, challenge, paused)
            return
        end
    end
end

AddClientModRPCHandler(NAMESPACE, "receipt", function(text)
    if G.type(text) ~= "string" or #text > 32768 then return end
    local ok, value = G.pcall(json.decode, text)
    local player = G.ThePlayer
    if not ok or G.type(value) ~= "table" or value.schema ~= "wilson-expedition/server-receipt@1"
        or player == nil or value.userid ~= player.userid
        or G.type(value.revision) ~= "string" or value.revision == ""
        or (value.challenge ~= nil and G.type(value.challenge) ~= "string")
        or G.type(value.life) ~= "string" or value.life == ""
        or G.type(value.session) ~= "string" or value.session == ""
        or G.type(value.deaths) ~= "number" or value.deaths < 0 or value.deaths ~= value.deaths
        or value.deaths == G.math.huge or value.deaths ~= G.math.floor(value.deaths)
        or G.type(value.failed) ~= "boolean" or G.type(value.seasons) ~= "table"
        or (value.elapsed_days ~= nil and (G.type(value.elapsed_days) ~= "number"
            or value.elapsed_days < 0 or value.elapsed_days ~= value.elapsed_days or value.elapsed_days == G.math.huge)) then
        return
    end
    player._wilsonexpedition_server = value
    player:PushEvent("wilsonexpedition_receipt", value)
end)

AddModRPCHandler(NAMESPACE, "status", function(player, challenge)
    if G.TheWorld == nil or not G.TheWorld.ismastersim or player == nil then return end
    local record = player.components.wilsonexpeditionrecord
    if record == nil then return end
    local now = G.GetTime()
    if record.last_request ~= nil and now - record.last_request < 2 then return end
    record.last_request = now
    if G.type(challenge) == "string" and #challenge > 0 and #challenge <= 256 then
        local ok, reason = record:Begin(challenge)
        if not ok then record:Log("binding_refused", { reason = reason }) end
    end
    record:Publish()
end)

G.WilsonExpeditionDiagnosticsRequest = function(challenge)
    if G.ThePlayer == nil then return end
    SendModRPCToServer(GetModRPC(NAMESPACE, "status"), challenge or "")
end

AddPlayerPostInit(function(inst)
    if G.TheWorld == nil or not G.TheWorld.ismastersim then return end
    inst:AddComponent("wilsonexpeditionrecord")
    inst.components.wilsonexpeditionrecord.send = function(userid, text)
        SendModRPCToClient(GetClientModRPC(NAMESPACE, "receipt"), userid, text)
    end
end)

-- [喵喵喵]: 首领监听等待进一步指令；本阶段仅执行四季生存测试。
--[=[
for _, prefab in ipairs({ "stalker_atrium", "alterguardian_phase1", "alterguardian_phase2", "alterguardian_phase3" }) do
    AddPrefabPostInit(prefab, function(inst)
        if not G.TheWorld.ismastersim then return end
        inst:ListenForEvent("death", function()
            for _, player in ipairs(G.AllPlayers) do
                local record = player.components.wilsonexpeditionrecord
                if record ~= nil then record:BossDeath(inst) end
            end
        end)
    end)
end
]=]
