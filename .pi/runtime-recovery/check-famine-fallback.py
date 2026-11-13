"""Regress famine scheduling when all direct food requests are cooling down."""
from pathlib import Path
import importlib.util
import sys
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("stock_checks", HERE / "check-stock-batching.py")
stock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stock)
stock.SOURCE = stock.base.SCRIPTS / "wilsonexpedition/survival.lua"
stock.light.SOURCE = stock.SOURCE
from lupa.lua51 import LuaError


def source(name, previous=None):
    relative = "scripts/wilsonexpedition/" + name + ".lua"
    if previous:
        with zipfile.ZipFile(previous) as archive:
            return archive.read("client/" + relative).decode("utf-8-sig")
    return (stock.base.SCRIPTS.parent / relative).read_text(encoding="utf-8-sig")


def fixture(previous=None):
    lua = stock.fixture()
    lua.globals().SURVIVAL_SOURCE = source("survival", previous)
    lua.globals().Survival = lua.execute(lua.globals().SURVIVAL_SOURCE)
    lua.globals().STATUS_SOURCE = source("status_text", previous)
    lua.execute('''
        function Vector3(x,y,z) return {x=x,y=y,z=z} end
        package.loaded["wilsonexpedition/supplies"].Report = function(_,_,status,why)
            cancelled,released_reason = status=="failed",why
            return true,status=="failed" and "terminal:failed" or "terminal:succeeded"
        end
        local exploration = package.loaded["wilsonexpedition/exploration"]
        function exploration.Next()
            return { id="food-frontier",x=12,z=0,range=1.5,kind="ray",priority=1 }
        end
        function exploration.Report(_, _, status) explored_receipt=status; return true end
        function food_cooldown(state)
            state.survival.blocked = state.survival.blocked or {}
            for _, food in ipairs({"berries","berries_juicy","carrot","cave_banana"}) do
                state.survival.blocked["vital:request:food:" .. food] = clock
            end
        end
        function empty_food(s)
            for i=#s.inventory.records,1,-1 do
                if s.inventory.records[i].prefab=="carrot" then table.remove(s.inventory.records,i) end
            end
            s.hunger=0
            return s
        end
        function init_cooldown(s,state)
            local first = assert(Survival.Plan(player,s,state))
            assert(Survival.Report(state,first,"succeeded","fixture_completed"))
            requests = {}
            food_cooldown(state)
        end
    ''')
    return lua


def check_idle_famine_never_replenishes_materials(previous=None):
    lua = fixture(previous)
    lua.execute('''
        for _, hunger in ipairs({0,0.08}) do
            local s,state=empty_food(stock_snapshot()),{}
            owned(s,"cutgrass",0)
            init_cooldown(s,state)
            s.hunger=hunger
            local cmd,why=Survival.Plan(player,s,state)
            assert(cmd and cmd.explore_goal and state.survival.active.priority == Survival.PRIORITY_STARVE,
                "food cooldown must retain famine exploration instead of ordinary stock: " .. tostring(why))
            assert(#requests==0 and cmd.goal.priority==Survival.PRIORITY_STARVE,
                "famine frontier must preserve executor priority without material requests")
            assert(state.survival.blocked["vital:request:food:berries"]==clock,
                "famine must not erase source failure cooldowns")
        end
    ''')


def check_inflight_stock_is_released(previous=None):
    lua = fixture(previous)
    lua.execute('''
        local s,state=stock_snapshot(),{}
        owned(s,"cutgrass",0)
        local first=assert(Survival.Plan(player,s,state))
        assert(requests[#requests].item=="cutgrass")
        empty_food(s)
        food_cooldown(state)
        requests={}
        local cmd,why=Survival.Plan(player,s,state)
        assert(cmd and cmd.explore_goal and cmd.id~=first.id,
            "new famine must replace active material procurement despite food cooldown: " .. tostring(why))
        assert(cancelled and cmd.preempt and cmd.preempt.id==first.id,
            "the old procurement executor must be released exactly through preemption")
        assert(#requests==0, "famine must not issue a replacement material request")
    ''')


