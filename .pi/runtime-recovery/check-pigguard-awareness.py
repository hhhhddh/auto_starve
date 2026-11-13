"""Regressions for visible pig guards and their protected torch perimeter."""

import importlib.util
from pathlib import Path
import re
import sys
import zipfile

spec = importlib.util.spec_from_file_location("death_checks", Path(__file__).with_name("check-death-iteration.py"))
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)
from lupa.lua51 import LuaError


def fixture(observer_source, navigation_source):
    native = baseline.GAME / "data/databundles/scripts"
    pig = (native / "prefabs/pigman.lua").read_text(encoding="utf-8-sig")
    torch = (native / "prefabs/pigtorch.lua").read_text(encoding="utf-8-sig")
    tuning = (native / "tuning.lua").read_text(encoding="utf-8-sig")
    common = re.search(r"local function common\(moonbeast\)(.*?)if moonbeast then", pig, re.S)
    assert common
    guard_tags = re.findall(r'inst:AddTag\("([^\"]+)"\)', common.group(1))
    torch_tags = re.findall(r'inst:AddTag\("([^\"]+)"\)', torch.split("inst.entity:SetPristine()", 1)[0])
    assert "pig" in guard_tags and "hostile" not in guard_tags and "guard" not in guard_tags
    assert "hostile" not in torch_tags and 'Configure("pigguard"' in torch
    native_retarget = pig.split('local KING_TAGS = { "king" }', 1)[1].split("local function GuardKeepTargetFn", 1)[0]
    native_retarget = 'local KING_TAGS = { "king" }' + native_retarget + "\nreturn GuardRetargetFn"
    lua = baseline.runtime()
    for name in ("PIG_GUARD_TARGET_DIST", "PIG_GUARD_DEFEND_DIST", "SPRING_COMBAT_MOD"):
        match = re.search(rf"\b{name}\s*=\s*([\d.]+)", tuning)
        assert match, name
        lua.globals().TUNING[name] = float(match.group(1))
    lua.globals().GUARD_TAGS = lua.table_from({tag: True for tag in guard_tags})
    lua.globals().TORCH_TAGS = lua.table_from({tag: True for tag in torch_tags})
    lua.globals().OBSERVER_SOURCE = observer_source
    lua.globals().NAVIGATION_SOURCE = navigation_source
    lua.globals().NATIVE_RETARGET = native_retarget
    lua.execute('''
        function Vector3(x, y, z) return { x = x, y = y, z = z } end
        function position(inst, x, z)
            inst.Transform = { GetWorldPosition = function() return x, 0, z end }
            function inst:IsNear(other, radius)
                local ox, _, oz = other.Transform:GetWorldPosition()
                return (x - ox)^2 + (z - oz)^2 < radius^2
            end
        end
        px = 0
        player.tags.player, player.tags.character = true, true
        player.Transform.GetWorldPosition = function() return px, 0, 0 end
        function player:IsInLight() return true end
        TheWorld.state = { phase = "day", isday = true, season = "spring", time = 0.3, cycles = 2 }
        function TheWorld:HasTag(tag) return tag == "forest" end
        TheWorld.Map.IsPassableAtPoint = function() return true end
        TheWorld.Map.IsPointNearHole = function() return false end
        TheWorld.Pathfinder = { IsClear = function() return true end }
        guard = entity(50, "pigguard", GUARD_TAGS)
        torch = entity(51, "pigtorch", TORCH_TAGS)
        pig = entity(52, "pigman", { character = true, pig = true, trader = true })
        house = entity(53, "pighouse", { structure = true })
        fire = entity(54, "campfire", { structure = true })
        position(guard, 6, 0); position(torch, 8, 0)
        position(pig, 3, 0); position(house, 4, 0); position(fire, 2, 0)
        TheSim = { FindEntities = function() return { guard, torch, pig, house, fire, player } end,
            GetLightAtPoint = function() return 1 end,
            GetAmbientColour = function() return 200, 200, 200 end }
        function SpringCombatMod(distance)
            return distance * (TheWorld.state.season == "spring" and TUNING.SPRING_COMBAT_MOD or 1)
        end
        function FindEntity(center, radius, fn, required, forbidden, oneof)
            local cx, _, cz = center.Transform:GetWorldPosition()
            for _, inst in ipairs({ player, guard }) do
                local x, _, z = inst.Transform:GetWorldPosition()
                local accepted = (x - cx)^2 + (z - cz)^2 < radius^2
                for _, tag in ipairs(required or {}) do accepted = accepted and inst:HasTag(tag) end
                for _, tag in ipairs(forbidden or {}) do accepted = accepted and not inst:HasTag(tag) end
                if oneof then
                    local any = false
                    for _, tag in ipairs(oneof) do any = any or inst:HasTag(tag) end
                    accepted = accepted and any
                end
                if accepted and (fn == nil or fn(inst)) then return inst end
            end
        end
        guard.components.homeseeker = { home = torch }
        torch.components.burnable = { IsBurning = function() return true end,
            GetLargestLightRadius = function() return 5 end }
        native_retarget = assert(loadstring(NATIVE_RETARGET))()
        local Actions = require("wilsonexpedition/actions")
        actions, cancelled_action = {}, false
        Actions.Step = function(_, command)
            actions[#actions + 1] = command
            return "pending", "move_pending"
        end
        Actions.Cancel = function() cancelled_action = true; return true end
        Observer = assert(loadstring(OBSERVER_SOURCE))()
        Navigation = assert(loadstring(NAVIGATION_SOURCE))()
        package.loaded["wilsonexpedition/observer"] = Observer
        package.loaded["wilsonexpedition/navigation"] = Navigation
    ''')
    baseline.observer_view_fixture(lua)
    return lua


