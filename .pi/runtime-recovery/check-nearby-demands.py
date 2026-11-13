"""Exercise shared, nearby acquisition through the real survival and supply planners."""
from pathlib import Path
import importlib.util
import re
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
    if previous:
        with zipfile.ZipFile(previous) as archive:
            return archive.read("WilsonExpedition/scripts/wilsonexpedition/" + name + ".lua").decode("utf-8-sig")
    return (stock.base.SCRIPTS / "wilsonexpedition" / (name + ".lua")).read_text(encoding="utf-8-sig")


def fixture(previous=None):
    lua = stock.fixture()
    native = (stock.base.GAME / "data/databundles/scripts/recipes.lua").read_text(encoding="utf-8-sig")
    recipes = {}
    for name in ("torch", "researchlab", "researchlab2", "backpack", "axe", "pickaxe", "rope", "boards", "cutstone", "transistor"):
        match = re.search(r'Recipe2\("' + name + r'",\s*\{(.*?)\},\s*TECH\.([A-Z_]+)', native)
        assert match, "Native recipe unavailable: " + name
        ingredients = re.findall(r'Ingredient\("([a-z_]+)",\s*([0-9]+)\)', match.group(1))
        assert ingredients, "Native ingredients unavailable: " + name
        level = {"NONE": 0, "SCIENCE_ONE": 1, "SCIENCE_TWO": 2}[match.group(2)]
        recipes[name] = '{name="' + name + '",level={SCIENCE=' + str(level) + '},ingredients={' + ",".join(
            '{type="' + item + '",amount=' + count + '}' for item, count in ingredients) + '}}'
    lua.globals().RECIPES_SOURCE = "return {" + ",".join('["' + k + '"]=' + v for k, v in recipes.items()) + "}"
    lua.execute('''
        function Vector3(x,y,z) return {x=x,y=y,z=z} end
        recipes = assert(loadstring(RECIPES_SOURCE))()
        function GetValidRecipe(name) return recipes[name] end
        TheWorld.Map.IsPassableAtPoint = function(_,x) return x~=water_x end
        TheWorld.Map.IsPointNearHole = function(_,point) return point.x==hole_x end
        player.replica.inventory = {
            IsFull = function() return bag_full == true end,
            GetItems = function()
                local result={}
                for _,r in ipairs(s.inventory.records) do result[#result+1]=r.entity end
                return result
            end,
            GetEquips = function() return {} end, GetActiveItem = function() return nil end,
        }
        player.replica.builder = {
            IsBuildBuffered = function(_,name) return name==buffered end,
            KnowsRecipe = function() return true end,
            GetTechTrees = function() return {SCIENCE=0} end,
            IngredientMod = function() return 1 end,
            HasIngredients = function(_,recipe)
                for _,ingredient in ipairs(recipe.ingredients) do
                    local n=0
                    for _,r in ipairs(s.inventory.records) do
                        if r.prefab==ingredient.type then n=n+r.count end
                    end
                    if n<ingredient.amount then return false end
                end
                return true
            end,
        }
        package.loaded["wilsonexpedition/exploration"].Next=function(_,snap)
            explored=(explored or 0)+1
            return {id="frontier:"..explored,x=snap.x+32,z=snap.z,range=1.5}
        end
        package.loaded["wilsonexpedition/exploration"].Report=function() return true end
        function set_owned(prefab,count)
            for i=#s.inventory.records,1,-1 do
                if s.inventory.records[i].prefab==prefab then table.remove(s.inventory.records,i) end
            end
            if count>0 then
                local r=item(700+#s.inventory.records,prefab,"inventory",count)
                r.entity.replica.stackable.IsFull=function() return stack_full==true end
                s.inventory.records[#s.inventory.records+1]=r
                return r
            end
        end
        function plant(guid,prefab,x,z,tags)
            return {entity=entity(guid,prefab,tags or {pickable=true}),guid=guid,prefab=prefab,
                x=x,z=z or 0,distance=math.sqrt((x-s.x)^2+((z or 0)-s.z)^2)}
        end
        function fresh()
            s,state=stock_snapshot(),{}
            s.nearby={}
            s.season=nil
            explored=0
            return s,state
        end
        function no_light()
            for i=#s.inventory.records,1,-1 do
                if s.inventory.records[i].prefab=="torch" then table.remove(s.inventory.records,i) end
            end
            s.time,s.time_until_night=0.05,360
        end
    ''')
    lua.globals().NAVIGATION_SOURCE = source("navigation", previous)
    lua.globals().Supplies = lua.execute(source("supplies", previous))
    lua.execute('package.loaded["wilsonexpedition/supplies"]=Supplies')
    lua.globals().Survival = lua.execute(source("survival", previous))
    lua.execute("fresh()")
    return lua


