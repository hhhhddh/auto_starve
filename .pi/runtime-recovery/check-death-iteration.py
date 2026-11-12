"""Offline regression checks for the first WilsonExpedition death iteration."""

import json
from pathlib import Path
import re
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[2]
SUPPORT = PROJECT / "development-support/nbot-relay"
sys.path.insert(0, str(SUPPORT))
from project_paths import game_dir, native_scripts
GAME = game_dir()
NATIVE_SCRIPTS = native_scripts()
SCRIPTS = PROJECT / "mods/WilsonExpedition/scripts"
from lupa.lua51 import LuaRuntime


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().MOD_SCRIPTS = str(SCRIPTS)
    lua.execute('package.path = MOD_SCRIPTS .. "/?.lua;" .. package.path')
    lua.execute('''
        clock = 100
        function GetTime() return clock end
        TUNING = {}
        EQUIPSLOTS = { HANDS = "hands", HEAD = "head", BODY = "body" }
        TheWorld = { GUID = 1, Map = {} }
        function entity(guid, prefab, tags)
            local inst = { GUID = guid, prefab = prefab, tags = tags or {}, components = {}, replica = {} }
            function inst:IsValid() return true end
            function inst:IsInLimbo() return false end
            function inst:HasTag(tag) return self.tags[tag] == true end
            function inst:IsVisible() return true end
            function inst:GetBufferedAction() return self.bufferedaction end
            inst.Transform = { GetWorldPosition = function() return 0, 0, 0 end }
            return inst
        end
        player = entity(10, "wilson")
        player.userid = "test_user"
        ThePlayer = player
        function item(guid, prefab, kind, count, tags)
            local inst = entity(guid, prefab, tags)
            inst.replica.inventoryitem = {
                IsGrandOwner = function(_, owner) return owner == player end,
                classified = { perish = { value = function() return 62 end } },
            }
            inst.replica.stackable = { StackSize = function() return count or 1 end }
            return { guid = guid, prefab = prefab, entity = inst, item = inst,
                kind = kind or "inventory", count = count or 1, slot = guid }
        end
        function snapshot()
            return { ready = true, prefab = "wilson", ghost = false, x = 0, z = 0, cycles = 0, phase = "day", time = 0.3,
                session = "test_world", shard = "surface", season = "autumn", health = 1,
                hunger = 1, sanity = 1, temperature = 25, moisture = 0,
                equipment = {}, nearby = {}, threats = {},
                inventory = { settled = true, records = {} },
                light = { available = true, dark = false, in_light = true, level = 1 } }
        end
        function stub_planners()
            calls = {}
            package.loaded["wilsonexpedition/observer"] = {}
            package.loaded["wilsonexpedition/navigation"] = { OWNER = "navigation", Cancel = function() end }
            package.loaded["wilsonexpedition/sailing"] = {}
            package.loaded["wilsonexpedition/exploration"] = {
                OWNER = "exploration", Cancel = function() end,
                Plan = function() return { id = "explore", purpose = "explore", owner = "exploration" } end,
            }
            package.loaded["wilsonexpedition/supplies"] = {
                OWNER = "supplies", LIGHT_ITEMS = { torch = true },
                Plan = function(_, _, _, request)
                    calls[#calls + 1] = request.item
                    return { id = request.id, owner = "supplies", purpose = "request:" .. request.item,
                        driver = "navigation" }
                end,
                Report = function(_, _, status, reason)
                    cancelled, released_reason = status == "failed", reason
                    return true
                end,
            }
        end
    ''')
    return lua


def native_method(lua, file, owner, name):
    source = (NATIVE_SCRIPTS / file).read_text(encoding="utf-8")
    pattern = rf"^function {owner}:{name}\([^\n]*\).*?^end[ \t]*$"
    match = re.search(pattern, source, re.M | re.S)
    if match is None:
        raise AssertionError(f"Native method not found: {owner}:{name}")
    lua.execute(match.group(0))