def check_guard_visibility(observer_source, navigation_source):
    lua = fixture(observer_source, navigation_source)
    lua.execute('''
        for _, phase in ipairs({ "day", "night" }) do
            TheWorld.state.phase, TheWorld.state.isday = phase, phase == "day"
            local s = Observer.Observe(player, {})
            assert(#s.threats == 2 and s.threats[1].entity == guard and s.threats[2].entity == torch,
                "pigguard and pigtorch without hostile tags must be threats")
            assert(#s.nearby == 5, "ordinary pigs and structures must remain visible")
            for _, threat in ipairs(s.threats) do
                assert(threat.prefab ~= "pigman" and threat.prefab ~= "pighouse" and threat.prefab ~= "campfire",
                    "neutral pigs and structures must remain neutral")
            end
        end
    ''')


def check_perimeter_routes(observer_source, navigation_source):
    lua = fixture(observer_source, navigation_source)
    lua.execute('''
        for _, prefab in ipairs({ "pigguard", "pigtorch" }) do
            local s, state = snapshot(), {}
            s.x, s.z, s.threats = 20, 0, { { prefab = prefab, x = 0, z = 0 } }
            local status = Navigation.Step(player, s, state, { id = "approach_" .. prefab, x = 10.5, z = 0 })
            assert(status == "pending" and #actions == 0,
                "native spring-expanded pig guard perimeter must block approach")
            Navigation.Cancel(player, state)
            s.x, s.z, state = -20, 5, {}
            status = Navigation.Step(player, s, state, { id = "cross_" .. prefab, x = 20, z = 5 })
            assert(status == "pending" and #actions == 0,
                "route with safe endpoints must not cross the guarded perimeter")
            Navigation.Cancel(player, state)
            s.x, s.z, state = 6, 0, {}
            status = Navigation.Step(player, s, state, { id = "leave_" .. prefab, x = 30, z = 0 })
            assert(status == "pending" and #actions == 1 and actions[1].x == 30,
                "guarded area must permit verified outward escape")
            Navigation.Cancel(player, state)
            actions = {}
        end
    ''')


def check_procurement_preemption(observer_source, navigation_source):
    lua = fixture(observer_source, navigation_source)
    lua.execute('''
        stub_planners()
        package.loaded["wilsonexpedition/observer"] = Observer
        package.loaded["wilsonexpedition/navigation"] = Navigation
        local Survival = require("wilsonexpedition/survival")
        local s, state = snapshot(), {}
        assert(Survival.Plan(player, s, state).owner == "supplies")
        s.threats = Observer.Observe(player, {}).threats
        local command = Survival.Plan(player, s, state)
        assert(command and command.priority == Survival.PRIORITY_ESCAPE and cancelled,
            "pig guard danger must interrupt ongoing procurement")
        Survival.Report(state, command, "succeeded", "arrived")
        s.x = -5
        command = Survival.Plan(player, s, state)
        assert(command and command.priority == Survival.PRIORITY_ESCAPE,
            "escape must persist until the existing clearance is reached")
        Survival.Report(state, command, "succeeded", "arrived")
        s.x = -30
        command = Survival.Plan(player, s, state)
        assert(command and command.owner == "supplies", "procurement must resume after safe separation")
    ''')


def check_home_before_guard_visible(observer_source, navigation_source):
    lua = fixture(observer_source, navigation_source)
    lua.execute('''
        -- [喵喵喵]: 原版索敌函数运行在服务器；该阶段 SetGuardPig 已补 guard 标签，客户端可见性另行验证。
        guard.tags.guard = true
        view_half_width = 16
        px = -10.5
        position(guard, 20, 0); position(torch, 0, 0)
        assert(native_retarget(guard) == player,
            "native guard must acquire a player near its home while the guard is outside the camera view")
        local s = Observer.Observe(player, {})
        assert(#s.threats == 1 and s.threats[1].entity == torch,
            "visible pig torch must protect its perimeter when its guard is out of sight")
        TheWorld.state.phase, TheWorld.state.isday, TheWorld.state.season = "night", false, "autumn"
        px = -4
        assert(native_retarget(guard) == player, "native guard must still defend its lit home at night")
        assert(Observer.Observe(player, {}).threats[1].entity == torch)
    ''')


checks = (check_guard_visibility, check_perimeter_routes, check_procurement_preemption, check_home_before_guard_visible)
if len(sys.argv) == 3 and sys.argv[1] == "--old":
    with zipfile.ZipFile(sys.argv[2]) as archive:
        observer = archive.read("client/scripts/wilsonexpedition/observer.lua").decode("utf-8-sig")
        navigation = archive.read("client/scripts/wilsonexpedition/navigation.lua").decode("utf-8-sig")
    messages = ("pigguard and pigtorch without hostile", "native spring-expanded pig guard perimeter",
                "pig guard danger must interrupt", "visible pig torch must protect")
    for check, message in zip(checks, messages):
        try:
            check(observer, navigation)
        except LuaError as error:
            assert message in str(error), str(error)
            print("REPRODUCED", check.__name__)
        else:
            raise AssertionError("Old source unexpectedly passed " + check.__name__)
else:
    observer = (baseline.SCRIPTS / "wilsonexpedition/observer.lua").read_text(encoding="utf-8-sig")
    navigation = (baseline.SCRIPTS / "wilsonexpedition/navigation.lua").read_text(encoding="utf-8-sig")
    for check in checks:
        check(observer, navigation)
        print("PASS", check.__name__)
