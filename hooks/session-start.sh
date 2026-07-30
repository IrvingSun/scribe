#!/bin/bash
# Non-blocking: inform Claude about the independent Scribe workflow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
scribe_ensure_data_dir
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
EOF

if [ "$pending" -gt 5 ]; then
  echo "[Scribe] inbox has $pending pending candidates. Suggest a focused review: $SCRIBE_ROOT/bin/review-ledger review"
fi