def check_no_frontier_waits_without_resume(previous=None):
    lua = fixture(previous)
    lua.execute('''
        local s,state=stock_snapshot(),{}
        owned(s,"cutgrass",0)
        assert(Survival.Plan(player,s,state))
        empty_food(s); food_cooldown(state); requests={}
        package.loaded["wilsonexpedition/exploration"].Next=function() return nil,"no_frontier" end
        for _=1,5 do
            local cmd,why=Survival.Plan(player,s,state)
            assert(cmd==nil and state.survival.active==nil and #requests==0,
                "no safe food frontier must stop procurement rather than resume stock: " .. tostring(why))
        end
        s.hunger=0.6
        local cmd,why=Survival.Plan(player,s,state)
        assert(cmd and requests[#requests].item=="cutgrass",
            "recovered hunger must restore ordinary batch replenishment: " .. tostring(why))
    ''')


def check_food_and_meal_interrupt_famine_search(previous=None):
    lua = fixture(previous)
    lua.execute('''
        local s,state=empty_food(stock_snapshot()),{}
        owned(s,"cutgrass",0)
        init_cooldown(s,state)
        local first=assert(Survival.Plan(player,s,state))
        assert(first.explore_goal,"fixture must enter famine search")
        state.survival.blocked["vital:request:food:berries"]=nil
        local pickup,why=Survival.Plan(player,s,state)
        assert(pickup and requested("berries") and pickup.id~=first.id,
            "food procurement must interrupt an equal-priority exploration goal: " .. tostring(why))
        owned(s,"carrot",1)
        local eat=assert(Survival.Plan(player,s,state))
        assert(eat.intent and eat.intent.action=="EAT" and cancelled,
            "carried food must immediately interrupt procurement")
        local display=assert(loadstring(STATUS_SOURCE))()
        assert(display("vital:search:food:ray: moving:moving")=="寻找救急食物 · 行走中",
            "famine search must have a specific Chinese status")
    ''')


def check_real_exploration_receipts_and_higher_priority_safety(previous=None):
    lua = fixture(previous)
    lua.globals().EXPLORATION_SOURCE=source("exploration",previous)
    lua.execute('''
        TheWorld.Map.IsPassableAtPoint=function() return true end
        TheWorld.Map.IsPointNearHole=function() return false end
        package.loaded["wilsonexpedition/exploration"]=assert(loadstring(EXPLORATION_SOURCE))()
        Survival=assert(loadstring(SURVIVAL_SOURCE))()
        local s,state=empty_food(stock_snapshot()),{}
        owned(s,"cutgrass",0)
        init_cooldown(s,state)
        local cmd=assert(Survival.Plan(player,s,state))
        assert(cmd.explore_goal and cmd.goal.priority==Survival.PRIORITY_STARVE,
            "famine must use actual exploration goals")
        s.x,s.z=cmd.goal.x,cmd.goal.z
        assert(Survival.Report(state,cmd,"succeeded","arrived:1.50"))
        assert(state.explore.current==nil,"arrival must advance the real exploration planner")
        cmd=assert(Survival.Plan(player,s,state))
        assert(cmd.id~="food-frontier" and cmd.explore_goal,"continue actual frontier selection")
        s.phase,s.time_until_night,s.time_until_day="night",0,50
        s.light.dark,s.light.ambient=true,0
        local light=assert(Survival.Plan(player,s,state))
        assert(light.intent and light.intent.action=="EQUIP","actual darkness must preempt famine")
        Survival.Cancel(state)
        s.phase,s.time_until_night,s.light.dark,s.light.ambient="day",300,false,0.8
        s.threats={{prefab="spider",x=s.x+2,z=s.z,distance=2}}
        local blocked,why=Survival.Plan(player,s,state)
        assert(blocked==nil and why:find("escape:wait",1,true),
            "unconfirmed retreat must retain the existing danger hold: " .. tostring(why))
    ''')
    return lua


def main():
    previous=Path(sys.argv[1]) if len(sys.argv)>1 else None
    checks=[check_idle_famine_never_replenishes_materials,check_inflight_stock_is_released,
            check_no_frontier_waits_without_resume,check_food_and_meal_interrupt_famine_search,
            check_real_exploration_receipts_and_higher_priority_safety]
    failed=0
    for check in checks:
        try:
            # [喵喵喵]: 同一组行为检查直接运行修复前归档，保证能发现本次故障。
            check(previous)
            print("PASS",check.__name__)
        except (AssertionError,LuaError) as exc:
            failed+=1
            print("FAIL",check.__name__,str(exc).splitlines()[0])
    if failed:
        raise SystemExit(1)


if __name__=="__main__":
    main()
