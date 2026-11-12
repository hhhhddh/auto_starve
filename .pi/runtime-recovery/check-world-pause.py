"""Check native client pause dispatch and verified two-shard pause receipts offline."""

import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
SUPPORT = PROJECT / "development-support/nbot-relay"
sys.path.insert(0, str(SUPPORT))
from project_paths import native_scripts
NATIVE_SCRIPTS = native_scripts()
from lupa.lua51 import LuaRuntime


def check_dispatch():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('''
        GLOBAL = _G
        type = type
        auto_iteration, admin, calls, requested = true, true, 0, nil
        package.preload.json = function() return { encode = function() return "{}" end } end
        package.preload.wilsonexpeditiondiagnosticsrevision = function() return "build" end
        function GetModConfigData() return auto_iteration end
        sim_callbacks, client_handlers = {}, {}
        function AddSimPostInit(fn) sim_callbacks[#sim_callbacks + 1] = fn end
        function AddClientModRPCHandler(_, name, fn) client_handlers[name] = fn end
        function AddModRPCHandler() end
        function AddPlayerPostInit() end
        function GetClientModRPC(_, name) return name end
        function SendModRPCToClient(name, userid, ...)
            assert(userid == "test_user")
            client_handlers[name](...)
        end
        function GetTime() return 100 end
        function print() end
        TheNet = {
            GetIsServerAdmin = function() return admin end,
            SetServerPaused = function(_, value) calls, requested = calls + 1, value end,
            GetSessionIdentifier = function() return "master" end,
            IsServerPaused = function() return requested == true end,
        }
        TheShard = { GetShardId = function() return "1" end }
        TheWorld = { ismastersim = true, ListenForEvent = function() end }
        local record = { challenge = "challenge", failed = true, Publish = function() end }
        ThePlayer = { userid = "test_user", components = { wilsonexpeditionrecord = record },
            _wilsonexpedition_server = { revision = "build", challenge = "challenge", failed = true } }
        AllPlayers = { ThePlayer }
    ''')
    source = (NATIVE_SCRIPTS / "mainfunctions.lua").read_text(encoding="utf-8")
    native = re.search(r"^function SetServerPaused\(pause\).*?^end[ \t]*$", source, re.M | re.S)
    assert native is not None
    lua.execute(native.group(0))
    lua.execute((PROJECT / "mods/WilsonExpeditionDiagnostics/modmain.lua").read_text(encoding="utf-8"))
    lua.execute('''
        for _, fn in ipairs(sim_callbacks) do fn() end
        WilsonExpeditionPauseTest("build", "challenge", true)
        assert(calls == 1 and requested == true, "must dispatch native pause from the client")
        WilsonExpeditionPauseTest("build", "challenge", false)
        assert(calls == 2 and requested == false, "approved reset must be able to release pause")
        local original = calls
        WilsonExpeditionPauseTest("wrong_build", "challenge", true)
        WilsonExpeditionPauseTest("build", "wrong_challenge", true)
        WilsonExpeditionPauseTest("build", "challenge", "true")
        auto_iteration = false
        WilsonExpeditionPauseTest("build", "challenge", true)
        auto_iteration, admin = true, false
        WilsonExpeditionPauseTest("build", "challenge", true)
        admin = true
        ThePlayer._wilsonexpedition_server.failed = false
        WilsonExpeditionPauseTest("build", "challenge", true)
        assert(calls == original, "disabled, mismatched, non-admin and live runs must not pause")
        ThePlayer.components.wilsonexpeditionrecord.failed = false
        ThePlayer._wilsonexpedition_server.failed = true
        WilsonExpeditionPauseTest("build", "challenge", true)
        assert(calls == original, "controller must not pause a living server record")
        ThePlayer.components.wilsonexpeditionrecord.completion_logged = true
        ThePlayer._wilsonexpedition_server.failed = false
        ThePlayer._wilsonexpedition_server.elapsed_days = 70
        WilsonExpeditionPauseTest("build", "challenge", true)
        assert(calls == original + 1 and requested == true, "70-day completion uses the same native pause")
    ''')


def check_confirmation():
    spec = importlib.util.spec_from_file_location("test_iteration", SUPPORT / "iteration.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    class Process:
        def poll(self):
            return None

    state = {"revision": "build", "sessions": {"Master": "master", "Caves": "caves"}}
    processes = {name: Process() for name in state["sessions"]}
    with tempfile.TemporaryDirectory() as directory:
        cluster = Path(directory)
        for name in state["sessions"]:
            (cluster / name).mkdir()

        def event(name, *, paused=True, revision="build"):
            return {"schema": "wilson-expedition/server-event@1", "event": "test_pause_state",
                    "revision": revision, "session": state["sessions"][name], "detail": {"paused": paused}}

        def log(name, events):
            (cluster / name / "server_log.txt").write_text(
                "\n".join("[WilsonExpeditionDiagnostics] " + json.dumps(row) for row in events), encoding="utf-8")

        for scenario in ("both", "one_shard", "stale", "unpaused", "latest_unpause", "release"):
            for name in state["sessions"]:
                entries = [event(name, paused=scenario != "release")]
                if scenario == "one_shard" and name == "Caves":
                    entries = []
                elif scenario == "stale" and name == "Caves":
                    entries = [event(name, revision="old")]
                elif scenario == "unpaused" and name == "Caves":
                    entries = [event(name, paused=False)]
                elif scenario == "latest_unpause" and name == "Caves":
                    entries.append(event(name, paused=False))
                log(name, entries)
            clock = [0.0]
            with patch.object(module.time, "monotonic", side_effect=lambda: clock[0]), \
                 patch.object(module.time, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                 patch.object(module, "process_command") as command:
                if scenario in ("both", "release"):
                    result = module.set_world_paused(processes, cluster, state, "challenge", scenario != "release")
                    assert set(result["shards"]) == {"Master", "Caves"}
                    assert result["paused"] is (scenario != "release")
                else:
                    try:
                        module.set_world_paused(processes, cluster, state, "challenge", True)
                    except ValueError as exc:
                        assert "did not confirm" in str(exc)
                    else:
                        raise AssertionError("Missing or stale native confirmation must fail: " + scenario)
                sent = command.call_args.args[1]
                assert 'WilsonExpeditionPauseTest("build", "challenge", ' in sent
                assert command.call_count == 1


if __name__ == "__main__":
    check_dispatch()
    print("PASS: native client pause dispatch and identity/admin/end-state boundaries")
    check_confirmation()
    print("PASS: both-shard confirmation, stale/missing/unpaused refusal and reset release")
