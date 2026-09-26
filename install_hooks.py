#!/usr/bin/env python3
"""Merge Agent Beacon's observation hooks into user-level tool settings."""

import json
import shlex
import shutil
import sys
from datetime import datetime
from pathlib import Path


def load(path):
    if not path.exists():
        return {}
    obj = json.loads(path.read_text())
    if not isinstance(obj, dict):
        raise ValueError(f"Expected a JSON object: {path}")
    return obj


def save(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup = path.with_suffix(path.suffix + ".agent-beacon-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".bak")
        shutil.copy2(path, backup)
    temporary = path.with_suffix(path.suffix + ".agent-beacon.tmp")
    temporary.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("cursor", "claude"):
        raise ValueError("Expected cursor or claude")
    source = sys.argv[1]
    support = Path.home() / "Library/Application Support/AgentBeacon"
    support.mkdir(parents=True, exist_ok=True)
    hook = support / "agent_beacon_hook.py"
    shutil.copy2(Path(__file__).with_name("agent_beacon_hook.py"), hook)
    command = f"/usr/bin/python3 {shlex.quote(str(hook))} {source}"
    if source == "cursor":
        path = Path.home() / ".cursor/hooks.json"
        obj = load(path)
        obj.setdefault("version", 1)
        hooks = obj.setdefault("hooks", {})
        if not isinstance(hooks, dict):
            raise ValueError("Invalid Cursor hooks field")
        for event in ("sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "stop", "sessionEnd"):
            entries = hooks.setdefault(event, [])
            if not any(isinstance(item, dict) and "agent_beacon_hook.py" in item.get("command", "") for item in entries):
                entries.append({"command": f"{command} {event}"})
    else:
        path = Path.home() / ".claude/settings.json"
        obj = load(path)
        hooks = obj.setdefault("hooks", {})
        if not isinstance(hooks, dict):
            raise ValueError("Invalid Claude hooks field")
        for event in ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"):
            entries = hooks.setdefault(event, [])
            existing = any(
                isinstance(group, dict) and any(
                    isinstance(item, dict) and "agent_beacon_hook.py" in item.get("command", "")
                    for item in group.get("hooks", [])
                ) for group in entries
            )
            if not existing:
                entries.append({"hooks": [{"type": "command", "command": f"{command} {event}"}]})
    save(path, obj)
    print(f"Connected {source}: {path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(exc, file=sys.stderr)
        sys.exit(1)
