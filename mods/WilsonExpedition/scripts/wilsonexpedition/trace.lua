local json = require("json")
local Revision = require("wilsonexpedition/revision")

local Trace = {}
local function position(entity)
    if entity ~= nil and entity:IsValid() then
        local x, _, z = entity.Transform:GetWorldPosition()
        return { prefab = entity.prefab, guid = entity.GUID, x = x, z = z }
    end
end

local function item_condition(item)
    local entity = item.entity or item.item
    local replica = entity ~= nil and entity.replica ~= nil and entity.replica.inventoryitem or nil
    local classified = replica ~= nil and replica.classified or nil
    if classified == nil then return end
    local ok, remaining, freshness = pcall(function()
        return classified.percentused ~= nil and classified.percentused:value() or nil,
            classified.perish ~= nil and classified.perish:value() or nil
    end)
    if not ok then return end
    -- [喵喵喵]: 原版 255/63 表示未知，不能当成剩余量；仅保存客户端已知的耐久与新鲜度。
    remaining = type(remaining) == "number" and remaining >= 0 and remaining <= 100 and remaining / 100 or nil
    freshness = type(freshness) == "number" and freshness >= 0 and freshness <= 62 and freshness / 62 or nil
    return remaining, freshness
end

function Trace.Sample(runtime, force)
    local now = GetTime()
    if not force and runtime.trace_time ~= nil and now - runtime.trace_time < 0.5 then return end
    local snapshot = runtime.snapshot or {}
    runtime.trace_time = now
    runtime.trace = runtime.trace or {}
    local threats = {}
    for i, record in ipairs(snapshot.threats or {}) do
        if i > 8 then break end
        threats[#threats + 1] = position(record.entity)
    end
    local counts, conditions
    if snapshot.ghost == false and type(snapshot.health) == "number" and snapshot.health > 0
        and snapshot.inventory ~= nil and snapshot.inventory.settled == true then
        local inventory, equipment = {}, {}
        counts, conditions = {}, {}
        for _, item in ipairs(snapshot.inventory.records or {}) do
            if item.kind == "inventory" or item.kind == "backpack" or item.kind == "equipment" or item.kind == "active" then
                local remaining, freshness = item_condition(item)
                inventory[#inventory + 1] = { prefab = item.prefab, count = item.count, kind = item.kind,
                    slot = item.slot, guid = item.guid, remaining = remaining, freshness = freshness }
                counts[item.prefab] = (counts[item.prefab] or 0) + item.count
            end
        end
        for slot, item in pairs(snapshot.equipment or {}) do
            equipment[slot] = item.prefab
            conditions[slot] = { guid = item.guid, remaining = item_condition(item) }
        end
        runtime.last_inventory, runtime.last_equipment = inventory, equipment
    end
    local light = snapshot.light or {}
    local entry = {
        tick = now, cycles = snapshot.cycles, time = snapshot.time, phase = snapshot.phase,
        light = { available = light.available, in_light = light.in_light, dark = light.dark, level = light.level,
            ambient = light.ambient, threshold = light.threshold },
        time_until_night = snapshot.time_until_night, shard_kind = snapshot.shard_kind,
        season = snapshot.season, shard = snapshot.shard, session = snapshot.session,
        health = snapshot.health, hunger = snapshot.hunger, sanity = snapshot.sanity,
        temperature = snapshot.temperature, moisture = snapshot.moisture,
        ghost = snapshot.ghost, x = snapshot.x, z = snapshot.z,
        task = runtime.command and runtime.command.purpose, reason = runtime.reason,
        command = runtime.command and tostring(runtime.command.id), mode = runtime.mode,
        threats = threats, equipment = runtime.last_equipment,
        inventory_counts = counts, equipment_condition = conditions,
    }
    runtime.trace[#runtime.trace + 1] = entry
    while #runtime.trace > 240 do table.remove(runtime.trace, 1) end
end

function Trace.Seal(runtime, cause)
    if runtime.death_sealed then return end
    runtime.death_sealed = true
    Trace.Sample(runtime, true)
    local record = runtime.record
    local bundle = {
        schema = "wilson-expedition/death-bundle@1", event = "death_bundle",
        challenge = record and record.id, userid = runtime.player.userid,
        session = runtime.snapshot and runtime.snapshot.session,
        shard = runtime.snapshot and runtime.snapshot.shard,
        cause = cause, mod_version = "0.1.5", revision = Revision, record = record,
        server_receipt = runtime.player._wilsonexpedition_server,
        inventory = runtime.last_inventory, equipment = runtime.last_equipment,
        game_build = rawget(_G, "APP_VERSION") or "unknown",
        trace = runtime.trace,
    }
    local text = json.encode(bundle)
    local key = "wilsonexpedition_death_" .. tostring(runtime.player.userid)
        .. "_" .. tostring(math.floor(GetTime() * 1000))
    -- [喵喵喵]: 原生日志会截断 4095 字节长行；完整轨迹先落盘，再发送短通知供本机采集器关联读取。 (2026-11-11)
    TheSim:SetPersistentString(key, text, false, function(success)
        print("[WilsonExpedition] " .. json.encode({
            schema = "wilson-expedition/client-event@1",
            event = success == false and "death_bundle_save_failed" or "death_bundle",
            detail = key, challenge = bundle.challenge, userid = bundle.userid,
            session = bundle.session, shard = bundle.shard, revision = bundle.revision,
        }))
    end)
end

return Trace
