"""Check read-only runtime task summaries and next-start world event settings."""
from pathlib import Path
import importlib.util
import inspect
import sys
import tempfile
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("death_checks", HERE / "check-death-iteration.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
sys.path.insert(0, str(base.PROJECT / "development-support/nbot-relay"))
import iteration


def fixture():
    lua = base.runtime()
    lua.execute('''
        stub_planners()
        package.loaded["wilsonexpedition/actions"] = {}
        package.loaded["wilsonexpedition/survival"] = { Cancel=function() end }
        package.loaded["wilsonexpedition/trace"] = {}
        package.loaded["wilsonexpedition/revision"] = "test:build"
        package.loaded["json"] = {encode=function() return "{}" end}
        TheSim = {GetPersistentString=function(_,_,cb) cb(false,"") end}
        TheInput = {AddKeyUpHandler=function() error("display must not register execution hotkeys") end}
        function player:ListenForEvent() end
        function player:DoPeriodicTask() return {Cancel=function() task_cancelled=true end} end
        Runtime = require("wilsonexpedition/runtime")
        current=Runtime.Attach(player)
    ''')
    return lua


def check_actual_tasks_and_readonly_summary():
    lua = fixture()
    lua.execute('''
        assert(current:DescribeTasks()[1]=="等待自动启动")
        current.mode="running"
        local active={key="reserve:material:flint",command={purpose="explore:flint"}}
        local queued={ {item="twigs"}, {item="torch"}, {item="researchlab2"}, {item="heatrock"}, {item="researchlab2"} }
        current.state.survival={active=active, demands=queued}
        local rows=current:DescribeTasks()
        local seen={}
        for _,line in ipairs(rows) do
            assert(not seen[line], "task groups must be unique")
            seen[line]=true
        end
        assert(seen["物资准备 · 执行中"] and seen["探索地图 · 执行中"])
        assert(seen["照明准备 · 待处理"] and seen["设施推进 · 待处理"] and seen["四季准备 · 待处理"])
        assert(seen["基础生存 · 监测中"] and not seen["设施推进 · 执行中"])
        assert(#rows==6 and current.state.survival.active==active and current.state.survival.demands==queued and #queued==5,
            "display must neither schedule nor mutate live requests")
        current.state.survival={active={key="escape:threat"},suspended=active}
        rows=current:DescribeTasks()
        assert(rows[1]=="安全避险 · 执行中" and rows[2]=="物资准备 · 待处理")
        current.state.survival=nil
        rows=current:DescribeTasks()
        assert(#rows==2 and rows[1]=="基础生存 · 监测中" and rows[2]=="探索地图 · 待命",
            "no stale construction or collection may survive a cleared scheduler")
    ''')


def check_modes_and_execution_input():
    lua = fixture()
    lua.execute('''
        current.state.survival={active={key="escape:threat"},demands={{item="researchlab2"}}}
        for mode,label in pairs({paused="自动任务已暂停",failed="本局任务已结束",stopped="自动任务待启动"}) do
            current.mode=mode;current.auto_start_pending=false
            local rows=current:DescribeTasks()
            assert(#rows==1 and rows[1]==label, "inactive summaries must not claim a task is executing")
        end
        current:Close()
        assert(task_cancelled and current.closed, "runtime cleanup must remain valid without input handlers")
    ''')
    source = (base.SCRIPTS / "wilsonexpedition/runtime.lua").read_text(encoding="utf-8")
    assert "AddKeyUpHandler" not in source and not any(key in source for key in ("KEY_F6", "KEY_F7", "KEY_F8"))
    main = (base.SCRIPTS.parent / "modmain.lua").read_text(encoding="utf-8")
    assert 'runtime:Pause("玩家接管")' in main, "manual takeover remains a safety boundary"


def check_next_start_events_and_native_application():
    with tempfile.TemporaryDirectory(prefix="world-events-", dir=HERE) as name:
        cluster = Path(name)
        for shard,preset in (("Master","ENDLESS"),("Caves","DST_CAVE")):
            folder = cluster / shard
            folder.mkdir()
            (folder / "worldgenoverride.lua").write_text(
                'KLEI     1 return { override_enabled=true, worldgen_preset="' + preset + '", settings_preset="' + preset
                + '", overrides={specialevent="default",resettime="none"} }', encoding="utf-8")
        iteration.disable_world_events(cluster)
        before = {}
        for shard,preset in (("Master","ENDLESS"),("Caves","DST_CAVE")):
            path = cluster / shard / "worldgenoverride.lua"
            data = iteration.config_table(path)
            assert data == {"override_enabled": True, "worldgen_preset": preset, "settings_preset": preset,
                            "overrides": {"specialevent": "none", "resettime": "none"}}
            before[shard] = path.read_bytes()
        iteration.disable_world_events(cluster)
        assert all((cluster / shard / "worldgenoverride.lua").read_bytes()==data for shard,data in before.items())
        path = cluster / "Master/worldgenoverride.lua"
        path.write_text('return { override_enabled=true, preset="ENDLESS", overrides={invalid={}} }', encoding="utf-8")
        before = path.read_bytes()
        try:
            iteration.disable_world_events(cluster)
        except ValueError:
            pass
        else:
            raise AssertionError("unrecognized override structure must fail explicitly")
        assert path.read_bytes() == before
        path.write_text('return { override_enabled=true, preset="ENDLESS", overrides={} }', encoding="utf-8")
        before = path.read_bytes()
        with patch.object(Path, "replace", side_effect=PermissionError("configuration busy")):
            try:
                iteration.disable_world_events(cluster)
            except PermissionError:
                pass
            else:
                raise AssertionError("a failed publish must be explicit")
        assert path.read_bytes() == before, "failed settings writes must preserve the old file"
    source = inspect.getsource(iteration.run)
    assert source.index('if probe.stdout.strip()') < source.index('disable_world_events(')
    assert source.index('if ports.stdout.strip()') < source.index('disable_world_events(')
    native = getattr(base,"NATIVE_SCRIPTS",base.GAME / "data/databundles/scripts")
    simutil = (native / "simutil.lua").read_text(encoding="utf-8-sig")
    lua = base.runtime()
    lua.execute('SPECIAL_EVENTS={NONE="none",HALLOWED_NIGHTS="hallowed_nights"};TECH={};WORLD_SPECIAL_EVENT="hallowed_nights"')
    lua.execute(simutil[simutil.index("local function ApplyEvent("):simutil.index("function ApplyExtraEvent(")])
    lua.execute('ApplySpecialEvent("none");assert(WORLD_SPECIAL_EVENT==SPECIAL_EVENTS.NONE,"native engine must receive the events-none value")')


if __name__ == "__main__":
    for check in (check_actual_tasks_and_readonly_summary, check_modes_and_execution_input,
                  check_next_start_events_and_native_application):
        check()
        print("PASS",check.__name__)
