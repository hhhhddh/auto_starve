"""Check batched stock replenishment without launching a game."""
from pathlib import Path
import ast
import importlib.util
import sys

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("light_checks", HERE / "check-light-budget.py")
light = importlib.util.module_from_spec(spec)
spec.loader.exec_module(light)
base = light.base
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else base.SCRIPTS / "wilsonexpedition/survival.lua"


def fixture():
    lua = light.fixture()
    lua.globals().Survival = lua.execute(SOURCE.read_text(encoding="utf-8-sig"))
    lua.execute('''
        package.loaded["wilsonexpedition/supplies"].Report = function()
            return true, "terminal:succeeded" end
        package.loaded["wilsonexpedition/navigation"].Retreat = function()
            return nil, "no_confirmed_path" end
        package.loaded["wilsonexpedition/exploration"].Next = function()
            return nil, "no_frontier" end
        function stock_snapshot()
            local s = snapshot()
            s.hunger, s.health, s.sanity = 1, 1, 1
            s.phase, s.shard_kind, s.time = "day", "surface", 0.2
            s.time_until_night, s.time_until_day, s.precipitation_rate = 300, 360, 0
            s.light.ambient = 0.8
            s.inventory.records = { torch(201, 100), torch(202, 100) }
            local values = { {"cutgrass", 20}, {"twigs", 20}, {"flint", 8}, {"log", 12}, {"carrot", 8} }
            for i, pair in ipairs(values) do
                local r = item(202 + i, pair[1], "inventory", pair[2])
                s.inventory.records[#s.inventory.records + 1] = r
            end
            return s
        end
        function owned(s, prefab, count)
            for _, r in ipairs(s.inventory.records) do
                if r.prefab == prefab then r.count = count; return r end
            end
            local r = item(300 + #s.inventory.records, prefab, "inventory", count)
            s.inventory.records[#s.inventory.records + 1] = r
            return r
        end
        function completed(state, command)
            assert(Survival.Report(state, command, "succeeded", "confirmed_inventory_gain"))
        end
        function requested(item, count)
            local r = requests[#requests]
            return r and r.item == item and (count == nil or r.count == count)
        end
    ''')
    return lua


def check_material_batches_and_progress():
    lua = fixture()
    lua.execute('''
        for _, stock in ipairs({ {"cutgrass", 8, 20}, {"twigs", 8, 20}, {"flint", 4, 8}, {"log", 6, 12} }) do
            local s, state = stock_snapshot(), {}
            owned(s, stock[1], stock[2] - 1)
            local command, reason = Survival.Plan(player, s, state)
            assert(command and requested(stock[1], stock[3]),
                "basic stock must refill a batch before ordinary technology: " .. stock[1] .. "|" .. tostring(reason))
        end
        local s, state = stock_snapshot(), {}
        owned(s, "cutgrass", 7)
        local command = assert(Survival.Plan(player, s, state))
        for _, n in ipairs({ 8, 12, 19 }) do
            owned(s, "cutgrass", n)
            completed(state, command)
            command = assert(Survival.Plan(player, s, state))
            assert(requested("cutgrass", 20), "crossing the low mark must not stop an unfinished batch")
        end
        owned(s, "cutgrass", 20)
        completed(state, command)
        command = assert(Survival.Plan(player, s, state))
        assert(not requested("cutgrass"), "completed stock must yield to progression")
        owned(s, "cutgrass", 19)
        completed(state, command)
        command = assert(Survival.Plan(player, s, state))
        assert(not requested("cutgrass"), "spending one item must not start another gathering trip")
        owned(s, "cutgrass", 7)
        command = assert(Survival.Plan(player, s, state))
        assert(requested("cutgrass", 20), "a new low-stock event must start the next batch")
    ''')


