local Observer = require("wilsonexpedition/observer")
local Actions = require("wilsonexpedition/actions")
local Navigation = require("wilsonexpedition/navigation")
local Sailing = require("wilsonexpedition/sailing")
local Survival = require("wilsonexpedition/survival")
local Supplies = require("wilsonexpedition/supplies")
local Exploration = require("wilsonexpedition/exploration")
local Trace = require("wilsonexpedition/trace")
local Revision = require("wilsonexpedition/revision")
local json = require("json")

local Runtime = {}
Runtime.INTERVAL = 0.25
Runtime.SAVE_INTERVAL = 15
Runtime.TARGET_DAYS = 70

local SEASONS = { "autumn", "winter", "spring", "summer" }
local MODES = { stopped = "已停止", paused = "已暂停", running = "运行中", failed = "本局失败" }
local TASK_GROUPS = {
    { "escape", "安全避险" }, { "vitals", "基础生存" }, { "light", "照明准备" },
    { "supplies", "物资准备" }, { "facilities", "设施推进" },
    { "season", "四季准备" }, { "explore", "探索地图" },
}
local FACILITIES = {
    researchlab = true, researchlab2 = true, firepit = true, coldfirepit = true,
    lightning_rod = true, cookpot = true, meatrack = true, icebox = true,
}
local SEASON_ITEMS = { heatrock = true, winterhat = true, grass_umbrella = true, strawhat = true, minifan = true }

local function task_group(key, item)
    key = key or ""
    if key:match("^escape:") then return "escape" end
    if key:match("^light:") or key == "reserve:torch" then return "light" end
    if key:match("^vital:") or key:match("^env:") or key:match("^reserve:cook:") then return "vitals" end
    if key:match("^season:") then return "season" end
    if key == "explore" then return "explore" end
    item = item or key:match("([^:]+)$")
    if Supplies.LIGHT_ITEMS[item] then return "light" end
    if FACILITIES[item] then return "facilities" end
    if SEASON_ITEMS[item] then return "season" end
    return "supplies"
end

local function finite(n)
    return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function pure_copy(value, depth)
    if depth > 12 then return nil end
    local kind = type(value)
    if kind == "string" or kind == "boolean" then return value end
    if kind == "number" then return finite(value) and value or nil end
    if kind ~= "table" then return nil end
    local result = {}
    for k, v in pairs(value) do
        if type(k) == "string" or (type(k) == "number" and finite(k)) then
            local copy = pure_copy(v, depth + 1)
            if copy ~= nil then result[k] = copy end
        end
    end
    return result
end

local function clock(snapshot)
    if finite(snapshot.cycles) and finite(snapshot.time) then
        return snapshot.cycles + snapshot.time
    end
end

local function all_seasons(record)
    for _, name in ipairs(SEASONS) do
        if record.seasons[name] ~= true then return false end
    end
    return true
end

local function log(self, event, detail)
    local entry = {
        schema = "wilson-expedition/client-event@1",
        event = event,
        detail = tostring(detail or ""),
        challenge = self.record and self.record.id,
        userid = self.player.userid,
        tick = GetTime(),
        day = self.snapshot and self.snapshot.day,
        shard = self.snapshot and self.snapshot.shard,
        session = self.snapshot and self.snapshot.session,
        revision = Revision,
    }
    print("[WilsonExpedition] " .. json.encode(entry))
end

local function cancel_executor(self)
    local command = self.command
    if command ~= nil then
        if command.via == "navigation" then
            Navigation.Cancel(self.player, self.state)
        elseif command.via == "sailing" then
            Sailing.Cancel(self.player, self.state)
        else
            Actions.Cancel(self.player)
        end
    end
    self.command = nil
end

local function release(self)
    cancel_executor(self)
    Survival.Cancel(self.state)
end

local function new_record(snapshot)
    return {
        version = 1,
        id = tostring(snapshot.userid) .. ":" .. tostring(snapshot.session) .. ":" .. tostring(clock(snapshot)),
        userid = snapshot.userid,
        prefab = "wilson",
        elapsed_days = 0,
        seasons = {},
        sessions = { [tostring(snapshot.session)] = true },
        failed = false,
        bosses = {},
        start_day = snapshot.day,
    }
end

