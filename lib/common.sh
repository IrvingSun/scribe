#!/bin/bash
# Shared paths. Code location is derived; mutable data lives outside this repository.
set -euo pipefail

SCRIBE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIBE_ROOT="$(cd "$SCRIBE_LIB_DIR/.." && pwd)"
SCRIBE_DATA_DIR="${SCRIBE_DATA_DIR:-$HOME/.claude/scribe}"

scribe_ensure_data_dir() {
  mkdir -p "$SCRIBE_DATA_DIR"/{candidates,approved,retired,archive,backups}
}
