"""Replay pig pursuit range and lost-contact retreat using native Lua and visible snapshots."""

import importlib.util
from pathlib import Path
import re
import sys
import zipfile

BASE = Path(__file__).parent
spec = importlib.util.spec_from_file_location("movement_checks", BASE / "check-move-continuity.py")
movement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(movement)
from lupa.lua51 import LuaError

GAME = movement.baseline.GAME
NATIVE = GAME / "data/databundles/scripts"
TUNING = (NATIVE / "tuning.lua").read_text(encoding="utf-8-sig")
PIG_TARGET_DIST = float(re.search(r"\bPIG_TARGET_DIST\s*=\s*([\d.]+)", TUNING)[1])
SPRING_COMBAT_MOD = float(re.search(r"\bSPRING_COMBAT_MOD\s*=\s*([\d.]+)", TUNING)[1])
OLD = {}
if len(sys.argv) == 3 and sys.argv[1] == "--old":
    with zipfile.ZipFile(sys.argv[2]) as archive:
        OLD = {name: archive.read("client/scripts/wilsonexpedition/" + name + ".lua").decode("utf-8-sig")
               for name in ("observer", "navigation", "survival")}


def load(lua, name):
    if name in OLD:
        lua.globals().source = OLD[name]
        result = lua.execute("return assert(loadstring(source))()")
        lua.globals().package.loaded["wilsonexpedition/" + name] = result
        return result
    return lua.eval("require")("wilsonexpedition/" + name)


def tune(lua):
    lua.globals().TUNING.PIG_TARGET_DIST = PIG_TARGET_DIST
    lua.globals().TUNING.SPRING_COMBAT_MOD = SPRING_COMBAT_MOD


def fixture():
    lua = movement.baseline.runtime()
    tune(lua)
    lua.execute('''
        stub_planners()
        package.loaded["wilsonexpedition/exploration"].BaseGoal = function() return nil end
        package.loaded["wilsonexpedition/navigation"] = nil
        function Vector3(x, y, z) return { x = x, y = y, z = z } end
        TheWorld.Map.IsOceanAtPoint = function() return false end
        TheWorld.Map.IsPassableAtPoint = function() return true end
        TheWorld.Map.IsPointNearHole = function() return false end
        TheWorld.Pathfinder = { IsClear = function() return true end }
        s, state = snapshot(), {}
        pig = { guid = 81, prefab = "pigman", x = 5, z = 0,
            entity = entity(81, "pigman", { werepig = true }) }
        s.threats, s.nearby = { pig }, { pig }
    ''')
    lua.globals().Navigation = load(lua, "navigation")
    lua.globals().Survival = load(lua, "survival")
    return lua