def check_mixed_recipe_stock_and_food(previous=None):
    lua = fixture(previous)
    lua.execute('''
        no_light()
        set_owned("cutgrass",0); set_owned("twigs",0); set_owned("carrot",1)
        s.nearby={plant(801,"grass",12),plant(802,"sapling",1),plant(803,"carrot_planted",5)}
        local cmd,why=Survival.Plan(player,s,state)
        assert(cmd and cmd.target_guid==802,"noncritical torch preparation must take nearest twigs: "..tostring(why))
        assert(cmd.intent.action=="PICK" and not cmd.intent.confirm(),"PICK requires an actual inventory gain")
        set_owned("twigs",20)
        assert(cmd.intent.confirm(),"confirmed twig gain must complete its acquisition")
        assert(Survival.Report(state,cmd,"succeeded","confirmed_inventory_gain"))
        s.nearby[2].entity.tags.pickable=nil
        cmd,why=Survival.Plan(player,s,state)
        assert(cmd and cmd.target_guid==803,"nearby food must compete with missing torch grass: "..tostring(why))
        assert(Survival.Report(state,cmd,"arrived","arrived"))
        s.x=4
        cmd=assert(Survival.Plan(player,s,state))
        assert(cmd.intent and cmd.intent.action=="PICK" and cmd.target_guid==803,"arrival must proceed to actual food collection")
        set_owned("carrot",8)
        assert(Survival.Report(state,cmd,"succeeded","confirmed_inventory_gain"))
        cmd=assert(Survival.Plan(player,s,state))
        assert(cmd.target_guid~=803,"a satisfied nutritional reserve must leave the shared candidate set")
        set_owned("cutgrass",2)
        assert(Survival.Report(state,cmd,"failed","preempted_for_replan"))
        cmd,why=Survival.Plan(player,s,state)
        assert(cmd and cmd.intent and cmd.intent.kind=="craft" and cmd.intent.recipe=="torch",
            "ready first-night lighting must be crafted before more opportunistic gathering: "..tostring(why))
    ''')


def check_science_materials_and_shared_quantities(previous=None):
    lua = fixture(previous)
    lua.execute('''
        set_owned("log",0); set_owned("goldnugget",0); s.season="autumn"
        s.nearby={plant(811,"log",1,0,{}),plant(812,"carrot_planted",6)}
        set_owned("carrot",1)
        local cmd,why=Survival.Plan(player,s,state)
        assert(cmd and cmd.target_guid==811,"nearby technology material must be acquired while food is still missing: "..tostring(why))
        local demands=state.survival.demands
        local science=false
        for _,r in ipairs(demands) do if r.item=="researchlab2" then science=true end end
        assert(science,"current technology progression must participate in shared demands")
        fresh(); set_owned("goldnugget",0); set_owned("rocks",0); set_owned("log",4)
        s.nearby={plant(814,"goldnugget",1,0,{}),plant(815,"rocks",5,0,{})}
        local laboratory=Supplies.NearbyRequest(player,s,state,{{item="researchlab",count=1}},nil)
        assert(laboratory and laboratory.item=="goldnugget" and laboratory.count==1,
            "science-machine demand must expand the native recipe ingredients")
        fresh(); no_light(); set_owned("twigs",0); set_owned("cutgrass",20); set_owned("flint",8)
        s.nearby={plant(813,"sapling",1)}
        local selected=Supplies.NearbyRequest(player,s,state,{
            {item="torch",count=1},{item="torch",count=1},{item="pickaxe",count=1}},nil)
        assert(selected and selected.item=="twigs" and selected.count==4,
            "independent recipe consumers add their shared ingredients; repeated torch intent is counted once")
        selected=assert(Supplies.NearbyRequest(player,s,state,{
            {item="torch",count=1},{item="pickaxe",count=1},{item="twigs",count=20}},nil))
        assert(selected.count==20,"ordinary stock is a floor rather than an extra recipe consumer")
        set_owned("twigs",20)
        assert(Supplies.NearbyRequest(player,s,state,{{item="twigs",count=20}},nil)==nil,
            "completed material batch must stop generating pickup detours")
        set_owned("flint",0); set_owned("twigs",0); set_owned("goldnugget",0); set_owned("pickaxe",0)
        s.nearby={plant(815,"flint",1,0,{})}
        selected=assert(Supplies.NearbyRequest(player,s,state,{
            {item="pickaxe",count=1},{item="goldnugget",count=1}},nil))
        assert(selected.item=="flint" and selected.count==2,
            "an explicit tool request must also cover the same work prerequisite")
        player.replica.builder.KnowsRecipe=function() return false end
        set_owned("log",0); set_owned("rocks",0)
        s.nearby={plant(816,"goldnugget",1,0,{})}
        selected=assert(Supplies.NearbyRequest(player,s,state,{
            {item="backpack",count=1},{item="researchlab",count=1}},nil))
        assert(selected.item=="goldnugget" and selected.count==1,
            "an explicit science-machine request must also cover the same technology prerequisite")
    ''')