def check_inventory():
    lua = runtime()
    lua.execute('''
        PlayerController, PlayerActionPicker = {}, {}
        CONTROL_FORCE_STACK, CONTROL_FORCE_TRADE = 1, 2
        ACTIONS = {}
        for i, name in ipairs({ "EQUIP", "UNEQUIP", "EAT", "HEAL", "LOOKAT", "DROP", "WALKTO" }) do
            ACTIONS[name] = { id = name, code = i }
        end
        RPC = { ControllerUseItemOnSelfFromInvTile = 100 }
        equips, items, sent = {}, {}, 0
        pc = setmetatable({ inst = player, handler = {}, deploy_mode = true }, { __index = PlayerController })
        function pc:IsControlPressed() return false end
        function pc:IsEnabled() return true end
        function pc:IsBusy() return false end
        function pc:CanLocomote() return true end
        picker = setmetatable({ inst = player }, { __index = PlayerActionPicker })
        function picker:SortActionList(actions, target, useitem)
            local result = {}
            for _, action in ipairs(actions) do
                result[#result + 1] = { doer = player, action = action, invobject = useitem, options = {} }
            end
            return result
        end
        player.components.playercontroller = pc
        player.components.playeractionpicker = picker
        player.replica.inventory = {
            GetItems = function() return items end, GetEquips = function() return equips end,
            GetNumSlots = function() return 15 end, GetActiveItem = function() return nil end,
        }
        torch = item(1, "torch").entity
        torch.replica.equippable = { IsEquipped = function() return equips.hands == torch end }
        function torch:CollectActions(_, _, actions)
            actions[1] = equips.hands == self and ACTIONS.UNEQUIP or ACTIONS.EQUIP
        end
        items[1] = torch
        function apply(action, object)
            sent = sent + 1
            if action == ACTIONS.EQUIP.code then equips.hands = object
            elseif action == ACTIONS.UNEQUIP.code then equips.hands = nil end
        end
        function SendRPCToServer(_, code, object) apply(code, object) end
    ''')
    native_method(lua, "components/playercontroller.lua", "PlayerController", "GetItemSelfAction")
    native_method(lua, "components/playercontroller.lua", "PlayerController", "RemoteControllerUseItemOnSelfFromInvTile")
    native_method(lua, "components/playeractionpicker.lua", "PlayerActionPicker", "GetInventoryActions")
    lua.execute('''
        local Actions = require("wilsonexpedition/actions")
        assert(pc:GetItemSelfAction(torch) == nil, "fixture must reproduce keyboard deploy-mode refusal")
        for _, mode in ipairs({ "remote_no_prediction", "remote_prediction", "host" }) do
            Actions.Cancel(player)
            equips.hands, player.bufferedaction = nil, nil
            pc.ismastersim = mode == "host"
            pc.locomotor = mode == "remote_prediction" and {
                PreviewAction = function(_, action) action.preview_cb() end,
            } or nil
            player.components.inventory = mode == "host" and {} or nil
            player.components.locomotor = mode == "host" and {
                PushAction = function(_, action) apply(action.action.code, action.invobject) end,
            } or nil
            local count = sent
            local equip = { kind = "inventory", action = "EQUIP", item = torch, id = mode }
            assert(Actions.Step(player, equip) == "pending", mode .. " must dispatch")
            assert(Actions.Step(player, equip) == "succeeded", mode .. " must confirm equipped entity")
            assert(sent == count + 1, "polling must not resend")
            local unequip = { kind = "inventory", action = "UNEQUIP", item = torch, id = mode .. "-off" }
            assert(Actions.Step(player, unequip) == "pending")
            assert(Actions.Step(player, unequip) == "succeeded")
        end
        Actions.Cancel(player)
        local count = sent
        local status, reason = Actions.Step(player, { kind = "inventory", action = "EAT", item = torch, id = "wrong" })
        assert(status == "failed" and reason:find("action_mismatch", 1, true), reason)
        assert(sent == count, "must not send a different native action")
    ''')


