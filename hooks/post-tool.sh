#!/bin/bash
# Append a privacy-minimised tool trace. Never logs file contents or Bash arguments.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
scribe_ensure_data_dir
input=$(cat)

export SCRIBE_TRACE_DIR="$SCRIBE_DATA_DIR/trace"
export SCRIBE_HOOK_INPUT="$input"
python3 -c '
import datetime as dt
import json
import os
import pathlib
import shlex

try:
    payload = json.loads(os.environ["SCRIBE_HOOK_INPUT"])
except Exception:
    raise SystemExit(0)

tool = payload.get("tool_name", "unknown")
tool_input = payload.get("tool_input") or {}
event = {
    "at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "session_id": payload.get("session_id"),
    "cwd": payload.get("cwd"),
    "tool": tool,
}
if tool in {"Edit", "Write", "MultiEdit", "NotebookEdit"}:
    event["file_path"] = tool_input.get("file_path")
elif tool == "Bash":
    command = tool_input.get("command", "")
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = []
    while tokens and "=" in tokens[0] and tokens[0].split("=", 1)[0].isidentifier():
        tokens.pop(0)
    event["command_kind"] = tokens[0] if tokens else ""

trace_dir = pathlib.Path(os.environ["SCRIBE_TRACE_DIR"])
name = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d") + ".jsonl"
with (trace_dir / name).open("a", encoding="utf-8") as f:
    f.write(json.dumps(event, ensure_ascii=False) + "\n")
'
