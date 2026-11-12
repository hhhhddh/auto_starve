"""Exercise JSON replacement with real Windows readers and persistent failures."""

import argparse
import importlib.util
from pathlib import Path
import sys
import tempfile
import threading
import time
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / "development-support/nbot-relay"))


def check(module):
    with tempfile.TemporaryDirectory(prefix="state-replace-", dir=PROJECT / ".pi/runtime-recovery") as directory:
        target = Path(directory) / "nested/state.json"
        old, updated = {"stage": "running", "count": 1}, {"stage": "running", "count": 2, "text": "状态"}
        module.write_json(target, old)
        native_replace = Path.replace
        failures = []

        def observed_replace(source, destination):
            try:
                return native_replace(source, destination)
            except PermissionError as exc:
                failures.append(getattr(exc, "winerror", None))
                assert module.read_json(target) == old, "readers must retain a complete previous state"
                raise

        reader = target.open("rb")
        release = threading.Timer(0.15, reader.close)
        release.start()
        try:
            with patch.object(Path, "replace", observed_replace):
                module.write_json(target, updated)
        finally:
            release.join()
            reader.close()
        assert failures and failures[0] in (5, 32, 33), "test must reproduce native sharing denial"
        assert module.read_json(target) == updated
        assert not target.with_name(target.name + ".tmp").exists()
        print("PASS: actual Windows reader reproduced", failures[0], "and replacement recovered atomically")

        module.write_json(target, old)
        started = time.monotonic()
        with target.open("rb"):
            try:
                module.write_json(target, updated)
            except PermissionError as exc:
                assert getattr(exc, "winerror", None) in (5, 32, 33)
            else:
                raise AssertionError("persistent reader lock must remain an explicit failure")
        elapsed = time.monotonic() - started
        assert 1.8 <= elapsed < 4.0, "sharing retries must have a bounded duration"
        assert module.read_json(target) == old
        module.write_json(target, updated)
        assert module.read_json(target) == updated
        print("PASS: persistent sharing denial stops within the bound and preserves the previous state")

        for error in (OSError(28, "disk full"), PermissionError(13, "unsupported access denial")):
            with patch.object(Path, "replace", side_effect=error), patch.object(module.time, "sleep") as sleep:
                try:
                    module.write_json(target, old)
                except OSError as exc:
                    assert exc is error
                else:
                    raise AssertionError("unrelated filesystem errors must propagate")
                sleep.assert_not_called()
        assert module.read_json(target) == updated
        print("PASS: unrelated errors are immediate and never truncate the published state")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=PROJECT / "development-support/nbot-relay/iteration.py")
    arguments = parser.parse_args()
    specification = importlib.util.spec_from_file_location("checked_iteration", arguments.source)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    check(module)
