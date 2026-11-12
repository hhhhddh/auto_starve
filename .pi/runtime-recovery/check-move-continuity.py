"""Offline checks for continuous handoff between native walking destinations."""

import importlib.util
from pathlib import Path

baseline_path = Path(__file__).with_name("check-death-iteration.py")
spec = importlib.util.spec_from_file_location("movement_baseline", baseline_path)
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)


def fixture(mode="remote_prediction", steps=None):
    lua = baseline.runtime()
    lua.globals().MODE = mode
    lua.execute('''
        function Class(constructor)
            local cls = {}; cls.__index = cls
            return setmetatable(cls, { __call = function(_, ...)
                local inst = setmetatable({}, cls); constructor(inst, ...); return inst
            end })
        end
        function Vector3(x, y, z)
            return { x = x, y = y, z = z, Get = function(self) return self.x, self.y, self.z end }
        end
        function DynamicPosition(pt) return { GetPosition = function() return pt end } end
        function distsq(x1, z1, x2, z2) return (x1-x2)^2 + (z1-z2)^2 end
        function Point(x, y, z) return Vector3(x, y, z) end
        CONTROL_PRIMARY = 1
        ACTIONS = { WALKTO = { id = "WALKTO", code = 1 } }
        RPC = { LeftClick = 1 }
        ARRIVE_STEP = 0.15
        PlayerController, LocoMotor, EntityScript = {}, {}, {}
        TheInput = {
            GetWorldPosition = function() error("must not query desktop cursor") end,
            GetWorldEntityUnderMouse = function() error("must not query desktop cursor") end,
        }
        time, x, z, speed, stops, dispatches, clears = 0, 0, 0, 6, 0, 0, 0
        clock = 0
        obstacles, paths_submitted, paths_killed = false, 0, 0
        TheWorld.ismastersim = MODE == "host"
        TheWorld.Map.IsPassableAtPoint = function(_, px) return px ~= blocked_endpoint end
        TheWorld.Map.IsPointNearHole = function(_, point) return hole_x == point.x end
        TheWorld.Map.GetTileCoordsAtPoint = function() return 0, 0 end
        TheWorld.Pathfinder = {
            IsClear = function(_, px, _, pz, gx, _, gz, caps)
                assert(caps == nil, "native walking uses default land path capabilities")
                if px == 0 and pz == 0 and gx == 30 and gz == 0 then return false end
                if line_unknown then error("path visibility unavailable") end
                return not obstacles
            end,
            SubmitSearch = function() paths_submitted = paths_submitted + 1; return paths_submitted end,
            GetSearchStatus = function() return 1 end,
            GetSearchResult = function() return { steps = path_steps } end,
            KillSearch = function() paths_killed = paths_killed + 1 end,
        }
        function player.Transform:GetWorldPosition() return x, 0, z end
        function player:GetCurrentPlatform() return nil end
        function player:GetPhysicsRadius() return 0.5 end
        function player:GetAngleToPoint() return 0 end
        function player:PushEvent() end
        function player:PushBufferedAction(buff) self.bufferedaction = buff end
        function player:PreviewBufferedAction(buff) self.bufferedaction = buff end
        player.Physics = {
            GetMotorVel = function() return speed, 0, 0 end,
            GetMotorSpeed = function() return 0 end,
        }
        player.sg = { HasStateTag = function(_, tag)
            return tag == "canrotate" or (loco ~= nil and loco.moving and (tag == "moving" or tag == "running"))
        end }
        local function locomotor(inst)
            local loco = setmetatable({ inst = inst, ismastersim = MODE == "host",
                directdrive = true, time_before_next_hop_is_allowed = 0 }, { __index = LocoMotor })
            function loco:CancelPredictMoveTimer() end
            function loco:StartUpdatingInternal() end
            function loco:StopUpdatingInternal() end
            function loco:StopMoveTimerInternal() end
            function loco:StartMoveTimerInternal() end
            function loco:WaitingForPathSearch() return false end
            function loco:ResetPath() self.path = nil end
            function loco:SetMoveDir() end
            function loco:GetRunSpeed() return speed end
            function loco:RunForward() self.isrunning = true end
            function loco:SetBufferedAction(buff) self.bufferedaction = buff end
            function loco:StopMoving() self.moving = false end
            function loco:Stop(...)
                if self.moving then stops = stops + 1 end
                LocoMotor.Stop(self, ...)
            end
            function loco:Clear()
                clears = clears + 1; LocoMotor.Clear(self)
            end
            return loco
        end
        pc = setmetatable({ inst = player, handler = {}, remote_controls = {},
            ismastersim = MODE == "host" }, { __index = PlayerController })
        function pc:IsEnabled() return true end
        function pc:IsBusy() return false end
        function pc:CanLocomote() return true end
        function pc:GetPlatformRelativePosition(gx, gz) return nil, gx, gz end
        function pc:DoActionAutoEquip() end
        player.components.playercontroller = pc
        loco = locomotor(player)
        pc.locomotor = MODE ~= "remote_no_prediction" and loco or nil
        function loco:OnRemoteBufferedAction() end
        function pc:OnRemoteBufferedAction() end
        player.components.locomotor = pc.locomotor
        function SendRPCToServer(rpc, code, gx, gz)
            assert(rpc == RPC.LeftClick and code == ACTIONS.WALKTO.code)
            loco:GoToPoint(nil, BufferedAction(player, nil, ACTIONS.WALKTO, nil, Vector3(gx, 0, gz)), true)
        end
        ThePlayer = player
        goal = { x = 30, z = 0, range = 1.2, id = "route" }
        state = {}
        function snapshot_at()
            local s = snapshot(); s.x, s.z, s.threats = x, z, threats or {}; return s
        end
        function advance_frame()
            clock = clock + 1/30
            loco:OnUpdate(1/30)
            if loco.dest and loco.wantstomoveforward then
                local tx, _, tz = loco.dest:GetPoint()
                local dx, dz = tx-x, tz-z
                local distance = math.sqrt(dx*dx + dz*dz)
                local step = math.min(distance, speed/30)
                x, z = x + dx/distance*step, z + dz/distance*step
                loco.moving = true
            end
        end
    ''')
    native_root = baseline.NATIVE_SCRIPTS
    lua.execute((native_root / "bufferedaction.lua").read_text(encoding="utf-8"))
    for method in ("DoAction",):
        baseline.native_method(lua, "components/playercontroller.lua", "PlayerController", method)
    baseline.native_method(lua, "entityscript.lua", "EntityScript", "ClearBufferedAction")
    lua.execute("player.ClearBufferedAction = EntityScript.ClearBufferedAction")
    for method in ("PreviewAction", "PushAction", "GoToPoint", "Clear", "Stop", "OnUpdate"):
        baseline.native_method(lua, "components/locomotor.lua", "LocoMotor", method)
    lua.execute('''
        function Dest(inst, pt, buff)
            return { inst = inst, IsValid = function() return true end,
                GetPoint = function() local point = pt or buff:GetActionPoint(); return point:Get() end }
        end
        local original_action = pc.DoAction
        function pc:DoAction(buff) dispatches = dispatches + 1; return original_action(self, buff) end
        function player:GetBufferedAction() return self.bufferedaction end
    ''')
    path = steps or [(10, 0), (20, 0), (30, 0)]
    lua.globals().path_steps = lua.table_from(
        [lua.table_from({"x": px, "z": pz}) for px, pz in path]
    )
    lua.execute('Navigation = require("wilsonexpedition/navigation"); Actions = require("wilsonexpedition/actions")')
    return lua


