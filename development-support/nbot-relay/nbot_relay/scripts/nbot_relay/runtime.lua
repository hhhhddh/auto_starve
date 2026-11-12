local Json = require("nbot_relay/json")
local Commands = require("nbot_relay/commands")
local Runtime = {}
Runtime.__index = Runtime

local function identifier(value)
    return type(value) == "string" and #value > 0 and #value <= 128
        and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

function Runtime.new(G, world, config, query_server)
    local port = config.port
    if port == nil then port = 20502 end
    assert(type(port) == "number" and port % 1 == 0 and port >= 1 and port <= 65535, "端口无效")
    local token = config.token
    if token == nil then token = "nbot-relay-default" end
    assert(type(token) == "string" and #token > 0 and #token <= 4096, "token 无效")
    assert(config.cluster_id == nil or identifier(config.cluster_id), "集群标识无效")
    local world_id = "-1"
    if G.TheNet:IsDedicated() then
        world_id = G.tostring(G.TheShard:GetShardId())
        assert(identifier(world_id) and world_id ~= "nil" and world_id ~= "", "shard ID 无效")
    end
    local self = setmetatable({
        G = G,
        world = world,
        query_server = query_server or G.TheSim.QueryServer,
        url = "http://127.0.0.1:" .. port,
        token = token,
        target = { world_id = world_id, cluster_id = config.cluster_id },
        stopped = true,
        tasks = {},
        head = 1,
        tail = 0,
        pending = {},
        schedules = {},
        poll_failures = 0,
    }, Runtime)
    self.commands = Commands.create(G, self.target)
    self.decode = G.require("json").decode
    -- Validate even a no-task request against the fixed default body budget.
    self.poll_body = Json.encode({ token = token, target = self.target })
    return self
end

function Runtime:Alive()
    return not self.stopped and self.G.TheWorld == self.world and self.world:IsValid()
end

function Runtime:Log(message)
    self.G.print("[NBot Relay " .. self.target.world_id .. "] " .. message)
end

function Runtime:Schedule(delay, fn)
    if not self:Alive() then return end
    self.schedules[#self.schedules + 1] = {
        at = delay > 0 and (self.G.os.time() + delay) or nil,
        fn = fn,
    }
end

function Runtime:OnWallUpdate()
    if not self:Alive() then return end
    -- Empty-server sim pause freezes static ticks too. Wall updates still run.
    -- dt can be zero and GetRealTime can advance slowly during sim pause.
    local now = self.G.os.time()
    local scheduled = self.schedules
    self.schedules = {}
    for _, task in ipairs(scheduled) do
        if not self:Alive() then break end
        if task.at == nil or task.at <= now then
            task.fn()
        else
            self.schedules[#self.schedules + 1] = task
        end
    end
end

function Runtime:Post(path, body, callback)
    if not self:Alive() then return end
    local delivered = false
    local function finish(data, success, status)
        if delivered or not self:Alive() then return end
        delivered = true
        local parsed
        if success and status == 200 and type(data) == "string" then
            local ok, value = pcall(Json.decode, data, self.decode)
            if ok and type(value) == "table" then parsed = value end
        end
        callback(parsed, status)
    end
    -- This is an HTTP transport timeout, not a Lua/task execution deadline.
    local ok = pcall(self.query_server, self.G.TheSim,
        self.url .. path, finish, "POST", body, 8)
    if not ok then finish(nil, false, 0) end
end

function Runtime:Start()
    if not self.stopped then return end
    self.stopped = false
    self.world:StartWallUpdatingComponent(self)
    self:Log("已启动，集群 " .. (self.target.cluster_id or "default"))
    self:Poll()
end

function Runtime:Stop()
    if self.stopped then return end
    self.stopped = true
    self.world:StopWallUpdatingComponent(self)
    self.schedules = {}
    self.tasks, self.pending = {}, {}
    self.head, self.tail = 1, 0
    -- Engine-owned HTTP callbacks may still arrive; Alive makes them inert.
end

function Runtime:Poll()
    if not self:Alive() or self.polling then return end
    self.polling = true
    self:Post("/poll", self.poll_body, function(response, status)
        self.polling = false
        if response == nil or response.code ~= 0 or response.ok ~= true
            or type(response.tasks) ~= "table" then
            self.poll_failures = self.poll_failures + 1
            if self.poll_failures == 1 then
                self:Log("轮询失败，稍后重连；HTTP " .. tostring(status or 0))
            end
            local delay = math.min(5, 2 ^ math.min(self.poll_failures - 1, 3))
            self:Schedule(delay, function() self:Poll() end)
            return
        end
        if self.poll_failures > 0 then self:Log("轮询连接已恢复") end
        self.poll_failures = 0
        for _, command in ipairs(response.tasks) do
            if type(command) == "table" and identifier(command.task_id)
                and not self.pending[command.task_id] then
                self.tail = self.tail + 1
                self.tasks[self.tail] = command
                self.pending[command.task_id] = true
            end
        end
        self:WakeWorker()
        self:Schedule(0, function() self:Poll() end)
    end)
end

function Runtime:WakeWorker()
    if self.working or self.head > self.tail then return end
    self.working = true
    self:Schedule(0, function() self:Work() end)
end

function Runtime:ResultBody(command, success, value)
    local result = {
        token = self.token,
        target = self.target,
        task_id = command.task_id,
        code = success and 0 or 4001,
        ok = success,
        message = success and "执行返回" or "执行失败",
    }
    if success then
        result.result = value == nil and Json.null or value
    else
        -- No source dump, print interception, or logging of credentials.
        local message = type(value) == "string" and value or "Lua 执行错误"
        result.message = "执行失败：" .. message:sub(1, 512)
    end
    return Json.encode(result)
end

function Runtime:Work()
    local command = self.tasks[self.head]
    self.tasks[self.head] = nil
    self.head = self.head + 1
    if self.head > self.tail then
        self.tasks = {}
        self.head, self.tail = 1, 0
    end
    local handler = self.commands[command.action]
    local ok, value = pcall(function()
        assert(type(handler) == "function", "不支持的操作")
        assert(type(command.args) == "table", "任务参数必须为对象")
        return handler(command.args)
    end)
    local encoded, body = pcall(self.ResultBody, self, command, ok, value)
    if not encoded then
        -- Side effects may have occurred already. Only replace the report.
        body = self:ResultBody(command, false, "返回值无法转换为 JSON，或结果超过 65536 字节；操作可能已执行")
    end
    self:Post("/result", body, function(response, status)
        self.pending[command.task_id] = nil
        if response == nil or response.code ~= 0 or response.ok ~= true
            or type(response.accepted) ~= "boolean" then
            self:Log("任务 " .. command.task_id .. " 回报失败，未重试；HTTP " .. tostring(status or 0))
        end
        -- accepted=false is a normal late-result discard, not a retry signal.
    end)
    self.working = false
    self:WakeWorker()
end

return Runtime
