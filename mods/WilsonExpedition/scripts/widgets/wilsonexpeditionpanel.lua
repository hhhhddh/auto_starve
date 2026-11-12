local Widget = require("widgets/widget")
local Text = require("widgets/text")
local TextButton = require("widgets/textbutton")
local Image = require("widgets/image")

local ExpeditionPanel = Class(Widget, function(self, runtime)
    Widget._ctor(self, "WilsonExpeditionPanel")
    self:SetHAnchor(ANCHOR_MIDDLE)
    self:SetVAnchor(ANCHOR_TOP)
    self:SetScaleMode(SCALEMODE_PROPORTIONAL)
    -- [喵喵喵]: 背景以中心定位，下移半高使面板顶部与窗口上沿贴齐。
    self:SetPosition(0, -78)
    self.background = self:AddChild(Image("images/global.xml", "square.tex"))
    self.background:SetSize(340, 156)
    self.background:SetTint(0.07, 0.09, 0.11, 0.88)
    self.background:MoveToBack()
    self.text = self:AddChild(Text(UIFONT, 20))
    self.text:SetRegionSize(320, 98)
    self.text:SetHAlign(ANCHOR_LEFT)
    self.text:SetPosition(0, 17)
    self.text:SetClickable(false)
    local function button(label, x, fn)
        local widget = self:AddChild(TextButton())
        widget:SetText(label)
        widget:SetTextSize(21)
        widget:SetPosition(x, -55)
        widget:SetOnClick(fn)
        return widget
    end
    self.start = button("继续 F6", -107, function()
        local ok, why = runtime:Start()
        if not ok then runtime.reason = why end
        self:Refresh(runtime)
    end)
    self.pause = button("暂停 F7", 0, function() runtime:Pause("手动暂停") end)
    self.stop = button("停止 F8", 107, function() runtime:Stop() self:Refresh(runtime) end)
    self:Refresh(runtime)
end)

function ExpeditionPanel:Refresh(runtime)
    self.text:SetString(runtime:Describe())
    self.start:SetText(runtime.auto_start_pending and "准备启动" or "继续 F6")
end

return ExpeditionPanel
