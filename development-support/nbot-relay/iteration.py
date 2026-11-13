"""Coordinate evidence-backed repairs and native resets of an owned DST test cluster."""

import argparse
import ast
import configparser
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

from project_paths import game_dir, storage_root

ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parent.parent
PRIVATE = ROOT / "private"
QUEUE = PRIVATE / "iteration-queue"
PROFILE = PRIVATE / "iteration-profile.json"
STATE = PRIVATE / "iteration-state.json"
GAME = game_dir()
CLIENT_MOD = GAME / "mods/WilsonExpedition"
DIAGNOSTICS = GAME / "mods/WilsonExpeditionDiagnostics"
STORAGE = storage_root()
REVISION_FILES = {CLIENT_MOD / "scripts/wilsonexpedition/revision.lua",
                  DIAGNOSTICS / "scripts/wilsonexpeditiondiagnosticsrevision.lua"}
HEX = re.compile(r"[0-9a-f]{64}")
MARKER = b"[WilsonExpeditionDiagnostics] "


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    # [喵喵喵]: Windows 读者可能短暂阻止文件替换；有界重试共享占用，持续失败仍保留旧状态并报错。 (2026-11-12)
    deadline = time.monotonic() + 2
    while True:
        try:
            temporary.replace(path)
            return
        except PermissionError as exc:
            if getattr(exc, "winerror", None) not in (5, 32, 33) or time.monotonic() >= deadline:
                raise
            time.sleep(0.05)


