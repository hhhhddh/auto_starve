"""Exercise visible terrain memory and resource-directed exploration through real planners."""
from pathlib import Path
import importlib.util
import sys
import zipfile

HERE = Path(__file__).resolve().parent


def load_check(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


screen = load_check("check-screen-food-memory")
nearby = load_check("check-nearby-demands")
base = screen.base
from lupa.lua51 import LuaError


def source(name, previous=None):
    if previous:
        with zipfile.ZipFile(previous) as archive:
            return archive.read("WilsonExpedition/scripts/wilsonexpedition/" + name + ".lua").decode("utf-8-sig")
    return (base.SCRIPTS / "wilsonexpedition" / (name + ".lua")).read_text(encoding="utf-8-sig")


def fixture(previous=None):
    screen.OBSERVER = source("observer", previous)
    lua = screen.observation_fixture()
    lua.globals().EXPLORATION_SOURCE = source("exploration", previous)
    lua.execute('''
        function Vector3(x,y,z) return {x=x,y=y,z=z} end
        WORLD_TILES={FOREST=1,GRASS=2,ROCKY=3,DIRT=4,SAVANNA=5,MARSH=6,DECIDUOUS=7,DESERT_DIRT=8}
        px,pz=0,0
        player.Transform.GetWorldPosition=function() return px,0,pz end
        tile_reads={}
        tile_at=function() return WORLD_TILES.FOREST end
        TheWorld.Map.GetTileAtPoint=function(_,x,_,z)
            tile_reads[#tile_reads+1]={x=x,z=z}
            return tile_at(x,z)
        end
        TheWorld.Map.IsPassableAtPoint=function(_,x) return x~=water_x end
        TheWorld.Map.IsOceanAtPoint=function(_,x) return x==water_x end
        TheWorld.Map.IsPointNearHole=function(_,point) return point.x==hole_x end
        package.loaded["wilsonexpedition/observer"]=Observer
        Exploration=assert(loadstring(EXPLORATION_SOURCE))()
        state={}
        function refresh()
            local observed=Observer.Observe(player,{})
            s=snapshot()
            s.x,s.z,s.view,s.terrain=px,pz,observed.view,observed.terrain
            s.shard_kind="surface"
            s.time_until_night=360
            return s
        end
        function record()
            return state.explore_memory.worlds[state.explore.world_key]
        end
        refresh()
    ''')
    return lua


def check_gold_terrain_over_unsuitable_landmarks(previous=None):
    native = (base.GAME / "data/databundles/scripts/map/rooms/forest/terrain_rocky.lua").read_text(encoding="utf-8-sig")
    assert "WORLD_TILES.ROCKY" in native and "rock2" in native
    lua = fixture(previous)
    lua.execute('''
        tile_at=function(x,z) return x>=12 and math.abs(z)<6 and WORLD_TILES.ROCKY or WORLD_TILES.GRASS end
        refresh()
        s.landmarks={passage={{x=-8,z=0}}}
        Exploration.Observe(player,s,state)
        local goal=assert(Exploration.Next(player,s,state,"goldnugget"))
        assert(goal.kind=="resource" and goal.x>=12 and math.abs(goal.z)<6,
            "gold acquisition must prefer observed rocky terrain over a nearby grassy passage")
        local held=assert(Exploration.Next(player,s,state,"goldnugget"))
        assert(held.id==goal.id,"resource planning must retain an in-flight destination")
        assert(Exploration.Report(state,goal,"arrived","arrived"))
        local cell=record().cells[string.format("%d|%d",math.floor(goal.x/4),math.floor(goal.z/4))]
        assert(cell.resource_checks.goldnugget==true,"completed searches must be recorded separately from footsteps")
    ''')


def check_known_terrain_after_travel_and_reload(previous=None):
    lua = fixture(previous)
    lua.execute('''
        view_half_width=120
        tile_at=function(x,z) return x>=55 and x<=65 and math.abs(z)<5 and WORLD_TILES.ROCKY or WORLD_TILES.FOREST end
        refresh()
        Exploration.Observe(player,s,state)
        local remembered=record()
        -- A previously walked mining region is still useful before it has been searched for gold.
        remembered.cells["15|0"]={gx=15,gz=0,visits=1,picks=0,seq=1}
        state={explore_memory=state.explore_memory}
        view_half_width=20
        refresh()
        local goal=assert(Exploration.Next(player,s,state,"goldnugget"))
        assert(goal.kind=="resource" and goal.x==60 and math.abs(goal.z)<0.1,
            "persisted suitable terrain outside the current view must guide travel even if previously walked")
        local arrived=goal
        assert(Exploration.Report(state,arrived,"arrived","arrived"))
        local another=assert(Exploration.Next(player,s,state,"goldnugget"))
        assert(another.x~=arrived.x or another.z~=arrived.z,
            "a searched empty mining cell must not immediately attract the same request")
    ''')


def check_frontiers_and_screen_light_boundaries(previous=None):
    lua = fixture(previous)
    lua.execute('''
        tile_at=function(x,z) return x>100 and WORLD_TILES.ROCKY or WORLD_TILES.FOREST end
        refresh()
        tile_reads={}
        local goal=assert(Exploration.Next(player,s,state,"goldnugget"))
        assert(goal.kind=="terrain","without a known mining region the goal must explore terrain rather than assume gold exists")
        assert(#tile_reads>0,"visible ground may be queried to guide a terrain frontier")
        for _,point in ipairs(tile_reads) do
            assert(math.abs(point.x)<=50 and math.abs(point.z)<=35,"terrain planning must not query hidden map tiles")
        end
        tile_reads={}
        TheSim.GetLightAtPoint=function() return 0 end
        local observed=Observer.Observe(player,{})
        assert(type(observed.terrain)=="table" and #observed.terrain==0 and #tile_reads==0,
            "dark ground must not create terrain observations or query hidden tile identities")
        night_vision=true
        observed=Observer.Observe(player,{})
        assert(#observed.terrain>0,"native night vision must permit visible terrain observations")
        in_storm=true
        tile_reads={}
        observed=Observer.Observe(player,{})
        for _,point in ipairs(tile_reads) do assert(point.x^2+point.z^2<=196,"native storm range must bound ground observations") end
        assert(#observed.terrain>0,"nearby visible ground must remain observable in a storm")
    ''')


def check_memory_dirtiness_bounds_and_shards(previous=None):
    lua = fixture(previous)
    lua.execute('''
        Exploration.Observe(player,s,state)
        local first=record()
        local count=first.n_cells
        s.terrain={{x=16,z=0,tile=WORLD_TILES.MARSH}}
        assert(Exploration.Observe(player,s,state),"newly seen ground while stationary must enter the next save cycle")
        assert(first.n_cells==count,"viewed terrain must not inflate actual travel history")
        local points={}
        for i=1,600 do points[i]={x=i*4,z=80,tile=WORLD_TILES.GRASS} end
        s.terrain=points
        Exploration.Observe(player,s,state)
        local actual=0
        for _,point in pairs(first.terrain_tiles) do
            actual=actual+1
            for _,value in pairs(point) do assert(type(value)=="number","persistent ground observations must contain plain numbers") end
        end
        assert(actual==Exploration.MAX_TERRAIN and first.n_terrain==actual,"terrain memory must retain its independent finite cap")
        s.shard,s.shard_kind,s.session,s.terrain="cave:2","cave","cave-session",{}
        Exploration.Observe(player,s,state)
        assert(record()~=first and record().terrain_tiles==nil,"terrain observations must remain scoped to their world and shard")
    ''')


def supply_fixture(previous=None):
    lua = nearby.fixture(previous)
    lua.globals().Supplies = lua.execute(source("supplies", previous))
    lua.execute('''
        s.shard,s.shard_kind="surface:1","surface"
        s.health,s.hunger,s.time_until_night=1,1,360
        set_owned("goldnugget",0)
        set_owned("pickaxe",1)
        s.nearby={}
        package.loaded["wilsonexpedition/exploration"].Next=function(_,snap,st,resource)
            calls_to_explore=(calls_to_explore or 0)+1
            explored_resource=resource
            return {id="planned-frontier",x=32,z=0,range=1.5}
        end
        function plan_gold()
            state={}
            calls_to_explore=0
            explored_resource=nil
            return Supplies.Plan(player,s,state,{item="goldnugget",count=1,id="gold"})
        end
    ''')
    return lua


def check_supply_priority_and_emergency_boundaries(previous=None):
    lua = supply_fixture(previous)
    lua.execute('''
        local cmd=assert(plan_gold())
        assert(cmd.explore_goal and explored_resource=="goldnugget",
            "a safe stocked surface character must pass its actual missing resource into terrain planning")
        s.hunger=0.1
        assert(plan_gold())
        assert(explored_resource==nil,"emergency hunger must retain generic rescue exploration")
        s.hunger=1;set_owned("torch",0)
        assert(plan_gold())
        assert(explored_resource==nil,"first lighting preparation must not become a cross-biome expedition")
        set_owned("torch",1);s.time_until_night=90
        assert(plan_gold())
        assert(explored_resource==nil,"lighting deadlines must prevent long terrain planning")
        s.time_until_night=360;s.shard_kind="cave"
        assert(plan_gold())
        assert(explored_resource==nil,"surface terrain associations must not be applied to caves")
        s.shard_kind="surface"
        s.nearby={plant(900,"goldnugget",0.5,0,{})}
        local pickup=assert(plan_gold())
        assert(pickup.via=="actions" and pickup.intent.action=="PICKUP" and calls_to_explore==0,
            "an actually visible gold drop must be acquired on any terrain before further exploration")
        s.nearby={}
        s.shard_memory={cats={resource={{prefab="rock2",x=25,z=0}}}}
        local known=assert(plan_gold())
        assert(known.landmark_key and calls_to_explore==0,"a known real resource landmark must precede terrain scouting")
    ''')


def main():
    previous = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    checks = [check_gold_terrain_over_unsuitable_landmarks, check_known_terrain_after_travel_and_reload,
              check_frontiers_and_screen_light_boundaries, check_memory_dirtiness_bounds_and_shards,
              check_supply_priority_and_emergency_boundaries]
    failures = 0
    for check in checks:
        try:
            check(previous)
            print("PASS", check.__name__)
        except (AssertionError, LuaError) as exc:
            failures += 1
            print("FAIL", check.__name__, str(exc).splitlines()[0])
    if failures:
        raise SystemExit(1)
    print("Terrain-guided resource planning regressions passed")


if __name__ == "__main__":
    main()