def check_survival():
    lua = runtime()
    lua.execute('''
        stub_planners()
        local Survival = require("wilsonexpedition/survival")
        local s, state = snapshot(), {}
        s.phase, s.time = "night", 0.95
        local fire = { entity = entity(20, "campfire", { fire = true, cooker = true }),
            prefab = "campfire", guid = 20, x = 0, z = 0, distance = 0 }
        s.nearby = { fire }
        local command, reason = Survival.Plan(player, s, state)
        assert(command == nil and reason:find("light_shelter", 1, true), tostring(reason))
        assert(#calls == 0, "static illumination must not authorize night procurement")
        fire.x, fire.distance = 8, 8
        command = Survival.Plan(player, s, state)
        assert(command and command.purpose == "light:seek_fire" and command.goal.x == 8)
        fire.x, fire.distance = 0, 0
        Survival.Report(state, command, "succeeded", "arrived")
        s.inventory.records = { item(2, "torch") }
        command = Survival.Plan(player, s, state)
        assert(command and command.intent.action == "EQUIP", "must equip available torch at night")
        Survival.Cancel(state)
        s.inventory.records = { item(3, "carrot", "inventory", 2) }
        s.hunger = 0.2
        command = Survival.Plan(player, s, state)
        assert(command and command.intent.action == "EAT", "shelter must allow eating")
        Survival.Cancel(state)
        s.phase, s.time, s.hunger, s.nearby, s.inventory.records = "day", 0.3, 1, {}, {}
        state = {}
        command = Survival.Plan(player, s, state)
        assert(command and state.survival.active, "fixture must start daytime procurement")
        s.phase, s.time, s.nearby = "night", 0.95, { fire }
        command, reason = Survival.Plan(player, s, state)
        assert(command == nil and cancelled and not state.survival.active
            and released_reason == "preempted_for_replan", "night shelter must release procurement before replanning")
        assert(reason:find("light_shelter", 1, true), tostring(reason))
        state = {}
        s.phase, s.time, s.hunger, s.nearby = "day", 0.3, 1, {}
        s.inventory.records = { item(4, "carrot", "inventory", 2) }
        Survival.Plan(player, s, state)
        for _, request in ipairs(calls) do assert(request ~= "carrot_cooked", "safe raw food must not trigger cooking") end
    ''')


def check_light_observation():
    lua = runtime()
    lua.execute('''
        self = {}
        PHASE_NAMES = { "day", "dusk", "night" }
        phase_index, remaining = 2, 12
        _phase = { value = function() return phase_index end }
        _remainingtimeinphase = { value = function() return remaining end }
        _segs = { { value = function() return 10 end }, { value = function() return 4 end },
            { value = function() return 2 end } }
        TUNING.SEG_TIME = 30
    ''')
    native_method(lua, "components/clock.lua", "self", "GetTimeUntilPhase")
    lua.execute('''
        TheWorld.net = { components = { clock = self } }
        TheWorld.state = { cycles = 0, phase = "dusk", time = 0.8, timeinphase = 0.9 }
        function TheWorld:HasTag(tag) return tag == "forest" end
        TheSim = {
            GetLightAtPoint = function() return 1 end,
            GetAmbientColour = function() return 150, 150, 150 end,
            FindEntities = function() return {} end,
        }
        local Observer = require("wilsonexpedition/observer")
        local s = Observer.Observe(player, {})
        assert(s.time_until_night == 12, "must observe the native phase countdown")
        assert(math.abs(s.light.ambient - 150 / 255) < 0.00001, "ambient must exclude portable lights")
        phase_index, remaining = 1, 10
        s = Observer.Observe(player, {})
        assert(s.time_until_night == 130, "native clock must include remaining dusk segments")
        TheSim.GetAmbientColour = function() return 0, 0, 0 end
        s = Observer.Observe(player, {})
        assert(s.light.ambient == 0 and s.light.dark == false, "own light must not masquerade as ambient light")
        TheSim.GetAmbientColour = nil
        s = Observer.Observe(player, {})
        assert(s.light.ambient == nil, "unavailable ambient observation must stay unknown")
        TheWorld.net = nil
        s = Observer.Observe(player, {})
        assert(s.time_until_night == nil, "world network must exist before reading its clock")
    ''')


