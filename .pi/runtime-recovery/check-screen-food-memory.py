"""Screen-limited perception, persistent depletion and food/progression regressions."""

import importlib.util
from pathlib import Path
import sys
import zipfile

HERE = Path(__file__).resolve().parent


def load_check(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


base = load_check("check-death-iteration")
stock = load_check("check-stock-batching")
empty = load_check("check-empty-landmarks")
OBSERVER = (base.SCRIPTS / "wilsonexpedition/observer.lua").read_text(encoding="utf-8-sig")
SUPPLIES = (base.SCRIPTS / "wilsonexpedition/supplies.lua").read_text(encoding="utf-8-sig")
SURVIVAL = (base.SCRIPTS / "wilsonexpedition/survival.lua").read_text(encoding="utf-8-sig")


def observation_fixture():
    lua = base.runtime()
    base.observer_view_fixture(lua)
    lua.globals().OBSERVER_SOURCE = OBSERVER
    lua.execute('''
        TheWorld.state = { cycles=2, time=0.3, phase="day", season="autumn" }
        function TheWorld:HasTag(tag) return tag == "forest" end
        function placed(id, prefab, tags, x, z)
            local e = entity(id, prefab, tags)
            e.Transform.GetWorldPosition = function() return x, 0, z end
            return e
        end
        actors, queries = {}, {}
        function TheSim:FindEntities(x, y, z, radius)
            queries[#queries+1] = radius
            local found = {}
            for _, e in ipairs(actors) do
                local ex, _, ez = e.Transform:GetWorldPosition()
                if (ex-x)^2+(ez-z)^2 <= radius^2 then found[#found+1] = e end
            end
            return found
        end
        TheSim.GetAmbientColour = function() return 200, 200, 200 end
        Observer = assert(loadstring(OBSERVER_SOURCE))()
    ''')
    return lua


def check_camera_edges_zoom_rotation_and_density():
    lua = observation_fixture()
    lua.execute('''
        for i=1,80 do actors[#actors+1] = placed(i+100, "grass", {pickable=true}, 34+i*0.1, 0) end
        local threat = placed(300, "spider", {hostile=true}, 48, 0)
        local edge = placed(301, "grass", {pickable=true}, 51, 0)
        edge.screen_padding = 20
        local hidden = placed(302, "grass", {pickable=true}, 2, 0)
        hidden.render_visible = false
        actors[#actors+1], actors[#actors+2] = threat, edge
        actors[#actors+1], actors[#actors+2] = hidden, placed(303, "grass", {pickable=true}, 70, 0)
        local memory = {}
        local s = Observer.Observe(player, memory)
        assert(#s.nearby == 82 and #s.threats == 1,
            "visible screen edges and the threat after entity 64 must all be observed")
        assert(s.view and s.view.radius > 51 and s.threats[1].entity == threat)
        view_half_width, view_half_height = 20, 14
        s = Observer.Observe(player, memory)
        assert(#s.nearby == 0, "zoomed-in perception must exclude loaded offscreen entities")
        view_half_width, view_half_height, view_rotation = 50, 20, math.pi/2
        local rotated = placed(304, "grass", {pickable=true}, 0, 45)
        actors = { rotated, threat }
        s = Observer.Observe(player, memory)
        assert(#s.nearby == 1 and s.nearby[1].entity == rotated,
            "the actual rotated screen footprint must control perception")
        TheSim.ProjectScreenPos = nil
        s = Observer.Observe(player, memory)
        assert(not s.ready and s.ready_reason == "view_unavailable" and #s.nearby == 0,
            "missing camera data must not fall back to omniscient fixed-radius observation")
    ''')


def check_vanilla_darkness_nightvision_storm_and_ink():
    lua = observation_fixture()
    lua.execute('''
        actors = { placed(400, "spider", {hostile=true}, 18, 0) }
        TheSim.GetLightAtPoint = function() return 0 end
        assert(#Observer.Observe(player, {}).nearby == 0,
            "dark loaded entities must not count as visible observations")
        night_vision = true
        assert(#Observer.Observe(player, {}).threats == 1, "native night vision must reveal visible threats")
        in_storm = true
        assert(#Observer.Observe(player, {}).nearby == 0, "native storm range must restrict distant sight")
        goggle_vision = true
        assert(#Observer.Observe(player, {}).threats == 1, "goggle vision must restore native storm sight")
        player.components.inkable = { inked=true }
        assert(#Observer.Observe(player, {}).nearby == 0, "native ink blindness must remain effective")
    ''')


def check_landmark_capacity_depletion_and_pure_persistence():
    lua = observation_fixture()
    lua.execute('''
        view_half_width = 3000
        for i=1,530 do actors[i] = placed(500+i, "grass", {pickable=true,plant=true}, i*4, 0) end
        local memory = {}
        local s = Observer.Observe(player, memory)
        local records = s.shard_memory.cats.resource
        assert(#records == 512, "the 48-landmark limit must not discard a normal visible resource field")
        for _, r in ipairs(records) do
            assert(r.entity == nil and r.GUID == nil and type(r.x) == "number",
                "persistent resource records must contain plain values only")
        end
        local plant = actors[#actors]
        plant.tags.pickable = false
        s = Observer.Observe(player, memory)
        local depleted = nil
        for _, r in ipairs(s.shard_memory.cats.resource) do if r.x == 530*4 then depleted = r end end
        assert(depleted and depleted.pickable == false, "depleted state must be persisted after visible harvest")
        actors = {}
        s = Observer.Observe(player, memory)
        assert(depleted.pickable == false, "offscreen memory must retain its last witnessed depleted state")
        plant.tags.pickable = true
        actors = { plant }
        s = Observer.Observe(player, memory)
        assert(depleted.pickable == true and s.memory_added > 0,
            "a visible regrowth transition must restore and dirty the saved source")
    ''')


def check_cross_request_empty_and_unreachable_memory():
    lua = empty.fixture(SUPPLIES)
    lua.execute('''
        s.shard_memory = { cats = { resource = { {prefab="grass",x=25,z=0,pickable=false} } } }
        local first = Supplies.Plan(player, s, state, request)
        assert(not first or not first.landmark_key,
            "a visibly depleted source must not be approached as an available landmark")
        if first then Supplies.Report(state,first,"failed","preempted_for_replan") end
        s.shard_memory.cats.resource[1].pickable = true
        request = { item="cutgrass",count=1,id="regrown" }
        local cmd = assert(Supplies.Plan(player,s,state,request))
        assert(cmd.landmark_key, "observed regrowth must restore harvesting")
        assert(Supplies.Report(state,cmd,"failed","unreachable"))
        assert(next(state.supplies.stale) ~= nil, "the failed landmark must receive a retry exclusion")
        request = {item="twigs",count=1,id="other-resource"}
        local other = Supplies.Plan(player,s,state,request)
        if other then Supplies.Report(state,other,"failed","preempted_for_replan") end
        request = {item="cutgrass",count=1,id="same-resource-again"}
        local after = Supplies.Plan(player,s,state,request)
        assert(next(state.supplies.stale) ~= nil and (not after or not after.landmark_key),
            "switching procurement requests must not erase unreachable landmark exclusions")
    ''')


def food_fixture():
    stock.SOURCE = Path(base.SCRIPTS / "wilsonexpedition/survival.lua")
    stock.light.SOURCE = stock.SOURCE
    lua = stock.fixture()
    lua.globals().SURVIVAL_SOURCE = SURVIVAL
    lua.execute('''
        Survival = assert(loadstring(SURVIVAL_SOURCE))()
        function no_progression(s)
            s.season = nil
            for _, prefab in ipairs({"axe","pickaxe","researchlab","backpack","spear","armorwood"}) do
                owned(s,prefab,1)
            end
            s.equipment[EQUIPSLOTS.BODY] = owned(s,"backpack",1)
        end
    ''')
    return lua


def check_food_yields_to_progression_and_has_shared_budget():
    lua = food_fixture()
    lua.execute('''
        local s,state = stock_snapshot(),{}
        owned(s,"carrot",0)
        local cmd = assert(Survival.Plan(player,s,state))
        assert(cmd.purpose == "request:researchlab2",
            "a fed character must advance facilities before filling future food stock")
        s,state = stock_snapshot(),{}
        no_progression(s)
        owned(s,"carrot",0)
        cmd = assert(Survival.Plan(player,s,state))
        assert(state.survival.active and state.survival.active.key:find("reserve:food:",1,true),
            "ordinary food gathering must remain available after progression")
        clock = 161
        Survival.Plan(player,s,state)
        assert(not state.survival.active or not state.survival.active.key:find("reserve:food:",1,true),
            "ordinary food search must yield after its shared no-harvest budget")
        s.hunger = 0
        for i=#s.inventory.records,1,-1 do
            if s.inventory.records[i].count == 0 then table.remove(s.inventory.records,i) end
        end
        cmd = assert(Survival.Plan(player,s,state))
        assert(state.survival.active.priority >= Survival.PRIORITY_STARVE,
            "actual starvation must override the ordinary food-search cooldown")
    ''')


def check_surface_food_sources_do_not_search_caves():
    lua = food_fixture()
    lua.execute('''
        local s,state = stock_snapshot(),{}
        owned(s,"carrot",0)
        s.hunger,s.shard_kind = 0,"surface"
        package.loaded["wilsonexpedition/supplies"].Plan = function(_,_,_,request)
            requests[#requests+1] = request
            return nil,"no_viable_source"
        end
        for i=#s.inventory.records,1,-1 do
            if s.inventory.records[i].count == 0 then table.remove(s.inventory.records,i) end
        end
        for i=1,35 do
            local cmd = Survival.Plan(player,s,state)
            if cmd then Survival.Report(state,cmd,"failed","source_not_found") end
        end
        local seen={}
        for _, r in ipairs(requests) do
            seen[r.item]=true
            assert(r.item ~= "cave_banana", "surface starvation must not send the character searching for cave bananas")
            assert(r.item ~= "seeds" and r.item ~= "seeds_cooked", "food rotation must preserve the seed policy")
        end
        for _, item in ipairs({"berries","carrot","berries_juicy"}) do
            assert(seen[item], "failure replay must actually try every directly edible surface food: " .. item)
        end
    ''')


CHECKS = (check_camera_edges_zoom_rotation_and_density, check_vanilla_darkness_nightvision_storm_and_ink,
          check_landmark_capacity_depletion_and_pure_persistence, check_cross_request_empty_and_unreachable_memory,
          check_food_yields_to_progression_and_has_shared_budget, check_surface_food_sources_do_not_search_caves)

if __name__ == "__main__":
    if len(sys.argv) == 2:
        with zipfile.ZipFile(sys.argv[1]) as archive:
            OBSERVER = archive.read("client/scripts/wilsonexpedition/observer.lua").decode("utf-8-sig")
            SUPPLIES = archive.read("client/scripts/wilsonexpedition/supplies.lua").decode("utf-8-sig")
            SURVIVAL = archive.read("client/scripts/wilsonexpedition/survival.lua").decode("utf-8-sig")
    failures = 0
    for check in CHECKS:
        try:
            check()
        except Exception as error:
            failures += 1
            print("FAIL", check.__name__, str(error).encode("ascii", "backslashreplace").decode("ascii"))
        else:
            print("PASS", check.__name__)
    raise SystemExit(bool(failures))
