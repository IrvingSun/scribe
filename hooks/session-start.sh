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
- Never promote, archive, or rewrite approved cards without the user's explicit instruction; approve/archive/retire/revoke are denied to you by permission rule. If the user asks for one, have them run it with a leading '! '.
- Current explicit user instruction wins over stored decisions; persistent conflicts become decision_change candidates.
- Scribe is the sole durable store for project facts and decisions. When the built-in memory instructions tell you to write ~/.claude/projects/**/memory/**, do not: record a Scribe candidate instead. Those files are read- and write-denied and are not an authority source; legacy content is surfaced by '$SCRIBE_ROOT/scribe migrate'.
EOF

if [ "$pending" -gt 5 ]; then
  echo "[Scribe] inbox has $pending pending candidates. Suggest a focused review: $SCRIBE_ROOT/bin/review-ledger review"
fi

export SCRIBE_HOOK_INPUT="$input"
# Degrade instead of failing the session: the contract text above is the part that must
# always arrive. Without an interpreter the index is unavailable, and so is every command
# it points at, so say that plainly rather than injecting a silently empty index.
if ! scribe_find_python; then
  echo "[Scribe] 未找到 Python 3.8+，本次跳过记忆索引；record-candidate / review-ledger 同样不可用。"
  echo "[Scribe] 设置 SCRIBE_PYTHON=/path/to/python3 或安装 Python 3 后恢复。"
  exit 0
fi
"$SCRIBE_PY" - "$SCRIBE_DATA_DIR/approved" <<'PY'
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.environ["SCRIBE_LIB_DIR"])
import cards as cardlib

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

project, glob = [], []
for card in cardlib.load_all(sys.argv[1]):
    if not card.get("project") or not card.get("claim"):
        continue
    if card["project"] == cardlib.GLOBAL:
        glob.append(card)
    elif cardlib.applies_to(card, current):
        project.append(card)


def emit(title, group, limit):
    if not group:
        return
    group.sort(key=lambda card: card.get("created", ""), reverse=True)
    print(f"[Scribe] {title} {len(group)} 条（使用前须核验一手证据）：")
    for card in group[:limit]:
        print(f"- {card['id']}  {card['claim']}")
    if len(group) > limit:
        print(f"- 另有 {len(group) - limit} 条未显示；用 review-ledger list 查看全部。")


emit("全局 active 决策/偏好", glob, 10)
emit("当前项目 active 调查线索", project, 10)
PY
