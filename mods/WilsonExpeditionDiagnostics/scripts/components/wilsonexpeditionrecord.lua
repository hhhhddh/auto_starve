local json = require("json")
local Revision = require("wilsonexpeditiondiagnosticsrevision")

-- [喵喵喵]: 两首领验收暂停，保留实现等待进一步指令；存档 bosses 字段继续兼容。
--[=[
local BOSSES = {
    stalker_atrium = "fuelweaver",
    alterguardian_phase1 = "champion_phase1",
    alterguardian_phase2 = "champion_phase2",
    alterguardian_phase3 = "champion",
}
]=]

local function entity_value(entity)
    if entity == nil then return nil end
    return { prefab = entity.prefab, guid = entity.GUID, userid = entity.userid }
end

local function age_seconds(inst)
    return inst.components.age ~= nil and inst.components.age:GetAge() or nil
end

local Record = Class(function(self, inst)
    self.inst = inst
    self.events = {}
    self.deaths = 0
    self.seasons = {}
    self.bosses = {}
    self.hits = {}
    self.life = nil
    inst:ListenForEvent("attacked", function(_, data)
        self:Log("attacked", { attacker = entity_value(data and data.attacker),
            damage = data and data.damage, original_damage = data and data.original_damage })
    end)
    inst:ListenForEvent("healthdelta", function(_, data)
        self:Log("healthdelta", { oldpercent = data and data.oldpercent,
            newpercent = data and data.newpercent, amount = data and data.amount,
            cause = data and data.cause, overtime = data and data.overtime })
    end)
    inst:ListenForEvent("performaction", function(_, data)
        local action = data and data.action
        if action == nil or action._wilsonexpedition_diagnostic then return end
        action._wilsonexpedition_diagnostic = true
        -- [喵喵喵]: performaction 在原生执行前触发；最终结果取原生回调，不能把派发当作成功。
        local detail = { action = action.action and action.action.id,
            target = entity_value(action.target), item = entity_value(action.invobject) }
        self:Log("action_started", detail)
        action:AddSuccessAction(function() self:Log("action_succeeded", detail) end)
        action:AddFailAction(function() self:Log("action_failed", detail) end)
    end)
    inst:ListenForEvent("death", function(_, data)
        self.deaths = self.deaths + 1
        self.failed = self.challenge ~= nil or self.failed
        self:Log("death", { cause = data and data.cause,
            afflicter = entity_value(data and data.afflicter), count = self.deaths })
        self:Flush()
        self:Publish()
    end)
    --[=[ 首领参与记录等待进一步指令。
    inst:ListenForEvent("onhitother", function(_, data)
        local target = data and data.target
        if target ~= nil and BOSSES[target.prefab] ~= nil then self.hits[target.GUID] = true end
    end)
    ]=]
    inst:ListenForEvent("builditem", function(_, data)
        self:Log("builditem", { item = entity_value(data and data.item) })
    end)
    inst:ListenForEvent("buildstructure", function(_, data)
        self:Log("buildstructure", { item = entity_value(data and data.item) })
    end)
    inst:DoPeriodicTask(5, function() self:Update() end)
end)

function Record:EnsureLife()
    if self.life == nil then
        self.life = tostring(TheNet:GetSessionIdentifier()) .. ":" .. tostring(self.inst.userid)
            .. ":" .. tostring(self.inst.GUID) .. ":" .. tostring(GetTime())
    end
end

function Record:Log(event, detail)
    self:EnsureLife()
    local x, y, z = self.inst.Transform:GetWorldPosition()
    local entry = {
        schema = "wilson-expedition/server-event@1", event = event, detail = detail, revision = Revision,
        challenge = self.challenge, life = self.life, userid = self.inst.userid,
        session = TheNet:GetSessionIdentifier(), shard = TheShard:GetShardId(),
        cycles = TheWorld.state.cycles, time = TheWorld.state.time, tick = GetTime(),
        x = x, y = y, z = z, build = rawget(_G, "APP_VERSION") or "unknown",
    }
    table.insert(self.events, entry)
    if #self.events > 120 then table.remove(self.events, 1) end
    print("[WilsonExpeditionDiagnostics] " .. json.encode(entry))
end