def check_native_pig_visibility():
    native = (NATIVE / "prefabs/pigman.lua").read_text(encoding="utf-8-sig")
    common = re.search(r"local function common\(moonbeast\)(.*?)if moonbeast then", native, re.S)[1]
    normal = {tag: True for tag in re.findall(r'inst:AddTag\("([^\"]+)"\)', common)}
    transform = re.search(r"local function SetWerePig\(inst\)(.*?)^end", native, re.M | re.S)[1]
    were = dict(normal)
    for tag in re.findall(r'inst:AddTag\("([^\"]+)"\)', transform):
        were[tag] = True
    for tag in re.findall(r'inst:RemoveTag\("([^\"]+)"\)', transform):
        were.pop(tag, None)
    moon = dict(normal)
    moon_block = native.split("local function common(moonbeast)", 1)[1].split("if moonbeast then", 1)[1].split("else", 1)[0]
    for tag in re.findall(r'inst:AddTag\("([^\"]+)"\)', moon_block):
        moon[tag] = True
    assert were.get("werepig") and not were.get("hostile") and moon.get("hostile")
    lua = movement.baseline.runtime()
    for name, tags in (("NORMAL_TAGS", normal), ("WERE_TAGS", were), ("MOON_TAGS", moon)):
        lua.globals()[name] = lua.table_from(tags)
    lua.execute('''
        TheWorld.state = { phase = "day", isday = true, season = "autumn", time = 0.3, cycles = 2 }
        function TheWorld:HasTag(tag) return tag == "forest" end
        function player:IsInLight() return true end
        normal = entity(81, "pigman", NORMAL_TAGS)
        were = entity(82, "pigman", WERE_TAGS)
        moon = entity(83, "pigman", MOON_TAGS)
        normal.Transform.GetWorldPosition = function() return 3, 0, 0 end
        were.Transform.GetWorldPosition = function() return 6, 0, 0 end
        moon.Transform.GetWorldPosition = function() return 9, 0, 0 end
        TheSim = { FindEntities = function() return { normal, were, moon, player } end,
            GetLightAtPoint = function() return 1 end, GetAmbientColour = function() return 200, 200, 200 end }
    ''')
    movement.baseline.observer_view_fixture(lua)
    lua.globals().Observer = load(lua, "observer")
    lua.execute('''
        local s = Observer.Observe(player, {})
        assert(#s.threats == 2 and s.threats[1].guid == 82 and s.threats[2].guid == 83,
            "native werepig and moonpig must both be identified before contact")
        assert(#s.nearby == 3 and not s.nearby[1].threat, "ordinary visible pig must remain neutral")
        were.tags = NORMAL_TAGS
        s = Observer.Observe(player, {})
        assert(#s.threats == 1 and s.threats[1].guid == 83,
            "observed reversal to an ordinary pig must release its threat status")
    ''')


def check_native_acquisition():
    source = (NATIVE / "prefabs/pigman.lua").read_text(encoding="utf-8-sig")
    retarget = re.search(r"^local function WerepigRetargetFn\(inst\).*?^end", source, re.M | re.S)[0]
    for prefab in ("pigman", "moonpig"):
        lua = movement.fixture("remote_prediction", [(30, 0)])
        tune(lua)
        lua.globals().Navigation = load(lua, "navigation")
        lua.globals().pig_prefab = prefab
        lua.execute('''
            function SpringCombatMod(n) return n * TUNING.SPRING_COMBAT_MOD end
            function FindEntity(_, distance) native_acquisition = distance end
        ''' + retarget + '''
            WerepigRetargetFn({})
            -- This segment approaches a pig beyond the old seven-metre safety circle.
            TheWorld.Pathfinder.IsClear = function() return true end
            threats = { { guid = 81, prefab = pig_prefab, x = 15, z = 15 } }
            goal.x = 10
            Navigation.Step(player, snapshot_at(), state, goal)
            assert(dispatches == 0, "must reject approach inside native pig acquisition range")
            assert(Navigation.THREAT_RADII[pig_prefab] > native_acquisition)
            goal = { id = "away", x = -20, z = 0, range = 1.5 }
            Navigation.Step(player, snapshot_at(), state, goal)
            assert(dispatches == 1, "safe retreat inside acquisition range must remain possible")
        ''')


def check_preempt_pursuit():
    lua = fixture()
    lua.execute('''
        pig.x = 10.7
        s.health, s.hunger = 0.2, 0.34
        state.survival = { world = "test_world|surface", active = {
            id = "food", key = "food", purpose = "landmark:berrybush2", owner = "supplies",
            priority = 10, via = "navigation", command = { id = "food" }, t = clock,
        } }
        local command = Survival.Plan(player, s, state)
        assert(command and command.purpose == "escape:threat",
            "must preempt ordinary food travel while pig pursuit remains close")
        assert(command.goal.x < s.x)
    ''')


