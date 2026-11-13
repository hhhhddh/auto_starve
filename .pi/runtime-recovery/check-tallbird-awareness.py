"""Regressions for visible tallbird avoidance and exploration feedback."""

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
    lua = baseline.runtime()
    native = (baseline.NATIVE_SCRIPTS / "prefabs/tallbird.lua").read_text(encoding="utf-8-sig")
    factory = native.split("local function fn()", 1)[1].split("inst.entity:SetPristine()", 1)[0]
    tags = re.findall(r'inst:AddTag\("([^"]+)"\)', factory)
    assert "tallbird" in tags and "hostile" not in tags
    lua.globals().NATIVE_TAGS = lua.table_from({tag: True for tag in tags})
    lua.globals().OBSERVER_SOURCE = observer_source
    lua.globals().NAVIGATION_SOURCE = navigation_source
    lua.execute('''
        function Vector3(x, y, z) return { x = x, y = y, z = z } end
        TUNING.TALLBIRD_TARGET_DIST, TUNING.TALLBIRD_DEFEND_DIST, TUNING.SPRING_COMBAT_MOD = 8, 12, 1.33
        TheWorld.Map.IsPassableAtPoint = function() return true end
        TheWorld.Map.IsPointNearHole = function() return false end
        TheWorld.Pathfinder = { IsClear = function() return true end }
        TheWorld.state = { phase = "day", time = 0.3, cycles = 2 }
        function TheWorld:HasTag(tag) return tag == "forest" end
        bird = entity(50, "tallbird", NATIVE_TAGS)
        bird.Transform = { GetWorldPosition = function() return 6, 0, 0 end }
        neutral = entity(51, "rabbit", { animal = true })
        neutral.Transform = { GetWorldPosition = function() return 4, 0, 0 end }
        local distant = entity(52, "tallbird", NATIVE_TAGS)
        distant.Transform = { GetWorldPosition = function() return 100, 0, 0 end }
        TheSim = { FindEntities = function() return { bird, neutral, distant, player } end,
            GetLightAtPoint = function() return 1 end,
            GetAmbientColour = function() return 200, 200, 200 end }
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


def check_native_visibility(observer_source, navigation_source):
    lua = fixture(observer_source, navigation_source)
    lua.execute('''
        local s = Observer.Observe(player, {})
        assert(#s.threats == 1 and s.threats[1].prefab == "tallbird",
            "visible tallbird without hostile tag must be a threat")
        assert(s.threats[1].distance == 6 and s.threats[1].entity == bird)
        assert(#s.nearby == 2, "distant entities and the player must not enter nearby threats")
        for _, t in ipairs(s.threats) do assert(t.prefab ~= "rabbit", "neutral animals must remain neutral") end
    ''')


def check_native_avoidance(observer_source, navigation_source):
    lua = fixture(observer_source, navigation_source)
    lua.execute('''
        local s, state = snapshot(), {}
        s.x, s.z = 20, 0
        s.threats = { { prefab = "tallbird", x = 0, z = 0 } }
        local status = Navigation.Step(player, s, state, { id = "toward_nest", x = 16, z = 0 })
        assert(status == "pending" and #actions == 0,
            "approach must avoid the native spring-expanded nesting radius before attack")
        Navigation.Cancel(player, state)
        state, s.x = {}, 6
        status = Navigation.Step(player, s, state, { id = "away_from_nest", x = 25, z = 0 })
        assert(status == "pending" and #actions == 1 and actions[1].x == 25,
            "escape from inside the nesting radius must remain possible")
    ''')


def check_observed_preemption(observer_source, navigation_source):
    lua = fixture(observer_source, navigation_source)
    lua.execute('''
        stub_planners()
        package.loaded["wilsonexpedition/observer"] = Observer
        package.loaded["wilsonexpedition/navigation"] = Navigation
        local Survival = require("wilsonexpedition/survival")
        local s, state = snapshot(), {}
        local command = assert(Survival.Plan(player, s, state))
        assert(command.owner == "supplies", "fixture must start ordinary procurement")
        s.threats = Observer.Observe(player, {}).threats
        command = Survival.Plan(player, s, state)
        assert(command and command.priority == Survival.PRIORITY_ESCAPE and cancelled,
            "observed tallbird must preempt active procurement")
        Survival.Report(state, command, "succeeded", "arrived")
        s.x = 20
        command = Survival.Plan(player, s, state)
        assert(command and command.priority == Survival.PRIORITY_ESCAPE,
            "escape must continue until the existing clearance is reached")
        Survival.Report(state, command, "succeeded", "arrived")
        s.x = 30
        command = Survival.Plan(player, s, state)
        assert(command and command.owner == "supplies",
            "procurement must be allowed after the visible threat is safely separated")
    ''')


def check_exploration_feedback(observer_source, navigation_source):
    lua = fixture(observer_source, navigation_source)
    lua.execute('''
        player.replica.inventory = { GetNumSlots = function() return 15 end,
            GetItems = function() return {} end, GetActiveItem = function() return nil end }
        local Supplies = require("wilsonexpedition/supplies")
        local s, state = snapshot(), {}
        s.session, s.shard, s.shard_memory = "feedback", "Master", { cats = {} }
        local previous
        for i = 1, 10 do
            local cmd = assert(Supplies.Plan(player, s, state, { item = "twigs", count = 2 }))
            assert(cmd.explore_goal and cmd.goal.id ~= previous, "completed goal must advance")
            s.x, s.z = cmd.goal.x - 1.4, cmd.goal.z
            local status, reason = Navigation.Step(player, s, state, cmd.goal)
            assert(status == "succeeded", reason)
            local accepted, detail = Supplies.Report(state, cmd, status, reason)
            assert(accepted and detail:find("explore=true:arrived", 1, true), detail)
            assert(state.explore.current == nil, "terminal report must clear the exploration selection")
            Navigation.Cancel(player, state)
            previous, clock = cmd.goal.id, clock + 0.2
        end
    ''')


checks = (check_native_visibility, check_native_avoidance, check_observed_preemption)
if len(sys.argv) == 3 and sys.argv[1] == "--old":
    with zipfile.ZipFile(sys.argv[2]) as archive:
        observer = archive.read("client/scripts/wilsonexpedition/observer.lua").decode("utf-8-sig")
        navigation = archive.read("client/scripts/wilsonexpedition/navigation.lua").decode("utf-8-sig")
    messages = ("visible tallbird without hostile tag", "approach must avoid the native", "observed tallbird must preempt")
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
    for check in (*checks, check_exploration_feedback):
        check(observer, navigation)
        print("PASS", check.__name__)
