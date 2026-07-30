#!/bin/bash
# Shared paths. Code location is derived; mutable data lives outside this repository.
set -euo pipefail

SCRIBE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIBE_ROOT="$(cd "$SCRIBE_LIB_DIR/.." && pwd)"
SCRIBE_DATA_DIR="${SCRIBE_DATA_DIR:-$HOME/.claude/scribe}"
# The helpers import lib/cards.py on every hook run; without this the checkout
# accumulates lib/__pycache__ (and can serve stale bytecode after an update).
export SCRIBE_LIB_DIR PYTHONDONTWRITEBYTECODE=1

scribe_ensure_data_dir() {
  mkdir -p "$SCRIBE_DATA_DIR"/{candidates,approved,retired,archive,backups,imported}
}

# Resolve the interpreter once instead of hardcoding python3 at every call site.
# `python` is Python 2 on many systems and these scripts need 3.8+ (pathlib missing_ok,
# subprocess capture_output), so it is accepted only after it proves its version —
# falling back blindly would turn a missing interpreter into a SyntaxError inside a heredoc.
SCRIBE_PY=""

scribe_usable_python() {
  [ -n "$1" ] || return 1
  command -v "$1" >/dev/null 2>&1 || return 1
  "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1
}

scribe_find_python() {
  local name dir candidate
  # Redirect at the call site, not just inside the probe: when a candidate dies on a signal
  # the shell itself reports "Killed: 9" to its own stderr, and only redirecting the whole
  # function call suppresses it. A broken interpreter must not inject noise into the
  # SessionStart hook's output.
  if scribe_usable_python "${SCRIBE_PYTHON:-}" 2>/dev/null; then
    SCRIBE_PY="${SCRIBE_PYTHON}"
    return 0
  fi
  # Scan every PATH entry, not just the first match of each name: an interpreter earlier on
  # PATH can be broken (a stale Homebrew symlink, a restricted binary) while a working one
  # sits further down. Two passes keep python3 preferred over python globally.
  for name in python3 python; do
    local IFS=:
    for dir in $PATH; do
      [ -n "$dir" ] || continue
      candidate="$dir/$name"
      [ -x "$candidate" ] || continue
      if scribe_usable_python "$candidate" 2>/dev/null; then
        SCRIBE_PY="$candidate"
        return 0
      fi
    done
  done
  return 1
}

scribe_require_python() {
  scribe_find_python && return 0
  echo "scribe: 需要 Python 3.8 或更高版本，未找到可用解释器（已尝试 SCRIBE_PYTHON、python3、python）。" >&2
  echo "        若已安装在非标准位置，设置 SCRIBE_PYTHON=/path/to/python3 后重试。" >&2
  return 1
}
