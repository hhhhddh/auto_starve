"""Configure and deploy this checkout, or run its offline checks; never launches DST."""

import argparse
import ast
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parent
SUPPORT = PROJECT / "development-support/nbot-relay"
sys.path.insert(0, str(SUPPORT))
import project_paths

MODS = ("WilsonExpedition", "WilsonExpeditionDiagnostics")
MARKER = ".auto-starve-deployment.json"


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def validate_game(directory):
    for name in ("dontstarve_steam_x64.exe", "dontstarve_dedicated_server_nullrenderer_x64.exe"):
        if not (directory / "bin64" / name).is_file():
            raise ValueError("The configured Windows DST installation is missing bin64/" + name)


def configure(args):
    game = Path(args.game_dir).expanduser().resolve()
    validate_game(game)
    value = {"schema": "auto-starve/deployment@1", "game_dir": str(game),
             "storage_root": args.storage_root}
    if args.scripts_dir:
        scripts = Path(args.scripts_dir).expanduser().resolve()
        if not (scripts / "components/playercontroller.lua").is_file():
            raise ValueError("scripts_dir must contain the extracted native scripts/components/playercontroller.lua")
        value["scripts_dir"] = str(scripts)
    storage = project_paths.resolve_path(args.storage_root, "storage_root")
    if PROJECT.is_relative_to(storage) or game.is_relative_to(storage):
        raise ValueError("Select dedicated test storage, not the repository/game directory or an ancestor")
    write_json(project_paths.CONFIG, value)
    return {"configured": True, "configuration": str(project_paths.CONFIG),
            "next": "python deploy.py install"}


def install(args):
    game = project_paths.game_dir()
    validate_game(game)
    plans = []
    for name in MODS:
        source, target = PROJECT / "mods" / name, game / "mods" / name
        lua_files = sorted(source.rglob("*.lua"))
        if not lua_files:
            raise ValueError("Mod source is missing: " + name)
        files = sorted(lua_files + list(source.rglob("*.md")))
        marker = target / MARKER
        previous = json.loads(marker.read_text(encoding="utf-8")) if marker.exists() else {}
        owned = previous.get("project") == str(PROJECT)
        expected = {file.relative_to(source) for file in lua_files}
        extra = {file.relative_to(target) for file in target.rglob("*.lua")} - expected
        needs_backup = target.exists() and (not owned or bool(extra))
        if needs_backup and not args.replace_existing:
            raise ValueError(name + " has another deployment or extra Lua files; use --replace-existing to preserve it in a backup")
        plans.append((source, target, files, needs_backup))
    backups = PROJECT / ".local/deployment-backups" / dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    installed = []
    for source, target, files, needs_backup in plans:
        if needs_backup:
            backups.mkdir(parents=True, exist_ok=True)
            shutil.move(str(target), str(backups / source.name))
        hashes = {}
        for file in files:
            relative = file.relative_to(source)
            destination = target / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(file, destination)
            hashes[relative.as_posix()] = hashlib.sha256(destination.read_bytes()).hexdigest()
        write_json(target / MARKER, {"schema": "auto-starve/installed@1", "project": str(PROJECT), "files": hashes})
        installed.append(source.name)
    return {"installed": installed, "gameStarted": False,
            "backup": str(backups) if backups.exists() else None,
            "next": "python development-support/nbot-relay/iteration.py prepare"}


def check():
    from luaparser import ast as lua_ast
    counts = {"lua": 0, "python": 0, "json": 0}
    for path in sorted((PROJECT / "mods").rglob("*.lua")) + sorted((SUPPORT / "nbot_relay").rglob("*.lua")):
        lua_ast.parse(path.read_text(encoding="utf-8-sig"))
        counts["lua"] += 1
    files = [PROJECT / "deploy.py", *SUPPORT.glob("*.py"), *(PROJECT / ".pi/runtime-recovery").glob("*.py"),
             *(PROJECT / "tests").glob("*.py")]
    for path in sorted(files):
        ast.parse(path.read_text(encoding="utf-8-sig"), filename=str(path))
        counts["python"] += 1
    for path in (PROJECT / "deployment.example.json", PROJECT / "handoff/iterations.json",
                 SUPPORT / "server/config.example.json", SUPPORT / "integration-manifest.json"):
        json.loads(path.read_text(encoding="utf-8-sig"))
        counts["json"] += 1
    return {"syntax": "passed", "files": counts, "nativeScriptsRequired": False, "gameStarted": False}


def test():
    if os.name != "nt":
        raise ValueError("The complete native regression suite targets Windows; use 'check' for portable syntax validation")
    native = project_paths.native_scripts()
    if not (native / "components/playercontroller.lua").is_file():
        raise ValueError("Native regression files are unavailable; configure --scripts-dir to extracted DST scripts")
    check()
    environment = dict(os.environ, DST_GAME_DIR=str(project_paths.game_dir()), DST_SCRIPTS_DIR=str(native))
    tests = ("check-death-iteration.py", "check-continuous-work.py", "check-move-continuity.py",
             "check-empty-landmarks.py", "check-threat-retreat.py", "check-tallbird-awareness.py",
             "check-world-pause.py", "check-paused-reset.py", "check-state-replace.py")
    for name in tests:
        subprocess.run([sys.executable, "-B", str(PROJECT / ".pi/runtime-recovery" / name)],
                       cwd=PROJECT, env=environment, check=True, timeout=45)
    subprocess.run([sys.executable, "-B", str(PROJECT / "tests/test_deployment.py")],
                   cwd=PROJECT, env=environment, check=True, timeout=45)
    node = shutil.which("node")
    if not node:
        raise ValueError("Node.js is required to validate the optional Pi death-notification extension")
    subprocess.run([node, "--check", str(PROJECT / ".pi/extensions/wilson-iteration.js")], check=True, timeout=15)
    subprocess.run([node, str(PROJECT / ".pi/runtime-recovery/wilson-notifier-check.mjs")],
                   cwd=PROJECT, check=True, timeout=30)
    return {"offlineRegressions": "passed", "gameStarted": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("configure", help="Write ignored local paths; does not prepare or launch a world")
    setup.add_argument("--game-dir", required=True)
    setup.add_argument("--storage-root", default=".local/dst")
    setup.add_argument("--scripts-dir", help="Optional extracted native scripts directory for regression checks")
    deployment = commands.add_parser("install", help="Install the two project Mods; never launches the game")
    deployment.add_argument("--replace-existing", action="store_true", help="Move an unrelated or stale Mod into a backup before installing this checkout")
    commands.add_parser("check", help="Syntax-check repository source without a game installation")
    commands.add_parser("test", help="Run offline regressions against local native scripts; never launches the game")
    args = parser.parse_args()
    if args.command == "configure":
        result = configure(args)
    elif args.command == "install":
        result = install(args)
    elif args.command == "check":
        result = check()
    else:
        result = test()
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, ImportError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(2)
