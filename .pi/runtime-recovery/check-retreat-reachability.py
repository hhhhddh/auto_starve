"""Emergency retreat reachability and Chinese HUD regression checks; never starts DST."""

import argparse
import importlib.util
from pathlib import Path
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("death_checks", HERE / "check-death-iteration.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


def retreat_runtime(before_zip=None):
    lua = base.runtime()
    native = getattr(base, "NATIVE_SCRIPTS", base.GAME / "data/databundles/scripts")
    lua.execute((native / "class.lua").read_text(encoding="utf-8"))
    lua.execute('package.loaded["class"] = true')
    lua.execute((native / "vector3.lua").read_text(encoding="utf-8"))
    if before_zip:
        with zipfile.ZipFile(before_zip) as archive:
            names = [name for name in archive.namelist()
                     if name.endswith("scripts/wilsonexpedition/navigation.lua")]
            assert len(names) == 1, "Expected exactly one archived navigation module"
            lua.globals().BEFORE_NAV = archive.read(names[0]).decode("utf-8-sig")
        lua.execute('package.loaded["wilsonexpedition/navigation"] = assert(loadstring(BEFORE_NAV))()')
    lua.execute('''
        Navigation = require("wilsonexpedition/navigation")
        Actions = require("wilsonexpedition/actions")
        action_calls, search_calls = 0, 0
        Actions.Step = function(_, intent)
            action_calls = action_calls + 1
            last_intent = intent
            return "pending", "moving"
        end
        Actions.Cancel = function() return true end
        TheWorld.Map.IsPassableAtPoint = function() return true end
        TheWorld.Map.IsPointNearHole = function() return false end
        TheWorld.Pathfinder = {
            IsClear = function() return true end,
            SubmitSearch = function() search_calls = search_calls + 1; return 1 end,
            KillSearch = function() end,
        }
        snap = snapshot()
        snap.threats = { {guid=2, prefab="crawlinghorror", x=3, z=0, distance=3} }
        state = {}
    ''')
    return lua


def check_blocked_direction(before_zip=None):
    lua = retreat_runtime(before_zip)
    lua.execute('''
        TheWorld.Pathfinder.IsClear = function(_, x0,y0,z0,x,y,z)
            return math.abs(z) > 2
        end
        goal, why = Navigation.Retreat(player, snap, state, 8)
        assert(goal and math.abs(goal.z) > 2, "retreat selected a blocked straight segment")
        local status = Navigation.Step(player, snap, state, goal)
        assert(status == "pending" and action_calls == 1 and search_calls == 0,
            "reachable retreat must start moving without waiting for a search")
    ''')
    print("PASS: blocked direction yields a clear alternative and immediate movement")


def check_short_clear_step(before_zip=None):
    for reachable_length in (4, 2):
        lua = retreat_runtime(before_zip)
        lua.globals().reachable_length = reachable_length
        lua.execute('''
            TheWorld.Pathfinder.IsClear = function(_, x0,y0,z0,x,y,z)
                return (x-x0)^2 + (z-z0)^2 <= reachable_length^2 + .001
            end
            goal, why = Navigation.Retreat(player, snap, state, 8)
            assert(goal and goal.x < 0 and goal.x^2 + goal.z^2 <= reachable_length^2 + .001,
                "retreat failed to shorten an obstructed long route")
            local status = Navigation.Step(player, snap, state, goal)
            assert(status == "pending" and action_calls == 1 and search_calls == 0)
        ''')
    print("PASS: short reachable retreat starts moving while distant routes are blocked")


def check_unknown_or_blocked(before_zip=None):
    for condition in ("false", "nil"):
        lua = retreat_runtime(before_zip)
        lua.execute('''
            TheWorld.Pathfinder.IsClear = function() return %s end
            local goal, why = Navigation.Retreat(player, snap, state, 8)
            assert(goal == nil and type(why) == "string", "unverified passage became an escape goal")
            assert(action_calls == 0 and search_calls == 0)
        ''' % condition)
    lua = retreat_runtime(before_zip)
    lua.execute('''
        TheWorld.Map.IsPassableAtPoint = function() return false end
        assert(Navigation.Retreat(player, snap, state, 8) == nil, "retreat may not cross water")
        TheWorld.Map.IsPassableAtPoint = function() return true end
        TheWorld.Map.IsPointNearHole = function() return true end
        assert(Navigation.Retreat(player, snap, state, 8) == nil, "retreat may not enter a hole")
    ''')
    print("PASS: unknown/blocked passages, water, and holes remain rejected")


def check_hud():
    lua = base.runtime()
    native = getattr(base, "NATIVE_SCRIPTS", base.GAME / "data/databundles/scripts")
    lua.execute((native / "class.lua").read_text(encoding="utf-8"))
    lua.execute('''
        STRINGS = { NAMES = { TWIGS = "原版译名" } }
        local StatusText = require("wilsonexpedition/status_text")
        assert(StatusText("request:twigs: moving:moving") == "获取原版译名 · 行走中")
        assert(StatusText("escape:threat: search_running") == "远离威胁 · 正在寻路")
        assert(StatusText("explore:frontier: arrived:1.50"):find("已到达",1,true))
        assert(StatusText("work:twigs@sapling: awaiting_confirmation"):find("等待动作确认",1,true))
        assert(StatusText("手动暂停") == "手动暂停")
        assert(StatusText("unrecognized_internal_code"):find("待识别",1,true))
        assert(StatusText("escape:threat: action_unavailable:EQUIP"):find("不可用",1,true))
        local Fake = Class(function(self) self.children = {} end)
        function Fake._ctor(self) self.children = {} end
        function Fake:AddChild(child) self.children[#self.children+1] = child; return child end
        function Fake:SetPosition(x,y) self.x,self.y=x,y end
        function Fake:SetSize(w,h) self.width,self.height=w,h end
        function Fake:SetRegionSize(w,h) self.region_width,self.region_height=w,h end
        function Fake:SetHAlign(value) self.align=value end
        function Fake:SetString(value) self.text=value end
        function Fake:SetText(value) self.text=value end
        function Fake:SetTextSize(value) self.size=value end
        function Fake:SetOnClick(fn) self.onclick=fn end
        function Fake:SetHAnchor(value) self.hanchor=value end
        function Fake:SetVAnchor(value) self.vanchor=value end
        function Fake:SetScaleMode(value) self.scalemode=value end
        function Fake:SetTint(r,g,b,a) self.tint={r,g,b,a} end
        function Fake:Show() self.shown=true end
        function Fake:Hide() self.shown=false end
        function Fake:MoveToBack() end
        function Fake:SetClickable(value) self.clickable=value end
        package.loaded["widgets/widget"] = Fake
        package.loaded["widgets/image"] = Fake
        package.loaded["widgets/textbutton"] = Fake
        package.loaded["widgets/text"] = function(font,size)
            local text=Fake(); text.font,text.size=font,size; return text
        end
        ANCHOR_MIDDLE,ANCHOR_TOP,SCALEMODE_PROPORTIONAL,UIFONT = 0,1,2,"ui_font"
        local runtime = {
            auto_start_pending=false, reason="escape:threat: search_running",
            Describe=function(self) return "运行中 8.77 / 70 天\\n四季 1/4\\n"..self.reason end,
            Start=function(self) self.started=true; return true end,
            Pause=function(self) self.paused=true end,
            Stop=function(self) self.stopped=true end,
            DescribeTasks=function(self) return self.tasks or {"基础生存 · 执行中", "探索地图 · 待命"} end,
        }
        local raw_reason=runtime.reason
        local Panel=require("widgets/wilsonexpeditionpanel")
        local panel=Panel(runtime)
        assert(#panel.lines==3, "HUD requires three independently centered lines")
        for _,text in ipairs(panel.lines) do
            assert(text.align==ANCHOR_MIDDLE and text.x==0 and text.size==22)
        end
        assert(panel.lines[1].y-panel.lines[2].y==34 and panel.lines[2].y-panel.lines[3].y==34)
        assert(panel.y+panel.background.height/2==-18 and panel.hanchor==ANCHOR_MIDDLE
            and panel.vanchor==ANCHOR_TOP, "panel top must sit slightly below the window top")
        assert(panel.background.width==400 and panel.background.height==112, "status layout must fit its three lines")
        local tint=panel.background.tint
        assert(tint[1]>tint[3] and tint[2]>tint[3] and tint[4]==.32, "panel must use translucent warm yellow")
        assert(panel.background.clickable==false and panel.task_background.clickable==false)
        assert(panel.taskbox.x-panel.task_background.width/2>panel.background.width/2,
            "task box must sit beside, not over, the main panel")
        assert(panel.taskbox.y+panel.task_background.y+panel.task_background.height/2==panel.background.height/2,
            "the two panel tops must align")
        assert(panel.task_lines[1].text=="基础生存 · 执行中" and panel.task_lines[2].text=="探索地图 · 待命")
        assert(panel.task_background.height==92 and panel.task_lines[3].shown==false)
        assert(panel.start==nil and panel.pause==nil and panel.stop==nil, "display has no execution controls")
        assert(panel.lines[1].text=="运行中 8.77 / 70 天" and panel.lines[2].text=="四季 1/4")
        assert(panel.lines[3].text=="远离威胁 · 正在寻路" and runtime.reason==raw_reason,
            "HUD translation must preserve raw diagnostics")
        runtime.reason="角色死亡，本局结束"; panel:Refresh(runtime)
        assert(panel.lines[3].text==runtime.reason)
        runtime.tasks={"本局任务已结束"}; panel:Refresh(runtime)
        assert(panel.task_background.height==66 and panel.task_lines[1].shown and not panel.task_lines[2].shown,
            "completed/paused lists must shrink without stale task rows")
        runtime.tasks={"安全避险 · 执行中", "基础生存 · 监测中", "照明准备 · 待处理", "物资准备 · 待处理",
            "设施推进 · 待处理", "四季准备 · 待处理", "探索地图 · 待命"}
        panel:Refresh(runtime)
        assert(panel.task_lines[7].shown and panel.task_background.height==222)
        assert(not runtime.started and not runtime.paused and not runtime.stopped,
            "refresh must not change automation state")
    ''')
    print("PASS: Chinese task/result display uses native names and preserves raw diagnostics")
    print("PASS: compact translucent yellow status and adjacent dynamic task list remain read-only")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before-zip", type=Path, help="Run retreat checks against archived pre-fix source")
    args = parser.parse_args()
    for check in (check_blocked_direction, check_short_clear_step, check_unknown_or_blocked):
        check(args.before_zip)
    if not args.before_zip:
        check_hud()
