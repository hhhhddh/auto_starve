"""Regress starvation food acquisition and priority changes with client snapshots."""
from pathlib import Path
import importlib.util
import sys

CHECKS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fuel_checks", CHECKS / "check-light-budget.py")
fuel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fuel)
fuel.SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else fuel.base.SCRIPTS / "wilsonexpedition/survival.lua"


def fixture():
    lua = fuel.fixture()
    lua.execute('''
        function food_snapshot(hunger)
            local s = dusk_snapshot()
            s.time_until_night, s.time_until_day = 300, 360
            s.hunger, s.health = hunger, 0.7
            s.inventory.records = { torch(801, 100), torch(802, 100) }
            return s
        end
        function source(guid, prefab, tags)
            local e = { GUID = guid, IsValid = function() return true end,
                HasTag = function(_, tag) return tags[tag] == true end }
            return { entity = e, guid = guid, prefab = prefab, x = 4, z = 0, distance = 4 }
        end
    ''')
    return lua


def check_food_before_equipment_dependencies():
    lua = fixture()
    lua.execute('''
        for _, hunger in ipairs({ 0.2, 0 }) do
            local s = food_snapshot(hunger)
            s.nearby = { source(810, "cactus", { pickable = true }),
                source(811, "rabbithole", {}) }
            local cmd, why = Survival.Plan(player, s, {})
            assert(cmd and requests[#requests].item == "berries",
                "no raw ingredients: do not start armor or trap prerequisites for a cooked meal: " .. tostring(why))

            s.shard_kind = "cave"
            s.equipment[EQUIPSLOTS.HANDS] = s.inventory.records[1]
            s.nearby[3] = source(812, "cave_banana_tree", { pickable = true })
            cmd, why = Survival.Plan(player, s, {})
            assert(cmd and requests[#requests].item == "cave_banana",
                "an edible raw banana should not require cooking: " .. tostring(why))
        end
    ''')


def check_cooking_existing_raw_and_fire():
    lua = fixture()
    lua.execute('''
        local s = food_snapshot(0)
        s.inventory.records[3] = item(820, "cactus_meat")
        local cmd, why = Survival.Plan(player, s, {})
        assert(cmd and requests[#requests].item == "berries",
            "starving without a cooker must seek direct food instead of fuel: " .. tostring(why))
        s.nearby[1] = source(821, "campfire", { cooker = true, fire = true })
        cmd, why = Survival.Plan(player, s, {})
        assert(cmd and requests[#requests].item == "cactus_meat_cooked",
            "owned cactus meat can be cooked on an existing fire: " .. tostring(why))
        s.inventory.records[3] = item(822, "smallmeat")
        cmd, why = Survival.Plan(player, s, {})
        assert(cmd and requests[#requests].item == "cookedsmallmeat",
            "owned small meat can use the same native cooking chain: " .. tostring(why))
    ''')


def check_starvation_over_future_light_reserve():
    lua = fixture()
    lua.execute('''
        local s = food_snapshot(0)
        s.inventory.records = { torch(830, 15), torch(831, 15) }
        s.time_until_night, s.time_until_day = 60, 120
        local cmd, why = Survival.Plan(player, s, {})
        assert(cmd and requests[#requests].item == "berries",
            "immediate starvation must outrank future fuel stock: " .. tostring(why))
        s.hunger = 0.2
        cmd, why = Survival.Plan(player, s, {})
        assert(cmd and requests[#requests].item == "torch",
            "ordinary food exploration must still yield to preparing for night: " .. tostring(why))
        s.hunger, s.phase, s.time_until_night, s.time_until_day = 0, "night", 0, 60
        s.light.ambient, s.light.level, s.light.dark = 0, 0, true
        cmd, why = Survival.Plan(player, s, {})
        assert(cmd and cmd.intent and cmd.intent.action == "EQUIP",
            "actual darkness must retain immediate illumination priority: " .. tostring(why))
    ''')


def check_inflight_priority_and_immediate_meal():
    lua = fixture()
    lua.execute('''
        local s = food_snapshot(0.2)
        s.inventory.records = { torch(840, 15), torch(841, 15) }
        local state = {}
        local cmd = Survival.Plan(player, s, state)
        assert(cmd and requests[#requests].item == "berries", "start ordinary food collection")
        local first = cmd.id
        s.hunger, s.time_until_night, s.time_until_day = 0, 60, 120
        local nextcmd, why = Survival.Plan(player, s, state)
        assert(nextcmd == nil and not cancelled,
            "same food task must rise in priority without cancellation or new fuel collection: " .. tostring(why))
        assert(requests[#requests].item == "berries", "food collection must retain the execution slot")
        s.inventory.records[3] = item(842, "berries")
        nextcmd, why = Survival.Plan(player, s, state)
        assert(nextcmd and nextcmd.intent and nextcmd.intent.action == "EAT" and cancelled,
            "an acquired meal must interrupt equal-priority procurement: " .. tostring(why))
        assert(nextcmd.id ~= first, "only the actual meal creates a new action")
    ''')


if __name__ == "__main__":
    for check in (check_food_before_equipment_dependencies, check_cooking_existing_raw_and_fire,
                  check_starvation_over_future_light_reserve, check_inflight_priority_and_immediate_meal):
        check()
        print("PASS", check.__name__)
