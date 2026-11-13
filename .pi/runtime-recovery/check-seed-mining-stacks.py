"""Replay food policy, collision-safe work approaches, and existing-stack opportunities."""
import argparse
import importlib.util
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("meal_checks", HERE / "check-multisource-food.py")
meal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(meal)
nearby = meal.nearby
from lupa.lua51 import LuaError


def fixture(previous=None):
    lua = meal.fixture(previous)
    native = nearby.stock.base.GAME / "data/databundles/scripts"
    sim = (native / "simutil.lua").read_text(encoding="utf-8-sig")
    lua.globals().NATIVE_SCRIPTS = native.as_posix()
    lua.globals().OFFSET_SOURCE = sim[sim.index("function FindValidPositionByFan"):sim.index("-- like FindWalkableOffset")]
    lua.execute('''
        package.path=NATIVE_SCRIPTS.."/?.lua;"..package.path
        require("class")
        require("vector3")
        PI,TWOPI=math.pi,2*math.pi
        assert(loadstring(OFFSET_SOURCE))()
        player.Physics={GetRadius=function() return .5 end}
        player.GetPhysicsRadius=function() return .5 end
        function player.Transform:GetWorldPosition() return s.x,0,s.z end
        TheWorld.Map.IsAboveGroundAtPoint=function(_,x,_,z)
            return not block_stands and x~=water_x and z~=water_z
        end
        TheWorld.Map.IsPointNearHole=function(_,pt) return all_holes==true or pt.x==hole_x end
        local old_plant=plant
        function plant(guid,prefab,x,z,tags)
            local r=old_plant(guid,prefab,x,z,tags)
            r.entity.Transform.GetWorldPosition=function() return r.x,0,r.z end
            return r
        end
        function obstacle(guid,prefab,x,z,radius)
            local r=plant(guid,prefab,x,z,{MINE_workable=true,blocker=true})
            r.entity.Physics={GetRadius=function() return radius end}
            r.entity.GetPhysicsRadius=function() return radius end
            return r
        end
        function no_food()
            set_owned("carrot",0);set_owned("berries",0)
        end
        function gear_ready()
            for _,name in ipairs({"axe","pickaxe","backpack","spear","armorwood"}) do set_owned(name,1) end
            s.equipment.body=set_owned("backpack",1)
        end
    ''')
    stack = (native / "components/stackable_replica.lua").read_text(encoding="utf-8-sig")
    lua.execute("Stackable={}; STACK_SIZES={40,20,10}")
    for name in ("StackSize", "MaxSize", "IsFull", "CanStackWith"):
        match = re.search(r"^function Stackable:" + name + r"\([^\n]*\).*?^end[ \t]*$", stack, re.M | re.S)
        assert match, name
        lua.execute(match.group())
    lua.execute('''
        function stack_item(prefab,count,maximum,skin)
            local r=set_owned(prefab,count)
            r.entity.AnimState={GetSkinBuild=function() return skin or "default" end}
            r.entity.replica.stackable=setmetatable({inst=r.entity,
                GetPreviewStackSize=function() return nil end,
                _ignoremaxsize={value=function() return false end},
                _maxsize={value=function() return maximum==20 and 1 or (maximum==10 and 2 or 0) end},
                _stacksize={value=function() return (r.count-1)%64 end},
                _stacksizeupper={value=function() return math.floor((r.count-1)/64) end},
            },{__index=Stackable})
            return r
        end
        function release(command)
            assert(Supplies.Report(state,command,"failed","preempted_for_replan"))
        end
    ''')
    return lua


