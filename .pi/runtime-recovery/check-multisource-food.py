"""Replay nearby mining, tool bootstrap, and safe meals against the actual planners."""
import argparse
import importlib.util
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("nearby_checks", HERE / "check-nearby-demands.py")
nearby = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nearby)
from lupa.lua51 import LuaError


def fixture(previous=None):
    lua = nearby.fixture(previous)
    native = (nearby.stock.base.GAME / "data/databundles/scripts/components/hunger_replica.lua").read_text(encoding="utf-8-sig")
    methods = []
    for method in ("Max", "GetCurrent"):
        match = re.search(r"function Hunger:" + method + r"\(\).*?\nend", native, re.S)
        assert match, "Native hunger replica method missing: " + method
        methods.append(match.group())
    lua.execute("Hunger = {}\n" + "\n".join(methods))
    lua.execute('''
        player.replica.hunger = setmetatable({inst=player,classified={
            maxhunger={value=function() return 150 end},
            currenthunger={value=function() return current_hunger or s.hunger*150 end},
        }},{__index=Hunger})
        function age(record,remaining)
            record.entity.replica.inventoryitem.classified.perish.value=function() return remaining end
            return record
        end
        function equip_pickaxe()
            local r=set_owned("pickaxe",1)
            r.kind,r.eslot="equipment","hands"
            s.equipment.hands=r
            return r
        end
        function is_action(command,action)
            return command and command.intent and command.intent.action==action
        end
    ''')
    return lua


def check_nearby_mining_competes_with_pickups(previous=None):
    rocks = (nearby.stock.base.GAME / "data/databundles/scripts/prefabs/rocks.lua").read_text(encoding="utf-8-sig")
    for rock in ("rock1", "rock2"):
        loot = re.search(r"SetSharedLootTable\( '" + rock + r"',\s*\{(.*?)\}\)", rocks, re.S)
        assert loot and re.search(r"\{'flint',\s+1\.00\}", loot.group(1)), "Native guaranteed flint source missing"
    lua = fixture(previous)
    lua.execute('''
        set_owned("flint",0); equip_pickaxe()
        s.nearby={plant(901,"flint",14,0,{}),plant(902,"rock1",1.2,0,{MINE_workable=true})}
        local cmd,why=Supplies.Plan(player,s,state,{item="flint",count=8})
        assert(is_action(cmd,"MINE") and cmd.intent.target.GUID==902,
            "nearby usable rock must beat distant loose flint: "..tostring(why))
        assert(Supplies.Report(state,cmd,"failed","preempted_for_replan"))
        local chosen=Supplies.NearbyRequest(player,s,state,{{item="flint",count=8}},nil)
        assert(chosen and chosen.guid==902,"shared requests must compare mining and pickup at the same boundary")
        s.nearby={plant(903,"flint",1,0,{}),plant(904,"rock2",12,0,{MINE_workable=true})}
        cmd=assert(Supplies.Plan(player,s,state,{item="flint",count=8}))
        assert(is_action(cmd,"PICKUP") and cmd.intent.target.GUID==903,"an immediate pickup must remain usable")
        assert(Supplies.Report(state,cmd,"failed","preempted_for_replan"))
        set_owned("flint",0); set_owned("twigs",0)
        s.nearby={plant(905,"flint",15,0,{}),plant(906,"rock1",1,0,{MINE_workable=true})}
        cmd=assert(Supplies.Plan(player,s,state,{item="axe",count=1}))
        assert(is_action(cmd,"MINE"),"recipe ingredients must use the same nearby mining selection")
    ''')


def check_bootstrap_and_work_safety(previous=None):
    lua = fixture(previous)
    lua.execute('''
        set_owned("flint",2); set_owned("twigs",2); set_owned("pickaxe",0)
        s.nearby={plant(911,"rock1",1,0,{MINE_workable=true})}
        local cmd,why=Supplies.Plan(player,s,state,{item="flint",count=8})
        assert(cmd and cmd.intent and cmd.intent.kind=="craft" and cmd.intent.recipe=="pickaxe",
            "native-ready first pickaxe must unlock mining before exploring for loose flint: "..tostring(why))
        assert(Supplies.Report(state,cmd,"succeeded","built"))
        set_owned("flint",0); set_owned("twigs",0); equip_pickaxe()
        cmd=assert(Supplies.Plan(player,s,state,{item="flint",count=8}))
        assert(is_action(cmd,"MINE"),"after crafting, mining must continue without requiring more loose flint")
        assert(Supplies.Report(state,cmd,"failed","preempted_for_replan"))
        set_owned("pickaxe",0); s.equipment.hands=nil
        cmd=Supplies.Plan(player,s,state,{item="flint",count=8})
        assert(not is_action(cmd,"MINE"),"zero bootstrap flint must not recurse into impossible mining")
        if cmd then assert(Supplies.Report(state,cmd,"failed","preempted_for_replan")) end
        equip_pickaxe(); s.phase="night"
        local torch=set_owned("torch",1); torch.kind,torch.eslot="equipment","hands"; s.equipment.hands=torch
        assert(Supplies.NearbyRequest(player,s,state,{{item="flint",count=8}},nil)==nil,
            "mining must not displace a handheld night light")
        s.phase="day"; equip_pickaxe(); water_x=1
        assert(Supplies.NearbyRequest(player,s,state,{{item="flint",count=8}},nil)==nil,
            "an unwalkable rock location must not become an opportunistic source")
    ''')


