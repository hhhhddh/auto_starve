"""Offline checks for native held work, cancellation, and ordinary clicks."""

import importlib.util
from pathlib import Path
import re

baseline_path = Path(__file__).with_name("check-death-iteration.py")
spec = importlib.util.spec_from_file_location("death_iteration_checks", baseline_path)
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)


def fixture(mode, action="CHOP"):
    lua = baseline.runtime()
    lua.globals().MODE, lua.globals().WORK_ACTION = mode, action
    lua.execute('''
        function Class(constructor)
            local cls = {}; cls.__index = cls
            return setmetatable(cls, { __call = function(_, ...)
                local inst = setmetatable({}, cls); constructor(inst, ...); return inst
            end })
        end
        function Vector3(x, y, z) return { x = x, y = y, z = z } end
        function CanEntitySeeTarget() return true end
        function SetClientRequestedAction() end
        function ClearClientRequestedAction() end
        function PlayMiningFX() end
        function State(value) return value end
        function TimeEvent(time, fn) return { time = time, fn = fn } end
        function EventHandler(event, fn) return { event = event, fn = fn } end
        FRAMES = 1 / 30
        CONTROL_PRIMARY, CONTROL_SECONDARY, CONTROL_ACTION = 1, 2, 3
        CONTROL_CONTROLLER_ACTION, CONTROL_CONTROLLER_ALTACTION = 4, 5
        RPC = { LeftClick = 1, RightClick = 2, StopControl = 3 }
        PlayerController, EntityScript = {}, {}
        ACTIONS = {}
        for i, name in ipairs({ "CHOP", "MINE", "HAMMER", "PICKUP", "LOOKAT", "WALKTO" }) do
            ACTIONS[name] = { id = name, code = i }
        end
        TheInput = {
            IsControlPressed = function(_, control) return physical_control == control end,
            GetWorldPosition = function() error("must not query desktop cursor") end,
            GetWorldEntityUnderMouse = function() error("must not query desktop cursor") end,
        }
    ''')
    native_root = baseline.NATIVE_SCRIPTS
    lua.execute((native_root / "bufferedaction.lua").read_text(encoding="utf-8"))
    for method in ("IsAnyOfControlsPressed", "RemoteStopControl", "OnRemoteStopControl", "OnRemoteLeftClick", "OnRemoteRightClick"):
        baseline.native_method(lua, "components/playercontroller.lua", "PlayerController", method)
    for method in ("PerformBufferedAction", "ClearBufferedAction", "GetBufferedAction"):
        baseline.native_method(lua, "entityscript.lua", "EntityScript", method)
    source = (native_root / "stategraphs/SGwilson.lua").read_text(encoding="utf-8")
    state = action.lower()
    start = re.search(r'(?m)^[ \t]*State\{[^\n]*\n[ \t]*name = "' + state + '",', source)
    following = re.search(r"(?m)^[ \t]*State\{", source[start.end():])
    block = source[start.start():start.end() + following.start()].strip().rstrip(",")
    lua.execute("NativeWorkState = " + block)
    lua.execute('''
        equipped = item(100, "tool", "equip", 1, { [WORK_ACTION .. "_tool"] = true }).entity
        local tool = equipped
        tool.replica.inventoryitem.IsHeldBy = function() return true end
        function tool:OnUsedAsItem() end
        target = entity(200, "resource", { [WORK_ACTION .. "_workable"] = true })
        target.work_left = 3
        target.components.workable = { CanBeWorked = function() return target.work_left > 0 end }
        function target:IsActionValid(action) return self:HasTag(action.id .. "_workable") end
        other = entity(300, "twigs")
        dispatches, hits, packets, listeners = 0, 0, {}, {}
        worker = MODE == "host" and player or entity(11, "server_wilson")
        for _, inst in ipairs({ player, worker }) do
            for name, fn in pairs(EntityScript) do inst[name] = fn end
            inst.AnimState = { PlayAnimation = function() end }
            inst.SoundEmitter = { PlaySound = function() end }
            inst.sg = { statemem = {}, RemoveStateTag = function() end, HasStateTag = function() return false end }
            function inst:AddTag(tag) self.tags[tag] = true end
            function inst:RemoveTag(tag) self.tags[tag] = nil end
            function inst:FacePoint() end
            function inst:PushBufferedAction(buff) self.bufferedaction = buff end
            function inst:ListenForEvent(event, fn)
                listeners[event] = listeners[event] or {}; listeners[event][fn] = true
            end
            function inst:RemoveEventCallback(event, fn) if listeners[event] then listeners[event][fn] = nil end end
            function inst:PushEvent(event, data)
                for fn in pairs(listeners[event] or {}) do fn(self, data) end
            end
            inst.replica.inventory = {
                GetEquippedItem = function() return equipped end, GetActiveItem = function() return nil end,
            }
            inst.components.combat = { SetTarget = function() end }
        end
        function PlayerController:IsEnabled() return not disabled end
        function PlayerController:IsBusy() return false end
        function PlayerController:UsingMouse() return true end
        function PlayerController:CanLocomote() return not blocked end
        function PlayerController:GetPlatformRelativePosition(x, z) return nil, x, z end
        function PlayerController:EncodeControlMods() return 0 end
        function PlayerController:DecodeControlMods() end
        function PlayerController:ClearControlMods() end
        function PlayerController:DoAction(buff)
            if self == pc then dispatches = dispatches + 1 end
            if self.ismastersim then self.inst.bufferedaction = buff
            elseif self.locomotor then
                self.inst.bufferedaction = buff
                if defer_preview then late_preview = buff.preview_cb else buff.preview_cb() end
            else buff.non_preview_cb() end
        end
        pc = setmetatable({ inst = player, handler = {}, remote_controls = {} }, { __index = PlayerController })
        pc.ismastersim = MODE == "host"
        pc.locomotor = MODE ~= "remote_no_prediction" and { Clear = function(self) self.bufferedaction = nil end } or nil
        serverpc = MODE == "host" and pc or setmetatable({ inst = worker, ismastersim = true,
            remote_controls = {}, locomotor = {} }, { __index = PlayerController })
        player.components.playercontroller = pc
        worker.components.playercontroller = serverpc
        local function picker(inst)
            return {
                DoGetMouseActions = function(_, position, object)
                    assert(object == target or object == other, "must use explicit target")
                    local action = object == target and ACTIONS[WORK_ACTION] or ACTIONS.PICKUP
                    local buff = BufferedAction(inst, object, action, object == target and tool or nil)
                    if action == ACTIONS.HAMMER then return nil, buff end
                    return buff
                end,
                GetDoubleClickActions = function() return {} end,
            }
        end
        player.components.playeractionpicker = picker(player)
        worker.components.playeractionpicker = picker(worker)
        ACTIONS[WORK_ACTION].fn = function(buff)
            hits = hits + 1; target.work_left = target.work_left - 1
            if target.work_left == 0 then
                target.tags[WORK_ACTION .. "_workable"] = nil
                buff.doer:PushEvent("finishedwork", { target = target, action = buff.action })
            end
            return true
        end
        function SendRPCToServer(rpc, ...)
            local args = { ... }; packets[#packets + 1] = { rpc = rpc, args = args }
            if rpc == RPC.LeftClick then
                serverpc:OnRemoteLeftClick(args[1], Vector3(args[2], 0, args[3]), args[4], args[5], args[6], args[7], args[8])
            elseif rpc == RPC.RightClick then
                serverpc:OnRemoteRightClick(args[1], Vector3(args[2], 0, args[3]), args[4], args[5], args[6], args[7], args[8], args[9])
            elseif rpc == RPC.StopControl then serverpc:OnRemoteStopControl(args[1]) end
        end
        function cycle()
            assert(worker.bufferedaction ~= nil, "native state must have queued its next swing")
            worker.sg.statemem = {}
            NativeWorkState.onenter(worker)
            for _, event in ipairs(NativeWorkState.timeline) do event.fn(worker) end
        end
        function stop_count()
            local count = 0
            for _, packet in ipairs(packets) do if packet.rpc == RPC.StopControl then count = count + 1 end end
            return count
        end
        function assert_released()
            assert(pc.remote_controls[CONTROL_PRIMARY] == nil and pc.remote_controls[CONTROL_SECONDARY] == nil)
            assert(serverpc.remote_controls[CONTROL_PRIMARY] == nil and serverpc.remote_controls[CONTROL_SECONDARY] == nil)
            assert(pc.IsAnyOfControlsPressed == PlayerController.IsAnyOfControlsPressed, "host input query must be restored")
            assert(next(listeners.finishedwork or {}) == nil and next(listeners.actionfailed or {}) == nil)
        end
        original_query = pc.IsAnyOfControlsPressed
        intent = { kind = "action", action = WORK_ACTION, target = target, id = "work", right = WORK_ACTION == "HAMMER" }
        Actions = require("wilsonexpedition/actions")
    ''')
    return lua


