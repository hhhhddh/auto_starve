"""Replay the owned controller with a paused world and the native reset entry point."""

import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / "development-support/nbot-relay"))
from project_paths import native_scripts
NATIVE_SCRIPTS = native_scripts()
from lupa.lua51 import LuaRuntime
import iteration


def check_paused_reset():
    flags = {"paused": False, "resets": 0}
    requested = []
    old_sessions = {"Master": "old-master", "Caves": "old-caves"}
    new_sessions = {"Master": "new-master", "Caves": "new-caves"}
    lua = LuaRuntime(unpack_returned_tuples=True)

    def reset_engine():
        assert flags["paused"], "fault world must remain paused until native reset"
        flags["resets"] += 1
        flags["paused"] = False

    lua.globals().reset_engine = reset_engine
    lua.execute("TheWorld = { ismastersim = true }; TheNet = { SendWorldResetRequestToServer = function() reset_engine() end }")
    source = (NATIVE_SCRIPTS / "consolecommands.lua").read_text(encoding="utf-8")
    native = re.search(r"^function c_regenerateworld\(\).*?^end[ \t]*$", source, re.M | re.S)
    assert native is not None
    lua.execute(native.group(0))

    class Process:
        def __init__(self, arguments):
            self.arguments = arguments
            self.status = None

        def poll(self):
            return self.status

        def wait(self, timeout=None):
            self.status = 0
            return 0

        def terminate(self):
            assert flags.get("next_round_running"), "the client and watcher must survive world regeneration"
            self.status = 0

    launched = []

    def launch(arguments, **kwargs):
        process = Process(arguments)
        launched.append(process)
        return process

    def pause_world(processes, cluster, state, challenge, paused):
        requested.append(paused)
        assert paused is True, "fault world must remain paused until native reset"
        flags["paused"] = True
        return {"paused": True, "shards": old_sessions}

    def command(process, text):
        if text == "c_regenerateworld()":
            lua.execute(text)
        elif text == "c_shutdown()":
            process.status = 0
        else:
            raise AssertionError("Unexpected lifecycle command: " + text)

    with tempfile.TemporaryDirectory(prefix="reset-check-", dir=PROJECT / ".pi/runtime-recovery") as directory:
        root = Path(directory)
        private, storage, queue = root / "private", root / "storage", root / "queue"
        for folder in (private, storage, queue):
            folder.mkdir()
        state_path, job_path = private / "state.json", queue / "death.json"
        iteration.write_json(storage / ".wilson-expedition-owner.json", {"owner": "test-owner"})
        iteration.write_json(job_path, {"id": "death", "stage": "approved", "challenge": "failed",
                                        "approval": {"revision": "repaired"}})
        original_write = iteration.write_json

        def write(path, value):
            original_write(path, value)
            if path == job_path and value.get("stage") == "next_round_running":
                clients = [process for process in launched if process.arguments == ["visible-client"]]
                assert len(clients) == 1 and clients[0].poll() is None, "both rounds must share one live client"
                flags["next_round_running"] = True
                (private / "iteration-stop.request").write_text("test complete", encoding="utf-8")

        def loaded_job(identity):
            assert identity == "death"
            return job_path, iteration.read_json(job_path), {"revision": "old:build", "session": "old-master"}, [{}]

        with patch.multiple(iteration, PRIVATE=private, STORAGE=storage, QUEUE=queue, STATE=state_path), \
             patch.object(iteration, "load_profile", return_value={"owner": "test-owner"}), \
             patch.object(iteration, "revision", side_effect=["old", "repaired"]), \
             patch.object(iteration, "write_revision", side_effect=lambda revision: revision + ":build"), \
             patch.object(iteration, "check_sources", return_value={}), \
             patch.object(iteration, "load_job", side_effect=loaded_job), \
             patch.object(iteration, "matches_death", return_value=True), \
             patch.object(iteration, "observe_survival_complete", return_value=False), \
             patch.object(iteration, "observe_new_world", side_effect=lambda *args: new_sessions if flags["resets"] else old_sessions), \
             patch.object(iteration, "observe_client_start", side_effect=lambda *args: "new-challenge" if flags["resets"] else "failed"), \
             patch.object(iteration, "client_command", return_value=["visible-client"]), \
             patch.object(iteration, "set_world_paused", side_effect=pause_world), \
             patch.object(iteration, "process_command", side_effect=command), \
             patch.object(iteration.subprocess, "Popen", side_effect=launch), \
             patch.object(iteration, "write_json", side_effect=write), \
             patch.object(iteration.time, "sleep"):
            iteration.run_owned({"luaFiles": 17, "pythonFiles": 3})
        state, job = iteration.read_json(state_path), iteration.read_json(job_path)
        assert flags["resets"] == 1 and requested == [True]
        assert len(launched) == 4, "two shards, one watcher and one client must span both rounds"
        assert state["round"] == 2 and state["sessions"] == new_sessions
        assert "pause" not in state, "old pause confirmation must not describe the new sessions"
        assert state["revision"] == "repaired:build" and state["challenge"] == "new-challenge"
        assert job["stage"] == "next_round_running" and job["newSessions"] == new_sessions
        assert job["nextChallenge"] == "new-challenge"


if __name__ == "__main__":
    check_paused_reset()
    print("PASS: native reset preserves the client process and gates continuation on both new sessions and approved source build")
