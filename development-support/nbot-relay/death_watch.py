"""Watch local DST client death markers and archive matching server/client evidence."""

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import time

import relay_tool
import iteration

ROOT = Path(__file__).resolve().parent
DEFAULT_CLIENT = Path.home() / "Documents/Klei/DoNotStarveTogether/client_log.txt"
MAX_TAIL = 4 * 1024 * 1024
MARKER = b"[WilsonExpedition] "
SERVER_MARKER = b"[WilsonExpeditionDiagnostics] "


def read_tail(path):
    with path.open("rb") as handle:
        size = handle.seek(0, os.SEEK_END)
        start = max(0, size - MAX_TAIL)
        handle.seek(start)
        data = handle.read(MAX_TAIL)
    return size, start, data


def diagnostic_events(data, marker):
    for line in data.splitlines():
        at = line.find(marker)
        if at < 0:
            continue
        try:
            value = json.loads(line[at + len(marker):].decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(value, dict):
            yield value


def death_bundles(data, client_log):
    events = list(diagnostic_events(data, MARKER))
    keys = ("challenge", "userid", "session", "revision")
    identities = {tuple(event.get(key) for key in keys) for event in events
                  if event.get("schema") == "wilson-expedition/client-event@1"
                  and all(isinstance(event.get(key), str) and 0 < len(event[key]) <= 256 for key in keys)}
    for event in events:
        if event.get("schema") == "wilson-expedition/death-bundle@1":
            yield event
    if not identities:
        return
    # [喵喵喵]: 完整死亡轨迹由 SetPersistentString 保存；仅读取当前客户端日志已证明身份的本地文件，恢复被原生日志截断的证据。 (2026-11-11)
    for account in client_log.parent.iterdir():
        if not account.name.isascii() or not account.name.isdigit() or not account.is_dir():
            continue
        directory = account / "client_save"
        candidates = sorted(directory.glob("wilsonexpedition_death_*"),
                            key=lambda path: path.stat().st_mtime, reverse=True)[:32]
        for path in candidates:
            with path.open("rb") as handle:
                raw = handle.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                continue
            if raw.startswith(b"KLEI     1 "):
                raw = raw[10:]
            try:
                bundle = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if (isinstance(bundle, dict) and bundle.get("schema") == "wilson-expedition/death-bundle@1"
                    and all(isinstance(bundle.get(key), str) for key in keys)
                    and tuple(bundle[key] for key in keys) in identities):
                yield bundle


def resource_review(trace):
    decreases, light_use = {}, {}

    def finite(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

    def natural_light(row):
        light = row.get("light") or {}
        return (row.get("shard_kind") == "surface" and row.get("phase") in ("day", "dusk")
                and finite(row.get("time_until_night")) and row["time_until_night"] > 5
                and light.get("in_light") is True and light.get("dark") is False
                and finite(light.get("ambient")) and finite(light.get("threshold"))
                and 0 < light["threshold"] <= light["ambient"] <= 1
                and finite(row.get("temperature")) and 15 <= row["temperature"] <= 60
                and row.get("threats") == [])

    for before, after in zip(trace, trace[1:]):
        if (not finite(before.get("tick")) or not finite(after.get("tick"))
                or not 0 < after["tick"] - before["tick"] <= 1
                or not isinstance(before.get("session"), str) or not before["session"]
                or before["session"] != after.get("session")
                or not isinstance(before.get("shard"), str) or not before["shard"]
                or before["shard"] != after.get("shard")
                or before.get("mode") != "running" or after.get("mode") != "running"
                or before.get("ghost") is not False or after.get("ghost") is not False):
            continue
        previous, current = before.get("inventory_counts"), after.get("inventory_counts")
        # [喵喵喵]: 原版 json 将空 Lua 表编码为 []；缺失字段仍表示未知，不能把死亡或初始化当成物资耗尽。
        if previous == []:
            previous = {}
        if current == []:
            current = {}
        if isinstance(previous, dict) and isinstance(current, dict):
            for prefab, count in previous.items():
                remaining = current.get(prefab, 0)
                if finite(count) and finite(remaining) and 0 <= remaining < count:
                    decreases[prefab] = decreases.get(prefab, 0) + count - remaining
        if not natural_light(before) or not natural_light(after):
            continue
        equipment = before.get("equipment") or {}
        for slot, condition in (before.get("equipment_condition") or {}).items():
            prefab = equipment.get(slot)
            later = (after.get("equipment_condition") or {}).get(slot, {})
            if (prefab not in ("torch", "lantern", "minerhat")
                    or (after.get("equipment") or {}).get(slot) != prefab
                    or condition.get("guid") is None or condition["guid"] != later.get("guid")
                    or not finite(condition.get("remaining")) or not finite(later.get("remaining"))
                    or not 0 <= later["remaining"] < condition["remaining"] <= 1):
                continue
            observation = light_use.setdefault((before["session"], before["shard"], prefab), {
                "kind": "light_in_natural_light", "prefab": prefab,
                "session": before["session"], "shard": before["shard"],
                "firstTick": before["tick"], "lastTick": after["tick"], "remainingFractionLost": 0,
                "reviewRequired": True,
            })
            observation["lastTick"] = after["tick"]
            observation["remainingFractionLost"] = round(observation["remainingFractionLost"]
                                                         + condition["remaining"] - later["remaining"], 6)
    return {"inventoryDecreases": decreases, "suspectedWaste": list(light_use.values()),
            "basis": "Adjacent visible observations; count decreases include useful consumption and transfers. "
                     "Inspect tasks and survival needs before changing behavior."}


def classify(bundle, events):
    trace = bundle.get("trace") or []
    recent = trace[-12:]
    last = recent[-1] if recent else {}
    attacks = [event for event in events if event.get("event") == "attacked"]
    reasons = [str(row.get("reason", "")) for row in recent]
    findings = []
    temperature = last.get("temperature")
    hunger = last.get("hunger")
    if isinstance(temperature, (int, float)) and temperature <= 0:
        findings.append({"kind": "cold", "evidence": "last_temperature", "value": temperature})
    if isinstance(temperature, (int, float)) and temperature >= 70:
        findings.append({"kind": "heat", "evidence": "last_temperature", "value": temperature})
    if isinstance(hunger, (int, float)) and hunger <= 0:
        findings.append({"kind": "starvation", "evidence": "last_hunger", "value": hunger})
    sourced_attacks = [event for event in attacks if event.get("detail", {}).get("attacker")]
    unsourced_attacks = [event for event in attacks if not event.get("detail", {}).get("attacker")]
    dark = any(row.get("light", {}).get("dark") is True
               or "dark_no_light" in str(row.get("reason", "")) for row in recent)
    if sourced_attacks:
        findings.append({"kind": "combat", "evidence": "server_attacker", "last_attacks": sourced_attacks[-6:]})
    if unsourced_attacks:
        findings.append({"kind": "darkness" if dark else "unattributed_damage",
                         "evidence": "client_dark_no_light_and_server_damage" if dark else "server_damage_without_attacker",
                         "last_attacks": unsourced_attacks[-6:]})
    if any(any(word in reason for word in ("stuck", "stall", "deadline", "no_path")) for reason in reasons):
        findings.append({"kind": "action_or_navigation", "evidence": "client_reasons", "reasons": reasons})
    if not findings:
        findings.append({"kind": "undetermined", "evidence": "insufficient_matching_observations"})
    return {"schema": "wilson-expedition/death-analysis@1", "challenge": bundle.get("challenge"),
            "hypotheses": findings, "causalityConfirmed": False,
            "resourceReview": resource_review(trace),
            "nextStep": "Inspect matching client/server evidence, fix the proven shared cause, syntax-check, then start a new challenge.",
            "trialPolicy": "Death invalidates this run; resume and resurrection do not certify the original challenge."}


def server_sources(config, bundle):
    challenge, userid = bundle.get("challenge"), bundle.get("userid")
    candidates = {Path(value) for value in config.get("server_logs", [])}
    for value in config.get("server_log_roots", []):
        root = Path(value)
        if not root.is_dir():
            continue
        # [喵喵喵]: 仅在配置的本机存档根目录找日志，避免遍历盘符或把其他机器的日志当作故障分片。
        directories = 0
        for current, children, files in os.walk(root):
            directories += 1
            children[:] = [child for child in children if child not in ("backup", "captures", ".git")]
            if directories > 2048:
                break
            if "server_log.txt" in files:
                candidates.add(Path(current) / "server_log.txt")
    matched = []
    for path in sorted(candidates):
        try:
            _, _, data = read_tail(path)
        except OSError:
            matched.append((path, []))
            continue
        events = [event for event in diagnostic_events(data, SERVER_MARKER)
                  if event.get("challenge") == challenge and event.get("userid") == userid
                  and event.get("revision") == bundle.get("revision")]
        # [喵喵喵]: 显式配置的两分片日志均归档；只有匹配挑战/玩家/版本的事件可用于死亡归因。
        matched.append((path, events))
    return matched


def capture(bundle, client_log, config, matched):
    challenge = bundle.get("challenge")
    created = dt.datetime.now(dt.timezone.utc).isoformat()
    key = hashlib.sha256(json.dumps(bundle, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:16]
    directory = ROOT / "captures" / (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + "-death-" + key)
    directory.mkdir(parents=True, exist_ok=False)
    token = ""
    profile_path = ROOT / "private/relay-config.json"
    if profile_path.exists():
        profile = json.loads(profile_path.read_text(encoding="utf-8-sig"))
        token = profile.get("token", "")
    sources = {"client": relay_tool.copy_log("client", str(client_log), str(directory), MAX_TAIL, token)}
    matched_events = []
    for i, (path, events) in enumerate(matched):
        name = "server_%d" % i
        sources[name] = relay_tool.copy_log(name, str(path), str(directory), MAX_TAIL, token)
        sources[name]["matchingEvents"] = len(events)
        matched_events.extend(events)
    if not matched_events:
        sources["server"] = {"status": "unavailable", "reason": "no_local_log_with_matching_challenge"}
    relay_tool.write_json(str(directory / "death-bundle.json"), bundle, token)
    relay_tool.write_json(str(directory / "server-events.json"), matched_events, token)
    relay_tool.write_json(str(directory / "analysis.json"), classify(bundle, matched_events), token)
    relay_tool.write_json(str(directory / "capture-manifest.json"), {
        "schema": "wilson-expedition/death-capture@1", "createdUtc": created,
        "challenge": challenge, "userid": bundle.get("userid"), "session": bundle.get("session"),
        "shard": bundle.get("shard"), "logs": sources,
        "sourceClockOrder": "unknown", "relayState": "not_requested",
        "serverReceipt": bundle.get("server_receipt"), "diagnosticVersion": "0.1.0",
    }, token)
    if config.get("enqueue_iterations") is True:
        iteration.queue_death(directory, bundle, matched_events)
    return directory


def load_config(path):
    if path is None:
        return {"client_log": str(DEFAULT_CLIENT), "server_log_roots": [str(DEFAULT_CLIENT.parent)]}
    data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if not isinstance(data, dict):
        raise ValueError("config must be an object")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", help="JSON with client_log, server_logs, server_log_roots")
    parser.add_argument("--watch", action="store_true", help="keep watching; otherwise capture new markers once")
    args = parser.parse_args()
    config = load_config(args.config)
    client_log = Path(config.get("client_log", str(DEFAULT_CLIENT)))
    checkpoint = ROOT / "private/death-watch-checkpoint.json"
    checkpoint.parent.mkdir(parents=True, exist_ok=True)
    seen = set(json.loads(checkpoint.read_text(encoding="utf-8"))) if checkpoint.exists() else set()
    pending = {}
    while True:
        try:
            _, _, data = read_tail(client_log)
            for bundle in death_bundles(data, client_log):
                if (bundle.get("schema") != "wilson-expedition/death-bundle@1"
                        or not all(isinstance(bundle.get(k), str) and 0 < len(bundle[k]) <= 256
                                   for k in ("challenge", "userid", "session", "revision"))
                        or not isinstance(bundle.get("trace"), list)
                        or not all(isinstance(row, dict) for row in bundle["trace"])):
                    continue
                identity = hashlib.sha256(json.dumps(bundle, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
                if identity in seen:
                    continue
                pending.setdefault(identity, (bundle, time.monotonic()))
            for identity, (bundle, first_seen) in list(pending.items()):
                matched = server_sources(config, bundle)
                events = [event for _, rows in matched for event in rows]
                complete = any(iteration.matches_death(bundle, event) for event in events)
                # [喵喵喵]: 日志写入顺序跨进程不固定；等待服务端死亡回执，超时保留缺证据归档供排查。
                if not complete and args.watch and time.monotonic() - first_seen < 20:
                    continue
                directory = capture(bundle, client_log, config, matched)
                seen.add(identity)
                iteration.write_json(checkpoint, sorted(seen))
                del pending[identity]
                print(json.dumps({"event": "death_captured", "directory": str(directory),
                                  "challenge": bundle["challenge"], "dualEvidence": complete}, ensure_ascii=False), flush=True)
        except (OSError, ValueError, relay_tool.ToolError) as exc:
            print(json.dumps({"event": "capture_error", "detail": str(exc)}, ensure_ascii=False), flush=True)
            if not args.watch:
                return 2
        if not args.watch:
            return 0
        time.sleep(2)


if __name__ == "__main__":
    raise SystemExit(main())
