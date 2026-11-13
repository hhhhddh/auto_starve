"""Regressions for client-visible killer bees and proximity-triggered hives."""

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
    native = baseline.NATIVE_SCRIPTS / "prefabs"
    bee_source = (native / "bee.lua").read_text(encoding="utf-8-sig")
    hive_source = (native / "wasphive.lua").read_text(encoding="utf-8-sig")
    common = bee_source.split("local function commonfn(", 1)[1].split("inst.entity:SetPristine()", 1)[0]
    bee_tags = re.findall(r'inst:AddTag\("([^\"]+)"\)', common)
    killer_tags = re.search(r'local function killerbee\(\).*?commonfn\("bee_angry_build", \{(.*?)\}', bee_source, re.S)
    assert killer_tags
    bee_tags += re.findall(r'"([^\"]+)"', killer_tags.group(1))
    hive_tags = re.findall(r'inst:AddTag\("([^\"]+)"\)', hive_source.split("inst.entity:SetPristine()", 1)[0])
    assert "hostile" not in bee_tags and "hostile" not in hive_tags
    assert "FindEntity(inst, SpringCombatMod(8)" in bee_source
    assert "SetDist(10, 13)" in hive_source and 'ReleaseAllChildren(target, "killerbee")' in hive_source
    lua = baseline.runtime()
    lua.globals().BEE_TAGS = lua.table_from({tag: True for tag in bee_tags})
    lua.globals().HIVE_TAGS = lua.table_from({tag: True for tag in hive_tags})
    lua.globals().OBSERVER_SOURCE = observer_source
    lua.globals().NAVIGATION_SOURCE = navigation_source
    lua.execute('''
        function Vector3(x, y, z) return { x = x, y = y, z = z } end
        TUNING.SPRING_COMBAT_MOD = 1.33
        TheWorld.Map.IsPassableAtPoint = function() return true end
        TheWorld.Map.IsPointNearHole = function() return false end
        TheWorld.Pathfinder = { IsClear = function() return true end }
        TheWorld.state = { phase = "day", time = 0.3, cycles = 0 }
        function TheWorld:HasTag(tag) return tag == "forest" end
        bee = entity(50, "killerbee", BEE_TAGS)
        bee.Transform = { GetWorldPosition = function() return 6, 0, 0 end }
        hive = entity(51, "wasphive", HIVE_TAGS)
        hive.Transform = { GetWorldPosition = function() return 8, 0, 0 end }
        worker = entity(52, "bee", { bee = true, insect = true, worker = true })
        worker.Transform = { GetWorldPosition = function() return 3, 0, 0 end }
        normal_hive = entity(53, "beehive", { structure = true, hive = true, beehive = true })
        normal_hive.Transform = { GetWorldPosition = function() return 4, 0, 0 end }
        TheSim = { FindEntities = function() return { bee, hive, worker, normal_hive, player } end,
            GetLightAtPoint = function() return 1 end,
            GetAmbientColour = function() return 200, 200, 200 end }
        local Actions = require("wilsonexpedition/actions")
        actions = {}
        Actions.Step = function(_, command)
            actions[#actions + 1] = command
            return "pending", "move_pending"
        end
        Actions.Cancel = function() return true end
        Observer = assert(loadstring(OBSERVER_SOURCE))()
        Navigation = assert(loadstring(NAVIGATION_SOURCE))()
        package.loaded["wilsonexpedition/observer"] = Observer
        package.loaded["wilsonexpedition/navigation"] = Navigation
    ''')
    baseline.observer_view_fixture(lua)
    return lua


def check_native_bee_visibility(observer_source, navigation_source):
    lua = fixture(observer_source, navigation_source)
    lua.execute('''
        local s = Observer.Observe(player, {})
        assert(#s.threats == 2 and s.threats[1].entity == bee and s.threats[2].entity == hive,
            "killerbee and wasphive without hostile tags must be visible threats")
        for _, t in ipairs(s.threats) do
            assert(t.prefab ~= "bee" and t.prefab ~= "beehive", "neutral workers and hives must remain neutral")
        end
    ''')


def check_proximity_route_avoidance(observer_source, navigation_source):
    lua = fixture(observer_source, navigation_source)
    lua.execute('''
        for _, prefab in ipairs({ "wasphive", "killerbee" }) do
            local s, state = snapshot(), {}
            s.x, s.z = 20, 0
            s.threats = { { prefab = prefab, x = 0, z = 0 } }
            local status = Navigation.Step(player, s, state, { id = "approach_" .. prefab, x = 11, z = 0 })
            assert(status == "pending" and #actions == 0,
                "route must avoid hive proximity and spring-expanded bee targeting before release or attack")
            Navigation.Cancel(player, state)
            state, s.x = {}, 6
            status = Navigation.Step(player, s, state, { id = "escape_" .. prefab, x = 30, z = 0 })
            assert(status == "pending" and #actions == 1 and actions[1].x == 30,
                "escaping the bee danger area must remain possible")
            Navigation.Cancel(player, state)
            actions = {}
        end
    ''')


def check_bee_procurement_preemption(observer_source, navigation_source):
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
            "observed bee danger must preempt active procurement")
        Survival.Report(state, command, "succeeded", "arrived")
        s.x = -30
        command = Survival.Plan(player, s, state)
        assert(command and command.owner == "supplies", "procurement must resume after safe separation")
    ''')


checks = (check_native_bee_visibility, check_proximity_route_avoidance, check_bee_procurement_preemption)
if len(sys.argv) == 3 and sys.argv[1] == "--old":
    with zipfile.ZipFile(sys.argv[2]) as archive:
        observer = archive.read("client/scripts/wilsonexpedition/observer.lua").decode("utf-8-sig")
        navigation = archive.read("client/scripts/wilsonexpedition/navigation.lua").decode("utf-8-sig")
    messages = ("killerbee and wasphive without hostile", "route must avoid hive proximity", "observed bee danger must preempt")
    for check, message in zip(checks, messages):
        try:
            check(observer, navigation)
        except LuaError as error:
            if message not in str(error):
                raise
            print("REPRODUCED", check.__name__)
        else:
            raise AssertionError("Old source unexpectedly passed " + check.__name__)
else:
    observer = (baseline.SCRIPTS / "wilsonexpedition/observer.lua").read_text(encoding="utf-8-sig")
    navigation = (baseline.SCRIPTS / "wilsonexpedition/navigation.lua").read_text(encoding="utf-8-sig")
    for check in checks:
        check(observer, navigation)
        print("PASS", check.__name__)