def check_safe_meals_and_capacity(previous=None):
    lua = fixture(previous)
    lua.execute('''
        s.hunger=.7
        age(set_owned("carrot",8),62)
        local berries=age(set_owned("berries",1),24)
        local cmd,why=Survival.Plan(player,s,state)
        assert(is_action(cmd,"EAT") and cmd.intent.item==berries.entity,
            "safe meals must prefer the oldest edible food before the low-hunger threshold: "..tostring(why))
        fresh(); s.hunger=.99
        age(set_owned("carrot",8),62); set_owned("berries",0)
        cmd=Survival.Plan(player,s,state)
        assert(not is_action(cmd,"EAT"),"a tiny hunger deficit must not waste a full carrot")
        fresh(); s.hunger=.95; age(set_owned("carrot",8),62)
        local berries=age(set_owned("berries",1),24)
        cmd=assert(Survival.Plan(player,s,state))
        assert(is_action(cmd,"EAT") and cmd.intent.item==berries.entity,
            "native hunger capacity must allow a small stale-berry meal at 95 percent")
        fresh(); s.hunger=.7
        age(set_owned("carrot",8),11); age(set_owned("berries",1),63)
        cmd=Survival.Plan(player,s,state)
        assert(not is_action(cmd,"EAT"),"spoiled and unknown-freshness food must remain excluded")
    ''')


def check_concrete_cooking_plan_and_action_continuity(previous=None):
    lua = fixture(previous)
    lua.execute('''
        s.health=.8; s.hunger=1
        local ingredient=set_owned("carrot",8)
        ingredient.entity.tags.cookable=true
        local fire=plant(921,"campfire",6,0,{cooker=true,fire=true})
        s.nearby={fire}
        local cmd,why=Survival.Plan(player,s,state)
        assert(cmd and cmd.via=="navigation" and cmd.purpose=="approach_fire:carrot_cooked",
            "fixture must start a real nearby cooking plan: "..tostring(why))
        assert(Survival.Report(state,cmd,"pending","moving"))
        s.hunger=.7
        local held=Survival.Plan(player,s,state)
        assert(not is_action(held,"EAT") and state.survival.active and state.survival.active.id==cmd.id,
            "safe meals must preserve food being taken to an actual nearby cooker")
        assert(Survival.Report(state,cmd,"failed","preempted_for_replan"))
        s.nearby={}
        local meal=assert(Survival.Plan(player,s,state))
        assert(is_action(meal,"EAT"),"a cancelled cooking route without a visible fire must not reserve raw food forever")
        fresh(); s.hunger=1; set_owned("cutgrass",0)
        s.nearby={plant(922,"grass",1)}
        cmd=assert(Survival.Plan(player,s,state))
        assert(is_action(cmd,"PICK"),"fixture must enter an actual gathering action")
        assert(Survival.Report(state,cmd,"pending","awaiting_confirmation"))
        s.hunger=.7
        held=Survival.Plan(player,s,state)
        assert(not is_action(held,"EAT") and state.survival.active and state.survival.active.id==cmd.id,
            "ordinary meals must not interrupt an issued gathering action")
        set_owned("cutgrass",20)
        assert(Survival.Report(state,cmd,"succeeded","confirmed_inventory_gain"))
        meal=assert(Survival.Plan(player,s,state))
        assert(is_action(meal,"EAT"),"a safe meal must run as soon as gathering completes")
    ''')


def check_emergency_and_uncertain_state(previous=None):
    lua = fixture(previous)
    lua.execute('''
        s.hunger=.01
        local carrot=age(set_owned("carrot",1),24)
        local cmd,why=Survival.Plan(player,s,state)
        assert(is_action(cmd,"EAT") and cmd.intent.item==carrot.entity,
            "an edible stale meal must remain usable during famine: "..tostring(why))
        fresh(); s.hunger=.7
        s.light.dark=true; s.light.in_light=false
        cmd=Survival.Plan(player,s,state)
        assert(not is_action(cmd,"EAT"),"ordinary meals must not replace actual darkness protection")
        fresh(); s.hunger=.7; s.threats={{prefab="spider",entity=entity(931,"spider",{}),x=1,z=0,distance=1}}
        cmd=Survival.Plan(player,s,state)
        assert(not is_action(cmd,"EAT"),"ordinary meals must not occupy an escape opportunity")
        fresh(); s.hunger=.7; player.replica.hunger=nil
        cmd=Survival.Plan(player,s,state)
        assert(not is_action(cmd,"EAT"),"unknown hunger capacity must not be replaced with a guessed character maximum")
    ''')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("previous", nargs="?", type=Path)
    parser.add_argument("--source-root", type=Path)
    args = parser.parse_args()
    if args.source_root:
        nearby.stock.base.SCRIPTS = args.source_root
        nearby.stock.SOURCE = args.source_root / "wilsonexpedition/survival.lua"
        nearby.stock.light.SOURCE = nearby.stock.SOURCE
    failures = []
    for check in (check_nearby_mining_competes_with_pickups, check_bootstrap_and_work_safety,
                  check_safe_meals_and_capacity, check_concrete_cooking_plan_and_action_continuity,
                  check_emergency_and_uncertain_state):
        try:
            check(args.previous)
            print("PASS", check.__name__)
        except (AssertionError, LuaError) as error:
            failures.append(check.__name__)
            print("FAIL", check.__name__, str(error).splitlines()[0])
    if failures:
        raise SystemExit(1)
    print("PASS 5 multi-source and safe-meal regression groups")


if __name__ == "__main__":
    main()
