"""Replay encircled retreat geometry and prevent procurement while escape is blocked."""
from pathlib import Path
import importlib.util
import sys
import zipfile

CHECKS = Path(__file__).resolve().parent

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, CHECKS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

routes = load("retreat_checks", "check-retreat-reachability.py")
fuel = load("fuel_checks", "check-light-budget.py")
fuel.SOURCE = fuel.base.SCRIPTS / "wilsonexpedition/survival.lua"
BEFORE_ZIP = sys.argv[1] if len(sys.argv) > 1 else None


def route_fixture():
    lua = routes.retreat_runtime(BEFORE_ZIP)
    lua.execute('''
        Nav = Navigation
        calls = {}
        Actions.Step = function(_, intent)
            calls[#calls + 1] = intent
            return "pending", "moving"
        end
    ''')
    return lua


def survival_fixture():
    lua = fuel.fixture()
    if BEFORE_ZIP:
        with zipfile.ZipFile(BEFORE_ZIP) as archive:
            names = [name for name in archive.namelist()
                     if name.endswith("scripts/wilsonexpedition/survival.lua")]
            assert len(names) == 1
            lua.globals().Survival = lua.execute(archive.read(names[0]).decode("utf-8-sig"),
                                                 name="@archived-survival.lua")
    return lua


def run_scenario(lua, source):
    ok, reason = lua.execute("local ok, why = pcall(function()\n" + source + "\nend); return ok, tostring(why)",
                             name="@swarmed-retreat-regression.lua")
    assert ok, reason


def check_encircled_corridor():
    lua = route_fixture()
    run_scenario(lua, '''
        local scenes = {
            { {0.913, 2.461, "spider"}, {-0.883, -2.489, "spider"},
              {-6.637, 0.206, "spider"}, {-3.689, 7.871, "spider"},
              {-7.309, -11.477, "spiderden"}, {-14.522, 6.277, "otter"},
              {9.361, 14.303, "spiderden"}, {16.962, 10.496, "spider"} },
            { {0.913, 2.461, "spider"}, {-0.883, -2.489, "spider"},
              {-5.291, -1.358, "spider"}, {-4.865, 4.355, "spider"},
              {10.270, 4.784, "spider"}, {-7.309, -11.477, "spiderden"},
              {3.384, -15.157, "spider"}, {9.361, 14.303, "spiderden"} },
        }
        for _, scene in ipairs(scenes) do
            local s, state = snapshot(), {}
            s.threats = {}
            local start_min = math.huge
            for i, v in ipairs(scene) do
                s.threats[i] = { x = v[1], z = v[2], prefab = v[3] }
                start_min = math.min(start_min, v[1]^2 + v[2]^2)
            end
            local goal, why = Nav.Retreat(player, s, state, 8)
            assert(goal, "visible crossfire has a traversable gap: " .. tostring(why))
            for _, t in ipairs(s.threats) do
                local length2 = goal.x^2 + goal.z^2
                local u = math.max(0, math.min(1, (t.x*goal.x+t.z*goal.z)/length2))
                local closest = (t.x-u*goal.x)^2 + (t.z-u*goal.z)^2
                assert(closest + 0.000001 >= start_min,
                    "retreat must not worsen the nearest visible separation")
                if t.x^2 + t.z^2 >= 49 then
                    assert(closest + 0.000001 >= 49, "do not enter a new threat zone")
                end
            end
            calls = {}
            local status, reason = Nav.Step(player, s, state, goal)
            assert(status == "pending" and #calls == 1 and calls[1].kind == "move",
                "selected retreat must pass the same route safety checks: " .. tostring(reason))
        end
    ''')


def check_distant_nest_does_not_forbid_escape():
    lua = route_fixture()
    run_scenario(lua, '''
        TheWorld.Pathfinder.IsClear = function(_, _, _, _, x, _, z)
            return x < -1 and math.abs(z) < 0.01
        end
        local s, state = snapshot(), {}
        s.threats = { {x=3,z=0,prefab="spider"}, {x=-20,z=0,prefab="spiderden"} }
        local goal, why = Nav.Retreat(player, s, state, 8)
        assert(goal and goal.x < -1, "a far nest cannot block the only safe exit: " .. tostring(why))
        assert(goal.x > -13, "retreat must stop before the nest danger zone")
        local status, reason = Nav.Step(player, s, state, goal)
        assert(status == "pending" and #calls == 1, tostring(reason))
    ''')


