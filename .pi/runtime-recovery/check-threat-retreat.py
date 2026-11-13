"""Replay visible-threat navigation and retreat decisions without game input."""

import importlib.util
from pathlib import Path
import sys
import zipfile

spec = importlib.util.spec_from_file_location("movement_checks", Path(__file__).with_name("check-move-continuity.py"))
movement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(movement)
from lupa.lua51 import LuaError

SOURCES = {}
if len(sys.argv) == 3 and sys.argv[1] == "--old":
    with zipfile.ZipFile(sys.argv[2]) as archive:
        SOURCES = {name: archive.read("client/scripts/wilsonexpedition/" + name + ".lua").decode("utf-8-sig")
                   for name in ("navigation", "survival")}


def load_module(lua, name):
    if name in SOURCES:
        lua.globals().module_source = SOURCES[name]
        value = lua.execute("return assert(loadstring(module_source))()")
        lua.globals().package.loaded["wilsonexpedition/" + name] = value
        return value
    return lua.eval("require")("wilsonexpedition/" + name)


def navigation_fixture(mode="remote_prediction"):
    lua = movement.fixture(mode, [(30, 0)])
    lua.globals().Navigation = load_module(lua, "navigation")
    return lua


def check_crossing_paths():
    for mode in ("host", "remote_prediction", "remote_no_prediction"):
        for route in ("direct", "search"):
            lua = navigation_fixture(mode)
            lua.globals().route = route
            lua.execute('''
                if route == "direct" then TheWorld.Pathfinder.IsClear = function() return true end end
                threats = { { guid = 51, prefab = "rook", x = 15, z = 0 } }
                for i = 1, 3 do
                    Navigation.Step(player, snapshot_at(), state, goal)
                    clock = clock + 0.266
                end
                assert(dispatches == 0, "must reject the whole segment before native movement")
            ''')


def check_acquisition_distance():
    lua = navigation_fixture()
    lua.execute('''
        TheWorld.Pathfinder.IsClear = function() return true end
        -- Both endpoints are outside melee range, but the route enters native rook acquisition range.
        goal.x = 24
        threats = { { guid = 52, prefab = "rook", x = 12, z = 10 } }
        Navigation.Step(player, snapshot_at(), state, goal)
        assert(dispatches == 0, "must avoid native acquisition radius, not just melee range")
    ''')


def check_escape_direction():
    for direction in (1, -1):
        lua = navigation_fixture()
        lua.globals().direction = direction
        lua.execute('''
            TheWorld.Pathfinder.IsClear = function() return true end
            threats = { { guid = 53, prefab = "rook", x = 2, z = 0 } }
            goal.x = direction * 20
            Navigation.Step(player, snapshot_at(), state, goal)
            if direction > 0 then
                assert(dispatches == 0, "escape must not pass through the threat")
            else
                assert(dispatches == 1, "monotonic retreat must remain possible inside danger radius")
            end
        ''')


def check_threat_moves_into_route():
    lua = navigation_fixture()
    lua.execute('''
        TheWorld.Pathfinder.IsClear = function() return true end
        Navigation.Step(player, snapshot_at(), state, goal)
        assert(dispatches == 1)
        threats = { { guid = 54, prefab = "rook", x = 15, z = 0 } }
        clock = clock + 0.266
        Navigation.Step(player, snapshot_at(), state, goal)
        assert(loco.bufferedaction == nil and not state.nav.action_active,
            "new visible danger must release owned movement immediately")
    ''')


def survival_fixture():
    lua = movement.baseline.runtime()
    lua.execute('''
        stub_planners()
        package.loaded["wilsonexpedition/exploration"].BaseGoal = function() return nil end
        package.loaded["wilsonexpedition/navigation"] = nil
        function Vector3(x, y, z) return { x = x, y = y, z = z } end
        TheWorld.Map.IsOceanAtPoint = function() return false end
        TheWorld.Map.IsPassableAtPoint = function() return true end
        TheWorld.Map.IsPointNearHole = function() return false end
        TheWorld.Pathfinder = { IsClear = function() return true end }
        s, state = snapshot(), {}
        threat = { guid = 55, prefab = "rook", x = 13, z = 0,
            entity = entity(55, "rook", { monster = true }) }
        s.threats = { threat }
    ''')
    lua.globals().Navigation = load_module(lua, "navigation")
    lua.globals().Survival = load_module(lua, "survival")
    return lua


def check_retreat_hysteresis():
    lua = survival_fixture()
    lua.execute('''
        local command = Survival.Plan(player, s, state)
        assert(command and command.purpose == "escape:threat", "must retreat before native acquisition")
        assert(command.goal.x < s.x, "retreat must lead away")
        assert(Survival.Report(state, command, "succeeded", "arrived"))
        threat.x = 16
        command = Survival.Plan(player, s, state)
        assert(command and command.purpose == "escape:threat", "must continue until safe separation")
        assert(Survival.Report(state, command, "succeeded", "arrived"))
        threat.x = 19
        command = Survival.Plan(player, s, state)
        assert(not command or command.purpose ~= "escape:threat", "must release retreat after safe separation")
        assert(state.survival.retreat_guid == nil)
    ''')
    lua = survival_fixture()
    lua.execute('''
        local command = Survival.Plan(player, s, state)
        assert(command and command.purpose == "escape:threat")
        assert(Survival.Report(state, command, "succeeded", "arrived"))
        s.session, threat.x = "new_world", 16
        command = Survival.Plan(player, s, state)
        assert(not command or command.purpose ~= "escape:threat", "world changes must clear retreat context")
    ''')


def check_each_visible_threat():
    lua = survival_fixture()
    lua.execute('''
        s.threats[2] = { guid = 56, prefab = "frog", x = 0, z = 6.5,
            entity = entity(56, "frog") }
        local command = Survival.Plan(player, s, state)
        assert(command and command.purpose == "escape:threat",
            "a nearer low-risk threat must not hide rook acquisition risk")
    ''')


checks = (check_crossing_paths, check_acquisition_distance, check_escape_direction,
          check_threat_moves_into_route, check_retreat_hysteresis, check_each_visible_threat)
expected_errors = {
    "check_crossing_paths": "must reject the whole segment before native movement",
    "check_acquisition_distance": "must avoid native acquisition radius, not just melee range",
    "check_escape_direction": "escape must not pass through the threat",
    "check_threat_moves_into_route": "new visible danger must release owned movement immediately",
    "check_retreat_hysteresis": "must retreat before native acquisition",
    "check_each_visible_threat": "a nearer low-risk threat must not hide rook acquisition risk",
}
for check in checks:
    if SOURCES:
        try:
            check()
        except LuaError as error:
            if expected_errors[check.__name__] not in str(error):
                raise
            print("REPRODUCED", check.__name__, str(error).splitlines()[0])
        else:
            raise AssertionError("Old source unexpectedly passed " + check.__name__)
    else:
        check()
        print("PASS", check.__name__)