def check_lost_contact():
    lua = fixture()
    lua.execute('''
        local command = Survival.Plan(player, s, state)
        assert(command and command.purpose == "escape:threat")
        assert(Survival.Report(state, command, "succeeded", "arrived"))
        s.x, s.threats, s.nearby = -8, {}, {}
        local seen_x = pig.x
        -- Hidden state must never be consulted after this point.
        pig.entity.HasTag = function() error("hidden tag read") end
        pig.entity.IsValid = function() error("hidden validity read") end
        pig.entity.Transform.GetWorldPosition = function() error("hidden position read") end
        clock = clock + 1
        command = Survival.Plan(player, s, state)
        assert(command and command.purpose == "escape:threat",
            "lost torch visibility must preserve retreat after waypoint arrival")
        assert(command.goal.x < s.x, "retreat must continue away from the last visible position")
        assert(#s.threats == 0 and #s.nearby == 0, "visible observations must stay unchanged")
        local contact = state.survival.retreat_contact
        assert(contact.x == seen_x and contact.entity == nil and contact.t == 100)
        assert(Survival.Report(state, command, "succeeded", "arrived"))
        s.x, clock = -30, clock + 1
        command = Survival.Plan(player, s, state)
        assert(command and command.purpose == "escape:threat",
            "distance from stale coordinates does not establish current enemy separation")
        assert(state.survival.retreat_contact.t == 100, "memory alone must not renew its own lifetime")
    ''')


def check_visible_clearance():
    lua = fixture()
    lua.execute('''
        local command = Survival.Plan(player, s, state)
        assert(Survival.Report(state, command, "succeeded", "arrived"))
        pig.x = 24
        command = Survival.Plan(player, s, state)
        assert(command and command.purpose == "escape:threat",
            "visible pig must retain retreat until acquisition clearance is reached")
        assert(Survival.Report(state, command, "succeeded", "arrived"))
        pig.x = 29
        command = Survival.Plan(player, s, state)
        assert(not command or command.purpose ~= "escape:threat")
        assert(state.survival.retreat_contact == nil and state.survival.retreat_guid == nil)
    ''')


def check_contact_release():
    for reason in ("timeout", "neutral", "session", "shard"):
        lua = fixture()
        lua.globals().reason = reason
        lua.execute('''
            local command = Survival.Plan(player, s, state)
            assert(Survival.Report(state, command, "succeeded", "arrived"))
            s.threats = {}
            if reason == "timeout" then s.nearby, clock = {}, clock + 16
            elseif reason == "neutral" then pig.threat = false
            elseif reason == "session" then s.nearby, s.session = {}, "another_world"
            elseif reason == "shard" then s.nearby, s.shard = {}, "cave" end
            command = Survival.Plan(player, s, state)
            assert(not command or command.purpose ~= "escape:threat", reason)
            assert(state.survival.retreat_contact == nil and state.survival.retreat_guid == nil, reason)
        ''')


def check_reacquired_position():
    lua = fixture()
    lua.execute('''
        local command = Survival.Plan(player, s, state)
        assert(Survival.Report(state, command, "succeeded", "arrived"))
        s.nearby, s.threats, clock = {}, {}, clock + 1
        command = Survival.Plan(player, s, state)
        assert(Survival.Report(state, command, "succeeded", "arrived"))
        pig.x, s.threats, clock = -5, { pig }, clock + 1
        command = Survival.Plan(player, s, state)
        assert(command and command.purpose == "escape:threat")
        assert(command.goal.x > s.x, "new visible position must override stale escape direction")
        assert(state.survival.retreat_contact.x == -5 and state.survival.retreat_contact.t == clock)
    ''')


checks = (check_native_pig_visibility, check_native_acquisition, check_preempt_pursuit, check_lost_contact,
          check_visible_clearance, check_contact_release, check_reacquired_position)
expected = {
    "check_native_pig_visibility": "native werepig and moonpig must both be identified before contact",
    "check_native_acquisition": "must reject approach inside native pig acquisition range",
    "check_preempt_pursuit": "must preempt ordinary food travel while pig pursuit remains close",
    "check_lost_contact": "lost torch visibility must preserve retreat after waypoint arrival",
    "check_visible_clearance": "visible pig must retain retreat until acquisition clearance is reached",
}
for check in checks:
    if OLD and check.__name__ not in expected:
        continue
    try:
        check()
    except LuaError as error:
        if not OLD or expected[check.__name__] not in str(error):
            raise
        print("REPRODUCED", check.__name__, str(error).splitlines()[0])
    else:
        if OLD:
            raise AssertionError("Archived source unexpectedly passed " + check.__name__)
        print("PASS", check.__name__)
