"""Check fresh-checkout setup and deployment in an isolated fake game directory."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
SUPPORT_RELATIVE = Path("development-support/nbot-relay")


def run(checkout, arguments, *, expected=0):
    environment = {key: value for key, value in os.environ.items()
                   if key not in ("DST_GAME_DIR", "DST_SCRIPTS_DIR", "WILSON_STORAGE_ROOT")}
    result = subprocess.run([sys.executable, "-B", *arguments], cwd=checkout, env=environment,
                            capture_output=True, text=True, encoding="utf-8", timeout=30)
    assert result.returncode == expected, (arguments, result.stdout, result.stderr)
    return result


def check():
    (PROJECT / ".local").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="deployment-check-", dir=PROJECT / ".local") as directory:
        temporary = Path(directory)
        checkout, game = temporary / "fork", temporary / "game"
        checkout.mkdir()
        for name in ("mods", "handoff", ".pi"):
            shutil.copytree(PROJECT / name, checkout / name, ignore=shutil.ignore_patterns("__pycache__", "*-check-*"))
        shutil.copytree(PROJECT / SUPPORT_RELATIVE, checkout / SUPPORT_RELATIVE,
                        ignore=shutil.ignore_patterns("private", "captures", "__pycache__"))
        for name in ("deploy.py", "deployment.example.json", ".gitignore", "requirements.txt"):
            shutil.copyfile(PROJECT / name, checkout / name)
        (game / "bin64").mkdir(parents=True)
        for name in ("dontstarve_steam_x64.exe", "dontstarve_dedicated_server_nullrenderer_x64.exe"):
            (game / "bin64" / name).write_bytes(b"offline-fixture")

        assert not (checkout / "deployment.local.json").exists()
        syntax = json.loads(run(checkout, ["deploy.py", "check"]).stdout)
        assert syntax["syntax"] == "passed" and syntax["gameStarted"] is False
        run(checkout, ["deploy.py", "configure", "--game-dir", str(game), "--storage-root", str(temporary)], expected=2)
        assert not (checkout / "deployment.local.json").exists(), "invalid roots must not persist a configuration"
        run(checkout, ["deploy.py", "configure", "--game-dir", str(game)])
        installation = json.loads(run(checkout, ["deploy.py", "install"]).stdout)
        assert installation["installed"] == ["WilsonExpedition", "WilsonExpeditionDiagnostics"]
        assert installation["gameStarted"] is False
        assert not (game / "mods/nbot_relay").exists(), "optional relay stays disabled"

        source = checkout / "mods/WilsonExpedition/modinfo.lua"
        installed = game / "mods/WilsonExpedition/modinfo.lua"
        assert installed.read_bytes() == source.read_bytes()
        history = Path("mods/WilsonExpedition/OPTIMIZATIONS.md")
        assert (game / history).read_bytes() == (checkout / history).read_bytes(), "optimization history must be installed"
        receipt = game / "mods/WilsonExpedition/.auto-starve-deployment.json"
        value = json.loads(receipt.read_text())
        value["project"] = "different-checkout"
        receipt.write_text(json.dumps(value), encoding="utf-8")
        before = installed.read_bytes()
        stale_lua = game / "mods/WilsonExpedition/scripts/old_version.lua"
        stale_lua.parent.mkdir(parents=True, exist_ok=True)
        stale_lua.write_text("return {}\n", encoding="utf-8")
        run(checkout, ["deploy.py", "install"], expected=2)
        assert installed.read_bytes() == before
        replacement = json.loads(run(checkout, ["deploy.py", "install", "--replace-existing"]).stdout)
        backup = Path(replacement["backup"])
        assert (backup / "WilsonExpedition/modinfo.lua").read_bytes() == before
        assert (backup / "WilsonExpedition/scripts/old_version.lua").read_text() == "return {}\n"
        assert not stale_lua.exists(), "the newly installed Mod must not load leftover code from the previous deployment"

        probe = '''
import json, sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(sys.argv[1]) / "development-support/nbot-relay"))
import iteration
with patch("winreg.OpenKey"), patch("winreg.QueryValueEx", return_value=(12345, 4)):
    profile, cluster, capture = iteration.prepare()
    report = iteration.preflight()
assert profile["account"] == "12345"
assert cluster.is_relative_to(Path(sys.argv[1]) / ".local/dst")
assert report["agentExtension"]["ready"] is False
assert iteration.config_table(cluster / "Master/worldgenoverride.lua")["preset"] == "ENDLESS"
assert iteration.config_table(cluster / "Caves/worldgenoverride.lua")["preset"] == "DST_CAVE"
settings = iteration.configparser.ConfigParser()
settings.read(Path(profile["clientStorageRoot"]) / profile["clientConfDir"] / "settings.ini", encoding="utf-8")
assert settings.getboolean("MISC", "modswarning") is False
assert settings.getboolean("MISC", "warn_mods_enabled") is False
assert settings.getboolean("GRAPHICS", "fullscreen") is False
print(json.dumps({"prepared": True, "validation": report["validation"]}))
'''
        prepared = json.loads(run(checkout, ["-c", probe, str(checkout)]).stdout)
        assert prepared["prepared"] is True
        assert prepared["validation"]["luaFiles"] == 17

        source.write_text(source.read_text(encoding="utf-8") + "\n-- deployment regression\n", encoding="utf-8")
        stale = probe.split("with patch(", 1)[0] + "iteration.check_sources()\n"
        result = run(checkout, ["-c", stale, str(checkout)], expected=1)
        assert "Installed Mod source is stale" in result.stderr
        history_source = checkout / history
        history_source.write_text(history_source.read_text(encoding="utf-8") + "\n## Deployment history update\n", encoding="utf-8")
        run(checkout, ["deploy.py", "install"])
        run(checkout, ["-c", stale, str(checkout)])
        assert (game / history).read_bytes() == history_source.read_bytes(), "later optimization records must be synchronized"

        subprocess.run(["git", "init", "-q", str(checkout)], check=True, capture_output=True, timeout=15)
        relative_files = ["deployment.local.json", ".local/dst/example",
                          "development-support/nbot-relay/private/iteration-profile.json",
                          "development-support/nbot-relay/captures/raw-log.txt", "cluster_token.txt", "adminlist.txt"]
        ignored = subprocess.run(["git", "-C", str(checkout), "check-ignore", "--stdin", "-z", "--no-index"],
                                 input="\0".join(relative_files) + "\0", capture_output=True,
                                 text=True, encoding="utf-8", check=True, timeout=15)
        assert set(ignored.stdout.rstrip("\0").split("\0")) == set(relative_files), ignored.stdout
        print("PASS: clean checkout syntax, configurable isolated setup, deployment ownership/backup, source synchronization, endless presets and private-data ignores")


if __name__ == "__main__":
    check()
