"""Check fuel-aware night preparation and starvation-safe scheduling."""
from pathlib import Path
import importlib.util
import sys

CHECKS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("death_checks", CHECKS / "check-death-iteration.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else base.SCRIPTS / "wilsonexpedition/survival.lua"


def fixture():
    lua = base.runtime()
    lua.execute('''
        stub_planners()
        requests = {}
        local supplies = package.loaded["wilsonexpedition/supplies"]
        supplies.PLAN_TIMEOUT = 180
        supplies.Plan = function(_, _, _, request)
            requests[#requests + 1] = request
            return { id = request.id, owner = "supplies", purpose = "request:" .. request.item,
                driver = "navigation" }
        end
        TUNING.TORCH_FUEL, TUNING.TOTAL_DAY_TIME, TUNING.TORCH_RAIN_RATE = 75, 480, 1.5
        function torch(guid, percent, kind)
            local r = item(guid, "torch", kind)
            r.entity.replica.inventoryitem.classified.percentused = { value = function() return percent end }
            return r
        end
        function dusk_snapshot()
            local s = snapshot()
            s.shard_kind, s.phase, s.time = "surface", "dusk", 0.75
            s.time_until_night, s.time_until_day = 60, 120
            s.precipitation_rate, s.light.ambient = 0, 150 / 255
            return s
        end
    ''')
    lua.globals().Survival = lua.execute(SOURCE.read_text(encoding="utf-8"))
    return lua


def check_used_torches_and_night_length():
    lua = fixture()
    lua.execute('''
        local s = dusk_snapshot()
        s.inventory.records = { torch(101, 25), torch(102, 25) }
        s.hunger = 0.2
        local state = {}
        local cmd, reason = Survival.Plan(player, s, state)
        assert(cmd and requests[#requests].item == "torch", "two spent torches must not satisfy the night budget: " .. tostring(reason))
        assert(requests[#requests].count == 3, "only one new torch is needed for this night")
        s.inventory.records[#s.inventory.records + 1] = torch(103, 100)
        cmd, reason = Survival.Plan(player, s, {})
        assert(requests[#requests].item ~= "torch", "sufficient fuel must return to food acquisition")

        s = dusk_snapshot()
        s.time_until_day = 240
        s.inventory.records = { torch(104, 100), torch(105, 100) }
        cmd, reason = Survival.Plan(player, s, {})
        assert(requests[#requests].item == "torch" and requests[#requests].count == 3,
            "long nights require enough fuel even with two full torches")

        s = dusk_snapshot()
        s.precipitation_rate = 1
        s.inventory.records = { torch(106, 100), torch(107, 100) }
        cmd, reason = Survival.Plan(player, s, {})
        assert(requests[#requests].item == "torch" and requests[#requests].count == 3,
            "rain consumption must be included")
    ''')


def check_preemption_and_immediate_food():
    lua = fixture()
    lua.execute('''
        local s = dusk_snapshot()
        s.hunger = 0.2
        s.inventory.records = { torch(111, 15), torch(112, 15) }
        s.time_until_night, s.time_until_day = 300, 360
        local state = {}
        local cmd = Survival.Plan(player, s, state)
        assert(cmd and requests[#requests].item ~= "torch", "early daylight should still seek food")
        s.time_until_night, s.time_until_day = 60, 120
        local nextcmd, reason = Survival.Plan(player, s, state)
        assert(nextcmd and requests[#requests].item == "torch", "food exploration must yield before night: " .. tostring(reason))
        assert(cancelled, "previous supply ownership must be released")

        s.hunger = 0.02
        s.inventory.records[#s.inventory.records + 1] = item(113, "berries")
        cmd, reason = Survival.Plan(player, s, {})
        assert(cmd and cmd.intent and cmd.intent.action == "EAT", "eat a carried starvation snack before preparing fuel")
        s.inventory.records[3] = nil
        local t = s.inventory.records[1]
        s.inventory.records[1] = nil
        s.inventory.records = { t, torch(114, 10) }
        t.kind = "equipment"
        s.equipment.hands = t
        s.phase, s.light.ambient, s.time_until_night, s.time_until_day = "night", 0, 0, 30
        cmd, reason = Survival.Plan(player, s, {})
        assert(cmd and requests[#requests].item == "torch", "replenish while the current torch is still burning")

        s.equipment.hands, t.kind = nil, "inventory"
        cmd, reason = Survival.Plan(player, s, {})
        assert(cmd and cmd.intent and cmd.intent.action == "EQUIP", "equip existing light before gathering")
    ''')


def check_unknown_fuel_and_day_clock():
    lua = fixture()
    lua.execute('''
        local s = dusk_snapshot()
        s.inventory.records = { torch(121, 255), torch(122, 100) }
        s.hunger = 0.2
        local cmd = Survival.Plan(player, s, {})
        assert(requests[#requests].item ~= "torch", "unknown network durability must not fabricate a fuel deficit")
        s.inventory.records = { torch(123, 100), torch(124, 100) }
        s.phase, s.time, s.time_until_night, s.time_until_day = "day", 0.625, 120, 0
        cmd = Survival.Plan(player, s, {})
        assert(requests[#requests].item ~= "torch", "native day countdown zero is not a zero-length night")
        s.time, s.time_until_night = 0.5, 60
        cmd = Survival.Plan(player, s, {})
        assert(requests[#requests].item == "torch" and requests[#requests].count == 3,
            "daytime preparation must account for the upcoming full night")
        s = dusk_snapshot()
        s.inventory.records = { torch(125, 25), torch(126, 25) }
        local lantern = item(127, "lantern")
        s.inventory.records[3] = lantern
        cmd = Survival.Plan(player, s, {})
        assert(requests[#requests].item ~= "torch", "an alternative usable light must not trigger torch overproduction")
    ''')


if __name__ == "__main__":
    for check in (check_used_torches_and_night_length, check_preemption_and_immediate_food,
                  check_unknown_fuel_and_day_clock):
        check()
        print("PASS", check.__name__)
