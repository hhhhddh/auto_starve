"""Regressions for remembering actual travel during long procurement runs."""

import importlib.util
from pathlib import Path
import sys
import zipfile

spec = importlib.util.spec_from_file_location("death_checks", Path(__file__).with_name("check-death-iteration.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
from lupa.lua51 import LuaError


def source(name, previous=None):
    path = f"scripts/wilsonexpedition/{name}.lua"
    if previous:
        with zipfile.ZipFile(previous) as archive:
            return archive.read("WilsonExpedition/" + path).decode("utf-8-sig")
    return (base.SCRIPTS.parent / path).read_text(encoding="utf-8-sig")


def fixture(previous=None):
    lua = base.runtime()
    lua.globals().EXPLORATION_SOURCE = source("exploration", previous)
    lua.globals().RUNTIME_SOURCE = source("runtime", previous)
    lua.globals().TRACE_SOURCE = source("trace", previous)
    lua.execute('''
        function Vector3(x, y, z) return { x = x, y = y, z = z } end
        function IsPaused() return false end
        TUNING.TOTAL_DAY_TIME = 480
        TheWorld.Map.IsPassableAtPoint = function() return true end
        TheWorld.Map.IsPointNearHole = function() return false end
        TheWorld.Map.IsOceanAtPoint = function() return false end
        -- [喵喵喵]: 在途命令持续持有执行器时，探索选点不必再次执行。
        TheWorld.Pathfinder = { IsClear = function() return false end }
        package.loaded["wilsonexpedition/navigation"] = { GOAL_RANGE = 1.5,
            Step = function() return "pending", "moving" end, Cancel = function() end }
        package.loaded["wilsonexpedition/observer"] = { Observe = function() return s end }
        package.loaded["wilsonexpedition/actions"] = { Cancel = function() end }
        package.loaded["wilsonexpedition/sailing"] = {}
        package.loaded["wilsonexpedition/trace"] = { Sample = function() end }
        package.loaded["wilsonexpedition/revision"] = "test-revision"
        package.loaded["json"] = { encode = function(value)
            if value.schema == "wilson-expedition/death-bundle@1" then sealed_bundle = value end
            return "{}"
        end }
        Exploration = assert(loadstring(EXPLORATION_SOURCE))()
        package.loaded["wilsonexpedition/exploration"] = Exploration
        local command = { id = "held-move", via = "navigation", owner = "supplies", purpose = "food" }
        package.loaded["wilsonexpedition/survival"] = {
            Plan = function(_, _, state)
                state.survival = { active = command }
                return command
            end,
            Report = function() return true end,
        }
        player.components.playercontroller = { IsEnabled = function() return true end }
        s = snapshot()
        state = {}
        runner = { player = player, loaded = true, mode = "running", memory = {}, state = state,
            record = { failed = false, sessions = {} }, last_save = clock }
        Runtime = assert(loadstring(RUNTIME_SOURCE))()
        function world_record(target)
            return target.explore_memory.worlds[target.explore.world_key]
        end
        function observe(x, z)
            s.x, s.z = x, z
            if Exploration.Observe then
                Exploration.Observe(player, s, state)
            else
                Exploration.Next(player, s, state)
            end
            clock = clock + 0.25
        end
    ''')
    return lua


def check_in_flight_footprints(previous=None):
    lua = fixture(previous)
    lua.execute('''
        Exploration.Next(player, s, state)
        local route = { {4, 0}, {4, 4}, {8, 4}, {12, 4}, {12, 8} }
        for _, p in ipairs(route) do
            s.x, s.z = p[1], p[2]
            Runtime.Tick(runner)
            clock = clock + Runtime.INTERVAL
        end
        local record = world_record(state)
        assert(record.cells["1|0"] and record.cells["1|1"] and record.cells["2|1"],
            "movement owned by another planner must remember actual intermediate footsteps")
        assert(record.cells["2|0"] == nil or record.cells["2|0"].visits == 0,
            "a curved route must not mark an unobserved straight-line shortcut as travelled")
        assert(runner.command.id == "held-move", "remembering movement must not replace its command")
        assert(runner.dirty == true, "travel updates must be included in the next progress save")
        local count = record.cells["3|2"].visits
        for _ = 1, 20 do Runtime.Tick(runner) end
        assert(record.cells["3|2"].visits == count, "stationary polling must not inflate visits")
    ''')


def check_long_coverage(previous=None):
    lua = fixture(previous)
    lua.execute('''
        Exploration.SetBase(state, s, 0, 0)
        for i = 0, 1023 do
            s.x = i * Exploration.GRID
            state.explore.current = { id = "held-local-goal", x = s.x + 8, z = 0, t = clock }
            Exploration.Next(player, s, state)
            clock = clock + 0.25
        end
        local record = world_record(state)
        assert(record.cells["0|0"] and record.cells["511|0"] and record.cells["1023|0"],
            "ordinary long exploration must retain early travel instead of recycling a 256-cell window")
        assert(record.n_cells == 1024, "visited-cell count must agree with retained history")
    ''')


def check_scope_and_boundaries(previous=None):
    lua = fixture(previous)
    lua.execute('''
        observe(0, 0)
        local forest = world_record(state)
        local visits = forest.cells["0|0"].visits
        s.ready = false; observe(4, 0)
        s.ready = true; s.platform = {}; observe(4, 0)
        s.platform = nil; s.ghost = true; observe(4, 0)
        s.ghost = false; s.health = 0; observe(4, 0)
        s.health = 1
        TheWorld.Map.IsPassableAtPoint = function() return false end
        observe(40, 0)
        TheWorld.Map.IsPassableAtPoint = function() return true end
        assert(forest.cells["1|0"] == nil and forest.cells["10|0"] == nil,
            "unready, dead, aboard, and invalid terrain must not create travel history")
        -- [喵喵喵]: 持久数据继续复用既有 explore_memory 结构，运行期实体不进入存档。
        state = { explore_memory = state.explore_memory }
        observe(0, 0)
        assert(world_record(state) == forest and forest.cells["0|0"].visits == visits + 1,
            "restored history must be reused with a fresh runtime")
        s.session, s.shard = "cave-world", "caves"
        observe(4, 0)
        assert(world_record(state) ~= forest and world_record(state).cells["0|0"] == nil,
            "different shard sessions must retain separate travel history")
        for i = 2, Exploration.MAX_CELLS + 20 do observe(i * 4, 0) end
        local record = world_record(state)
        local count = 0
        for _ in pairs(record.cells) do count = count + 1 end
        assert(count == record.n_cells and count == Exploration.MAX_CELLS,
            "expanded coverage must remain bounded and keep its count accurate")
    ''')


def check_trace_context(previous=None):
    lua = fixture(previous)
    lua.execute('''
        observe(0, 0)
        runner.snapshot = s
        s.time_until_day, s.time_until_night, s.precipitation_rate = 45, 0, 0.6
        Trace = assert(loadstring(TRACE_SOURCE))()
        Trace.Sample(runner, true)
        local sample = runner.trace[1]
        assert(sample.time_until_day == 45 and sample.precipitation_rate == 0.6,
            "fuel analysis must retain actual remaining darkness and rain rate")
        assert(sample.explored_cells == world_record(state).n_cells,
            "the trace must expose travel-memory saturation for future waste review")
        TheSim = { SetPersistentString = function(_, _, _, _, callback) callback(true) end }
        Trace.Seal(runner, "test")
        assert(sealed_bundle.mod_version == "0.1.6", "death metadata must match the fixed display version")
        assert(#runner.trace <= 240, "additional context must keep the two-minute trace bounded")
    ''')


def main():
    previous = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    checks = [check_in_flight_footprints, check_long_coverage, check_trace_context]
    if previous is None:
        checks.append(check_scope_and_boundaries)
    failures = 0
    for check in checks:
        try:
            check(previous)
            print("PASS", check.__name__)
        except (AssertionError, LuaError) as exc:
            failures += 1
            print("FAIL", check.__name__, str(exc).splitlines()[0])
    if failures:
        raise SystemExit(1)
    print("Travel memory and trace context regressions passed")


if __name__ == "__main__":
    main()
