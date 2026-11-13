"""Verify longer safe threat escapes without removing short disengagement routes."""
import argparse
import importlib.util
from pathlib import Path
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("walking_checks", HERE / "check-move-continuity.py")
movement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(movement)
from lupa.lua51 import LuaError


def source(previous):
    if previous:
        with zipfile.ZipFile(previous) as z:
            for name in ("client/scripts/wilsonexpedition/survival.lua", "WilsonExpedition/scripts/wilsonexpedition/survival.lua"):
                if name in z.namelist():
                    return z.read(name).decode("utf-8-sig")
        raise AssertionError("Archive has no survival source")
    return (movement.baseline.SCRIPTS / "wilsonexpedition/survival.lua").read_text(encoding="utf-8-sig")


def fixture(previous=None):
    lua = movement.baseline.runtime()
    lua.execute('''
        stub_planners()
        package.loaded["wilsonexpedition/exploration"].BaseGoal=function() return nil end
        package.loaded["wilsonexpedition/navigation"]=nil
        function Vector3(x,y,z) return {x=x,y=y,z=z} end
        TheWorld.Map.IsOceanAtPoint=function() return false end
        TheWorld.Map.IsPassableAtPoint=function() return not water end
        TheWorld.Map.IsPointNearHole=function() return holes==true end
        TheWorld.Pathfinder={IsClear=function(_,x,_,z,gx,_,gz)
            return not blocked and (max_segment==nil or (gx-x)^2+(gz-z)^2<=max_segment^2) end}
        s,state=snapshot(),{}
        s.threats={{guid=101,prefab="pigman",x=12,z=0,entity=entity(101,"pigman",{werepig=true})}}
        s.nearby=s.threats
        Navigation=require("wilsonexpedition/navigation")
    ''')
    lua.globals().Survival=lua.execute(source(previous))
    return lua


def check_clear_leg_crosses_warning_zone(previous=None):
    lua=fixture(previous)
    lua.execute('''
        cmd=assert(Survival.Plan(player,s,state))
        assert(cmd.purpose=="escape:threat" and cmd.goal.x<0)
        local distance=math.sqrt((cmd.goal.x-s.x)^2+(cmd.goal.z-s.z)^2)
        assert(distance-cmd.goal.range>=Navigation.THREAT_RADII.pigman+Survival.ESCAPE_CLEARANCE,
            "a clear retreat leg must avoid periodic arrivals inside the pursuer warning distance")
        assert(distance<=40,"native route distance limit is preserved")
    ''')


def check_native_motion_before_clearance(previous=None):
    planned=fixture(previous)
    planned.execute("cmd=assert(Survival.Plan(player,s,state))")
    goal=planned.globals().cmd["goal"]
    for mode in ("host","remote_prediction","remote_no_prediction"):
        lua=movement.fixture(mode)
        lua.globals().GX,lua.globals().GZ=goal["x"],goal["z"]
        lua.execute('''
            goal={id="one-escape-leg",x=GX,z=GZ,range=1.5,priority=96}
            local status=Navigation.Step(player,snapshot_at(),state,goal)
            local starting_stops,starting_clears=stops,clears
            for frame=1,64 do
                advance_frame()
                if frame%8==0 then
                    status=Navigation.Step(player,snapshot_at(),state,goal)
                    assert(status=="pending","native escape must not complete a short waypoint while still inside the warning zone")
                end
            end
            assert(stops==starting_stops and clears==starting_clears,
                "clear escape motion must not be explicitly stopped during the early chase")
            assert(math.sqrt(x*x+z*z)>11,"the replay must make physical walking progress")
            assert(Navigation.Cancel(player,state),"manual cancellation must still release owned movement")
            assert(not state.nav.action_active,"cancellation retains ownership accounting")
        ''')


def check_short_and_unsafe_routes(previous=None):
    for limit in (4,2):
        lua=fixture(previous)
        lua.globals().max_segment=limit
        lua.execute('''
            local cmd=assert(Survival.Plan(player,s,state))
            assert(cmd.purpose=="escape:threat" and cmd.goal.x<0)
            assert(math.sqrt(cmd.goal.x^2+cmd.goal.z^2)<=max_segment+1e-6,
                "a blocked long leg must retain the existing short safe disengagement")
        ''')
    for flag in ("blocked","water","holes"):
        lua=fixture(previous)
        lua.globals()[flag]=True
        lua.execute('''
            local cmd,why=Survival.Plan(player,s,state)
            assert(cmd==nil and why:find("escape:wait",1,true),"unverified routes must never fall back to procurement")
        ''')


CHECKS=(check_clear_leg_crosses_warning_zone,check_native_motion_before_clearance,check_short_and_unsafe_routes)
if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("previous",nargs="?",type=Path)
    parser.add_argument("--mod-root",type=Path)
    args=parser.parse_args()
    if args.mod_root:movement.baseline.SCRIPTS=args.mod_root/"scripts"
    failed=0
    for check in CHECKS:
        try:
            check(args.previous)
            print("PASS",check.__name__)
        except (LuaError,AssertionError) as error:
            failed+=1
            print("FAIL",check.__name__,str(error).splitlines()[0])
    raise SystemExit(1 if failed else 0)