def check_native_repetition():
    for mode in ("host", "remote_prediction", "remote_no_prediction"):
        for action in ("CHOP", "MINE", "HAMMER"):
            lua = fixture(mode, action)
            lua.execute('''
                assert(Actions.Step(player, intent) == "pending")
                if MODE ~= "host" then
                    local packet = packets[1]
                    assert(packet.args[WORK_ACTION == "HAMMER" and 6 or 5] == false, "work must be held")
                end
                for i = 1, 3 do
                    cycle()
                    assert(hits == i, "one authoritative hit per native cycle")
                    local status = Actions.Step(player, intent)
                    assert(status == (i == 3 and "succeeded" or "pending"), "one swing must not finish whole target")
                end
                assert(dispatches == 1, "native state must repeat without redispatch")
                assert_released()
                assert(Actions.Step(player, intent) == "succeeded", "terminal must latch")
                assert(dispatches == 1)
                Actions.Cancel(player); assert_released()
            ''')


def check_cancel_and_preemption():
    for mode in ("host", "remote_prediction", "remote_no_prediction"):
        for scenario in ("cancel", "tool", "timeout", "lost", "preempt", "failure", "superseded"):
            lua = fixture(mode)
            lua.globals().SCENARIO = scenario
            lua.execute('''
                assert(Actions.Step(player, intent) == "pending")
                cycle(); assert(Actions.Step(player, intent) == "pending")
                pc.remote_controls[99] = 4
                if SCENARIO == "cancel" then Actions.Cancel(player)
                elseif SCENARIO == "preempt" then
                    assert(Actions.Step(player, { kind = "action", action = "PICKUP", target = other,
                        priority = 10, id = "urgent" }) == "pending")
                else
                    if SCENARIO == "tool" then equipped = nil
                    elseif SCENARIO == "timeout" then clock = clock + 91
                    elseif SCENARIO == "lost" then function target:IsValid() return false end
                    elseif SCENARIO == "failure" then
                        if MODE == "host" then player:PushEvent("actionfailed", { action = worker.bufferedaction })
                        else pc:RemoteStopControl(CONTROL_PRIMARY) end
                    elseif SCENARIO == "superseded" then
                        if pc.locomotor then pc.locomotor.bufferedaction = { foreign = true }; clock = clock + 2
                        else pc:RemoteStopControl(CONTROL_PRIMARY) end
                    end
                    assert(Actions.Step(player, intent) == "failed", "interruption must fail and release")
                end
                assert_released()
                assert(pc.remote_controls[99] == 4, "must preserve other controls")
                if SCENARIO == "superseded" and pc.locomotor then
                    assert(pc.locomotor.bufferedaction.foreign, "must preserve another action")
                end
                local count = stop_count(); Actions.Cancel(player)
                assert(stop_count() == count, "must release exactly once")
                if SCENARIO == "cancel" then
                    worker.bufferedaction = nil
                    for _, event in ipairs(NativeWorkState.timeline) do event.fn(worker) end
                    assert(worker.bufferedaction == nil, "cancelled work must not queue another swing")
                end
            ''')


