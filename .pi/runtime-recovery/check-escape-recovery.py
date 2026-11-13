"""Keep emergency retreats responsive after terminal failures and equip existing protection."""
import argparse
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("escape_leg_checks", HERE / "check-retreat-legs.py")
legs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legs)
from lupa.lua51 import LuaError


def fixture(previous=None):
    lua = legs.fixture(previous)
    lua.execute('''
        s.threats={{guid=101,prefab="spider",x=1,z=0,entity=entity(101,"spider")}}
        s.nearby=s.threats
        function add_armor(prefab,kind)
            local armor=item(200,prefab or "armorgrass",kind)
            armor.entity.replica.equippable={EquipSlot=function() return "body" end}
            s.inventory.records={armor}
            s.equipment={body=item(201,"backpack","equipment"),hands=item(202,"torch","equipment")}
            return armor
        end
    ''')
    return lua


def run(lua, source):
    ok, why = lua.execute("local ok,why=pcall(function()\n" + source + "\nend); return ok,tostring(why)",
                          name="@escape-recovery-regression.lua")
    assert ok, why


def check_failure_after_successes(previous=None):
    lua = fixture(previous)
    run(lua, '''
        for _=1,6 do
            local command=assert(Survival.Plan(player,s,state))
            assert(Survival.Report(state,command,"succeeded","arrived"))
        end
        local failed=assert(Survival.Plan(player,s,state))
        assert(Survival.Report(state,failed,"failed","route_blocked:threat_blocked"))
        clock=clock+0.5
        local command,why=Survival.Plan(player,s,state)
        assert(command and command.purpose=="escape:threat",
            "successful route IDs must not disable the next escape after one failure: "..tostring(why))
        assert(command.id~=failed.id,"the retry needs a fresh terminal identity")
        assert(state.survival.blocked["escape:threat"]==nil)
    ''')


def check_repeated_route_failures(previous=None):
    lua = fixture(previous)
    run(lua, '''
        local previous
        for _=1,8 do
            local command,why=Survival.Plan(player,s,state)
            assert(command and command.purpose=="escape:threat",
                "new visible escape opportunities must remain eligible: "..tostring(why))
            assert(command.id~=previous,"each terminated route has a new ID")
            previous=command.id
            assert(Survival.Report(state,command,"failed","route_blocked:threat_blocked"))
            clock=clock+0.5
        end
        -- Only visible relative positions are needed to replay the fatal crowd geometry.
        s.threats={{x=1.022376,z=0.225891,prefab="spider"},
            {x=-2.701569,z=-3.253967,prefab="spider"},
            {x=-14.655388,z=-4.282532,prefab="spider"},
            {x=9.328125,z=-16.617431,prefab="crawlinghorror"},
            {x=-10.650520,z=-16.079834,prefab="spiderden"},
            {x=-11.644218,z=-15.902465,prefab="spider"}}
        local command,why=Survival.Plan(player,s,state)
        assert(command and command.purpose=="escape:threat",
            "observed final scene has a geometrically valid retreat: "..tostring(why))
    ''')


def check_expired_command_recovery(previous=None):
    lua = fixture(previous)
    run(lua, '''
        local old=assert(Survival.Plan(player,s,state))
        clock=clock+Survival.MAX_HOLD+1
        assert(Survival.Report(state,old,"pending","busy"))
        local command,why=Survival.Plan(player,s,state)
        assert(command and command.purpose=="escape:threat" and command.id~=old.id,
            "the route lifetime remains bounded without imposing a long emergency cooldown: "..tostring(why))
        assert(not Survival.Report(state,old,"failed","late receipt"),"a late receipt cannot erase the new route")
        assert(state.survival.active.command.id==command.id)
    ''')