def check_light_economy():
    lua = runtime()
    lua.execute('''
        stub_planners()
        local Survival = require("wilsonexpedition/survival")
        local s = snapshot()
        local torch = item(40, "torch", "equipment")
        local spare = item(41, "torch")
        s.shard_kind = "surface"
        s.phase, s.time_in_phase, s.time_until_night = "dusk", 0.8, 24
        s.light.ambient = 150 / 255
        s.equipment.hands = torch
        s.inventory.records = { torch, spare }
        local command, reason = Survival.Plan(player, s, {})
        assert(command and command.intent and command.intent.action == "UNEQUIP",
            "safe dusk must stow an equipped light: " .. tostring(reason))
        assert(command.intent.item == torch.entity and command.priority == Survival.PRIORITY_LIGHT)

        -- [喵喵喵]: 备用光源先存包里，只在临近入夜时预先装备。
        s.equipment.hands, torch.kind = nil, "inventory"
        command, reason = Survival.Plan(player, s, {})
        assert(not command or not command.intent or command.intent.action ~= "EQUIP",
            "dusk progress alone must not ignite a torch")
        s.time_until_night = 4
        command = Survival.Plan(player, s, {})
        assert(command and command.intent and command.intent.action == "EQUIP",
            "must leave time to equip before night")
        s.phase, s.time_until_night, s.light.dark = "day", 100, true
        command = Survival.Plan(player, s, {})
        assert(command and command.intent and command.intent.action == "EQUIP", "actual darkness always wins")

        -- [喵喵喵]: 原版制作会自动上手，普通采购未结束时也必须能收灯。
        s.light.dark, s.phase, s.time_until_night = false, "day", 100
        local state = {}
        command = Survival.Plan(player, s, state)
        assert(command and command.owner == "supplies", "fixture must hold a procurement command")
        s.equipment.hands, torch.kind = torch, "equipment"
        command = Survival.Plan(player, s, state)
        assert(command and command.intent and command.intent.action == "UNEQUIP" and cancelled,
            "stowing must preempt procurement instead of waiting for it to finish")

        for _, environment in ipairs({ "night", "cave", "ambient_dark", "ambient_unknown", "light_unknown", "imminent" }) do
            s.phase, s.shard_kind, s.time_until_night = "dusk", "surface", 24
            s.light.ambient, s.light.dark = 150 / 255, false
            if environment == "night" then s.phase = "night"
            elseif environment == "cave" then s.shard_kind = "cave"
            elseif environment == "ambient_dark" then s.light.ambient = 0
            elseif environment == "ambient_unknown" then s.light.ambient = nil
            elseif environment == "light_unknown" then s.light.dark = nil
            else s.time_until_night = 4 end
            command, reason = Survival.Plan(player, s, {})
            assert(not command or not command.intent or command.intent.action ~= "UNEQUIP",
                "must retain illumination when unsafe or unknown: " .. environment)
        end
        s.phase, s.shard_kind, s.time_until_night, s.light.ambient = "day", "surface", 100, 1
        s.light.dark, s.equipment.hands = false, nil
        local hat = item(42, "minerhat", "equipment")
        s.equipment.head, s.inventory.records = hat, { hat, spare }
        command = Survival.Plan(player, s, {})
        assert(command and command.intent and command.intent.action == "UNEQUIP" and command.intent.item == hat.entity,
            "daylight must also conserve equipped head lights")
    ''')