local function save(self)
    if not self.loaded or self.record == nil then return end
    -- [喵喵喵]: 只持久化纯值记忆；实体、执行器、回调和 GetTime 截止点属于当前进程。
    local data = {
        version = 1,
        record = self.record,
        explore_memory = pure_copy(self.state.explore_memory, 0),
        memory = pure_copy(self.memory, 0),
    }
    self.save_payload = json.encode(data)
    self.dirty = false
    if self.saving then return end
    local function flush()
        local payload = self.save_payload
        self.save_payload = nil
        self.saving = true
        TheSim:SetPersistentString(self.save_key, payload, false, function(success)
            self.saving = false
            if success == false then
                self.save_error = "进度写入失败"
                self.dirty = true
            end
            if self.save_payload ~= nil then flush() end
        end)
    end
    flush()
    self.last_save = GetTime()
end

local function update_progress(self, snapshot)
    local record = self.record
    if record == nil or not record.sessions[tostring(snapshot.session)] then
        self.last_clock = nil
        return
    end
    if snapshot.ghost == true or (snapshot.settled and finite(snapshot.health) and snapshot.health <= 0) then
        if not record.failed then
            record.failed = true
            record.failure_day = snapshot.day
            self.mode, self.reason = "failed", "角色死亡，本局结束"
            release(self)
            log(self, "death", self.reason)
            Trace.Seal(self, self.reason)
            self.player:PushEvent("wilsonexpedition_death", { record = record, snapshot = snapshot })
            self.dirty = true
            save(self)
        end
        return
    end
    local current = clock(snapshot)
    local alive = snapshot.settled == true and snapshot.ghost == false
        and finite(snapshot.health) and snapshot.health > 0
    if alive and not record.failed and current ~= nil then
        -- [喵喵喵]: 断线、换分片和读档后的第一帧重建基线；不把离线世界时间算作角色存活。
        local previous = self.last_clock
        if previous ~= nil and self.last_world == TheWorld then
            local delta = current - previous
            if delta >= 0 and delta <= 2 * Runtime.INTERVAL / TUNING.TOTAL_DAY_TIME then
                record.elapsed_days = record.elapsed_days + delta
            elseif delta < -0.001 then
                record.clock_discontinuity = true
                self.mode, self.reason = "paused", "世界时间回退，进度需核实"
                release(self)
                log(self, "clock_rollback", tostring(delta))
            end
        end
        record.sessions[tostring(snapshot.session)] = true
        record.seasons[snapshot.season or "unknown"] = true
        record.survival_complete = record.elapsed_days >= Runtime.TARGET_DAYS and all_seasons(record)
            and not record.clock_discontinuity
        self.dirty = true
    end
    self.last_clock = alive and current or nil
    self.last_world = TheWorld
end

local function execute(self, command, snapshot)
    if command.via == "actions" then
        return Actions.Step(self.player, command.intent)
    elseif command.via == "navigation" then
        return Navigation.Step(self.player, snapshot, self.state, command.goal)
    elseif command.via == "sailing" then
        return Sailing.Step(self.player, snapshot, self.state, command.goal)
    end
    return "failed", "unknown_executor:" .. tostring(command.via)
end

local function synchronize_receipt(self)
    local record, receipt = self.record, self.player._wilsonexpedition_server
    if record == nil or type(receipt) ~= "table" or receipt.challenge ~= record.id
        or receipt.userid ~= record.userid or self.snapshot == nil
        or tostring(receipt.session) ~= tostring(self.snapshot.session) then return end
    if record.server_life ~= nil and record.server_life ~= receipt.life then
        self:Pause("服务端角色身份变化，挑战待核实")
        return
    end
    record.server_life = receipt.life
    record.sessions[tostring(receipt.session)] = true
    if receipt.failed == true or (record.server_deaths ~= nil and receipt.deaths > record.server_deaths) then
        record.failed = true
        self.mode, self.reason = "failed", "服务端确认角色死亡，本局结束"
        release(self)
        Trace.Seal(self, self.reason)
    end
    record.server_deaths = receipt.deaths
    if finite(receipt.elapsed_days) and receipt.elapsed_days >= record.elapsed_days then
        record.elapsed_days = receipt.elapsed_days
    end
    for _, season in ipairs(SEASONS) do
        if receipt.seasons ~= nil and receipt.seasons[season] == true then record.seasons[season] = true end
    end
    -- [喵喵喵]: 首领进度接收等待进一步指令，已有 bosses 存档字段原样保留。
    -- record.bosses = type(receipt.bosses) == "table" and receipt.bosses or record.bosses
    record.survival_complete = record.elapsed_days >= Runtime.TARGET_DAYS and all_seasons(record)
        and not record.failed and not record.clock_discontinuity
    self.dirty = true
