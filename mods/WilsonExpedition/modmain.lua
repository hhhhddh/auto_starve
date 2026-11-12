local Runtime = require("wilsonexpedition/runtime")
local Panel = require("widgets/wilsonexpeditionpanel")

AddClassPostConstruct("screens/redux/lobbyscreen", function(screen)
    if GLOBAL.TheNet:IsDedicated() then return end
    local previous = screen.OnUpdate
    local requested = false
    screen.OnUpdate = function(self, dt)
        if previous ~= nil then previous(self, dt) end
        if requested or not self.enabled or GLOBAL.TheFrontEnd:GetActiveScreen() ~= self
            or GLOBAL.type(self.cb) ~= "function" then return end
        -- [喵喵喵]: 选角时世界模拟可能暂停；由客户端 UI 更新调用原版回调，保留出生皮肤和技能握手。 (2026-11-11)
        requested = true
        print("[WilsonExpedition] auto_select:wilson")
        self.cb("wilson", "wilson_none", "", "", "", "")
    end
    screen:StartUpdating()
end)

AddClassPostConstruct("widgets/controls", function(controls)
    local player = controls.owner
    if player == nil or GLOBAL.TheNet:IsDedicated() then return end
    local runtime = Runtime.Attach(player)
    runtime.panel = controls:AddChild(Panel(runtime))
end)

local manual = {
    [GLOBAL.CONTROL_PRIMARY] = true,
    [GLOBAL.CONTROL_SECONDARY] = true,
    [GLOBAL.CONTROL_ACTION] = true,
    [GLOBAL.CONTROL_ATTACK] = true,
    [GLOBAL.CONTROL_MOVE_UP] = true,
    [GLOBAL.CONTROL_MOVE_DOWN] = true,
    [GLOBAL.CONTROL_MOVE_LEFT] = true,
    [GLOBAL.CONTROL_MOVE_RIGHT] = true,
}
for control = GLOBAL.CONTROL_INV_1, GLOBAL.CONTROL_INV_10 do manual[control] = true end

-- [喵喵喵]: 前端控件消费输入前先暂停，背包和制作 UI 的手动操作也能接管。 (2026-11-11)
local input = GLOBAL.TheInput
local previous = input.OnControl
input.OnControl = function(self, control, down, ...)
    local player = GLOBAL.ThePlayer
    local runtime = player ~= nil and player._wilsonexpedition or nil
    if down and manual[control] and runtime ~= nil
        and (runtime.mode == "running" or runtime.auto_start_pending) then
        runtime:Pause("玩家接管")
    end
    return previous(self, control, down, ...)
end
