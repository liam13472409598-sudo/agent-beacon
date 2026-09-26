#!/usr/bin/env python3
"""Small, observation-only hook shared by Cursor and Claude Code."""

import json
import os
import sys
import time
from pathlib import Path


def short(value, limit=160):
    if not isinstance(value, str):
        return ""
    return " ".join(value.split())[:limit]


def code_snippet(payload):
    tool_input = payload.get("tool_input") or payload.get("toolInput") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    for obj in (tool_input, payload):
        for key in ("command", "cmd", "code", "content", "file_path", "filePath"):
            value = obj.get(key)
            if isinstance(value, str) and value.strip():
                return "\n".join(value.splitlines()[:8])[:520]
    return ""


def main():
    if len(sys.argv) < 3:
        return
    source, event = sys.argv[1:3]
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    session = (payload.get("session_id") or payload.get("conversation_id")
               or payload.get("generation_id") or "default")
    title = short(payload.get("prompt") or payload.get("user_prompt"))
    tool = payload.get("tool_name") or payload.get("tool")
    if isinstance(tool, dict):
        tool = tool.get("name")
    step = "调用 " + short(tool, 60) if tool else ""
    if event in ("stop", "Stop"):
        step = "已完成" if payload.get("status", "completed") == "completed" else "已结束"
    elif event in ("sessionStart", "SessionStart"):
        step = "会话已开始"
    elif event in ("beforeSubmitPrompt", "UserPromptSubmit"):
        step = "开始处理任务"
    elif event in ("afterFileEdit", "PostToolUse") and not step:
        step = "文件已更新"

    record = {
        "source": "Cursor" if source == "cursor" else "Claude Code",
        "session": str(session),
        "event": event,
        "title": title,
        "step": step,
        "code": code_snippet(payload) if event in ("preToolUse", "PreToolUse", "beforeShellExecution") else "",
        "timestamp": time.time(),
    }
    folder = Path.home() / "Library/Application Support/AgentBeacon"
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / "events.jsonl"
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, (json.dumps(record, ensure_ascii=False) + "\n").encode())
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    main()