end

function Runtime.Tick(self)
    if self.closed or not self.player:IsValid() or self.player ~= ThePlayer then return end
    local snapshot = Observer.Observe(self.player, self.memory)
    self.snapshot = snapshot
    if not self.loaded then return end
    if self.record ~= nil and GetTime() - (self.last_receipt_request or -10) >= 5
        and rawget(_G, "WilsonExpeditionDiagnosticsRequest") ~= nil then
        self.last_receipt_request = GetTime()
        -- [喵喵喵]: 未关联分片先只查询身份；不能把上一轮 challenge 绑定到新世界的新角色。 (2026-11-11)
        local associated = self.record.sessions[tostring(snapshot.session)]
        WilsonExpeditionDiagnosticsRequest(associated and self.record.id or "")
    end
    synchronize_receipt(self)
    Trace.Sample(self)
    update_progress(self, snapshot)
    local receipt = self.player._wilsonexpedition_server
    if self.record ~= nil and self.record.survival_complete and not self.completion_reported
        and type(receipt) == "table" and receipt.challenge == self.record.id and receipt.life == self.record.server_life
        and receipt.revision == Revision and receipt.failed == false
        and finite(receipt.elapsed_days) and receipt.elapsed_days >= Runtime.TARGET_DAYS and all_seasons(receipt) then
        -- [喵喵喵]: 当前验收止于真实存活满 70 天且经历四季；同版本服务端回执确认后保留世界待验收。
        self.completion_reported = true
        self:Pause("四季生存目标完成，等待验收")
        log(self, "survival_complete", self.reason)
    end
    if self.auto_start_pending and self.mode == "stopped" then
        local controller = self.player.components.playercontroller
        if snapshot.ready and snapshot.settled and controller ~= nil and controller:IsEnabled()
            and self.player.HUD ~= nil and not IsPaused()
            and TheFrontEnd:GetActiveScreen() == self.player.HUD and not self.player.HUD:HasInputFocus() then
            local ok, why = self:Start()
            if not ok then
                self.reason = why
                -- [喵喵喵]: 初始化会重试；已确认的角色、存档或挑战错误保持停止，避免每帧重复发起。 (2026-11-11)
                if why ~= "等待角色初始化" and why ~= "等待存活状态确认"
                    and why ~= "当前分片未关联挑战，等待诊断握手"
                    and why ~= "等待角色与世界身份就绪" and why ~= "等待诊断握手" then
                    self.auto_start_pending = false
                end
            end
        else
            self.reason = "等待角色、存档和游戏输入就绪后自动开始"
        end
    end
    if self.mode == "running" and self.record ~= nil and not self.record.failed then
        local controller = self.player.components.playercontroller
        if IsPaused() or controller == nil or not controller:IsEnabled() then
            -- [喵喵喵]: 角色在入洞、受击等原生状态中会临时禁用控制器；暂停执行而非永久改成手动暂停。 (2026-11-11)
            release(self)
            self.reason = "等待游戏或原生角色控制恢复"
        else
            if Exploration.Observe(self.player, snapshot, self.state) then self.dirty = true end
            -- [喵喵喵]: 每帧先让策略处理抢占，再只轮询它本次交出的命令；旧执行器先释放。
            local command, why = Survival.Plan(self.player, snapshot, self.state)
            self.reason = why or "等待可执行目标"
            if command == nil and self.state.survival ~= nil and self.state.survival.active ~= nil then
                command = self.state.survival.active.command
            end
            if command ~= nil then
                if self.command ~= nil and (self.command.id ~= command.id
                    or self.command.owner ~= command.owner or self.command.via ~= command.via) then
                    cancel_executor(self)
                end
                self.command = command
                local status, detail = execute(self, command, snapshot)
                if status ~= "pending" then log(self, "action_result", tostring(command.purpose) .. ":" .. tostring(detail)) end
                local accepted, reported = Survival.Report(self.state, command, status, detail)
                self.reason = tostring(command.purpose) .. ": " .. tostring(detail)
                local active = self.state.survival and self.state.survival.active
                if status ~= "pending" or not accepted or active == nil or active.id ~= command.id then
                    cancel_executor(self)
                end
            elseif self.command ~= nil then
                cancel_executor(self)
            end
        end
    end
    if self.dirty and GetTime() - self.last_save >= Runtime.SAVE_INTERVAL then save(self) end
    if self.panel ~= nil then self.panel:Refresh(self) end