def check_enroute_handoff_and_action_continuity(previous=None):
    lua = fixture(previous)
    lua.execute('''
        set_owned("cutgrass",0); set_owned("twigs",0)
        s.nearby={plant(821,"grass",24)}
        local cmd=assert(Survival.Plan(player,s,state))
        assert(cmd.via=="navigation" and cmd.target_guid==821)
        assert(Survival.Report(state,cmd,"pending","moving"))
        s.x=8
        s.nearby[2]=plant(822,"sapling",9)
        local nextcmd,why=Survival.Plan(player,s,state)
        assert(nextcmd and nextcmd.target_guid==822 and why:find("|preempt=",1,true)
            and state.supplies.last.id==cmd.id,
            "a needed resource met en route must replace the longer walk: "..tostring(why))
        assert(nextcmd.intent and nextcmd.intent.action=="PICK")
        assert(state.supplies.last.reason=="preempted_for_replan","detour must release the old command without marking its target bad")
        assert(Survival.Report(state,nextcmd,"pending","awaiting_confirmation"))
        s.nearby[3]=plant(823,"flint",8.1,0,{})
        set_owned("flint",0)
        local held,heldwhy=Survival.Plan(player,s,state)
        assert(held==nil and state.survival.active.id==nextcmd.id,
            "ordinary demands must not interrupt an issued pickup: "..tostring(heldwhy))
        set_owned("twigs",20)
        assert(Survival.Report(state,nextcmd,"succeeded","confirmed_inventory_gain"))
        local resumed=assert(Survival.Plan(player,s,state))
        assert(resumed.target_guid==823,"next acquisition must use the new actual inventory and nearest deficit")
        fresh(); set_owned("log",0)
        local axe=set_owned("axe",1)
        axe.kind,axe.eslot="equipment","hands"
        s.equipment.hands=axe
        s.nearby={plant(824,"evergreen",.5,0,{CHOP_workable=true})}
        local chop=assert(Survival.Plan(player,s,state))
        assert(chop.via=="actions" and chop.intent.action=="CHOP")
        set_owned("flint",0)
        s.nearby[2]=plant(825,"flint",.1,0,{})
        local continued=Survival.Plan(player,s,state)
        assert(continued==nil and state.survival.active.id==chop.id,
            "a new ordinary supply deficit must not interrupt the current tree's work hold")
        s.hunger=0
        local meal=assert(Survival.Plan(player,s,state))
        assert(meal.intent.action=="EAT" and state.supplies.cmd==nil,
            "starvation may still preempt continuous work immediately")
    ''')


def check_emergency_preemption_and_deadlines(previous=None):
    lua = fixture(previous)
    lua.execute('''
        no_light(); set_owned("cutgrass",0); set_owned("twigs",0); set_owned("carrot",1)
        s.nearby={plant(831,"grass",20),plant(832,"sapling",1),plant(833,"carrot_planted",6)}
        s.hunger=0
        local cmd=assert(Survival.Plan(player,s,state))
        assert(cmd.intent and cmd.intent.action=="EAT","owned starvation food must preempt all shared gathering")
        fresh(); no_light(); set_owned("cutgrass",0); set_owned("twigs",0); set_owned("carrot",1)
        s.phase,s.time_until_night,s.time_until_day="dusk",4,64
        s.nearby={plant(834,"carrot_planted",1),plant(835,"sapling",6)}
        cmd=assert(Survival.Plan(player,s,state))
        assert(cmd.target_guid==835,"imminent darkness must gather torch material instead of nearer ordinary food")
        fresh(); no_light(); set_owned("cutgrass",0); set_owned("twigs",0); set_owned("carrot",1)
        s.nearby={plant(837,"carrot_planted",6),plant(838,"grass",20),plant(839,"sapling",24)}
        cmd=assert(Survival.Plan(player,s,state))
        assert(cmd.via=="navigation" and cmd.target_guid==837,
            "ordinary daylight preparation must include nearer food before the lighting deadline")
        s.time_until_night=90
        local deadline,deadlinewhy=Survival.Plan(player,s,state)
        assert(deadline and deadline.target_guid==838 and deadlinewhy:find("|preempt=",1,true),
            "the lighting deadline must reclaim an ordinary detour already in flight")
        fresh(); set_owned("cutgrass",0)
        s.nearby={plant(836,"grass",1)}
        cmd=assert(Survival.Plan(player,s,state))
        s.threats={{prefab="spider",x=1,z=0,distance=1}}
        local held,why=Survival.Plan(player,s,state)
        assert(held==nil and why:find("escape:wait",1,true),"danger must preempt even an issued collection action")
        assert(state.supplies.cmd==nil,"emergency must release its supply execution slot")
    ''')


