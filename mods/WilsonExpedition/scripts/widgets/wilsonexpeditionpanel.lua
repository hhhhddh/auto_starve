local Widget = require("widgets/widget")
local Text = require("widgets/text")
local Image = require("widgets/image")
local StatusText = require("wilsonexpedition/status_text")

local ExpeditionPanel = Class(Widget, function(self, runtime)
    Widget._ctor(self, "WilsonExpeditionPanel")
    self:SetHAnchor(ANCHOR_MIDDLE)
    self:SetVAnchor(ANCHOR_TOP)
    self:SetScaleMode(SCALEMODE_PROPORTIONAL)
    -- [喵喵喵]: 顶部留出 18 个界面单位，任务框与状态框顶边对齐，避免紧贴窗口边缘。
    self:SetPosition(0, -74)
    self.background = self:AddChild(Image("images/global.xml", "square.tex"))
    self.background:SetSize(400, 112)
    self.background:SetTint(0.94, 0.84, 0.44, 0.32)
    self.background:SetClickable(false)
    self.background:MoveToBack()
    self.lines = {}
    for index, y in ipairs({ 34, 0, -34 }) do
        local text = self:AddChild(Text(UIFONT, 22))
        text:SetRegionSize(380, 30)
        text:SetHAlign(ANCHOR_MIDDLE)
        text:SetPosition(0, y)
        text:SetClickable(false)
        self.lines[index] = text
    end
    self.taskbox = self:AddChild(Widget("WilsonExpeditionTasks"))
    self.taskbox:SetPosition(332, 56)
    self.task_background = self.taskbox:AddChild(Image("images/global.xml", "square.tex"))
    self.task_background:SetTint(0.94, 0.84, 0.44, 0.32)
    self.task_background:SetClickable(false)
    self.task_background:MoveToBack()
    local title = self.taskbox:AddChild(Text(UIFONT, 22))
    title:SetRegionSize(220, 26)
    title:SetHAlign(ANCHOR_MIDDLE)
    title:SetPosition(0, -18)
    title:SetString("当前任务")
    title:SetClickable(false)
    self.task_lines = {}
    for index = 1, 7 do
        local text = self.taskbox:AddChild(Text(UIFONT, 20))
        text:SetRegionSize(220, 24)
        text:SetHAlign(ANCHOR_MIDDLE)
        text:SetPosition(0, -46 - (index - 1) * 26)
        text:SetClickable(false)
        self.task_lines[index] = text
    end
    self:Refresh(runtime)
end)

function ExpeditionPanel:Refresh(runtime)
    local heading, progress, reason = runtime:Describe():match("^([^\n]*)\n([^\n]*)\n(.*)$")
    assert(heading ~= nil, "WilsonExpedition panel expected three status lines")
    self.lines[1]:SetString(heading)
    self.lines[2]:SetString(progress)
    self.lines[3]:SetString(StatusText(reason))
    local tasks = runtime:DescribeTasks()
    assert(#tasks >= 1 and #tasks <= #self.task_lines, "WilsonExpedition task list exceeds its display capacity")
    local height = 40 + #tasks * 26
    self.task_background:SetSize(240, height)
    self.task_background:SetPosition(0, -height / 2)
    for index, text in ipairs(self.task_lines) do
        if tasks[index] ~= nil then
            text:SetString(tasks[index])
            text:Show()
        else
            text:Hide()
        end
    end
end

return ExpeditionPanel
