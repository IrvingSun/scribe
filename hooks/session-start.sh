#!/bin/bash
# Non-blocking: inform Claude about the independent Scribe workflow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
scribe_ensure_data_dir
input=$(cat)
pending=0
if [ -d "$SCRIBE_DATA_DIR/candidates" ]; then
  pending=$(find "$SCRIBE_DATA_DIR/candidates" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')
fi

cat <<EOF
[Scribe]
Scribe records only reusable candidates.
- If this task establishes a reusable, evidence-backed project fact, an explicit user decision/preference, or a correction worth preventing, create a candidate with: $SCRIBE_ROOT/bin/record-candidate.
- A candidate must state evidence, scope, what it does not cover, invalidation conditions, and future use. Do not create candidates for routine progress, transient output, or unverified inference.
- Approved cards are a research route, not an answer: verify current primary evidence before relying on them; cite a card ID in the final answer only when it materially influenced the conclusion.
- Before a task that may overlap prior work, retrieve only matching approved cards: $SCRIBE_ROOT/bin/review-ledger recall KEYWORD...
- Never promote, archive, or rewrite approved cards without the user's explicit instruction. Current explicit user instruction wins over stored decisions; persistent conflicts become decision_change candidates.
- Scribe is the sole durable store for project facts and decisions. Do not read or write Claude Code native project-memory files; they are intentionally protected and are not an authority source.
EOF

if [ "$pending" -gt 5 ]; then
  echo "[Scribe] inbox has $pending pending candidates. Suggest a focused review: $SCRIBE_ROOT/bin/review-ledger review"
fi

export SCRIBE_HOOK_INPUT="$input"
python3 - "$SCRIBE_DATA_DIR/approved" <<'PY'
import json
import os
from pathlib import Path
import sys

try:
    payload = json.loads(os.environ.get("SCRIBE_HOOK_INPUT", "{}"))
except Exception:
    payload = {}
cwd = payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
if not cwd:
    raise SystemExit(0)

try:
    current = Path(cwd).resolve()
except OSError:
    raise SystemExit(0)

cards = []
for card in Path(sys.argv[1]).glob("*.md"):
    lines = card.read_text(encoding="utf-8").splitlines()
    project = next((line[6:] for line in lines if line.startswith("- 项目: ")), "")
    claim = next((line[6:] for line in lines if line.startswith("- 主张: ")), "")
    created = next((line[6:] for line in lines if line.startswith("- 创建时间: ")), "")
    if not project or not claim:
        continue
    try:
        project_path = Path(project).expanduser().resolve()
        current.relative_to(project_path)
    except (OSError, ValueError):
        continue
    cards.append((created, card.stem, claim))

if not cards:
    raise SystemExit(0)
cards.sort(reverse=True)
print(f"[Scribe] 当前项目 active 调查线索 {len(cards)} 条（使用前须核验一手证据）：")
for _, card_id, claim in cards[:10]:
    print(f"- {card_id}  {claim}")
if len(cards) > 10:
    print(f"- 另有 {len(cards) - 10} 条未显示；用 review-ledger recall 细查。")
PY