def check_cooking():
    lua = runtime()
    lua.execute('''
        stub_planners()
        package.loaded["wilsonexpedition/supplies"] = nil
        local Supplies = require("wilsonexpedition/supplies")
        player.replica.inventory = { GetItems = function() return {} end, GetNumSlots = function() return 15 end }
        player.replica.builder = {}
        AllRecipes = { campfire = { name = "campfire", ingredients = { { type = "cutgrass", amount = 3 } } } }
        local s = snapshot()
        s.inventory.records = { item(5, "carrot", "inventory", 2, { cookable = true }) }
        local command, reason = Supplies.Plan(player, s, {}, { item = "carrot_cooked", count = 1 })
        assert(command == nil and reason == "need_fire:carrot_cooked", tostring(reason))
        TheWorld.Map.IsPassableAtPoint = function() return true end
        s.nearby = { { prefab = "campfire", guid = 25, x = 0, z = 0, distance = 0,
            entity = entity(25, "campfire", { cooker = true, fire = true }) } }
        command, reason = Supplies.Plan(player, s, {}, { item = "carrot_cooked", count = 1 })
        assert(command and command.intent.action == "COOK", tostring(reason))
    ''')


def table_value(value):
    if not hasattr(value, "items"):
        return value
    pairs = dict(value.items())
    if pairs and set(pairs) == set(range(1, len(pairs) + 1)):
        return [table_value(pairs[index]) for index in range(1, len(pairs) + 1)]
    return {key: table_value(item) for key, item in pairs.items()}


def check_trace():
    lua = runtime()
    lua.globals().JSON_ENCODE = lambda value: json.dumps(table_value(value), ensure_ascii=False)
    messages = []
    lua.globals().print = messages.append
    lua.execute('''
        package.preload["json"] = function() return { encode = JSON_ENCODE } end
        TheSim = { SetPersistentString = function(_, key, text, encoded, done)
            saved_key, saved_text = key, text
            assert(encoded == false)
            done(true)
        end }
        local Trace = require("wilsonexpedition/trace")
        local rt = { player = player, snapshot = snapshot(), trace = {}, mode = "failed", record = { id = "test_challenge" } }
        for i = 1, 240 do rt.trace[i] = { tick = i, reason = string.rep("evidence ", 24) } end
        Trace.Seal(rt, "test")
        Trace.Seal(rt, "test_again")
        assert(#rt.trace == 240)
    ''')
    assert len(messages) == 1 and len(messages[0].encode()) < 4095
    full = json.loads(lua.globals().saved_text)
    notice = json.loads(messages[0].split("[WilsonExpedition] ", 1)[1])
    assert len(lua.globals().saved_text.encode()) > 4095 and len(full["trace"]) == 240
    assert notice["event"] == "death_bundle" and notice["detail"] == lua.globals().saved_key
    assert full["trace"][-1]["phase"] == "day" and full["trace"][-1]["light"]["level"] == 1


def check_collector():
    sys.path.insert(0, str(SUPPORT))
    import death_watch
    diagnosis = death_watch.classify({"trace": [{"reason": "explore_blocked:dark_no_light"}]},
                                     [{"event": "attacked", "detail": {"damage": 100}}])
    assert [row["kind"] for row in diagnosis["hypotheses"]] == ["darkness"]
    assert diagnosis["causalityConfirmed"] is False
    diagnosis = death_watch.classify({"trace": []},
                                     [{"event": "attacked", "detail": {"attacker": {"prefab": "hound"}}}])
    assert [row["kind"] for row in diagnosis["hypotheses"]] == ["combat"]
    with tempfile.TemporaryDirectory(prefix="wilson-death-check-", dir=PROJECT / ".pi/runtime-recovery") as temporary:
        root = Path(temporary)
        log = root / "client_log.txt"
        key = "wilsonexpedition_death_test_user_123"
        bundle = {"schema": "wilson-expedition/death-bundle@1", "event": "death_bundle",
                  "userid": "test_user", "challenge": "test_challenge", "session": "test_session", "revision": "test_revision",
                  "trace": [{"reason": "trace " * 200} for _ in range(120)]}
        notice = {**{key: bundle[key] for key in ("userid", "challenge", "session", "revision")},
                  "schema": "wilson-expedition/client-event@1", "event": "death_bundle", "detail": key}
        log.write_text("[WilsonExpedition] " + json.dumps(bundle)[:4095] + "\n[WilsonExpedition] " + json.dumps(notice) + "\n", encoding="utf-8")
        server = root / "server_log.txt"
        server.write_text("[WilsonExpeditionDiagnostics] " + json.dumps({
            **notice, "schema": "wilson-expedition/server-event@1", "event": "death",
        }), encoding="utf-8")
        config = root / "config.json"
        config.write_text(json.dumps({"client_log": str(log), "server_logs": [str(server)]}), encoding="utf-8")
        previous_root, previous_argv = death_watch.ROOT, sys.argv
        death_watch.ROOT = root
        sys.argv = [str(SUPPORT / "death_watch.py"), "--config", str(config)]
        try:
            assert death_watch.main() == 0
            assert not (root / "captures").exists(), "notice before disk write must wait"
            saves = root / "12345/client_save"
            saves.mkdir(parents=True)
            (saves / key).write_bytes(b"KLEI     1 " + json.dumps(bundle).encode())
            assert death_watch.main() == 0
            captures = list((root / "captures").iterdir())
            assert len(captures) == 1
            assert json.loads((captures[0] / "death-bundle.json").read_text(encoding="utf-8")) == bundle
            assert death_watch.main() == 0
            assert len(list((root / "captures").iterdir())) == 1, "must deduplicate after watcher restart"
        finally:
            death_watch.ROOT, sys.argv = previous_root, previous_argv