def check_food_nutrition_and_hysteresis():
    lua = fixture()
    lua.execute('''
        local function ready_for_stock(s)
            -- [喵喵喵]: 此场景只检查储粮数量；建设优先级由独立推进回归验证。
            s.season = nil
            for _, prefab in ipairs({"axe", "pickaxe", "researchlab", "backpack", "spear", "armorwood"}) do
                owned(s, prefab, 1)
            end
            s.equipment[EQUIPSLOTS.BODY] = owned(s, "backpack", 1)
        end
        local s, state = stock_snapshot(), {}
        ready_for_stock(s)
        owned(s, "carrot", 0)
        owned(s, "berries", 4)
        s.nearby = { { prefab = "carrot_planted", entity = entity(401, "carrot_planted", {pickable=true}),
            guid = 401, distance = 2, x = 2, z = 0 } }
        local cmd = assert(Survival.Plan(player, s, state))
        assert(requested("carrot", 5), "four low-calorie berries need five carrots to complete the nutritional reserve")
        local stale = owned(s, "carrot", 2)
        stale.entity.replica.inventoryitem.classified.perish.value = function() return 6 end
        completed(state, cmd)
        cmd = assert(Survival.Plan(player, s, state))
        assert(requested("carrot", 7), "stale inventory must not satisfy fresh-food stock")

        s, state = stock_snapshot(), {}
        ready_for_stock(s)
        owned(s, "carrot", 3)
        s.nearby = { { prefab = "carrot_planted", entity = entity(402, "carrot_planted", {pickable=true}),
            guid = 402, distance = 2, x = 2, z = 0 } }
        cmd = assert(Survival.Plan(player, s, state))
        assert(requested("carrot", 8), "food needs a bounded batch instead of one extra item")
        for _, n in ipairs({4, 7}) do
            owned(s, "carrot", n)
            completed(state, cmd)
            cmd = assert(Survival.Plan(player, s, state))
            assert(requested("carrot", 8), "food refill must continue above its low mark")
        end
        owned(s, "carrot", 8)
        completed(state, cmd)
        local before = #requests
        cmd = Survival.Plan(player, s, state)
        assert(#requests == before or not requested("carrot"), "full food reserve must end the gathering trip")
        owned(s, "carrot", 7)
        before = #requests
        cmd = Survival.Plan(player, s, state)
        assert(#requests == before or not requested("carrot"), "one meal must not trigger another food stock trip")
    ''')


def check_emergency_preemption_and_capacity():
    lua = fixture()
    lua.execute('''
        local s, state = stock_snapshot(), {}
        owned(s, "cutgrass", 7)
        local command = assert(Survival.Plan(player, s, state))
        assert(requested("cutgrass", 20))
        s.hunger = 0.02
        command = assert(Survival.Plan(player, s, state))
        assert(command.intent and command.intent.action == "EAT", "carried food must interrupt a stock batch")

        s, state = stock_snapshot(), {}
        owned(s, "cutgrass", 7)
        command = assert(Survival.Plan(player, s, state))
        s.phase, s.light.ambient, s.time_until_night = "night", 0, 0
        command = assert(Survival.Plan(player, s, state))
        assert(command.intent and command.intent.action == "EQUIP", "actual darkness must interrupt a stock batch")

        s, state = stock_snapshot(), {}
        owned(s, "cutgrass", 7)
        command = assert(Survival.Plan(player, s, state))
        s.threats = { { prefab="spider", entity=entity(410, "spider", {hostile=true}),
            guid=410, x=2, z=0, distance=2 } }
        command = Survival.Plan(player, s, state)
        assert(command == nil and state.survival.active == nil,
            "threats without a confirmed retreat must stop ordinary stock acquisition")
    ''')
    spec = importlib.util.spec_from_file_location("empty_checks", HERE / "check-empty-landmarks.py")
    empty = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(empty)
    lua = empty.fixture((base.SCRIPTS / "wilsonexpedition/supplies.lua").read_text(encoding="utf-8-sig"))
    lua.execute('''
        request.count = 20
        player.replica.inventory.IsFull = function() return false end
        s.nearby = { { prefab="grass", guid=420, x=0, z=0, distance=0,
            entity=entity(420, "grass", {pickable=true}) } }
        local cmd = assert(Supplies.Plan(player, s, state, request))
        for _, n in ipairs({ 1, 8, 19 }) do
            assert(Supplies.Report(state, cmd, "succeeded", "caller_confirmed"))
            local r = item(421, "cutgrass", "inventory", n)
            s.inventory.records = { r }
            cmd = assert(Supplies.Plan(player, s, state, request))
            assert(cmd.intent and cmd.intent.action == "PICK", "native gathering must continue until batch inventory is confirmed")
        end
        assert(Supplies.Report(state, cmd, "succeeded", "caller_confirmed"))
        s.inventory.records = { item(421, "cutgrass", "inventory", 20) }
        local done, reason = Supplies.Plan(player, s, state, request)
        assert(done == nil and reason:find("satisfied:", 1, true), "the real planner must stop at confirmed target stock")
        state = {}
        request = { item="twigs", count=20, id="full-inventory-batch" }
        player.replica.inventory.IsFull = function() return true end
        local blocked, why = Supplies.Plan(player, s, state, request)
        assert(blocked == nil and why:find("inventory_full:", 1, true), "batch collection must not exceed available capacity")
    ''')


if __name__ == "__main__":
    ast.parse(Path(__file__).read_text(encoding="utf-8"))
    for check in (check_material_batches_and_progress, check_food_nutrition_and_hysteresis,
                  check_emergency_preemption_and_capacity):
        check()
        print("PASS", check.__name__)