def check_armor_before_close_contact(previous=None):
    lua = fixture(previous)
    run(lua, '''
        local armor=add_armor()
        s.threats[1].x=6
        local command,why=Survival.Plan(player,s,state)
        assert(command and command.intent and command.intent.action=="EQUIP" and command.intent.item==armor.entity,
            "carried armor must be considered before retreat locks out equipment: "..tostring(why))
        assert(command.priority>Survival.PRIORITY_LIGHT and command.priority<Survival.PRIORITY_ESCAPE)
        local same=Survival.Plan(player,s,state)
        assert(same==nil and state.survival.active.id==command.id,"do not send a second equip while pending")
        s.threats[1].x=1
        local escape=assert(Survival.Plan(player,s,state))
        assert(escape.purpose=="escape:threat" and escape.preempt,"imminent contact can interrupt unconfirmed equipment")

        Survival.Cancel(state)
        state={}
        s.threats[1].x=6
        command=assert(Survival.Plan(player,s,state))
        s.equipment.body=armor
        s.inventory.records={item(201,"backpack")}
        assert(Survival.Report(state,command,"succeeded","equipped:body"))
        local escape=assert(Survival.Plan(player,s,state))
        assert(escape.purpose=="escape:threat" and s.equipment.hands.prefab=="torch")
    ''')


def check_safety_and_normal_cooldowns(previous=None):
    for scenario in ("close", "moving", "heavy", "overflow", "blocked", "normal", "dead"):
        lua = fixture(previous)
        lua.globals().scenario = scenario
        run(lua, '''
            local armor=add_armor(scenario=="heavy" and "armormarble" or "armorgrass",
                scenario=="overflow" and "backpack" or "inventory")
            if scenario=="normal" then
                s.threats,s.nearby={},{}
                s.phase,s.time="night",0.9
                s.equipment={}
                s.inventory.records={item(210,"torch")}
                local first=assert(Survival.Plan(player,s,state))
                local stage=state.survival.active.key
                for _=1,3 do
                    local cmd=state.survival.active and state.survival.active.command or Survival.Plan(player,s,state)
                    assert(cmd)
                    assert(Survival.Report(state,cmd,"failed","gave_up:test"))
                end
                assert(state.survival.blocked[stage],"failed non-escape inventory operations still cool down")
                return
            end
            if scenario=="dead" then
                s.health=0
                local cmd=Survival.Plan(player,s,state)
                assert(cmd==nil and state.survival.failed,"death never restarts actions")
                return
            end
            if scenario=="moving" then
                local cmd=assert(Survival.Plan(player,s,state))
                s.threats[1].x=6
                assert(Survival.Plan(player,s,state)==nil and state.survival.active.id==cmd.id,
                    "do not stop an active escape for ordinary protection")
            else
                if scenario~="close" then s.threats[1].x=6 end
                if scenario=="blocked" then
                    s.threats[1].x=1
                    blocked=true
                    for _=1,4 do
                        local cmd,why=Survival.Plan(player,s,state)
                        assert(cmd==nil and why:find("escape:wait",1,true),
                            "unconfirmed terrain must wait without procurement: "..tostring(why))
                    end
                    blocked=false
                end
                local cmd=assert(Survival.Plan(player,s,state))
                assert(cmd.purpose=="escape:threat",
                    scenario..": close contact, slowing armor and overflow-only swaps must preserve movement: "..tostring(cmd.purpose))
            end
        ''')


CHECKS=(check_failure_after_successes, check_repeated_route_failures, check_expired_command_recovery,
        check_armor_before_close_contact, check_safety_and_normal_cooldowns)
if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("previous",nargs="?",type=Path)
    parser.add_argument("--mod-root",type=Path)
    args=parser.parse_args()
    if args.mod_root: legs.movement.baseline.SCRIPTS=args.mod_root/"scripts"
    failed=0
    for check in CHECKS:
        try:
            check(args.previous)
            print("PASS",check.__name__)
        except (AssertionError,LuaError) as error:
            failed+=1
            print("FAIL",check.__name__,str(error).splitlines()[0])
    raise SystemExit(1 if failed else 0)
