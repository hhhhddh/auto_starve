"""Check early first-light preparation and visible recipe-ingredient acquisition."""
from pathlib import Path
import importlib.util
import re
import sys
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fuel_checks", HERE / "check-light-budget.py")
fuel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fuel)
fuel.SOURCE = fuel.base.SCRIPTS / "wilsonexpedition/survival.lua"
from lupa.lua51 import LuaError


def source(name, previous=None):
    if previous:
        with zipfile.ZipFile(previous) as archive:
            return archive.read("client/scripts/wilsonexpedition/" + name + ".lua").decode("utf-8-sig")
    return (fuel.base.SCRIPTS / "wilsonexpedition" / (name + ".lua")).read_text(encoding="utf-8-sig")


def planner(previous=None):
    lua = fuel.fixture()
    lua.globals().Survival = lua.execute(source("survival", previous))
    lua.execute('''
        function first_day()
            local s = dusk_snapshot()
            s.phase, s.time, s.time_until_night, s.time_until_day = "day", 0.05, 396, 0
            s.inventory.records = { item(901, "cutgrass") }
            return s
        end
    ''')
    return lua


def procurement(previous=None):
    lua = fuel.base.runtime()
    # [喵喵喵]: 配料和顺序取本机原版配方，避免测试恰好采用与生产不同的缺料顺序。
    recipes = (fuel.base.GAME / "data/databundles/scripts/recipes.lua").read_text(encoding="utf-8-sig")
    native = re.search(r'Recipe2\("torch",\s*\{(.*?)\},\s*TECH.NONE\)', recipes)
    assert native, "Native torch recipe unavailable"
    ingredients = re.findall(r'Ingredient\("([a-z_]+)",\s*([0-9]+)\)', native.group(1))
    assert ingredients == [("cutgrass", "2"), ("twigs", "2")]
    lua.globals().NATIVE_INGREDIENTS = "{" + ",".join(
        '{type="' + name + '",amount=' + amount + '}' for name, amount in ingredients) + "}"
    lua.execute('''
        function Vector3(x,y,z) return {x=x,y=y,z=z} end
        TheWorld.Map.IsPassableAtPoint = function() return true end
        player.replica.inventory = { IsFull = function() return false end }
        player.replica.builder = { IsBuildBuffered = function() return buffered == true end,
            KnowsRecipe = function() return true end,
            HasIngredients = function() return has_ingredients ~= false end }
        local ingredients = assert(loadstring("return " .. NATIVE_INGREDIENTS))()
        function GetValidRecipe(name)
            return name == "torch" and { name=name, ingredients=ingredients, level={} } or nil
        end
        explored = 0
        package.loaded["wilsonexpedition/exploration"] = {
            Next = function(_, s)
                explored = explored + 1
                return {id="frontier:" .. explored,x=s.x+32,z=s.z}
            end, Report = function() return true end,
        }
        function raw(guid,prefab,x,tags)
            return {entity=entity(guid,prefab,tags),guid=guid,prefab=prefab,x=x,z=0,distance=math.abs(x)}
        end
        s,state = snapshot(),{}
        s.shard_kind = "surface"
        s.inventory.records = {item(902,"cutgrass")}
        s.nearby = {raw(903,"sapling",1,{pickable=true})}
        request = {item="torch",count=1,id="first-light"}
    ''')
    lua.globals().Supplies = lua.execute(source("supplies", previous))
    return lua


def check_first_light_before_bulk_stock(previous=None):
    lua = planner(previous)
    lua.execute('''
        local s,state=first_day(),{}
        local cmd,why=Survival.Plan(player,s,state)
        assert(cmd and requests[#requests].item=="torch",
            "no usable light: first-day preparation must outrank bulk grass: " .. tostring(why))
        assert(requests[#requests].count==1,"one dry autumn night needs one full torch")
        s.time_until_night,s.time,s.phase=180,0.5,"dusk"
        s.time_until_day=240
        local before=#requests
        local nextcmd=Survival.Plan(player,s,state)
        assert(nextcmd==nil and #requests==before and not cancelled,
            "the same early preparation must retain ownership rather than restart on dusk")
        s=first_day()
        s.inventory.records[2]=torch(904,100)
        local before=#requests
        cmd=Survival.Plan(player,s,{})
        assert(#requests>before and requests[#requests].item=="cutgrass",
            "usable carried fuel must preserve ordinary material batching in early daylight")
    ''')