def check_food_policy_and_nutritional_reserve(previous=None):
    lua = fixture(previous)
    lua.execute('''
        no_food();s.hunger=.95
        stack_item("seeds",40,40); stack_item("seeds_cooked",20,40)
        s.nearby={plant(1001,"seeds",.5,0,{})}
        local cmd=Survival.Plan(player,s,state)
        assert(not is_action(cmd,"EAT"),"safe meals must preserve seed inventory")
        fresh();no_food();s.hunger=.01
        stack_item("seeds",40,40);stack_item("seeds_cooked",20,40)
        s.nearby={plant(1002,"seeds",.5,0,{})}
        cmd=Survival.Plan(player,s,state)
        assert(not is_action(cmd,"EAT"),"emergency eating must follow the same seed policy")
        for _,d in ipairs(state.survival.demands) do
            assert(d.item~="seeds" and d.item~="seeds_cooked","seed acquisition must not become a food request")
        end
        fresh();gear_ready();no_food();stack_item("seeds",40,40)
        s.nearby={plant(1003,"carrot_planted",5)}
        cmd=assert(Survival.Plan(player,s,state))
        local wanted
        for _,d in ipairs(state.survival.demands) do if d.item=="carrot" then wanted=d.count end end
        assert(wanted==8,"seed inventory must not satisfy the food reserve")
        assert(Supplies.NearbyRequest(player,s,state,{},nil)==nil,"seed stacks must not create opportunistic food collection")
    ''')


def check_mining_collision_handoff(previous=None):
    lua = fixture(previous)
    lua.execute('''
        for _,radius in ipairs({1,2,3}) do
            fresh();equip_pickaxe();set_owned("rocks",0)
            local rock=obstacle(1010+radius,"rock1",10,0,radius)
            s.nearby={rock}
            local cmd,why=Supplies.Plan(player,s,state,{item="rocks",count=8})
            assert(cmd and cmd.via=="navigation","distant work must begin with navigation: "..tostring(why))
            local d=math.sqrt((cmd.goal.x-rock.x)^2+(cmd.goal.z-rock.z)^2)
            assert(d-cmd.goal.range>radius+.5,"the entire arrival disk must stay outside both collision bodies")
            assert(cmd.target_x==rock.x and cmd.target_z==rock.z,"target identity remains the actual visible rock")
            -- Model the physical clamp: the old center goal cannot enter its fixed arrival radius.
            assert(d+cmd.goal.range<=math.max(2.5,radius+.5+.75)+1e-6,"handoff must already be within the work-dispatch range")
            s.x,s.z=cmd.goal.x-cmd.goal.range*.5,cmd.goal.z
            assert(Supplies.Report(state,cmd,"arrived","arrived"))
            cmd,why=Supplies.Plan(player,s,state,{item="rocks",count=8})
            assert(is_action(cmd,"MINE") and cmd.intent.target==rock.entity,
                "one collision-safe approach must hand off directly to the native target action: "..tostring(why))
        end
    ''')


def check_blocked_work_stands(previous=None):
    lua = fixture(previous)
    lua.execute('''
        equip_pickaxe();set_owned("rocks",0)
        local rock=obstacle(1021,"rock1",10,0,1)
        local neighbour=obstacle(1022,"rock2",8,0,.8)
        s.nearby={rock,neighbour}
        local cmd=assert(Supplies.Plan(player,s,state,{item="rocks",count=8}))
        assert((cmd.goal.x-8)^2+cmd.goal.z^2>(.8+.5)^2,
            "the nearest stand occupied by a second body must use a different native fan offset")
        release(cmd);state={};block_stands=true
        cmd=Supplies.Plan(player,s,state,{item="rocks",count=8})
        assert(cmd==nil,"no walkable stand must not fall back to an occupied center")
        state={};block_stands=false;all_holes=true
        cmd=Supplies.Plan(player,s,state,{item="rocks",count=8})
        assert(cmd==nil,"cave holes must remain excluded from work stands")
        state={};all_holes=false;s.threats={{prefab="spider",x=10,z=0,distance=10}}
        cmd=Supplies.Plan(player,s,state,{item="rocks",count=8})
        assert(not cmd or cmd.target_guid~=rock.guid,"work approaches must retain threat avoidance")
    ''')