end

function Runtime:Start()
    if not self.loaded then return false, "进度仍在读取" end
    local snapshot = self.snapshot
    if snapshot == nil or not snapshot.ready or not snapshot.settled then return false, "等待角色初始化" end
    if type(snapshot.userid) ~= "string" or snapshot.userid == ""
        or type(snapshot.session) ~= "string" or snapshot.session == "" then
        return false, "等待角色与世界身份就绪"
    end
    if snapshot.prefab ~= "wilson" then return false, "请选择威尔逊" end
    if snapshot.ghost ~= false then return false, "等待存活状态确认" end
    if self.load_error then return false, self.load_error end
    local needs_new_record = self.record == nil
    if self.record ~= nil and not self.record.sessions[tostring(snapshot.session)] then
        local receipt = self.player._wilsonexpedition_server
        local current_receipt = type(receipt) == "table" and receipt.userid == self.record.userid
            and tostring(receipt.session) == tostring(snapshot.session)
        -- [喵喵喵]: 第一天也可能进入洞穴；先用服务端角色身份区分迁移和真正的新世界。 (2026-11-11)
        if not current_receipt then return false, "当前分片未关联挑战，等待诊断握手" end
        if receipt.life == self.record.server_life and receipt.challenge == self.record.id then
            self.record.sessions[tostring(snapshot.session)] = true
        elseif snapshot.cycles == 0 and receipt.challenge == nil and receipt.life ~= self.record.server_life then
            needs_new_record = true
        else
            return false, "当前分片未关联挑战，等待诊断握手"
        end
    end
    if needs_new_record then
        if snapshot.cycles ~= 0 then return false, "挑战须从新世界第 1 天开始" end
        self.record = new_record(snapshot)
        self.state, self.memory = {}, {}
        self.last_clock, self.last_world = nil, nil
        self.trace, self.trace_time, self.death_sealed = nil, nil, nil
        self.completion_reported = nil
    end
    if self.record.failed then return false, "本局已死亡，请在新世界开始新局" end
    if self.record.clock_discontinuity then return false, "世界时间发生回退，需核实进度" end
    if rawget(_G, "WilsonExpeditionDiagnosticsRequest") ~= nil then
        local receipt = self.player._wilsonexpedition_server
        if type(receipt) ~= "table" or receipt.challenge ~= self.record.id
            or receipt.userid ~= snapshot.userid or receipt.session ~= snapshot.session then
            -- [喵喵喵]: 诊断绑定先于第一条自动动作，避免首帧遇险后双端死亡记录无法关联。 (2026-11-11)
            if GetTime() - (self.last_bind_request or -10) >= 2 then
                self.last_bind_request = GetTime()
                WilsonExpeditionDiagnosticsRequest(self.record.id)
            end
            return false, "等待诊断握手"
        end
        if receipt.revision ~= Revision then return false, "客户端与服务器代码版本不同，等待核对" end
        if receipt.failed then return false, "服务端已确认本局失败" end
    end
    self.auto_start_pending = false
    self.mode, self.reason = "running", "开始规划"
    self.last_clock, self.last_world = clock(snapshot), TheWorld
    log(self, "start", self.reason)
    self.dirty = true
    save(self)
    return true
end

function Runtime:Pause(reason)
    self.auto_start_pending = false
    release(self)
    if self.mode ~= "failed" then self.mode = "paused" end
    self.reason = reason or "手动暂停"
    self.dirty = true
    log(self, "pause", self.reason)
    save(self)
    if self.panel ~= nil then self.panel:Refresh(self) end
end

