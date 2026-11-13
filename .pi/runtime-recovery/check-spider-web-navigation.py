"""Verify visible spider-nest avoidance and land navigation out of walkable creep."""
import argparse
import importlib.util
from pathlib import Path
import re
import zipfile

HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


routes = load("web_retreat_checks", "check-retreat-reachability.py")
movement = load("web_movement_checks", "check-move-continuity.py")
fuel = load("web_survival_checks", "check-light-budget.py")
fuel.SOURCE = fuel.base.SCRIPTS / "wilsonexpedition/survival.lua"
BEFORE = None


def navigation(lua):
    if BEFORE:
        with zipfile.ZipFile(BEFORE) as archive:
            names = [n for n in archive.namelist() if n.endswith("scripts/wilsonexpedition/navigation.lua")]
            assert len(names) == 1
            nav = lua.execute(archive.read(names[0]).decode("utf-8-sig"))
    else:
        lua.globals().package.loaded["wilsonexpedition/navigation"] = None
        nav = lua.eval('require("wilsonexpedition/navigation")')
    lua.globals().Nav = nav
    lua.globals().package.loaded["wilsonexpedition/navigation"] = nav
    return lua


def check_nest_coverage():
    native = getattr(routes.base, "NATIVE_SCRIPTS", routes.base.GAME / "data/databundles/scripts")
    text = (native / "tuning.lua").read_text(encoding="utf-8-sig")
    radii = re.search(r"SPIDERDEN_CREEP_RADIUS\s*=\s*\{([^}]+)\}", text)
    assert radii, "Expected the native creep radius table"
    largest = max(float(v) for v in re.findall(r"\d+(?:\.\d+)?", radii.group(1)))
    lua = navigation(fuel.fixture())
    lua.globals().largest_creep = largest
    lua.execute('''
        function Vector3(x,y,z) return {x=x,y=y,z=z} end
        TheWorld.Map.IsPassableAtPoint = function() return true end
        TheWorld.Map.IsPointNearHole = function() return false end
        TheWorld.Pathfinder = { IsClear = function() return true end }
        package.loaded["wilsonexpedition/survival"] = nil
        Survival = require("wilsonexpedition/survival")
        local radius = Nav.THREAT_RADII.spiderden or Nav.THREAT_RADIUS
        assert(radius >= largest_creep + 2, "nest avoidance must cover native web radius and walking margin")
        local s = dusk_snapshot()
        s.x, s.z = 0, 0
        s.hunger = 0.1
        s.inventory.records = { torch(901,100), torch(902,100) }
        s.threats = { {guid=401,prefab="spiderden",x=largest_creep+1,z=0,distance=largest_creep+1} }
        local cmd, reason = Survival.Plan(player, s, {})
        assert(cmd and cmd.purpose == "escape:threat", "visible web edge must preempt procurement: "..tostring(reason))
    ''')
    lua = navigation(movement.fixture())
    lua.globals().largest_creep = largest
    lua.execute('''
        TheWorld.Pathfinder.IsClear = function() return true end
        threats = { {guid=402,prefab="spiderden",x=15,z=largest_creep+0.5} }
        Nav.Step(player, snapshot_at(), state, goal)
        assert(dispatches == 0, "a route may not cross the web margin between clear endpoints")
    ''')


def check_walk_out_of_creep():
    for mode in ("host", "remote_prediction", "remote_no_prediction"):
        lua = navigation(movement.fixture(mode))
        lua.execute('''
            TheWorld.Pathfinder.IsClear = function(_, x0,y0,z0,x1,y1,z1,caps)
                return caps ~= nil and caps.ignorecreep == true
                    and not caps.ignorewalls and not caps.allowocean
            end
            threats = { {guid=403,prefab="spider",x=3,z=0} }
            local s = snapshot_at()
            local retreat, why = Nav.Retreat(player, s, state, 8)
            assert(retreat and retreat.x < 0, "walkable web must not seal a visible safe exit: "..tostring(why))
            local status, reason = Nav.Step(player, s, state, retreat)
            assert(status == "pending" and dispatches == 1, "validated exit must dispatch native walking: "..tostring(reason))
            assert(paths_submitted == 0, "a direct exit must start without waiting for a detour search")
            for frame=1,8 do advance_frame() end
            assert(x < -0.5, "native walking must make progress away from the spider")
            assert(Nav.Cancel(player, state), "cancel must still release owned web escape")
            if MODE ~= "remote_no_prediction" then
                assert(loco.bufferedaction == nil, "owned local escape must be released")
            end        ''')


def check_search_capabilities():
    lua = navigation(movement.fixture())
    lua.execute('''
        local checks, searches = 0, 0
        TheWorld.Pathfinder.IsClear = function(_, x0,y0,z0,x1,y1,z1,caps)
            assert(caps and caps.ignorecreep == true and next(caps) == "ignorecreep"
                and next(caps,"ignorecreep") == nil, "LOS must retain wall and ocean restrictions")
            checks = checks + 1
            return math.abs(x1-x0) < 25
        end
        TheWorld.Pathfinder.SubmitSearch = function(_,x0,y0,z0,x1,y1,z1,caps)
            assert(caps and caps.ignorecreep == true and next(caps) == "ignorecreep"
                and next(caps,"ignorecreep") == nil, "search and direct checks need the same land capabilities")
            searches = searches + 1
            return 9
        end
        Nav.Step(player, snapshot_at(), state, goal)
        clock = clock + 0.266
        Nav.Step(player, snapshot_at(), state, goal)
        assert(checks > 0 and searches == 1 and dispatches == 1, "web-aware search must hand off to native movement")
    ''')


def check_physical_boundaries():
    for scenario in ("wall", "unknown", "query_error", "water", "hole"):
        lua = navigation(routes.retreat_runtime())
        lua.globals().SCENARIO = scenario
        lua.execute('''
            if SCENARIO == "wall" then TheWorld.Pathfinder.IsClear = function() return false end
            elseif SCENARIO == "unknown" then TheWorld.Pathfinder.IsClear = function() return nil end
            elseif SCENARIO == "query_error" then TheWorld.Pathfinder.IsClear = function() error("unavailable") end
            elseif SCENARIO == "water" then TheWorld.Map.IsPassableAtPoint = function() return false end
            elseif SCENARIO == "hole" then TheWorld.Map.IsPointNearHole = function() return true end end
            local goal = Nav.Retreat(player, snap, state, 8)
            assert(goal == nil and action_calls == 0, "creep capability must not bypass a physical or unknown boundary")
        ''')


def main():
    global BEFORE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--old", type=Path)
    BEFORE = parser.parse_args().old
    failures = []
    for check in (check_nest_coverage, check_walk_out_of_creep,
                  check_search_capabilities, check_physical_boundaries):
        try:
            check()
            print("PASS", check.__name__)
        except Exception as exc:
            failures.append(check.__name__)
            print("FAIL", check.__name__, str(exc))
    if failures:
        raise SystemExit("Failed: " + ", ".join(failures))


if __name__ == "__main__":
    main()
