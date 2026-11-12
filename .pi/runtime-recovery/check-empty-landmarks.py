"""Regression checks for empty resource landmarks and procurement progress."""

import importlib.util
from pathlib import Path
import sys
import zipfile

spec = importlib.util.spec_from_file_location("death_checks", Path(__file__).with_name("check-death-iteration.py"))
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)
from lupa.lua51 import LuaError


def fixture(source):
    lua = baseline.runtime()
    lua.execute('''
        function Vector3(x, y, z) return { x = x, y = y, z = z } end
        TheWorld.Map.IsPassableAtPoint = function() return true end
        player.replica.inventory = {
            GetNumSlots = function() return 15 end, GetItems = function() return {} end,
            GetActiveItem = function() return nil end,
        }
        package.loaded["wilsonexpedition/exploration"] = {
            Next = function(_, snapshot)
                return { id = "frontier:" .. tostring(clock), x = snapshot.x + 32, z = snapshot.z }
            end,
            Report = function() return true end,
        }
        s, state = snapshot(), {}
        s.shard_memory = { cats = { resource = {
            { prefab = "grass", x = 8, z = 0 }, { prefab = "grass", x = 20, z = 0 },
        } } }
        request = { item = "cutgrass", count = 2, id = "gather" }
    ''')
    lua.globals().SUPPLIES_SOURCE = source
    lua.execute('Supplies = assert(loadstring(SUPPLIES_SOURCE))()')
    return lua


def check_independent_landmarks(source):
    lua = fixture(source)
    lua.execute('''
        local landmarks, frontiers = 0, 0
        for i = 1, 12 do
            local command, reason = Supplies.Plan(player, s, state, request)
            if command ~= nil then
                if command.landmark_key then landmarks = landmarks + 1
                else frontiers = frontiers + 1 end
                clock = clock + 4
                s.x, s.z = command.goal.x, command.goal.z
                assert(Supplies.Report(state, command, "arrived", "arrived"))
            else
                assert(reason:find("landmark_waiting_observation", 1, true), reason)
                clock = clock + 4
            end
        end
        assert(landmarks <= 2 and frontiers > 0,
            "must retire each empty landmark independently instead of alternating forever")
        assert(state.supplies.fail_total == 0, "empty observations are not rejected native actions")
        -- Visible regrowth must remain usable even when its remembered landmark is stale.
        s.nearby = { { prefab = "grass", guid = 70, entity = entity(70, "grass", { pickable = true }),
            x = s.x, z = s.z, distance = 0 } }
        local command = Supplies.Plan(player, s, state, request)
        assert(command and command.intent and command.intent.action == "PICK", "regrowth must be collectable")
    ''')


def check_visible_empty(source):
    lua = fixture(source)
    lua.execute('''
        local empty = entity(80, "grass")
        s.nearby = { { prefab = "grass", guid = 80, entity = empty, x = 8, z = 0, distance = 8 },
            { prefab = "grass", guid = 81, entity = entity(81, "grass"), x = 20, z = 0, distance = 20 } }
        local command = Supplies.Plan(player, s, state, request)
        assert(command and command.explore_goal,
            "visible depleted plants must be skipped before travelling to their memory")
        assert(Supplies.Report(state, command, "arrived", "arrived"))
        empty.tags.pickable = true
        command = Supplies.Plan(player, s, state, request)
        assert(command and command.target_guid == 80 and command.purpose:find("approach:", 1, true),
            "fresh visible availability must override an older empty observation")
    ''')


def check_progress_budget(source):
    lua = fixture(source)
    lua.execute('''
        local command = assert(Supplies.Plan(player, s, state, request))
        clock = clock + Supplies.PLAN_TIMEOUT + 1
        s.x, s.z = command.goal.x, command.goal.z
        assert(Supplies.Report(state, command, "arrived", "arrived"))
        local next_command, reason = Supplies.Plan(player, s, state, request)
        assert(next_command == nil and reason:find("plan_timeout", 1, true),
            "arrival without resources must not renew the procurement deadline")
    ''')
    lua = fixture(source)
    lua.execute('''
        s.nearby = { { prefab = "grass", guid = 90, entity = entity(90, "grass", { pickable = true }),
            x = 0, z = 0, distance = 0 } }
        local command = assert(Supplies.Plan(player, s, state, request))
        assert(command.intent.action == "PICK")
        clock = clock + Supplies.PLAN_TIMEOUT - 10
        assert(Supplies.Report(state, command, "succeeded", "caller_confirmed"))
        s.inventory.records, s.nearby = { item(91, "cutgrass") }, {}
        clock = clock + 100
        local next_command, reason = Supplies.Plan(player, s, state, request)
        assert(next_command ~= nil, "confirmed acquisition must renew the budget: " .. tostring(reason))
        assert(Supplies.Report(state, next_command, "failed", "preempted_for_replan"))
        local replacement = Supplies.Plan(player, s, state, { item = "twigs", count = 1, id = "urgent" })
        assert(replacement ~= nil, "preemption must release the shared procurement slot")
    ''')


checks = (check_independent_landmarks, check_visible_empty, check_progress_budget)
if len(sys.argv) == 3 and sys.argv[1] == "--old":
    with zipfile.ZipFile(sys.argv[2]) as archive:
        source = archive.read("client/scripts/wilsonexpedition/supplies.lua").decode("utf-8-sig")
    expected = ("must retire each empty landmark", "visible depleted plants must be skipped", "arrival without resources must not renew")
    for check, message in zip(checks, expected):
        try:
            check(source)
        except LuaError as error:
            if message not in str(error):
                raise
            print("REPRODUCED", check.__name__)
        else:
            raise AssertionError("Old source unexpectedly passed " + check.__name__)
else:
    source = (baseline.SCRIPTS / "wilsonexpedition/supplies.lua").read_text(encoding="utf-8-sig")
    for check in checks:
        check(source)
        print("PASS", check.__name__)
