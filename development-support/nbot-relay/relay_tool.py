#!/usr/bin/env python3
# [喵喵喵] WilsonExpedition 本地开发工具：只读客户端状态采样 + 日志归集。
# 设计边界（与私有 profile、未改动的 Go 中转协议对齐）：
#   * 只走回环地址，不跟随重定向、不使用环境代理，绝不把 token 发往非本机；
#   * 只实现暂存档位允许的两个动作 world_info / players，绝不提交 lua 或任何改动游戏状态的动作；
#   * 只读取调用方显式指定的日志文件（或文档化的默认客户端日志），不扫描目录、不碰存档与凭据；
#   * 不启动监听/守护进程/定时任务，不产生遥测上传；一次性执行后退出。
# 用法：
#   python relay_tool.py worlds [--cluster-id default]
#   python relay_tool.py world-info --world-id -1 [--cluster-id default]
#   python relay_tool.py players    --world-id -1
#   python relay_tool.py capture    --world-id -1 [--client-log default]
#                                   [--surface-log PATH] [--caves-log PATH]
"""Read-only client state sampling and log capture over the local NBot relay.

本工具只消费本地私有 profile 与未改动的中转协议，不包含任何生存逻辑，
也不提供通用 lua 提交或任何改动游戏状态的入口。
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

TOOL_VERSION = "0.1.0"
CAPTURE_SCHEMA = "wilson-expedition/nbot-relay-capture@1"

SUPPORT_ROOT = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PROFILE = os.path.join(SUPPORT_ROOT, "private", "relay-config.json")
CAPTURE_ROOT = os.path.join(SUPPORT_ROOT, "captures")

# [喵喵喵] 与暂存档位一致的动作白名单：仅只读动作。中转源码虽接受六个动作，
# 但本工具永不提交其余动作，也不碰 /poll、/result（那是 Mod 侧接口）。
ALLOWED_ACTIONS = ("world_info", "players")
CLIENT_ENDPOINTS = ("/worlds", "/execute")

DEFAULT_TIMEOUT = 8.0          # 中转单次业务等待 5s，留 3s 传输余量
MAX_TIMEOUT = 30.0
MAX_RESPONSE_BYTES = 256 * 1024
DEFAULT_MAX_LOG_BYTES = 4 * 1024 * 1024
HARD_MAX_LOG_BYTES = 16 * 1024 * 1024
MAX_RESULT_PRINT_BYTES = 2048

LOOPBACK_HOSTS = ("127.0.0.1", "::1", "localhost")
IDENTIFIER = re.compile(r"^[A-Za-z0-9_-]{1,128}$")

# 与 server/relay/protocol.go 的错误码表保持一致（仅用于把数字翻译成名字）
ERROR_NAMES = {
    0: "OK",
    1001: "InvalidJSON",
    1002: "InvalidTarget",
    1003: "UnsupportedAction",
    1004: "InvalidArgs",
    1005: "InvalidTaskID",
    1006: "InvalidResult",
    1007: "BodyTooLarge",
    1008: "MethodNotAllowed",
    1009: "RouteNotFound",
    1010: "UnsupportedMediaType",
    2001: "InvalidToken",
    3001: "ResultTimeout",
    3002: "TaskTargetMismatch",
    3003: "TaskNotClaimed",
    4001: "ModExecutionFailed",
    5001: "GlobalTaskLimit",
    5002: "PollLimit",
    5003: "ServerStopping",
    5004: "InternalError",
}

EXIT_OK = 0
EXIT_RELAY_ERROR = 2
EXIT_PARTIAL = 3
EXIT_MOD_FAILED = 4
EXIT_TIMEOUT_UNKNOWN = 5
EXIT_TRANSPORT = 6
EXIT_USAGE = 7


class ToolError(Exception):
    """Local usage/profile problem; message never contains the token."""


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def error_name(code):
    return ERROR_NAMES.get(code, "UnknownCode(%s)" % code)


def redact(text, secret):
    """Remove the bearer token from anything that may be printed or saved."""
    if text is None:
        return text
    out = str(text)
    if secret:
        out = out.replace(secret, "<redacted-token>")
    return out


def is_loopback_host(host):
    if host is None:
        return False
    return host.strip("[]").lower() in LOOPBACK_HOSTS


def load_profile(path):
    """Load the private relay profile. Never echoes the token."""
    if not os.path.isfile(path):
        raise ToolError("找不到私有 profile：%s（复制 private/relay-config.json 后再试）" % path)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            profile = json.load(handle)
    except (OSError, ValueError) as exc:
        raise ToolError("私有 profile 无法解析：%s" % exc)
    if not isinstance(profile, dict):
        raise ToolError("私有 profile 必须是 JSON 对象")
    listen = profile.get("listen")
    token = profile.get("token")
    if not isinstance(listen, str) or ":" not in listen:
        raise ToolError("私有 profile 的 listen 字段无效")
    if not isinstance(token, str) or not token:
        raise ToolError("私有 profile 的 token 字段无效")
    host, _, port = listen.rpartition(":")
    host = host.strip("[]")
    if not is_loopback_host(host):
        # [喵喵喵] 开发档位只允许本机回环：非回环监听会把凭据暴露到 LAN。
        raise ToolError("私有 profile 的监听地址不是回环（仅支持 127.0.0.1/::1/localhost）：%s" % listen)
    if not port.isdigit() or not (1 <= int(port) <= 65535):
        raise ToolError("私有 profile 的端口无效")
    return {
        "path": path,
        "base_url": "http://127.0.0.1:%d" % int(port),
        "listen": listen,
        "token": token,
        "max_body_bytes": profile.get("max_body_bytes"),
        "max_polls": profile.get("max_polls"),
    }


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # [喵喵喵] 绝不跟随重定向：3xx 一律当错误，避免把请求体（含 token）转投到其他主机。
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def build_opener():
    # [喵喵喵] 显式清空代理，避免系统/环境代理把回环请求转发到外部主机。
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


def guard_url(base_url):
    parsed = urllib.parse.urlsplit(base_url)
    if parsed.scheme != "http":
        raise ToolError("仅支持 http 回环端点")
    if not is_loopback_host(parsed.hostname):
        raise ToolError("拒绝访问非本机地址：%s" % base_url)
    return base_url.rstrip("/")


def post_json(profile, endpoint, payload, timeout, max_bytes):
    """POST one JSON object; returns a result dict (never raises for HTTP semantics)."""
    if endpoint not in CLIENT_ENDPOINTS:
        raise ToolError("本工具只使用 %s 端点" % ", ".join(CLIENT_ENDPOINTS))
    base_url = guard_url(profile["base_url"])
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        base_url + endpoint, data=body, method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json"})
    result = {"endpoint": endpoint, "http_status": None, "data": None,
              "transport_error": None, "bytes_read": 0, "truncated": False,
              "request_bytes": len(body), "redirect_refused": False}
    opener = build_opener()
    raw = b""
    try:
        with opener.open(request, timeout=timeout) as response:
            result["http_status"] = response.status
            raw = response.read(max_bytes + 1)
    except urllib.error.HTTPError as exc:
        try:
            if 300 <= exc.code < 400:
                # [喵喵喵] 不读取也不跟随重定向：请求体（含 token）已只发往本机回环。
                result["http_status"] = exc.code
                result["redirect_refused"] = True
                return result
            # 中转的错误信封同样带 JSON 正文；照常读取，不当作异常抛出。
            result["http_status"] = exc.code
            raw = exc.read(max_bytes + 1)
        except Exception as read_error:  # noqa: BLE001
            result["transport_error"] = redact(
                "%s: %s" % (type(read_error).__name__, read_error), profile["token"])
            return result
        finally:
            exc.close()
    except (urllib.error.URLError, OSError, ValueError) as exc:
        result["transport_error"] = redact("%s: %s" % (type(exc).__name__, exc), profile["token"])
        return result
    if len(raw) > max_bytes:
        result["truncated"] = True
        raw = raw[:max_bytes]
    result["bytes_read"] = len(raw)
    try:
        decoded = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        result["transport_error"] = redact("响应不是有效 JSON：%s" % exc, profile["token"])
        return result
    if not isinstance(decoded, dict):
        result["transport_error"] = "响应不是 JSON 对象"
        return result
    result["data"] = decoded
    return result


def classify(result):
    """Map a transfer result to (state, exit_code)."""
    if result["redirect_refused"]:
        return "redirect_refused", EXIT_RELAY_ERROR
    if result["transport_error"]:
        return "transport_error", EXIT_TRANSPORT
    if result["truncated"]:
        return "invalid_response", EXIT_RELAY_ERROR
    status = result["http_status"]
    if isinstance(status, int) and 300 <= status < 400:
        return "redirect_refused", EXIT_RELAY_ERROR
    data = result["data"]
    if data is None:
        return "invalid_response", EXIT_RELAY_ERROR
    code = data.get("code")
    if code == 0 and data.get("ok") is True:
        return "ok", EXIT_OK
    if code == 4001:
        return "mod_failed", EXIT_MOD_FAILED
    if code == 3001:
        return "timeout_unknown", EXIT_TIMEOUT_UNKNOWN
    return "relay_error", EXIT_RELAY_ERROR


def describe(result):
    if result["redirect_refused"]:
        return "拒绝了 HTTP %s 重定向（不会把凭据发往其他主机）" % result["http_status"]
    if result["transport_error"]:
        return result["transport_error"]
    data = result["data"] or {}
    code = data.get("code")
    return "%s(%s) %s" % (code, error_name(code), str(data.get("message", ""))[:200])


def require_identifier(value, field):
    if not isinstance(value, str) or not IDENTIFIER.match(value):
        raise ToolError("%s 必须匹配 ^[A-Za-z0-9_-]{1,128}$" % field)
    return value


def worlds_payload(profile, cluster_id):
    payload = {"token": profile["token"]}
    if cluster_id is not None:
        payload["cluster_id"] = require_identifier(cluster_id, "cluster_id")
    return payload


def execute_payload(profile, action, world_id, cluster_id):
    if action not in ALLOWED_ACTIONS:
        # [喵喵喵] 与暂存 Mod 的白名单一致：本工具没有提交 lua/announce/save/rollback 的路径。
        raise ToolError("本开发工具只允许 %s" % ", ".join(ALLOWED_ACTIONS))
    target = {"world_id": require_identifier(world_id, "world_id")}
    if cluster_id is not None:
        target["cluster_id"] = require_identifier(cluster_id, "cluster_id")
    return {"token": profile["token"], "target": target, "action": action, "args": {}}


def bounded_json(value, limit=MAX_RESULT_PRINT_BYTES):
    text = json.dumps(value, ensure_ascii=False, indent=2)
    encoded = text.encode("utf-8")
    if len(encoded) > limit:
        return encoded[:limit].decode("utf-8", "replace") + "\n...(输出已按 %d 字节截断)" % limit
    return text


def capture_directory(world_id):
    stamp = utc_now().strftime("%Y%m%dT%H%M%SZ")
    base = os.path.join(CAPTURE_ROOT, "%s_world-%s" % (stamp, world_id))
    candidate = base
    index = 1
    while True:
        try:
            os.makedirs(candidate)
            return candidate
        except FileExistsError:
            # [喵喵喵] 绝不覆盖既有采集目录：冲突时追加序号。
            index += 1
            candidate = "%s-%02d" % (base, index)
        except OSError as exc:
            raise ToolError("无法创建采集目录：%s" % exc)


def documented_client_log():
    """Documented current DST client log path on Windows; no directory scanning."""
    profile_dir = os.environ.get("USERPROFILE") or os.path.expanduser("~")
    return os.path.join(profile_dir, "Documents", "Klei", "DoNotStarveTogether", "client_log.txt")


def copy_log(kind, source, destination_dir, max_bytes, token):
    record = {"kind": kind, "requested": source is not None, "sourcePath": None,
              "resolvedFromDefault": source == "default", "status": "not_requested",
              "bytesWritten": 0, "sourceBytes": None, "skippedBytes": None,
              "truncated": False, "sha256": None, "sourceMtimeUtc": None,
              "savedAs": None, "error": None}
    if source is None:
        return record
    path = documented_client_log() if source == "default" else source
    record["sourcePath"] = path
    try:
        stat = os.stat(path)
    except OSError as exc:
        # 缺失的分片日志保持显式 unavailable，不推断为“没有事件”。
        record["status"] = "unavailable"
        record["error"] = redact("%s: %s" % (type(exc).__name__, exc), token)
        return record
    if not os.path.isfile(path):
        record["status"] = "unavailable"
        record["error"] = "目标不是普通文件"
        return record
    record["sourceBytes"] = stat.st_size
    record["sourceMtimeUtc"] = iso(datetime.datetime.fromtimestamp(stat.st_mtime, datetime.timezone.utc))
    offset = max(0, stat.st_size - max_bytes)
    try:
        with open(path, "rb") as handle:
            handle.seek(offset)
            chunk = handle.read(max_bytes)
    except OSError as exc:
        record["status"] = "unavailable"
        record["error"] = redact("%s: %s" % (type(exc).__name__, exc), token)
        return record
    # [喵喵喵]: 原始日志也须过滤已知中继凭据，不能只过滤错误文本与 JSON。
    if token:
        secret = token.encode("utf-8")
        record["redactedOccurrences"] = chunk.count(secret)
        chunk = chunk.replace(secret, b"<redacted-token>")
    name = "%s_%s" % (kind, os.path.basename(path) or "log.txt")
    saved = os.path.join(destination_dir, name)
    try:
        with open(saved, "wb") as handle:
            handle.write(chunk)
    except OSError as exc:
        record["status"] = "unavailable"
        record["error"] = redact("写入失败：%s" % exc, token)
        return record
    record["savedAs"] = name
    record["bytesWritten"] = len(chunk)
    record["skippedBytes"] = offset
    record["truncated"] = offset > 0
    record["sha256"] = hashlib.sha256(chunk).hexdigest()
    record["status"] = "copied_truncated" if offset > 0 else "copied"
    return record


def write_json(path, value, token):
    text = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
    if token and token in text:
        # [喵喵喵] 兜底断言：任何落盘内容都不允许出现真实 token。
        raise ToolError("拒绝写入含凭据的内容：%s" % os.path.basename(path))
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    return len(text.encode("utf-8"))


def command_worlds(profile, args):
    result = post_json(profile, "/worlds", worlds_payload(profile, args.cluster_id),
                       args.timeout, args.max_response_bytes)
    state, code = classify(result)
    if state != "ok":
        print("世界发现失败：%s" % describe(result), file=sys.stderr)
        return code
    data = result["data"]
    print(bounded_json({
        "cluster_id": data.get("cluster_id"),
        "world_ids": data.get("world_ids"),
        "window_seconds": data.get("window_seconds"),
        "note": "world_ids 仅代表最近联系过中转的世界；空数组不等于没有世界或存档。",
    }))
    return EXIT_OK


def command_state(profile, args, action):
    payload = execute_payload(profile, action, args.world_id, args.cluster_id)
    result = post_json(profile, "/execute", payload, args.timeout, args.max_response_bytes)
    state, code = classify(result)
    data = result["data"] or {}
    envelope = {"action": action, "state": state, "httpStatus": result["http_status"],
                "code": data.get("code"),
                "codeName": error_name(data.get("code")) if data else None,
                "message": data.get("message"), "taskId": data.get("task_id"),
                "result": data.get("result")}
    if state == "ok":
        print(bounded_json(envelope))
        return EXIT_OK
    if state == "timeout_unknown":
        print("等待结果超时（执行结果未知，可能已执行）：%s" % describe(result), file=sys.stderr)
    elif state == "mod_failed":
        print("Mod 侧执行失败或被拒绝：%s" % describe(result), file=sys.stderr)
    else:
        print("采样失败：%s" % describe(result), file=sys.stderr)
    return code


def command_capture(profile, args):
    world_id = require_identifier(args.world_id, "world_id")
    if args.cluster_id is not None:
        require_identifier(args.cluster_id, "cluster_id")
    if args.max_log_bytes <= 0 or args.max_log_bytes > HARD_MAX_LOG_BYTES:
        raise ToolError("--max-log-bytes 必须在 1..%d 之间" % HARD_MAX_LOG_BYTES)

    directory = capture_directory(world_id)
    started = utc_now()
    state_records = {}
    exit_code = EXIT_OK

    for action in ALLOWED_ACTIONS:
        payload = execute_payload(profile, action, world_id, args.cluster_id)
        transfer = post_json(profile, "/execute", payload, args.timeout, args.max_response_bytes)
        state, code = classify(transfer)
        data = transfer["data"] or {}
        saved = None
        if data:
            saved = "%s.json" % action
            write_json(os.path.join(directory, saved), {
                "action": action, "capturedUtc": iso(utc_now()),
                "httpStatus": transfer["http_status"],
                "code": data.get("code"), "codeName": error_name(data.get("code")),
                "message": data.get("message"), "taskId": data.get("task_id"),
                "result": data.get("result"),
                "truncated": transfer["truncated"], "bytesRead": transfer["bytes_read"],
            }, profile["token"])
        state_records[action] = {
            "state": state, "httpStatus": transfer["http_status"],
            "code": data.get("code") if data else None,
            "codeName": error_name(data.get("code")) if data else None,
            "message": redact(data.get("message"), profile["token"]),
            "taskId": data.get("task_id"), "savedAs": saved,
            "bytesRead": transfer["bytes_read"],
            "responseTruncated": transfer["truncated"],
            "transportError": transfer["transport_error"],
        }
        if state != "ok" and exit_code == EXIT_OK:
            # 客户端不可读不阻断日志归集：先记录失败，再继续后面的来源。
            exit_code = code

    log_records = {
        "client": copy_log("client", args.client_log, directory, args.max_log_bytes,
                           profile["token"]),
        "surface": copy_log("surface", args.surface_log, directory, args.max_log_bytes,
                            profile["token"]),
        "caves": copy_log("caves", args.caves_log, directory, args.max_log_bytes,
                          profile["token"]),
    }
    if exit_code == EXIT_OK and any(r["status"] == "unavailable"
                                    for r in log_records.values()):
        exit_code = EXIT_PARTIAL

    observed = state_records["world_info"]["state"] == "ok"
    manifest = {
        "captureSchema": CAPTURE_SCHEMA,
        "toolVersion": TOOL_VERSION,
        "createdUtc": iso(started),
        "finishedUtc": iso(utc_now()),
        "profile": {
            "path": os.path.relpath(profile["path"], SUPPORT_ROOT).replace("\\", "/"),
            "baseUrl": profile["base_url"],
            "loopbackOnly": True,
            "tokenRecorded": False,
        },
        "target": {"worldId": world_id, "clusterId": args.cluster_id or "default"},
        "state": state_records,
        "logs": log_records,
        "metadata": {
            "gameVersion": "unknown",
            "gameBuild": "unknown",
            "challenge": "unknown",
            "clusterName": "unknown" if not observed else "see world_info result name",
            "reason": "中转只返回 Mod 能读到的字段；工具不推断、也不补造游戏/挑战/版本信息",
            "observedSources": ["world_info", "players"] if observed else [],
        },
        "correlation": {
            "crossShardChronology": "unknown",
            "reason": "各来源分别按本机 UTC 记录；本工具无法断言 Surface/Caves/客户端事件的先后因果，"
                      "也不提供跨分片顺序保证",
        },
        "limits": {
            "requestTimeoutSeconds": args.timeout,
            "maxResponseBytes": args.max_response_bytes,
            "maxLogBytesPerSource": args.max_log_bytes,
            "allowedActions": list(ALLOWED_ACTIONS),
            "clientEndpoints": list(CLIENT_ENDPOINTS),
        },
        "notes": [
            "结果按原样保存；缺失字段表示客户端未提供，不代表值为零或事件不存在",
            "超时（code 3001）表示执行结果未知、副作用可能已发生，不代表动作未执行",
            "被拒动作以 code 4001 / ok=false 记录，绝不当作成功",
        ],
    }
    write_json(os.path.join(directory, "capture-manifest.json"), manifest, profile["token"])

    print(bounded_json({
        "captureDirectory": os.path.relpath(directory, SUPPORT_ROOT).replace("\\", "/"),
        "worldId": world_id,
        "clusterId": args.cluster_id or "default",
        "state": {k: v["state"] for k, v in state_records.items()},
        "logs": {k: v["status"] for k, v in log_records.items()},
        "exitCode": exit_code,
    }, 4096))
    return exit_code


def build_parser():
    parser = argparse.ArgumentParser(
        prog="relay_tool.py",
        description="只读客户端状态采样与日志归集（本机回环、仅 world_info/players）。",
        epilog="退出码：0 成功 / 2 中转错误 / 3 部分采集 / 4 Mod 失败或被拒 / "
               "5 超时（结果未知） / 6 传输错误 / 7 用法或 profile 问题")
    parser.add_argument("--profile", default=DEFAULT_PROFILE,
                        help="私有 profile 路径（默认 private/relay-config.json）")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                        help="单次请求超时秒数（默认 8，上限 30）")
    parser.add_argument("--max-response-bytes", type=int, default=MAX_RESPONSE_BYTES,
                        help="单次响应读取上限（默认 262144）")
    subparsers = parser.add_subparsers(dest="command", required=True)

    worlds = subparsers.add_parser("worlds", help="POST /worlds 发现最近联系的世界 ID")
    worlds.add_argument("--cluster-id", default=None)

    for name, action in (("world-info", "world_info"), ("players", "players")):
        sub = subparsers.add_parser(name, help="对已发现目标执行只读动作 %s" % action)
        sub.add_argument("--world-id", required=True, help="已发现的世界 ID；普通客户端为 -1")
        sub.add_argument("--cluster-id", default=None)

    capture = subparsers.add_parser(
        "capture", help="采集 world_info+players 与指定日志到新的时间戳目录")
    capture.add_argument("--world-id", required=True)
    capture.add_argument("--cluster-id", default=None)
    capture.add_argument("--client-log", default=None,
                         help="客户端日志路径；传 default 使用文档化的当前 DST 客户端日志路径")
    capture.add_argument("--surface-log", default=None, help="Surface 分片日志路径（可缺省）")
    capture.add_argument("--caves-log", default=None, help="Caves 分片日志路径（可缺省）")
    capture.add_argument("--max-log-bytes", type=int, default=DEFAULT_MAX_LOG_BYTES,
                         help="每个日志最多复制的字节数（默认 4 MiB，上限 16 MiB；超出时保留尾部）")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.timeout > MAX_TIMEOUT:
        print("用法错误：--timeout 必须在 0..%s 秒之间" % MAX_TIMEOUT, file=sys.stderr)
        return EXIT_USAGE
    if args.max_response_bytes <= 0 or args.max_response_bytes > MAX_RESPONSE_BYTES:
        print("用法错误：--max-response-bytes 必须在 1..%d 之间" % MAX_RESPONSE_BYTES,
              file=sys.stderr)
        return EXIT_USAGE
    try:
        profile = load_profile(args.profile)
        if args.command == "worlds":
            return command_worlds(profile, args)
        if args.command == "world-info":
            return command_state(profile, args, "world_info")
        if args.command == "players":
            return command_state(profile, args, "players")
        if args.command == "capture":
            return command_capture(profile, args)
        print("未知命令：%s" % args.command, file=sys.stderr)
        return EXIT_USAGE
    except ToolError as exc:
        print("工具错误：%s" % exc, file=sys.stderr)
        return EXIT_USAGE
    except KeyboardInterrupt:
        print("已中断", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