function Runtime:Stop()
    self.auto_start_pending = false
    release(self)
    if self.mode ~= "failed" then self.mode = "stopped" end
    self.reason = "已停止自动操作，进度保留"
    self.dirty = true
    log(self, "stop", self.reason)
    save(self)
end

function Runtime:Describe()
    local record = self.record
    local elapsed = record and record.elapsed_days or 0
    local seen = {}
    for _, name in ipairs(SEASONS) do
        if record and record.seasons[name] then seen[#seen + 1] = name end
    end
    return string.format("%s  %.2f / %d 天\n四季 %d/4\n%s",
        MODES[self.mode] or self.mode, elapsed, Runtime.TARGET_DAYS, #seen, self.reason or "")
end

function Runtime:DescribeTasks()
    if self.mode ~= "running" then
        if self.mode == "failed" then return { "本局任务已结束" } end
        if self.mode == "paused" then return { "自动任务已暂停" } end
        return { self.auto_start_pending and "等待自动启动" or "自动任务待启动" }
    end
    local statuses = { vitals = "监测中", explore = "待命" }
    local rt = self.state.survival
    -- [喵喵喵]: 显示只读调度器现有的执行与候选需求，不为界面额外规划或发出动作。
    if rt ~= nil then
        if rt.active ~= nil then
            statuses[task_group(rt.active.key)] = "执行中"
            local command = rt.active.command
            if command ~= nil and (command.purpose == "explore" or (command.purpose or ""):match("^explore:")) then
                statuses.explore = "执行中"
            end
        end
        if rt.suspended ~= nil then
            local group = task_group(rt.suspended.key)
            if statuses[group] ~= "执行中" then statuses[group] = "待处理" end
        end
        for _, request in ipairs(rt.demands or {}) do
            local group = task_group(nil, request.item)
            if statuses[group] ~= "执行中" then statuses[group] = "待处理" end
        end
    end
    local lines = {}
    for _, status in ipairs({ "执行中", "待处理", "监测中", "待命" }) do
        for _, group in ipairs(TASK_GROUPS) do
            if statuses[group[1]] == status then lines[#lines + 1] = group[2] .. " · " .. status end
        end
    end
    return lines
end

function Runtime:Close()
    if self.closed then return end
    release(self)
    save(self)
    self.closed = true
    if self.task ~= nil then self.task:Cancel() end
    if self.panel ~= nil then self.panel:Kill() self.panel = nil end
end

function Runtime.Attach(player)
    if player._wilsonexpedition ~= nil then return player._wilsonexpedition end
    local self = setmetatable({
        player = player, state = {}, memory = {}, mode = "stopped", reason = "进入世界后自动开始",
        auto_start_pending = true,
        loaded = false, last_save = GetTime(),
        save_key = "wilsonexpedition_progress_" .. tostring(player.userid or TheNet:GetUserID()),
    }, { __index = Runtime })
    player._wilsonexpedition = self
    TheSim:GetPersistentString(self.save_key, function(success, data)
        if self.closed then return end
        if success and type(data) == "string" and data ~= "" then
            local ok, decoded = pcall(json.decode, data)
            if ok and type(decoded) == "table" and decoded.version == 1
                and type(decoded.record) == "table" and decoded.record.version == 1
                and decoded.record.userid == (player.userid or TheNet:GetUserID())
                and finite(decoded.record.elapsed_days) and decoded.record.elapsed_days >= 0
                and type(decoded.record.sessions) == "table" and type(decoded.record.seasons) == "table" then
                self.record = decoded.record
                self.memory = type(decoded.memory) == "table" and decoded.memory or {}
                self.state.explore_memory = decoded.explore_memory
            else
                self.load_error = "存档格式无效，进度未覆盖"
                self.reason = self.load_error
            end
        end
        self.loaded = true
    end)
    player:ListenForEvent("playerdeactivated", function() self:Close() end)
    player:ListenForEvent("onremove", function() self:Close() end)
    self.task = player:DoPeriodicTask(Runtime.INTERVAL, function()
        local ok, err = xpcall(function() Runtime.Tick(self) end, debug.traceback)
        if not ok then
            self:Pause("执行异常，请查看客户端日志")
            log(self, "runtime_error", err)
        end
    end)
    return self
end

return Runtime