def check_resource_review():
    lua = runtime()
    lua.execute((NATIVE_SCRIPTS / "json.lua").read_text(encoding="utf-8"))
    lua.execute('''
        local Trace = require("wilsonexpedition/trace")
        fuel = 100
        local torch = item(100, "torch", "equipment", 1)
        torch.entity.replica.inventoryitem.classified.percentused = { value = function() return fuel end }
        local grass = item(101, "cutgrass", "inventory", 2)
        local packed_grass = item(102, "cutgrass", "backpack", 2)
        local carrot = item(103, "carrot", "inventory", 2)
        local stored = item(104, "log", "container", 99)
        local s = snapshot()
        s.shard_kind, s.time_until_night = "surface", 90
        s.phase, s.light.ambient, s.light.threshold = "dusk", 0.5, 0.1
        s.inventory.records, s.equipment.hands = { torch, grass, packed_grass, carrot, stored }, torch
        rt = { player = player, snapshot = s, mode = "running", record = { id = "resource_test" } }
        clock = 0
        Trace.Sample(rt, true)
        fuel, grass.count, carrot.count, clock = 99, 1, 1, 0.5
        Trace.Sample(rt, true)
        fuel, clock = 98, 1
        Trace.Sample(rt, true)
        assert(rt.trace[1].inventory_counts.cutgrass == 4)
        assert(rt.trace[2].inventory_counts.cutgrass == 3)
        assert(rt.trace[1].inventory_counts.log == nil)
        assert(rt.trace[1].equipment_condition.hands.remaining == 1)
        assert(rt.trace[3].equipment_condition.hands.remaining == 0.98)
        assert(rt.last_inventory[4].freshness == 1)
        resource_trace = require("json").encode(rt.trace)
        fuel, clock = 255, 1.5
        carrot.entity.replica.inventoryitem.classified.perish.value = function() return 63 end
        Trace.Sample(rt, true)
        assert(rt.trace[4].equipment_condition.hands.remaining == nil)
        assert(rt.last_inventory[4].freshness == nil)
        clock, s.inventory.settled = 2, false
        Trace.Sample(rt, true)
        assert(rt.trace[5].inventory_counts == nil and rt.trace[5].equipment_condition == nil)
        clock, s.ghost, s.health = 2.5, true, 0
        s.inventory.records, s.equipment = {}, {}
        Trace.Sample(rt, true)
        assert(rt.trace[6].inventory_counts == nil)
        assert(rt.last_equipment.hands == "torch" and rt.last_inventory[1].prefab == "torch")
    ''')
    sys.path.insert(0, str(SUPPORT))
    import death_watch
    trace = json.loads(lua.globals().resource_trace)
    review = death_watch.classify({"trace": trace}, [])["resourceReview"]
    assert review["inventoryDecreases"] == {"cutgrass": 1, "carrot": 1}
    assert review["suspectedWaste"] == [{"kind": "light_in_natural_light", "prefab": "torch",
        "session": "test_world", "shard": "surface",
        "firstTick": 0, "lastTick": 1, "remainingFractionLost": 0.02, "reviewRequired": True}]
    from copy import deepcopy
    migrated = deepcopy(trace)
    for row in migrated:
        row["session"] = "another_surface_session"
    observations = death_watch.resource_review(trace + migrated)["suspectedWaste"]
    assert len(observations) == 2 and all(row["remainingFractionLost"] == 0.02 for row in observations)
    safe_cases = (
        lambda row: row.update(phase="night"),
        lambda row: row.update(shard_kind="cave"),
        lambda row: row["light"].pop("ambient"),
        lambda row: row["light"].update(ambient=0),
        lambda row: row["light"].pop("threshold"),
        lambda row: row.update(temperature=0),
        lambda row: row.update(temperature=70),
        lambda row: row.update(threats=[{"prefab": "hound"}]),
        lambda row: row.update(time_until_night=5),
        lambda row: row.update(mode="paused"),
        lambda row: row.update(ghost=True),
        lambda row: row.update(session="other_world"),
        lambda row: row.update(shard="cave"),
        lambda row: row.update(tick=10),
        lambda row: row.update(tick=0),
        lambda row: row["equipment_condition"]["hands"].update(guid=999),
        lambda row: row["equipment_condition"]["hands"].pop("remaining"),
        lambda row: row["equipment_condition"]["hands"].update(remaining=255),
    )
    for mutate in safe_cases:
        pair = deepcopy(trace[:2])
        mutate(pair[1])
        assert death_watch.resource_review(pair)["suspectedWaste"] == [], repr(pair)
    pair = deepcopy(trace[:2])
    pair[1]["inventory_counts"] = []
    assert death_watch.resource_review(pair)["inventoryDecreases"] == {"torch": 1, "cutgrass": 4, "carrot": 2}
    for field in ("inventory_counts", "equipment_condition"):
        pair = deepcopy(trace[:2])
        for row in pair:
            row.pop(field)
        review = death_watch.resource_review(pair)
        if field == "inventory_counts":
            assert review["inventoryDecreases"] == {}
        else:
            assert review["suspectedWaste"] == []
    legacy = deepcopy(trace)
    for row in legacy:
        row.pop("inventory_counts", None)
        row.pop("equipment_condition", None)
    old = {"schema": "wilson-expedition/death-bundle@1", "trace": legacy}
    unchanged = deepcopy(old)
    assert death_watch.classify(old, [])["resourceReview"]["suspectedWaste"] == []
    assert old == unchanged, "legacy evidence remains unchanged during analysis"
    lua.execute('''
        local Trace = require("wilsonexpedition/trace")
        rt.snapshot, rt.trace, rt.mode = snapshot(), {}, "running"
        for i = 1, 30 do
            local record = item(1000 + i, "resource_prefab_with_long_name_" .. i, "inventory", 40)
            rt.snapshot.inventory.records[i] = record
        end
        for i = 1, 240 do clock = 100 + i * 0.5; Trace.Sample(rt, true) end
        TheSim = { SetPersistentString = function(_, key, text, encoded, done)
            resource_bundle = text
            done(true)
        end }
        Trace.Seal(rt, "test_resource_capture")
    ''')
    bundle = lua.globals().resource_bundle
    assert len(bundle.encode("utf-8")) < 1024 * 1024
    assert len(json.loads(bundle)["trace"]) == 240


if __name__ == "__main__":
    for check in (check_inventory, check_survival, check_light_observation, check_light_economy,
                  check_cooking, check_trace, check_collector, check_resource_review):
        check()
        print("PASS", check.__name__)
