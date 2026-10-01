#!/usr/bin/env python3
"""Read the signed-in Codex plan limits through the local app-server RPC."""

import json
import os
import select
import shutil
import subprocess
import sys
import time


def codex_executable():
    home = os.path.expanduser("~")
    for path in (
        shutil.which("codex"),
        os.path.join(home, ".local/bin/codex"),
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ):
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def read_response(process, request_id, deadline, pending):
    while time.monotonic() < deadline:
        if b"\n" in pending:
            line, _, pending = pending.partition(b"\n")
            try:
                response = json.loads(line)
            except (ValueError, UnicodeDecodeError):
                continue
            if response.get("id") == request_id:
                return response, pending
            continue
        remaining = deadline - time.monotonic()
        if not select.select([process.stdout], [], [], max(0, remaining))[0]:
            break
        chunk = os.read(process.stdout.fileno(), 65536)
        if not chunk:
            break
        pending += chunk
    raise TimeoutError("Codex app-server did not answer")


def send(process, message):
    process.stdin.write(json.dumps(message, separators=(",", ":")).encode() + b"\n")
    process.stdin.flush()


def main():
    executable = codex_executable()
    if not executable:
        return {"error": "Codex CLI 未安装"}
    process = subprocess.Popen(
        [executable, "app-server", "--listen", "stdio://"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 10
        send(process, {"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "agent-beacon", "version": "0.13.0"}}})
        response, pending = read_response(process, 1, deadline, b"")
        if "error" in response:
            return {"error": "Codex 连接失败"}
        send(process, {"method": "initialized"})
        send(process, {"id": 2, "method": "account/rateLimits/read"})
        response, _ = read_response(process, 2, deadline, pending)
        if "error" in response:
            return {"error": "Codex 额度不可读取"}
        result = response.get("result") or {}
        buckets = result.get("rateLimitsByLimitId") or {}
        snapshot = buckets.get("codex") or result.get("rateLimits") or {}
        if not snapshot.get("primary") and not snapshot.get("secondary"):
            return {"error": "Codex 未返回额度"}
        return {"source": "Codex", "primary": snapshot.get("primary"),
                "secondary": snapshot.get("secondary")}
    finally:
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    try:
        print(json.dumps(main(), ensure_ascii=False))
    except (OSError, TimeoutError, ValueError):
        print(json.dumps({"error": "Codex 额度读取失败"}, ensure_ascii=False))
        sys.exit(1)