def check_visible_missing_ingredient_before_exploring(previous=None):
    lua=procurement(previous)
    lua.execute('''
        local cmd,why=Supplies.Plan(player,s,state,request)
        assert(cmd and cmd.intent and cmd.intent.action=="PICK" and cmd.target_guid==903,
            "visible missing twigs must be acquired before exploring for scarce grass: " .. tostring(why))
        assert(explored==0,"unselected exploration must not change frontier state")
        local waiting,why=Supplies.Plan(player,s,state,request)
        assert(waiting==nil and why:find("in_flight:",1,true),"selected PICK must hold its execution slot")
        assert(Supplies.Report(state,cmd,"succeeded","caller_confirmed"))
        s.inventory.records[2]=item(905,"twigs","inventory",1)
        cmd=assert(Supplies.Plan(player,s,state,request))
        assert(cmd.target_guid==903,"must finish the native twig requirement")
        assert(Supplies.Report(state,cmd,"succeeded","caller_confirmed"))
        s.inventory.records[2]=item(905,"twigs","inventory",2)
        cmd=assert(Supplies.Plan(player,s,state,request))
        assert(cmd.explore_goal and explored==1,"only the remaining grass deficit should explore")
        assert(Supplies.Report(state,cmd,"arrived","arrived"))
        s.inventory.records[1]=item(902,"cutgrass","inventory",2)
        cmd=assert(Supplies.Plan(player,s,state,request))
        assert(cmd.intent and cmd.intent.kind=="craft" and cmd.intent.recipe=="torch",
            "confirmed native ingredients must proceed to actual crafting")
    ''')


def check_ingredient_approach_and_hazards(previous=None):
    lua=procurement(previous)
    lua.execute('''
        s.nearby[1]=raw(910,"sapling",6,{pickable=true})
        local cmd=assert(Supplies.Plan(player,s,state,request))
        assert(cmd.target_guid==910 and cmd.via=="navigation" and not cmd.explore_goal,
            "safe visible approach must precede exploring another missing ingredient")
        assert(Supplies.Report(state,cmd,"failed","preempted_for_replan"))
        s.nearby[1].entity.tags.pickable=nil
        cmd=assert(Supplies.Plan(player,s,{},request))
        assert(cmd.explore_goal,"depleted visible plants must not justify ingredient detours")
        s.nearby[1].entity.tags.pickable=true
        s.threats={{prefab="spider",x=6,z=0,distance=6}}
        cmd=assert(Supplies.Plan(player,s,{},request))
        assert(cmd.explore_goal,"threatened ingredient must not bypass the native safety filter")
        s.threats={}
        TheWorld.Map.IsPassableAtPoint=function(_,x) return x~=6 end
        cmd=assert(Supplies.Plan(player,s,{},request))
        assert(cmd.explore_goal,"water or unknown terrain must not become a pickup detour")
    ''')


def check_darkness_crafting_and_emergency_bounds(previous=None):
    lua=procurement(previous)
    lua.execute('''
        s.phase,s.light.dark="night",true
        s.nearby[1]=raw(920,"sapling",6,{pickable=true})
        local cmd,why=Supplies.Plan(player,s,state,request)
        assert(cmd==nil and why:find("night_light_reserve",1,true),
            "without light a visible far ingredient must not authorize travel: " .. tostring(why))
        s.nearby[1]=raw(921,"sapling",1,{pickable=true})
        cmd=assert(Supplies.Plan(player,s,{},request))
        assert(cmd.intent and cmd.intent.action=="PICK","reachable ingredient remains usable in darkness")
        s.inventory.records={item(922,"cutgrass","inventory",2),item(923,"twigs","inventory",2)}
        has_ingredients=false
        cmd,why=Supplies.Plan(player,s,{},request)
        assert(cmd==nil and why:find("has_ingredients_false",1,true),
            "native HasIngredients still decides whether crafting can be issued")
        buffered=true
        s.inventory.records={}
        cmd=assert(Supplies.Plan(player,s,{},request))
        assert(cmd.intent.kind=="craft","buffered recipe must not pay ingredients twice")
    ''')
    lua=planner(previous)
    lua.execute('''
        local s=first_day()
        s.hunger=0
        local cmd=assert(Survival.Plan(player,s,{}))
        assert(requests[#requests].item~="torch","ongoing starvation retains priority over future light")
        s.inventory.records[2]=item(924,"carrot")
        cmd=assert(Survival.Plan(player,s,{}))
        assert(cmd.intent and cmd.intent.action=="EAT","an owned rescue meal remains immediate")
    ''')


if __name__ == "__main__":
    previous=Path(sys.argv[1]) if len(sys.argv)>1 else None
    failures=0
    for check in (check_first_light_before_bulk_stock,check_visible_missing_ingredient_before_exploring,
                  check_ingredient_approach_and_hazards,check_darkness_crafting_and_emergency_bounds):
        try:
            check(previous)
            print("PASS",check.__name__)
        except LuaError as error:
            failures+=1
            print("FAIL",check.__name__,str(error).splitlines()[0])
    raise SystemExit(1 if failures else 0)