def check_native_route_handoff():
    for mode in ("host", "remote_prediction", "remote_no_prediction"):
        for speed in (6, 9):
            for path in (
                [(10, 0), (20, 0), (30, 0)],
                [(px, 0) for px in range(4, 29, 4)],
                [(px, 0) for px in range(2, 21, 2)] + [(30, 0)],
            ):
                lua = fixture(mode, path)
                lua.globals().speed = speed
                run_route(lua)


def run_route(lua):
    lua.execute('''
                local result
                for frame = 1, 360 do
                    advance_frame()
                    if frame % 8 == 0 then
                        result = Navigation.Step(player, snapshot_at(), state, goal)
                        if result == "succeeded" then break end
                        assert(result == "pending", "route must remain active")
                    end
                end
                assert(result == "succeeded", "route must arrive")
                assert(stops <= 1, "native walking must not stop at intermediate waypoints: " .. stops)
                assert(paths_submitted == 1 and paths_killed == 1, "one native search per route")
                assert(math.abs(x - goal.x) <= goal.range, "final arrival must remain exact")
                local count = dispatches
                assert(Navigation.Step(player, snapshot_at(), state, goal) == "succeeded")
                assert(dispatches == count, "terminal must latch")
            ''')


def check_unsafe_shortcuts():
    for scenario in ("wall", "unknown", "water", "hole", "threat"):
        lua = fixture()
        lua.globals().SCENARIO = scenario
        lua.execute('''
            assert(Navigation.Step(player, snapshot_at(), state, goal) == "pending")
            if SCENARIO == "wall" then obstacles = true
            elseif SCENARIO == "unknown" then line_unknown = true
            elseif SCENARIO == "water" then blocked_endpoint = 20
            elseif SCENARIO == "hole" then hole_x = 20
            elseif SCENARIO == "threat" then threats = { { x = 15, z = 6 } } end
            clock = clock + 0.266
            assert(Navigation.Step(player, snapshot_at(), state, goal) == "pending")
            assert(state.nav.wp.x == 10, "must keep first waypoint when shortcut is unsafe: " .. SCENARIO)
            x, clock = 8.5, clock + 0.266
            local count = dispatches
            assert(Navigation.Step(player, snapshot_at(), state, goal) == "pending")
            assert(state.nav.wp.x == 10 and dispatches == count,
                "must not cut a corner or approach a threat just to keep moving")
        ''')


