# Scribe

[中文](README.md) · **English**

> A human-reviewed ledger for durable Claude Code facts and decisions.

## Start with the problem it solves

Claude Code is effective within a session, but a new session does not automatically inherit verified project context. That leads to repeated explanations and repeated investigation of the same code paths.

Letting a model write its own durable memory has the opposite risk: an unverified inference can later be cited as established fact. Scribe is not designed to make the model remember more. It is designed to retain only reusable information in a reviewable, reversible form.

## Core idea

Scribe separates discovery from confirmation:

```text
Claude finds reusable information
        │
        ▼
candidate (a proposal, not a fact)
        │
        │  You review and explicitly confirm it
        ▼
active (a lead discoverable by later sessions)
        │
        ├── new evidence contradicts it → superseded
        ├── user changes a decision     → superseded
        ├── no longer applicable        → retired
        └── confirmed wrong             → revoked
```

The important part is not Markdown itself, but permissions and state semantics: Claude may propose a candidate but may not promote it to durable guidance. Even an active card is a research route, not authority over current primary evidence. The user's current instruction always wins over an old card.

## What Scribe is not

- It is not an auto-writing knowledge base; candidates are never promoted automatically.
- It is not a vector database; project scope, a small index, and keywords are enough at this scale.
- It is not a project-documentation generator; it does not edit project docs or code.
- It is not a security sandbox; Claude Code deny rules reduce accidents but cannot contain arbitrary shell wrappers.

## Install

### Prerequisites

- Claude Code
- Git
- Python 3.8 or later

Clone into any directory you manage. `<scribe-dir>` below means that directory; no machine-specific path is assumed.

```bash
git clone <repository-url> <scribe-dir>
cd <scribe-dir>
./scribe install claude-code
./scribe doctor
```

`install` is idempotent. It:

1. creates a private store (by default `<home>/.claude/scribe`);
2. creates a local Git baseline for that store;
3. registers one SessionStart hook;
4. permits Claude to write candidates;
5. denies Claude's direct approve, archive, retire, and revoke commands.

If multiple Python installations exist, Scribe first uses a usable Python 3.8+ from `SCRIBE_PYTHON`; otherwise it scans `python3` and then `python` across `PATH`. Commands fail clearly when no usable interpreter exists. The session hook still prints the contract but skips the index, so it does not block a session.

## First use

After installation, do normal work first. Do not bulk-import or manufacture a large set of cards.

When Claude establishes information worth reusing across sessions, it calls `record-candidate`. A useful candidate includes:

- claim
- evidence
- scope
- exclusions
- invalidation condition
- future use

Review periodically rather than being interrupted every time:

```bash
cd <scribe-dir>
./bin/review-ledger review
```

The command shows up to five oldest candidates and rotates through two active cards for spot checks. When more than five candidates are pending, the next session gets a non-blocking reminder.

## Your confirmation actions

Confirmation, archive, retirement, and revocation are your actions, not Claude's. After reviewing, run one of these in your own terminal:

```bash
./bin/review-ledger approve SCR-YYYYMMDD-XXXXXX
./bin/review-ledger archive SCR-YYYYMMDD-XXXXXX
./bin/review-ledger retire SCR-YYYYMMDD-XXXXXX 'reason it no longer applies'
./bin/review-ledger revoke SCR-YYYYMMDD-XXXXXX 'reason it is incorrect'
```

In an interactive Claude Code terminal, prefix the command with `! ` to run it in your shell. For example:

```text
! ./bin/review-ledger approve SCR-YYYYMMDD-XXXXXX
```

State meanings:

| State | Meaning | Recalled? |
|---|---|---|
| `candidate` | awaiting your review | no |
| `active` | approved research lead | yes |
| `superseded` | replaced by a newer card | no |
| `retired` | no longer applicable | no |
| `revoked` | confirmed incorrect | no |
| `archived` | reviewed and not adopted | no |

## Scope: project and global cards

Project cards appear when the current working directory is inside their project scope. `--project` is required and must be an existing absolute directory.

