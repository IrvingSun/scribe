# Scribe

Scribe is a standalone Claude Code harness for preserving reusable, reviewable memory.

## Install

```bash
git clone <your-scribe-repository> ~/Documents/harness/scribe
cd ~/Documents/harness/scribe
./scribe install claude-code
./scribe doctor
```

`install` is idempotent. It derives the code location, creates private mutable data at
`~/.claude/scribe/`, initializes a local Git repository for that data, and registers only
Scribe's Claude Code hooks and candidate-write permission. `uninstall` removes only those
settings and preserves the data. `update` fast-forwards this checkout and re-runs install.

## v1 contract

- Claude may create **candidate** cards only.
- A candidate is not a fact. It must include evidence, scope, exclusions, invalidation conditions, and future use.
- Only an explicit user review may promote or archive a card. Promotion preserves the original candidate in `ledger/archive/`.
- Approved cards are investigation routes, never authority over current primary evidence or the user's latest explicit instruction.
- A new user instruction immediately governs the active task. Persistent conflicts with an approved decision become a `decision_change` candidate; evidence that contradicts an approved fact becomes a `fact_supersession` candidate.

## Commands

Create a candidate (normally Claude does this itself):

```bash
./bin/record-candidate \
  --type project_fact \
  --claim '...' --evidence 'path:line or data source' \
  --scope '...' --not-covered '...' --invalidated-by '...' \
  --future-use '...' --project "$PWD"
```

Review candidates and sample approved cards:

```bash
./bin/review-ledger review
```

Recall up to five approved cards matching every supplied keyword. Treat results as a
research route and re-check current primary evidence before relying on them:

```bash
./bin/review-ledger recall 订单 支付
```

After your review, you may explicitly approve or archive one card:

```bash
./bin/review-ledger approve SCR-YYYYMMDD-XXXXXX
./bin/review-ledger archive SCR-YYYYMMDD-XXXXXX
```

## Deferred deliberately

No vector retrieval, automatic expiry detection, automatic promotion, automatic commits, or automatic edits to project documentation are included in v1. Assess real use after three tasks for friction and after roughly ten varied tasks for reduced background repetition and rework.