def check_navigation_cancellation():
    for scenario in ("cancel", "foreign", "supersede", "goal", "world", "shard"):
        lua = fixture("host")
        lua.globals().SCENARIO = scenario
        lua.execute('''
            assert(Navigation.Step(player, snapshot_at(), state, goal) == "pending")
            clock = clock + 0.266
            assert(Navigation.Step(player, snapshot_at(), state, goal) == "pending")
            for frame = 1, 8 do advance_frame() end
            assert(Navigation.Step(player, snapshot_at(), state, goal) == "pending")
            local original = loco.bufferedaction
            local foreign = { Fail = function() error("must preserve foreign action") end }
            if SCENARIO == "foreign" then loco.bufferedaction = foreign end
            if SCENARIO == "supersede" then
                loco.bufferedaction = foreign
                local count = dispatches
                local status, why = Navigation.Step(player, snapshot_at(), state, goal)
                assert(status == "pending" and why:find("superseded_by_other_action", 1, true))
                assert(loco.bufferedaction == foreign and dispatches == count)
            elseif SCENARIO == "cancel" or SCENARIO == "foreign" then
                assert(Navigation.Cancel(player, state))
                assert(loco.bufferedaction == (SCENARIO == "foreign" and foreign or nil))
                assert(not state.nav.action_active and state.nav.route == nil)
                assert(Navigation.Cancel(player, state), "repeat cancel is safe")
            else
                if SCENARIO == "goal" then goal = { x = 0, z = 12, id = "urgent" }
                elseif SCENARIO == "world" then
                    local old = TheWorld; TheWorld = { GUID = 2, Map = old.Map, Pathfinder = old.Pathfinder }
                end
                local s = snapshot_at()
                if SCENARIO == "shard" then s.shard = "cave" end
                assert(Navigation.Step(player, s, state, goal) == "pending")
                assert(loco.bufferedaction ~= original, "new route must release old owned movement")
                if SCENARIO == "world" then assert(state.nav.world == TheWorld) end
            end
        ''')


if __name__ == "__main__":
    for check in (check_native_route_handoff, check_unsafe_shortcuts, check_navigation_cancellation):
        check()
        print("PASS", check.__name__)