def check_fully_blocked_routes_remain_rejected():
    lua = route_fixture()
    run_scenario(lua, '''
        local s = snapshot()
        s.threats = { {x=2,z=0,prefab="spider"}, {x=-1,z=math.sqrt(3),prefab="spider"},
            {x=-1,z=-math.sqrt(3),prefab="spider"} }
        local goal = Nav.Retreat(player, s, {}, 8)
        assert(goal == nil and #calls == 0,
            "a fully enclosing contact ring has no route preserving nearest separation")
        TheWorld.Pathfinder.IsClear = function() return false end
        s.threats = { {x=3,z=0,prefab="spider"} }
        assert(Nav.Retreat(player, s, {}, 8) == nil, "physical barriers must remain authoritative")
    ''')


def check_blocked_escape_preempts_procurement():
    lua = survival_fixture()
    run_scenario(lua, '''
        local navigation = package.loaded["wilsonexpedition/navigation"]
        navigation.Retreat = function() return nil, "no_safe_point" end
        local s = dusk_snapshot()
        s.hunger = 0.1
        s.time_until_night, s.time_until_day = 300, 360
        s.inventory.records = { torch(901,100), torch(902,100) }
        local state = {}
        local first = Survival.Plan(player, s, state)
        assert(first and first.owner == "supplies", "start food procurement")
        local n = #requests
        s.threats = { {x=3,z=0,prefab="spider",distance=3} }
        local cmd, reason = Survival.Plan(player, s, state)
        assert(cmd == nil and state.survival.active == nil and cancelled,
            "no escape route must cancel ordinary procurement: " .. tostring(reason))
        assert(#requests == n, "do not replace cancelled procurement while surrounded")
        assert(require("wilsonexpedition/status_text")(reason):find("等待安全退路", 1, true),
            "show the blocked retreat state in Chinese")
        for _ = 1, 4 do
            cmd, reason = Survival.Plan(player, s, state)
            assert(cmd == nil and state.survival.active == nil and #requests == n,
                "blocked escape must retain safety priority on subsequent ticks: " .. tostring(reason))
        end
        s.threats = {}
        cmd, reason = Survival.Plan(player, s, state)
        assert(cmd == nil and state.survival.active == nil and #requests == n,
            "lost visibility must keep procurement stopped during contact grace: " .. tostring(reason))
        clock = clock + 16
        cmd, reason = Survival.Plan(player, s, state)
        assert(cmd and #requests > n, "normal procurement may resume after danger clears: " .. tostring(reason))

        s.threats = { {x=3,z=0,prefab="spider",distance=3} }
        s.phase, s.light.ambient, s.light.level, s.light.dark = "night", 0, 0, true
        s.time_until_night, s.time_until_day = 0, 45
        cmd, reason = Survival.Plan(player, s, {})
        assert(cmd and cmd.intent and cmd.intent.action == "EQUIP",
            "blocked movement must still allow equipping a carried light in darkness: " .. tostring(reason))
    ''')


def check_mixed_threat_clearance():
    lua = route_fixture()
    run_scenario(lua, '''
        local s, state = snapshot(), {}
        s.threats = { {x=3,z=0,prefab="spider"}, {x=-6,z=0,prefab="rook"} }
        local goal, reason = Nav.Retreat(player, s, state, 8)
        assert(goal, "mixed threat ranges still permit a perpendicular exit: " .. tostring(reason))
        local length2 = goal.x^2 + goal.z^2
        for _, t in ipairs(s.threats) do
            local u = math.max(0, math.min(1, (t.x*goal.x+t.z*goal.z)/length2))
            local d2 = (t.x-u*goal.x)^2 + (t.z-u*goal.z)^2
            local radius = Nav.THREAT_RADII[t.prefab] or Nav.THREAT_RADIUS
            assert(d2 + 0.000001 >= 9, "do not reduce absolute nearest separation")
            assert(d2/(radius*radius) + 0.000001 >= 9/49,
                "larger enemies must retain the same relative safety floor")
        end
    ''')


if __name__ == "__main__":
    checks = (check_encircled_corridor, check_distant_nest_does_not_forbid_escape,
              check_fully_blocked_routes_remain_rejected, check_blocked_escape_preempts_procurement,
              check_mixed_threat_clearance)
    failures = []
    for check in checks:
        try:
            check()
            print("PASS", check.__name__)
        except Exception as exc:
            failures.append(check.__name__)
            print("FAIL", check.__name__, str(exc))
    if failures:
        raise SystemExit("Failed: " + ", ".join(failures))