```bash
./bin/record-candidate \
  --type project_fact \
  --claim 'Order status enum is defined in order.py:15' \
  --evidence 'app/models/order.py:15' \
  --scope 'order status lookups' \
  --not-covered 'final payment channel result' \
  --invalidated-by 'the status enum is moved or renamed' \
  --future-use 'diagnosing unexpected order states' \
  --project "$(git rev-parse --show-toplevel)"
```

When recording from a Git subdirectory, Scribe widens the scope to the repository root by default. This prevents a card from disappearing silently when a later session starts at the repository root. Use `--scope-exact` only for genuinely package-local facts.

Use `--project @global` for cards that apply across projects; they appear in every session. It is limited to cross-project `decision`, `preference`, `correction`, and `decision_change` cards. Facts should always belong to a specific project.

## Replacing an old conclusion

Do not delete an old card. Create a `fact_supersession` when new evidence contradicts a fact, or a `decision_change` when the user changes an approved decision. Scribe preserves the old history while removing it from active guidance.

Replacement has two constraints: the same scope and a compatible type. Fact supersession can only replace a fact; decision change can only replace a decision, preference, correction, or earlier decision change. Scribe validates both when writing and when approving.

```bash
./bin/record-candidate \
  --type decision_change \
  --claim 'short statement of the new decision' \
  --evidence 'the user explicitly updated this decision in the current session' \
  --scope 'where this decision applies' \
  --not-covered 'technical details that did not change' \
  --invalidated-by 'the user changes the decision again' \
  --future-use 'avoid following the superseded decision next time' \
  --project @global \
  --replaces SCR-YYYYMMDD-XXXXXX \
  --new-statement 'the user latest wording'
```

If the replaced card used `--scope-exact` for a subdirectory, the replacement must use it too. Scribe explains this in its error message.

## Finding and using cards

At session start, Scribe injects a compact index of active project and global cards. It shows only IDs and claims, rather than placing the whole ledger into context.

When you need detail:

```bash
./bin/review-ledger list
./bin/review-ledger recall orders payment
./bin/review-ledger recall --all orders
./bin/review-ledger show SCR-YYYYMMDD-XXXXXX
```

`list` and `recall` default to the current project plus global cards; use `--all` to inspect every project. Every match still needs verification against code, logs, data sources, or the user's current statement.

## Data, snapshots, and privacy

The default data directory is `<home>/.claude/scribe`, separate from the code repository. It is a local Git repository, but ledger content is never committed automatically:

```bash
./scribe snapshot 'after weekly review'
```

`backups/` contains verbatim settings backups and `imported/` contains unreviewed legacy memory. Both are ignored by Git and should not be pushed. If old history tracked them, untracking does not remove historical blobs; do not push the data repository until you rewrite its history or rebuild it.

Installation may create an empty baseline commit or a housekeeping commit that stops tracking `backups/` / `imported/`. Neither contains ledger cards.

## Migrating legacy native memory

If you previously used native Claude Code project memory, start with a dry run:

```bash
./scribe migrate
./scribe migrate --apply
```

`--apply` copies only and never deletes source files. Existing imported files are skipped, preserving your annotations. Importing is not approval: review each item and re-record only the still-valid ones as evidence-backed candidates.

## Verification and maintenance

Run the regression suite:

```bash
./tests/run.sh
./tests/run.sh -v
```

The suite uses temporary data, settings, and native memory. It does not read or write the real ledger or Claude configuration. It covers write validation, scope, deduplication, the full lifecycle, recall, simulated hook injection, spot-check rotation, repair checks, migration, interpreter selection, and installation idempotency.

Approval performs multiple file operations. If it is interrupted, run:

```bash
./scribe doctor --repair-check
```

The check reports duplicate IDs, invalid active states, broken replacement chains, and inconsistent historical states. It reports problems; it does not modify the ledger on your behalf.

## Known limits

- Candidate validation checks structure and evidence shape; it cannot prove a claim true.
- Deny rules are an accident-prevention floor, not security isolation from arbitrary shell commands.
- Validate actual SessionStart behavior in your Claude Code environment with one project card and one global card.
- Verify whether native memory is injected automatically outside tool permissions in one real new session.
- Use three real tasks to assess friction, then roughly ten varied tasks to assess whether repeated explanation and rework actually decrease.