function Record:Begin(challenge)
    self:EnsureLife()
    if self.challenge == challenge then return true end
    if self.challenge ~= nil then return false, "character_already_bound" end
    if self.inst.prefab ~= "wilson" or self.inst:HasTag("playerghost") then return false, "not_living_wilson" end
    local age = age_seconds(self.inst)
    if age == nil or age >= TUNING.TOTAL_DAY_TIME or TheWorld.state.cycles ~= 0 then
        return false, "challenge_requires_new_world"
    end
    self.challenge = challenge
    self.start_age = age
    self.start_deaths = self.deaths
    self.last_age = age
    self.failed = false
    self.seasons = {}
    self.bosses = {}
    self:Log("challenge_started", { age = age })
    return true
end

function Record:Snapshot()
    self:EnsureLife()
    local age = age_seconds(self.inst)
    local hp = self.inst.components.health
    return {
        schema = "wilson-expedition/server-receipt@1", revision = Revision, challenge = self.challenge,
        userid = self.inst.userid, life = self.life, deaths = self.deaths,
        failed = self.failed == true, elapsed_days = age ~= nil and self.start_age ~= nil
            and math.max(0, age - self.start_age) / TUNING.TOTAL_DAY_TIME or nil,
        seasons = self.seasons, bosses = self.bosses,
        ghost = self.inst:HasTag("playerghost"), health = hp and hp.currenthealth,
        session = TheNet:GetSessionIdentifier(), shard = tostring(TheShard:GetShardId()),
        cycles = TheWorld.state.cycles, time = TheWorld.state.time,
        build = rawget(_G, "APP_VERSION") or "unknown",
    }
end

function Record:Publish()
    if self.inst.userid ~= nil and self.send ~= nil then self.send(self.inst.userid, json.encode(self:Snapshot())) end
end

function Record:Update()
    self:EnsureLife()
    if self.challenge ~= nil then
        local age = age_seconds(self.inst)
        if age ~= nil and self.last_age ~= nil and age < self.last_age - 1 then
            self.failed = true
            self:Log("age_rollback", { previous = self.last_age, current = age })
        end
        self.last_age = age
        if not self.failed and not self.inst:HasTag("playerghost") then
            self.seasons[TheWorld.state.season] = true
            local complete = age ~= nil and self.start_age ~= nil and age - self.start_age >= 70 * TUNING.TOTAL_DAY_TIME
            for _, season in ipairs({ "autumn", "winter", "spring", "summer" }) do
                complete = complete and self.seasons[season] == true
            end
            if complete and not self.completion_logged then
                self.completion_logged = true
                self:Log("survival_complete", { elapsed_days = (age - self.start_age) / TUNING.TOTAL_DAY_TIME,
                    seasons = self.seasons })
                self:Flush()
            end
        end
        self:Publish()
    end
end

--[=[ 首领击杀验收等待进一步指令。
function Record:BossDeath(boss)
    local kind = BOSSES[boss.prefab]
    if kind == nil or self.challenge == nil or self.failed then return end
    if not self.hits[boss.GUID] or self.inst:GetDistanceSqToInst(boss) > 50 * 50 then return end
    self.hits[boss.GUID] = nil
    local snap = self:Snapshot()
    local all = true
    for _, season in ipairs({ "autumn", "winter", "spring", "summer" }) do
        if not self.seasons[season] then all = false end
    end
    local valid = snap.elapsed_days ~= nil and snap.elapsed_days >= 70 and all
    if kind == "champion" and self.bosses.fuelweaver == nil then valid = false end
    local receipt = { prefab = boss.prefab, guid = boss.GUID, session = snap.session,
        shard = snap.shard, cycles = snap.cycles, time = snap.time,
        elapsed_days = snap.elapsed_days, participated = true, after_survival = valid }
    if valid then self.bosses[kind] = receipt end
    self:Log("boss_death", receipt)
    self:Flush()
    self:Publish()
end
]=]

function Record:Flush()
    if self.inst.userid == nil then return end
    TheSim:SetPersistentString("wilsonexpedition_server_" .. self.inst.userid,
        json.encode({ schema = "wilson-expedition/server-trace@1", snapshot = self:Snapshot(), events = self.events }),
        false)
end

function Record:OnSave()
    self:EnsureLife()
    return { life = self.life, deaths = self.deaths, challenge = self.challenge,
        start_age = self.start_age, start_deaths = self.start_deaths, last_age = self.last_age,
        failed = self.failed, seasons = self.seasons, bosses = self.bosses }
end

function Record:OnLoad(data)
    if data == nil then return end
    self.life = data.life
    self.deaths = data.deaths or 0
    self.challenge = data.challenge
    self.start_age, self.start_deaths = data.start_age, data.start_deaths
    self.last_age = data.last_age
    self.failed = data.failed
    self.seasons = data.seasons or {}
    self.bosses = data.bosses or {}
end

return Record