def revision():
    digest = hashlib.sha256()
    for label, directory in (("client", CLIENT_MOD), ("diagnostics", DIAGNOSTICS)):
        files = sorted(directory.rglob("*.lua"))
        if not files:
            raise ValueError("Mod sources unavailable: " + str(directory))
        for path in files:
            if path in REVISION_FILES:
                continue
            digest.update((label + "/" + path.relative_to(directory).as_posix()).encode())
            digest.update(b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def check_sources():
    from luaparser import ast as lua_ast
    count = 0
    for directory in (CLIENT_MOD, DIAGNOSTICS):
        repository = PROJECT / "mods" / directory.name
        expected = {p.relative_to(repository) for p in repository.rglob("*.lua")}
        installed = {p.relative_to(directory) for p in directory.rglob("*.lua")}
        if not expected or expected != installed:
            raise ValueError("Installed Mod files differ from this checkout; run python deploy.py install")
        for relative in expected:
            if directory / relative not in REVISION_FILES and (repository / relative).read_bytes() != (directory / relative).read_bytes():
                raise ValueError("Installed Mod source is stale; run python deploy.py install: " + directory.name)
        for path in sorted(directory.rglob("*.lua")):
            lua_ast.parse(path.read_text(encoding="utf-8-sig"))
            count += 1
    for path in (ROOT / "relay_tool.py", ROOT / "death_watch.py", ROOT / "project_paths.py", Path(__file__)):
        ast.parse(path.read_text(encoding="utf-8-sig"), filename=str(path))
    return {"luaFiles": count, "pythonFiles": 4, "checkedUtc": now()}


def load_profile():
    profile = read_json(PROFILE)
    if profile.get("schema") != "wilson-expedition/iteration-profile@1":
        raise ValueError("Invalid iteration profile")
    if Path(profile.get("storageRoot", "")).resolve() != STORAGE.resolve():
        raise ValueError("Only the dedicated project test storage is supported")
    if not re.fullmatch(r"[0-9a-f]{32}", profile.get("owner", "")):
        raise ValueError("Invalid cluster owner")
    return profile


def matches_death(bundle, event):
    return (isinstance(event, dict) and event.get("schema") == "wilson-expedition/server-event@1" and event.get("event") == "death"
            and all(isinstance(bundle.get(key), str) and bundle[key]
                    and event.get(key) == bundle[key] for key in ("challenge", "userid", "session", "revision")))


def queue_death(directory, bundle, events):
    identity = hashlib.sha256(json.dumps(bundle, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
    path = QUEUE / (identity + ".json")
    if path.exists():
        return path
    directory = Path(directory).resolve()
    directory.relative_to((ROOT / "captures").resolve())
    running = read_json(STATE) if STATE.exists() else {}
    capture_only = (running.get("deathPolicy") == "capture_only"
                    and running.get("revision") == bundle.get("revision")
                    and bundle.get("session") in running.get("sessions", {}).values())
    job = {"schema": "wilson-expedition/iteration@1", "id": identity,
           "stage": "captured" if capture_only else "awaiting_fix", "createdUtc": now(),
           "deathPolicy": "capture_only" if capture_only else "repair_and_regenerate", "capture": directory.name,
           "challenge": bundle.get("challenge"), "userid": bundle.get("userid"),
           "session": bundle.get("session"), "loadedRevision": bundle.get("revision"),
           "sourceRevision": revision(),
           "serverDeathEvidence": any(matches_death(bundle, e) for e in events),
           "approval": None}
    write_json(path, job)
    return path


def load_job(identity):
    if not HEX.fullmatch(identity):
        raise ValueError("Iteration id must be its complete SHA-256")
    path = QUEUE / (identity + ".json")
    job = read_json(path)
    if job.get("schema") != "wilson-expedition/iteration@1" or job.get("id") != identity:
        raise ValueError("Invalid iteration job")
    capture = (ROOT / "captures" / job["capture"]).resolve()
    capture.relative_to((ROOT / "captures").resolve())
    bundle = read_json(capture / "death-bundle.json")
    events = read_json(capture / "server-events.json")
    expected = hashlib.sha256(json.dumps(bundle, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
    if expected != identity or bundle.get("challenge") != job.get("challenge") or not isinstance(events, list):
        raise ValueError("Death evidence does not match the queued iteration")
    return path, job, bundle, events


def approve(identity, summary):
    path, job, bundle, events = load_job(identity)
    if job["stage"] != "awaiting_fix" or not summary.strip():
        raise ValueError("A pending fix and a concrete repair summary are required")
    if not any(matches_death(bundle, e) for e in events):
        raise ValueError("Matching server death evidence is required before a world reset")
    current = revision()
    manifest = read_json(ROOT / "captures" / job["capture"] / "capture-manifest.json")
    logs = manifest.get("logs", {})
    if not any(isinstance(row, dict) and row.get("kind") == "client" and row.get("status") in ("copied", "copied_truncated")
               for row in logs.values()):
        raise ValueError("The client log must be archived before a world reset")
    if not any(isinstance(row, dict) and row.get("matchingEvents", 0) > 0
               and row.get("status") in ("copied", "copied_truncated") for row in logs.values()):
        raise ValueError("The matching server log must be archived before a world reset")
    if current == job["sourceRevision"] or current == str(job.get("loadedRevision", "")).split(":")[0]:
        raise ValueError("Implement the evidence-backed Mod repair before approving the next round")
    validation = check_sources()
    job["approval"] = {"revision": current, "summary": summary.strip(), "validation": validation}
    job["stage"] = "approved"
    write_json(path, job)
    return {"id": identity, "stage": job["stage"], "revision": current, "validation": validation}


def prepare():
    PRIVATE.mkdir(parents=True, exist_ok=True)
    if not PROFILE.exists():
        write_json(PROFILE, {"schema": "wilson-expedition/iteration-profile@1",
                            "owner": uuid.uuid4().hex, "storageRoot": str(STORAGE),
                            "clientLog": str(Path.home() / "Documents/Klei/DoNotStarveTogether/client_log.txt")})
    profile = load_profile()
    marker = STORAGE / ".wilson-expedition-owner.json"
    if STORAGE.exists() and not marker.exists():
        raise ValueError("Existing unowned storage will not be adopted: " + str(STORAGE))
    if marker.exists():
        ownership = read_json(marker)
        if ownership.get("owner") != profile["owner"] or Path(ownership.get("project", "")).resolve() != PROJECT.resolve():
            raise ValueError("Test storage belongs to another owner/project")
    STORAGE.mkdir(parents=True, exist_ok=True)
    write_json(marker, {"owner": profile["owner"], "project": str(PROJECT)})
    cluster = STORAGE / "WilsonExpedition/Iteration"
    cluster.mkdir(parents=True, exist_ok=True)
    if not (cluster / "cluster.ini").exists():
        (cluster / "cluster.ini").write_text(
            "[GAMEPLAY]\ngame_mode = endless\nmax_players = 1\npvp = false\npause_when_empty = true\n"
            "[NETWORK]\ncluster_name = WilsonExpedition Iteration\ncluster_description = Project-owned test world\n"
            "lan_only_cluster = true\noffline_cluster = true\ncluster_intention = cooperative\n"
            "[SHARD]\nshard_enabled = true\nbind_ip = 127.0.0.1\nmaster_ip = 127.0.0.1\nmaster_port = 11243\n"
            "cluster_key = " + profile["owner"] + "\n[MISC]\nconsole_enabled = true\n", encoding="utf-8")
    for name, shard_id, port, preset in (("Master", "1", 11011, "ENDLESS"),
                                         ("Caves", "2", 11012, "DST_CAVE")):
        directory = cluster / name
        directory.mkdir(exist_ok=True)
        for file, content in {
            "server.ini": ("[NETWORK]\nserver_port = %d\n[SHARD]\nis_master = %s\nname = %s\nid = %s\n"
                           "[STEAM]\nauthentication_port = %d\nmaster_server_port = %d\n" %
                           (port, "true" if name == "Master" else "false", name, shard_id,
                            11243 + int(shard_id), 11245 + int(shard_id))),
            "worldgenoverride.lua": 'return { override_enabled = true, preset = "%s", overrides = { specialevent = "none" } }\n' % preset,
            "modoverrides.lua": ('return { ["WilsonExpeditionDiagnostics"] = { enabled = true, '
                                 'configuration_options = { auto_iteration = true } } }\n'),
        }.items():
            target = directory / file
            if not target.exists():
                target.write_text(content, encoding="utf-8")
    disable_world_events(cluster)
    # [喵喵喵]: 客户端使用项目独立存储，仅启用本项目 Mod，不修改平时的存档与 Mod 列表。
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam\ActiveProcess") as key:
        account = str(winreg.QueryValueEx(key, "ActiveUser")[0])
    if not account.isdigit() or int(account) <= 0:
        raise ValueError("Start Steam with the test account before preparing the client profile")
    client_root = STORAGE / "Client"
    client_conf = client_root / "WilsonExpeditionClient"
    client_save = client_conf / account / "client_save"
    client_save.mkdir(parents=True, exist_ok=True)
    modindex = client_save / "modindex"
    if not modindex.exists():
        modindex.write_text('return { known_api_version = 10, known_mods = { '
                            '["WilsonExpedition"] = { enabled = true, seen_api_version = 10 }, '
                            '["WilsonExpeditionDiagnostics"] = { enabled = false, seen_api_version = 10 } } }\n',
                            encoding="utf-8")
    settings = client_conf / "settings.ini"
    adminlist = cluster / "adminlist.txt"
    if not adminlist.exists():
        adminlist.write_text("OU_" + str(76561197960265728 + int(account)) + "\n", encoding="utf-8")
    if not settings.exists():
        settings.write_text('[MISC]\nconsole_enabled = true\nmodswarning = false\nwarn_mods_enabled = false\n'
                            '[GRAPHICS]\nfullscreen = false\n', encoding="utf-8")
    profile.update(clientStorageRoot=str(client_root), clientConfDir="WilsonExpeditionClient", account=account,
                   clientLog=str(client_conf / "client_log.txt"), clientModIndex=str(modindex))
    write_json(PROFILE, profile)
    config = PRIVATE / "iteration-capture.json"
    write_json(config, {"client_log": profile["clientLog"], "enqueue_iterations": True,
                        "server_logs": [str(cluster / name / "server_log.txt") for name in ("Master", "Caves")],
                        "server_log_roots": []})
    return profile, cluster, config


def client_command(profile):
    return [str(GAME / "bin64/dontstarve_steam_x64.exe"), "-persistent_storage_root", profile["clientStorageRoot"],
            "-conf_dir", profile["clientConfDir"], "-offline", "+connect", "127.0.0.1:11011"]


def config_table(path):
    """Read the generated literal Lua tables without executing Lua."""
    from luaparser import ast as lua_ast
    from luaparser import astnodes as nodes
    text = Path(path).read_text(encoding="utf-8-sig")
    if text.startswith("KLEI     1D"):
        import base64
        import struct
        import zlib
        data = base64.b64decode(text[11:].strip(), validate=True)
        version, offset, size, packed = struct.unpack("<4I", data[:16])
        if version != 1 or offset != 16 or not 0 < size <= 4 * 1024 * 1024 or packed != len(data) - 16:
            raise ValueError("Invalid compressed configuration header: " + str(path))
        decoder = zlib.decompressobj()
        decoded = decoder.decompress(data[16:], size + 1)
        if len(decoded) != size or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
            raise ValueError("Invalid compressed configuration payload: " + str(path))
        text = decoded.decode("utf-8")
    elif text.startswith("KLEI     1"):
        text = text[10:]
    # [喵喵喵]: 原版会将配置写回为明文或压缩格式；解码后仍只解析字面量，不执行 Lua。
    tree = lua_ast.parse(text)
    body = tree.body.body
    if len(body) != 1 or not isinstance(body[0], nodes.Return) or len(body[0].values) != 1:
        raise ValueError("Expected a literal return table: " + str(path))

    def value(node):
        if isinstance(node, nodes.Table):
            result = {}
            for field in node.fields:
                key = field.key.id if isinstance(field.key, nodes.Name) else value(field.key)
                if not isinstance(key, (str, int)) or key in result:
                    raise ValueError("Invalid or duplicate table key: " + str(path))
                result[key] = value(field.value)
            return result
        if isinstance(node, nodes.String):
            return node.s.decode("utf-8") if isinstance(node.s, bytes) else node.s
        if isinstance(node, nodes.Number):
            return node.n
        if isinstance(node, (nodes.TrueExpr, nodes.FalseExpr)):
            return node.value
        raise ValueError("Only literal configuration values are allowed: " + str(path))

    result = value(body[0].values[0])
    if not isinstance(result, dict):
        raise ValueError("Expected a table: " + str(path))
    return result


def disable_world_events(cluster):
    """Set the next owned world startup to vanilla events-none without editing saves."""
    for shard in ("Master", "Caves"):
        path = cluster / shard / "worldgenoverride.lua"
        world = config_table(path)
        if (world.get("override_enabled") is not True or not isinstance(world.get("overrides"), dict)
                or set(world) - {"override_enabled", "preset", "worldgen_preset", "settings_preset", "overrides"}
                or not all(isinstance(k, str) and isinstance(v, str) for k, v in world["overrides"].items())):
            raise ValueError("Unexpected world generation configuration: " + shard)
        if world["overrides"].get("specialevent") == "none":
            continue
        world["overrides"]["specialevent"] = "none"
        lines = ["return {", "    override_enabled = true,"]
        for key in ("preset", "worldgen_preset", "settings_preset"):
            if key in world:
                if not isinstance(world[key], str):
                    raise ValueError("Invalid world preset: " + shard)
                lines.append("    " + key + " = " + json.dumps(world[key], ensure_ascii=False) + ",")
        lines.append("    overrides = {")
        for key, value in sorted(world["overrides"].items()):
            lines.append("        [" + json.dumps(key, ensure_ascii=False) + "] = " + json.dumps(value, ensure_ascii=False) + ",")
        lines.extend(["    },", "}", ""])
        temporary = path.with_name(path.name + ".tmp")
        temporary.write_text("\n".join(lines), encoding="utf-8")
        temporary.replace(path)


def preflight():
    profile = load_profile()
    marker = read_json(STORAGE / ".wilson-expedition-owner.json")
    if marker.get("owner") != profile["owner"] or Path(marker.get("project", "")).resolve() != PROJECT.resolve():
        raise ValueError("Test storage ownership does not match this project")
    if Path(profile.get("clientStorageRoot", "")).resolve() != (STORAGE / "Client").resolve():
        raise ValueError("Client must use the isolated test storage")
    if profile.get("clientConfDir") != "WilsonExpeditionClient" or not re.fullmatch(r"\d+", profile.get("account", "")):
        raise ValueError("Invalid isolated client configuration")
    client_conf = STORAGE / "Client/WilsonExpeditionClient"
    if Path(profile.get("clientLog", "")).resolve() != (client_conf / "client_log.txt").resolve():
        raise ValueError("Client log must be collected from the isolated profile")
    if Path(profile.get("clientModIndex", "")).resolve() != (client_conf / profile["account"] / "client_save/modindex").resolve():
        raise ValueError("Client Mod index must belong to the test account")
    validation = check_sources()
    for executable in (GAME / "bin64/dontstarve_dedicated_server_nullrenderer_x64.exe", GAME / "bin64/dontstarve_steam_x64.exe"):
        if not executable.is_file():
            raise ValueError("Game executable unavailable: " + str(executable))
    modindex = config_table(profile["clientModIndex"])
    mods = modindex.get("known_mods", {})
    # [喵喵喵]: 连接服务器后原版保留临时启停标记；按 IsModEnabledAny 核对实际加载集，而非要求所有临时标记为空。 (2026-11-11)
    if (not all(isinstance(row, dict) for row in mods.values())
            or {name for name, row in mods.items() if row.get("enabled") is True} != {"WilsonExpedition"}
            or mods.get("WilsonExpeditionDiagnostics", {}).get("enabled") is not False
            or {name for name, row in mods.items()
                if (row.get("enabled") is True or row.get("temp_enabled") is True)
                and row.get("temp_disabled") is not True}
                not in ({"WilsonExpedition"}, {"WilsonExpedition", "WilsonExpeditionDiagnostics"})
            or any(row.get("disabled_bad") for row in mods.values())
            or any(row.get(flag) is not None and not isinstance(row[flag], bool)
                   for row in mods.values() for flag in ("enabled", "temp_enabled", "temp_disabled", "disabled_bad"))):
        raise ValueError("The isolated client profile must enable only this project's automation Mod")
    cluster = STORAGE / "WilsonExpedition/Iteration"
    adminlist = cluster / "adminlist.txt"
    expected_admin = "OU_" + str(76561197960265728 + int(profile["account"]))
    if not adminlist.is_file() or adminlist.read_text(encoding="utf-8-sig").splitlines() != [expected_admin]:
        raise ValueError("The isolated offline test account must be the cluster's only pause administrator")
    ini = configparser.ConfigParser()
    ini.read(cluster / "cluster.ini", encoding="utf-8-sig")
    if (ini.get("GAMEPLAY", "game_mode") != "endless" or ini.getint("GAMEPLAY", "max_players") != 1
            or not ini.getboolean("GAMEPLAY", "pause_when_empty") or ini.getboolean("GAMEPLAY", "pvp")
            or not ini.getboolean("NETWORK", "offline_cluster") or not ini.getboolean("NETWORK", "lan_only_cluster")
            or not ini.getboolean("SHARD", "shard_enabled") or ini.get("SHARD", "bind_ip") != "127.0.0.1"
            or ini.get("SHARD", "master_ip") != "127.0.0.1" or ini.getint("SHARD", "master_port") != 11243
            or ini.get("SHARD", "cluster_key") != profile["owner"]):
        raise ValueError("Test cluster gameplay/ownership settings have changed")
    for name, preset, port in (("Master", "ENDLESS", 11011), ("Caves", "DST_CAVE", 11012)):
        directory = cluster / name
        server = configparser.ConfigParser()
        server.read(directory / "server.ini", encoding="utf-8-sig")
        if (server.getint("NETWORK", "server_port") != port
                or server.getboolean("SHARD", "is_master") != (name == "Master")
                or server.get("SHARD", "id") != ("1" if name == "Master" else "2")
                or server.getint("STEAM", "authentication_port") != (11244 if name == "Master" else 11245)
                or server.getint("STEAM", "master_server_port") != (11246 if name == "Master" else 11247)):
            raise ValueError("Test shard settings mismatch: " + name)
        level_data = directory / "leveldataoverride.lua"
        if level_data.exists() and level_data.read_text(encoding="utf-8-sig").strip() != "return nil":
            raise ValueError("World presets must be supplied through worldgenoverride.lua: " + name)
        world = config_table(directory / "worldgenoverride.lua")
        if world.get("overrides", {}).get("specialevent") == "none":
            world["overrides"] = {key: value for key, value in world["overrides"].items() if key != "specialevent"}
        expected_world = {"override_enabled": True, "preset": preset, "overrides": {}}
        saved_world = {"override_enabled": True, "worldgen_preset": preset, "settings_preset": preset, "overrides": {}}
        saved_cave = dict(saved_world, overrides={"basicresource_regrowth": "always", "ghostsanitydrain": "none",
                                                  "portalresurection": "always", "resettime": "none"})
        # [喵喵喵]: 原版会将地表无尽模式的四项设置同步写入洞穴；它们与空覆盖使用同一游戏模式。
        if world not in (expected_world, saved_world) and (name != "Caves" or world != saved_cave):
            raise ValueError("Keep the standard endless surface preset and cave preset: " + name)
        mods = config_table(directory / "modoverrides.lua")
        if mods != {"WilsonExpeditionDiagnostics": {"enabled": True, "configuration_options": {"auto_iteration": True}}}:
            raise ValueError("Only the diagnostic Mod with automatic Wilson selection is allowed: " + name)
    config = read_json(PRIVATE / "iteration-capture.json")
    expected_logs = [str(cluster / name / "server_log.txt") for name in ("Master", "Caves")]
    if config.get("client_log") != profile["clientLog"] or config.get("server_logs") != expected_logs or config.get("enqueue_iterations") is not True:
        raise ValueError("Capture configuration does not match the owned cluster")
    if (PRIVATE / "iteration-run.lock").exists():
        raise ValueError("Iteration lock exists; inspect the owner before starting")
    state = read_json(STATE) if STATE.exists() else None
    if state is not None and state.get("stage") not in ("stopped", "closed"):
        raise ValueError("Previous iteration state must be inspected before launch")
    ready_path = PRIVATE / "iteration-agent-ready.json"
    agent = read_json(ready_path) if ready_path.exists() else {}
    target_path = PRIVATE / "iteration-agent-target.json"
    target = read_json(target_path) if target_path.exists() else {}
    target_session = target.get("sessionId") if target.get("schema") == "wilson-expedition/agent-target@1" else None
    notified_at = agent.get("updatedUtc")
    agent_ready = False
    if isinstance(notified_at, str):
        try:
            elapsed = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(notified_at)).total_seconds()
            # [喵喵喵]: 同项目的其他会话也可能有新鲜心跳；只有显式指定对话的回执才允许启动测试。 (2026-11-13)
            agent_ready = (isinstance(target_session, str) and bool(target_session.strip())
                           and agent.get("sessionId") == target_session and agent.get("routing") == "explicit-session@1"
                           and agent.get("schema") == "wilson-expedition/agent-ready@1" and agent.get("status") == "active"
                           and 0 <= elapsed <= 30
                           and (not os.environ.get("PI_SESSION_ID") or agent.get("sessionId") == os.environ["PI_SESSION_ID"]))
        except (ValueError, TypeError):
            pass
    return {"schema": "wilson-expedition/preflight@1", "checkedUtc": now(), "status": "static_ready",
            "sourceRevision": revision(), "validation": validation, "cluster": str(cluster),
            "clientLog": profile["clientLog"], "clientCommand": client_command(profile),
            "enabledClientMod": "WilsonExpedition", "enabledServerMod": "WilsonExpeditionDiagnostics",
            "gameMode": "endless", "surfacePreset": "ENDLESS", "cavePreset": "DST_CAVE",
            "acceptance": "Wilson survives 70 full in-game days through all four seasons; death invalidates the run",
            "runtimeVerified": False,
            "runtimeChecks": ["Client Mod load, native Lua engine and input path", "Both shard handshakes and character selection",
                              "Death capture and source repair approval", "World regeneration reloads client and both shard builds"],
            "agentExtension": {"path": str(PROJECT / ".pi/extensions/wilson-iteration.js"),
                               "receipt": str(ready_path), "targetSessionId": target_session, "ready": agent_ready},
            "remainingPrerequisites": ([] if agent_ready else ["Reload Pi extensions and run /wilson-notify-here in the intended conversation"])
                                      + ["Explicit game-test authorization is required"],
            "relayRequired": False}


def write_revision(value):
    build = value + ":" + uuid.uuid4().hex
    for path in REVISION_FILES:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('return "%s"\n' % build, encoding="utf-8")
    return build


def process_command(process, command):
    if process.poll() is not None:
        raise ValueError("Owned server process is no longer running")
    process.stdin.write((command + "\n").encode("utf-8"))
    process.stdin.flush()


def set_world_paused(processes, cluster, state, challenge, paused):
    import death_watch
    process_command(processes["Master"], "c_save(); WilsonExpeditionPauseTest(" +
                    json.dumps(state["revision"]) + ", " + json.dumps(challenge) + ", " + json.dumps(paused) + ")")
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        confirmed = {}
        for name in ("Master", "Caves"):
            _, _, data = death_watch.read_tail(cluster / name / "server_log.txt")
            events = [event for event in death_watch.diagnostic_events(data, MARKER)
                      if event.get("event") == "test_pause_state" and event.get("revision") == state["revision"]
                      and event.get("session") == state["sessions"].get(name)]
            if events and (events[-1].get("detail") or {}).get("paused") is paused:
                confirmed[name] = events[-1]
        if len(confirmed) == 2:
            return {"confirmedUtc": now(), "paused": paused, "shards": confirmed}
        if any(process.poll() is not None for process in processes.values()):
            raise ValueError("An owned shard exited before the world pause was confirmed")
        time.sleep(0.5)
    raise ValueError("Both shards did not confirm the requested native world pause state within 15 seconds")


def observe_new_world(cluster, old_sessions, expected):
    # [喵喵喵]: 每次加载使用独立 build 标识，旧日志里的同版事件不能冒充新世界的就绪信号。
    import death_watch
    sessions = {}
    for name in ("Master", "Caves"):
        try:
            _, _, data = death_watch.read_tail(cluster / name / "server_log.txt")
        except OSError:
            return None
        events = list(death_watch.diagnostic_events(data, MARKER))
        loaded = [e for e in events if e.get("event") == "world_loaded" and e.get("revision") == expected]
        if not loaded or not loaded[-1].get("session"):
            return None
        sessions[name] = loaded[-1]["session"]
        if sessions[name] == old_sessions.get(name):
            return None
    return sessions


def observe_survival_complete(profile, cluster, state):
    import death_watch
    try:
        _, _, data = death_watch.read_tail(Path(profile["clientLog"]))
    except OSError:
        return False
    client = any(e.get("event") == "survival_complete" and e.get("challenge") == state.get("challenge")
                 and e.get("revision") == state["revision"]
                 for e in death_watch.diagnostic_events(data, death_watch.MARKER))
    if not client:
        return False
    for name in ("Master", "Caves"):
        try:
            _, _, data = death_watch.read_tail(cluster / name / "server_log.txt")
        except OSError:
            continue
        for event in death_watch.diagnostic_events(data, MARKER):
            if (event.get("event") == "survival_complete" and event.get("challenge") == state.get("challenge")
                    and event.get("revision") == state["revision"] and event.get("session") in state["sessions"].values()):
                detail = event.get("detail") or {}
                seasons = detail.get("seasons") or {}
                if (isinstance(detail.get("elapsed_days"), (int, float)) and detail["elapsed_days"] >= 70
                        and all(seasons.get(s) is True for s in ("autumn", "winter", "spring", "summer"))):
                    return True
    return False


def observe_client_start(profile, state):
    import death_watch
    try:
        _, _, data = death_watch.read_tail(Path(profile["clientLog"]))
    except OSError:
        return None
    for event in reversed(list(death_watch.diagnostic_events(data, death_watch.MARKER))):
        if (event.get("event") == "start" and event.get("revision") == state["revision"]
                and event.get("session") in state["sessions"].values() and event.get("challenge")):
            return event["challenge"]
    return None


def run_owned(validation, capture_only=False):
    # [喵喵喵]: 唯一可以重建的对象由本进程创建并持有 stdin；不搜索或接管其他存档、进程和服务器。
    if STATE.exists() and read_json(STATE).get("stage") not in ("stopped", "closed"):
        raise ValueError("Existing iteration state needs inspection; an interrupted server is never silently adopted")
    (PRIVATE / "iteration-stop.request").unlink(missing_ok=True)
    profile = load_profile()
    cluster = STORAGE / "WilsonExpedition/Iteration"
    capture_config = PRIVATE / "iteration-capture.json"
    executable = GAME / "bin64/dontstarve_dedicated_server_nullrenderer_x64.exe"
    if not executable.is_file():
        raise ValueError("Dedicated server executable is unavailable")
    current = revision()
    build = write_revision(current)
    state = {"schema": "wilson-expedition/iteration-state@1", "owner": profile["owner"],
             "pid": os.getpid(), "stage": "starting", "revision": build, "sourceRevision": current,
             "sessions": {}, "round": 1, "updatedUtc": now(), "validation": validation,
             "deathPolicy": "capture_only" if capture_only else "repair_and_regenerate"}
    write_json(STATE, state)
    processes, handles = {}, []
    watcher = None
    client = None
    client_environment = dict(os.environ, SteamAppId="322330", SteamGameId="322330")
    try:
        for name in ("Master", "Caves"):
            output = (PRIVATE / (name + "-console.log")).open("ab", buffering=0)
            handles.append(output)
            processes[name] = subprocess.Popen(
                [str(executable), "-console", "-persistent_storage_root", str(STORAGE),
                 "-conf_dir", "WilsonExpedition", "-cluster", "Iteration", "-shard", name],
                cwd=str(GAME / "bin64"), stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT)
        watcher_output = (PRIVATE / "death-watch.log").open("ab", buffering=0)
        handles.append(watcher_output)
        watcher = subprocess.Popen([sys.executable, str(ROOT / "death_watch.py"), "--watch",
                                    "--config", str(capture_config)], cwd=str(ROOT),
                                   stdout=watcher_output, stderr=subprocess.STDOUT)
        deadline, resetting = time.monotonic() + 240, None
        while True:
            if any(p.poll() is not None for p in processes.values()) or watcher.poll() is not None:
                raise ValueError("An owned server or capture process exited; inspect its log before recovery")
            if client is not None and client.poll() is not None:
                raise ValueError("The owned game client exited; inspect client_log.txt before recovery")
            if (PRIVATE / "iteration-stop.request").exists():
                state["stage"] = "stopped"
                break
            sessions = (observe_new_world(cluster, state["sessions"], state["revision"])
                        if state["stage"] in ("starting", "regenerating") else None)
            if sessions is not None:
                state["sessions"] = sessions
                state.pop("pause", None)
                state["stage"] = "world_ready"
                deadline = time.monotonic() + 180
                if resetting is not None:
                    path, job = resetting
                    job["stage"], job["newSessions"] = "new_world_ready", sessions
                    write_json(path, job)
            if state["stage"] == "world_ready":
                if client is None:
                    output = (PRIVATE / "client-console.log").open("ab", buffering=0)
                    handles.append(output)
                    client = subprocess.Popen(client_command(profile), cwd=str(GAME / "bin64"),
                                              env=client_environment, stdout=output, stderr=subprocess.STDOUT)
                challenge = observe_client_start(profile, state)
                if challenge is not None:
                    state["stage"], state["challenge"] = "running", challenge
                    state.pop("death", None)
                    if resetting is not None:
                        path, job = resetting
                        job["stage"], job["nextChallenge"] = "next_round_running", challenge
                        write_json(path, job)
                        resetting = None
                # [喵喵喵]: 可见单轮测试等待人工确认启动界面，自动迭代仍检查客户端启动期限。
                elif time.monotonic() > deadline and not capture_only:
                    raise ValueError("The client did not start the new world with the approved build within 180 seconds")
            if state["stage"] in ("starting", "regenerating") and time.monotonic() > deadline:
                raise ValueError("New sessions with the approved revision were not observed within 240 seconds")
            if state["stage"] == "running" and observe_survival_complete(profile, cluster, state):
                state["pause"] = set_world_paused(processes, cluster, state, state["challenge"], True)
                state["stage"] = "survival_complete"
                state["completedUtc"] = now()
            for path in sorted(QUEUE.glob("*.json")):
                job = read_json(path)
                if job.get("stage") not in ("awaiting_fix", "approved", "captured"):
                    continue
                _, job, bundle, events = load_job(job["id"])
                if (bundle.get("revision") != state["revision"]
                        or bundle.get("session") not in state["sessions"].values()):
                    continue
                if not any(matches_death(bundle, e) for e in events):
                    continue
                if state["stage"] not in ("world_ready", "running", "awaiting_fix"):
                    continue
                if state.get("challenge") is not None and state["challenge"] != job["challenge"]:
                    continue
                if state["stage"] in ("world_ready", "running"):
                    state["pause"] = set_world_paused(processes, cluster, state, job["challenge"], True)
                    state["stage"], state["death"] = ("death_captured" if capture_only else "awaiting_fix"), job["id"]
                # [喵喵喵]: 单轮观察只封存证据，保持死亡画面；既不审批修复，也不重建世界。
                if capture_only:
                    job["stage"] = "captured"
                    job["deathPolicy"] = "capture_only"
                    write_json(path, job)
                    continue
                if job["stage"] != "approved" or state.get("death") != job["id"]:
                    continue
                approval = job.get("approval") or {}
                if revision() != approval.get("revision") or approval.get("revision") == state["sourceRevision"]:
                    raise ValueError("Approved source revision changed or no repair was made")
                check_sources()
                marker = read_json(STORAGE / ".wilson-expedition-owner.json")
                if marker.get("owner") != state["owner"]:
                    raise ValueError("Cluster ownership changed")
                build = write_revision(approval["revision"])
                # [喵喵喵]: 保持故障世界暂停到引擎执行重建；不依赖暂停客户端再回应解暂停 RPC。 (2026-11-12)
                process_command(processes["Master"], "c_regenerateworld()")
                job["stage"], job["resetRequestedUtc"] = "regenerating", now()
                write_json(path, job)
                state.update(stage="regenerating", revision=build, sourceRevision=approval["revision"],
                             round=state["round"] + 1)
                resetting = path, job
                deadline = time.monotonic() + 240
                break
            state["updatedUtc"] = now()
            write_json(STATE, state)
            time.sleep(2)
    except BaseException as exc:
        state["stage"], state["error"] = "blocked", str(exc)
        raise
    finally:
        # [喵喵喵]: 只关闭本次 Popen 创建的进程；异常不触发新一轮，也不删除故障存档。
        for process in processes.values():
            if process.poll() is None:
                try:
                    process_command(process, "c_shutdown()")
                    process.wait(timeout=10)
                except (OSError, ValueError, subprocess.TimeoutExpired):
                    process.terminate()
                    process.wait(timeout=5)
        if client is not None and client.poll() is None:
            client.terminate()
            client.wait(timeout=10)
        if watcher is not None and watcher.poll() is None:
            watcher.terminate()
            watcher.wait(timeout=5)
        for handle in handles:
            handle.close()
        state["childrenExited"] = all(p.poll() is not None for p in processes.values())
        state["updatedUtc"] = now()
        write_json(STATE, state)


def run(capture_only=False):
    PRIVATE.mkdir(parents=True, exist_ok=True)
    report = preflight()
    if not report["agentExtension"]["ready"]:
        raise ValueError("Reload Pi extensions and run /wilson-notify-here: the designated conversation must have a current notifier heartbeat")
    # [喵喵喵]: 已运行的客户端可能持有不同配置；不接管、不关闭它，也不让 Steam 复用它连接测试世界。
    probe = subprocess.run(["pwsh", "-NoProfile", "-Command",
                            '$ErrorActionPreference="Stop"; @(Get-Process -ErrorAction SilentlyContinue | '
                            'Where-Object { $_.ProcessName -like "dontstarve*" } | '
                            'Select-Object ProcessName,Id) | ConvertTo-Json -Compress'],
                           capture_output=True, text=True, encoding="utf-8", timeout=15, check=True)
    if probe.stdout.strip() not in ("", "[]"):
        raise ValueError("An existing DST client/server is running; close it explicitly before the isolated test")
    ports = subprocess.run(["pwsh", "-NoProfile", "-Command",
                            '$ErrorActionPreference="Stop"; $ports=@(Get-NetUDPEndpoint | '
                            'Where-Object { $_.LocalPort -in @(11011,11012,11243,11244,11245,11246,11247) }); '
                            '$tcp=@(Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -eq 11243 }); '
                            'Write-Output ($ports.Count + $tcp.Count)'],
                           capture_output=True, text=True, encoding="utf-8", timeout=20, check=True)
    if ports.stdout.strip() != "0":
        raise ValueError("The reserved test ports are occupied; no existing process was stopped")
    # [喵喵喵]: 只在确认游戏进程和端口空闲后的下次启动写覆盖项，不改变正在运行的挑战。
    disable_world_events(STORAGE / "WilsonExpedition/Iteration")
    lock = PRIVATE / "iteration-run.lock"
    handle = lock.open("x", encoding="utf-8")
    try:
        handle.write(str(os.getpid()))
        handle.flush()
        return run_owned(report["validation"], capture_only=capture_only)
    finally:
        handle.close()
        lock.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prepare")
    launch = commands.add_parser("run")
    launch.add_argument("--capture-only", action="store_true", help="Pause after death and keep evidence without repairing or regenerating")
    commands.add_parser("status")
    commands.add_parser("preflight")
    commands.add_parser("stop")
    approval = commands.add_parser("approve")
    approval.add_argument("id")
    approval.add_argument("--summary", required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        profile, cluster, config = prepare()
        result = {"profile": str(PROFILE), "cluster": str(cluster), "captureConfig": str(config)}
    elif args.command == "run":
        run(capture_only=args.capture_only)
        return 0
    elif args.command == "preflight":
        result = preflight()
        write_json(PRIVATE / "preflight.json", result)
    elif args.command == "approve":
        result = approve(args.id, args.summary)
    elif args.command == "stop":
        PRIVATE.mkdir(parents=True, exist_ok=True)
        (PRIVATE / "iteration-stop.request").write_text(now(), encoding="utf-8")
        result = {"stopRequested": True}
    else:
        result = {"state": read_json(STATE) if STATE.exists() else None,
                  "pending": [read_json(p) for p in sorted(QUEUE.glob("*.json"))]}
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, ImportError, configparser.Error, subprocess.SubprocessError) as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(2)