def check_existing_stack_opportunities(previous=None):
    lua = fixture(previous)
    lua.execute('''
        local grass=stack_item("cutgrass",20,40)
        s.nearby={plant(1031,"grass",1)}
        local request=Supplies.NearbyRequest(player,s,state,{},nil)
        assert(request and request.item=="cutgrass" and request.count==40,"nearby grass may fill an existing stack above its 20-item target")
        bag_full=true
        assert(Supplies.NearbyRequest(player,s,state,{},nil),"existing compatible stack space remains usable with a full bag")
        grass.count=40
        assert(Supplies.NearbyRequest(player,s,state,{},nil)==nil,"a completed stack must stop the extra collection")
        grass.count=20;s.nearby[1].x=10;s.nearby[1].distance=10
        assert(Supplies.NearbyRequest(player,s,state,{},nil)==nil,"surplus stock must not cause a dedicated collection trip")
        s.nearby={plant(1032,"cutgrass",1,0,{})}
        s.nearby[1].entity.AnimState={GetSkinBuild=function() return "other-skin" end}
        assert(Supplies.NearbyRequest(player,s,state,{},nil)==nil,"a skin-incompatible stack cannot justify surplus pickup")
        s.nearby[1].entity.AnimState.GetSkinBuild=function() return "default" end
        assert(Supplies.NearbyRequest(player,s,state,{},nil),"native stack compatibility must allow a matching pickup")
        s.nearby[1].prefab="flint";s.nearby[1].entity.prefab="flint"
        assert(Supplies.NearbyRequest(player,s,state,{},nil)==nil,"surplus gathering requires the matching carried material")
        s.nearby={plant(1033,"grass",1)};s.hunger=.01
        assert(Supplies.NearbyRequest(player,s,state,{},nil)==nil,"famine must not create stack-filling opportunities")
    ''')


def check_topup_scheduling_and_priority(previous=None):
    lua = fixture(previous)
    lua.execute('''
        gear_ready();stack_item("cutgrass",20,40)
        s.nearby={plant(1041,"grass",1)}
        local cmd,why=Survival.Plan(player,s,state)
        assert(is_action(cmd,"PICK") and cmd.target_guid==1041,
            "idle/exploring planners must use an existing-stack opportunity above the stock target: "..tostring(why))
        assert(Survival.Report(state,cmd,"pending","awaiting_inventory_gain"))
        s.nearby[#s.nearby+1]=plant(1042,"sapling",.2)
        local held=Survival.Plan(player,s,state)
        assert(held==nil and state.survival.active.id==cmd.id,"ordinary opportunities must retain issued actions")
        s.hunger=.01
        local meal=assert(Survival.Plan(player,s,state))
        assert(is_action(meal,"EAT"),"emergency eating must interrupt surplus gathering")
        fresh();gear_ready();stack_item("cutgrass",20,40);s.nearby={plant(1043,"grass",1)}
        cmd=assert(Survival.Plan(player,s,state))
        s.phase,s.time_until_night="night",0;s.light.dark=true;s.light.ambient=0
        assert(is_action(Survival.Plan(player,s,state),"EQUIP"),"darkness must take priority over optional stacks")
        fresh();set_owned("backpack",0);stack_item("cutgrass",20,40);s.nearby={plant(1044,"grass",1)}
        cmd=assert(Survival.Plan(player,s,state))
        assert(cmd.intent and cmd.intent.kind=="craft" and cmd.intent.recipe=="backpack",
            "ready progression crafting must run before optional collection")
    ''')


CHECKS=(check_food_policy_and_nutritional_reserve,check_mining_collision_handoff,check_blocked_work_stands,
        check_existing_stack_opportunities,check_topup_scheduling_and_priority)
if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("previous",nargs="?",type=Path)
    parser.add_argument("--mod-root",type=Path)
    args=parser.parse_args()
    if args.mod_root:
        nearby.stock.base.SCRIPTS=args.mod_root/"scripts"
        nearby.stock.SOURCE=nearby.stock.base.SCRIPTS/"wilsonexpedition/survival.lua"
        nearby.stock.light.SOURCE=nearby.stock.SOURCE
    failures=0
    for check in CHECKS:
        try:
            check(args.previous)
            print("PASS",check.__name__)
        except (LuaError,AssertionError) as error:
            failures+=1
            print("FAIL",check.__name__,str(error).splitlines()[0])
    raise SystemExit(1 if failures else 0)