def check_safety_capacity_and_tool_prerequisites(previous=None):
    lua = fixture(previous)
    lua.execute('''
        set_owned("cutgrass",0); set_owned("twigs",0)
        local demands={{item="cutgrass",count=20},{item="twigs",count=20}}
        s.nearby={plant(841,"grass",1),plant(842,"sapling",5)}
        s.nearby[1].entity.tags.pickable=nil
        local r=assert(Supplies.NearbyRequest(player,s,state,demands,nil))
        assert(r.guid==842,"depleted nearby resources must not win")
        s.nearby[1].entity.tags.pickable=true
        water_x=1
        r=assert(Supplies.NearbyRequest(player,s,state,demands,nil))
        assert(r.guid==842,"water cannot justify a detour")
        water_x=nil; hole_x=5
        local actions=package.loaded["wilsonexpedition/actions"]
        actions.WORLD_LIMIT,actions.DEFAULT_RANGE,actions.DEFAULT_PRIORITY=100000,1.5,1
        local navigation=assert(loadstring(NAVIGATION_SOURCE))()
        local status,why=navigation.Step(player,s,state,{id="hole-check",x=5,z=0,range=.1})
        assert(status=="failed" and why:find("terrain_near_hole",1,true),"navigation must still reject cave-entry holes")
        hole_x=nil; s.threats={{prefab="spider",x=1,z=0,distance=1}}
        assert(Supplies.NearbyRequest(player,s,state,demands,nil)==nil,"threatened targets must remain excluded")
        s.threats={}; bag_full=true
        assert(Supplies.NearbyRequest(player,s,state,demands,nil)==nil,"full inventory without stack room cannot collect")
        local twigs=set_owned("twigs",1)
        twigs.entity.replica.stackable.MaxSize=function() return 40 end
        twigs.entity.replica.stackable.StackSize=function() return stack_full and 40 or 1 end
        twigs.entity.replica.stackable.CanStackWith=function(_,e) return e.prefab=="twigs" end
        r=assert(Supplies.NearbyRequest(player,s,state,demands,nil))
        assert(r.item=="twigs","full inventory can use room in the same material stack")
        stack_full=true
        assert(Supplies.NearbyRequest(player,s,state,demands,nil)==nil)
        bag_full,stack_full=false,false
        set_owned("log",0); set_owned("axe",0); set_owned("flint",0)
        s.nearby={plant(843,"flint",1,0,{}),plant(844,"evergreen",2,0,{CHOP_workable=true})}
        r=assert(Supplies.NearbyRequest(player,s,state,{{item="log",count=12}},nil))
        assert(r.item=="flint","work requirements must expose currently obtainable tool ingredients")
        s.light.dark=true
        assert(Supplies.NearbyRequest(player,s,state,demands,nil)==nil,"unknown/dark travel keeps existing restrictions")
        fresh(); no_light(); set_owned("cutgrass",0); set_owned("twigs",0)
        s.nearby={plant(845,"grass",12),plant(846,"sapling",1)}
        local chosen=assert(Survival.Plan(player,s,state))
        local key=state.survival.active.key
        assert(chosen.target_guid==846)
        assert(Survival.Report(state,chosen,"failed","target_temporarily_unavailable"))
        state.survival.blocked[key]=GetTime()+30
        Supplies.Plan(player,s,state,{id="independent-request",item="log",count=12})
        local alternative=assert(Survival.Plan(player,s,state))
        assert(alternative.target_guid~=846,"switching requests must not bypass the scheduler's failed-target cooldown")
    ''')


CHECKS = (check_mixed_recipe_stock_and_food, check_science_materials_and_shared_quantities,
          check_enroute_handoff_and_action_continuity, check_emergency_preemption_and_deadlines,
          check_safety_capacity_and_tool_prerequisites)
if __name__ == "__main__":
    previous = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    failures = 0
    for check in CHECKS:
        try:
            check(previous)
            print("PASS", check.__name__)
        except LuaError as error:
            failures += 1
            print("FAIL", check.__name__, str(error).splitlines()[0])
    raise SystemExit(bool(failures))