def check_dispatch_boundaries():
    lua = fixture("remote_prediction")
    lua.execute('''
        defer_preview = true
        assert(Actions.Step(player, intent) == "pending")
        assert(#packets == 0)
        Actions.Cancel(player); late_preview(); assert(#packets == 0, "cancelled preview must never send held input")
        assert_released()
        blocked = true; clock = clock + 1; intent.id = "blocked"
        assert(Actions.Step(player, intent) == "pending")
        clock = clock + 16
        assert(Actions.Step(player, intent) == "failed", "dispatch blocking must not extend deadline")
        assert_released()
        blocked, defer_preview = false, false; intent.id = "occupied"
        pc.remote_controls[CONTROL_PRIMARY] = 9
        assert(Actions.Step(player, intent) == "failed")
        assert(pc.remote_controls[CONTROL_PRIMARY] == 9 and #packets == 0, "must not take another held control")
        pc.remote_controls[CONTROL_PRIMARY] = nil
        assert(Actions.Step(player, { kind = "action", action = "PICKUP", target = other, id = "click",
            confirm = function() return true end }) == "pending")
        assert(packets[1].args[5] == true, "ordinary click must remain released")
        assert(Actions.Step(player, { kind = "action", action = "PICKUP", target = other, id = "click",
            confirm = function() return true end }) == "succeeded")
        assert(stop_count() == 0); assert_released()
    ''')


if __name__ == "__main__":
    for check in (check_native_repetition, check_cancel_and_preemption, check_dispatch_boundaries):
        check()
        print("PASS", check.__name__)
