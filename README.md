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
`~/.claude/scribe/`, initializes a local Git repository for that data with a baseline commit,
and registers only Scribe's Claude Code hook, candidate-write permission, and Scribe-owned
deny rules. Settings backups are kept inside `~/.claude/scribe/backups/`, newest five only.
`uninstall` removes only those settings and preserves the data. `update` fast-forwards this
checkout and re-runs install.

`SCRIBE_DATA_DIR`, `SCRIBE_SETTINGS`, and `SCRIBE_NATIVE_MEMORY` override the store, the
settings file, and the legacy-memory location, so install, doctor, and migrate can be
exercised against a throwaway location. Deny rules are generated from the store actually in
use, so an overridden data directory is still protected.

## Python requirement

The scripts are Bash wrappers around inline Python and need **Python 3.8+** (`pathlib`
`missing_ok`, `subprocess` `capture_output`). The interpreter is resolved once in
`lib/common.sh`:

1. `SCRIBE_PYTHON`, if set and usable.
2. Every `PATH` entry, looking for `python3`.
3. Every `PATH` entry, looking for `python`.

Each candidate must prove `sys.version_info >= (3, 8)` before it is used. `python` is
accepted only after passing that probe, never on name alone — on many systems it is Python 2,
and using it would surface as a `SyntaxError` deep inside a heredoc instead of a clear
message. Every `PATH` entry is scanned rather than only the first name match, because an
interpreter earlier on `PATH` can be broken (a stale Homebrew symlink did exactly that during
development) while a working one sits further down.

If nothing usable is found, the commands refuse to run with one clear message naming
`SCRIBE_PYTHON`. The SessionStart hook instead degrades: it still prints the contract text,
then says the index was skipped, so a missing interpreter never fails the session.

## v1 contract

- Claude may create **candidate** cards only.
- A candidate is not a fact. It must include evidence, scope, exclusions, invalidation conditions, and future use.
- Only an explicit user review may promote, archive, retire, revoke, or supersede a card. Promotion preserves the original candidate in `archive/`.
- Only active cards are recalled. Superseded, retired, and revoked cards remain as historical evidence, never as active guidance.
- Approved cards are investigation routes, never authority over current primary evidence or the user's latest explicit instruction.
- A new user instruction immediately governs the active task. Persistent conflicts with an approved decision become a `decision_change` candidate; evidence that contradicts an approved fact becomes a `fact_supersession` candidate.
- Scribe is the sole durable store for project facts and decisions. Native Claude Code project-memory files are denied for read and edit to prevent a second authority source.

### What the deny rules do and do not enforce

`install` denies Claude the `approve` / `archive` / `retire` / `revoke` subcommands, plus edits
to `~/.claude/scribe/**` and reads of native project memory. This raises promotion from a
prompt-level convention to a permission rule — but it is **a floor, not a boundary**: any shell
wrapper (`bash -c`, another reader) still reaches the same files. Treat the rules as removing
accidents, not as containing a determined agent.

Consequence worth knowing: when you want a card promoted, run it yourself. In an interactive
session, prefix the command with `! ` so it runs in your shell rather than Claude's.

## Commands

Create a candidate (normally Claude does this itself):

```bash
./bin/record-candidate \
  --type project_fact \
  --claim '...' --evidence 'path:line or data source' \
  --scope '...' --not-covered '...' --invalidated-by '...' \
  --future-use '...' --project "$PWD"
```

`--project` is required and must be an existing absolute path — a card pointing at a path that
does not exist would never surface. Global cards are injected in **every** session; project
cards only when the session's cwd sits inside their root.

`@global` is limited to `decision`, `preference`, `correction`, and `decision_change`: a fact
is always about one codebase, so `project_fact` and `fact_supersession` must name a project.

If the path sits inside a Git worktree but is not its root, the scope is widened to the
repository root and a notice is printed. A card scoped to a subdirectory is invisible from the
repository root — the hook only injects cards whose project contains the session's cwd — and
since callers usually pass `"$PWD"`, a session that happened to start in a subdirectory would
otherwise lose the card silently. Too broad shows one extra card; too narrow loses it. Pass
`--scope-exact` to keep the given path for a genuinely package-local fact.

`--replaces` and `--new-statement` are rejected outright on types that cannot use them, rather
than being stored and failing only at approval.

A replacement must stay inside the scope and the kind of thing it replaces. `@global` is its
own namespace and is never equal to a project path, so a project card cannot supersede a global
one. `fact_supersession` may only replace `project_fact` (or an earlier `fact_supersession`);
`decision_change` may only replace `decision` / `preference` / `correction` (or an earlier
`decision_change`). Both rules are checked when the candidate is written **and again at
approval**, since the target may have been retired or superseded in between.

Fields are checked for placeholders (`无`, `TBD`, `-`, …) and for evidence that names a source
but states nothing (`命令: 无`). Duplicate detection is scoped to one project — the same
sentence can be a distinct fact in two repositories. Within a project an identical claim is
rejected, ≥80% token overlap is rejected as a near-duplicate, and ≥50% prints a warning and
still records. This is shape checking, not semantic validation — it cannot tell a true claim
from a confident wrong one.

The on-disk field vocabulary lives in `lib/cards.py` and nothing else parses or writes card
lines by hand, so renaming a label cannot silently break recall, replacement checks, or the
session hook. State changes go through `replace_status()`, which raises when a card is not in
the state the transition expects instead of writing a card with no status at all.

Review candidates and spot-check active cards (two per run, rotating least-recently-sampled
first; the rotation cursor lives in `review-state.json`, never inside the cards):

```bash
./bin/review-ledger review
```

List or search active cards. Both default to the current project plus `@global`; `--all`
drops the project filter and reports how many out-of-scope cards were hidden. Treat results
as a research route and re-check current primary evidence before relying on them:

```bash
./bin/review-ledger list
./bin/review-ledger recall 订单 支付
./bin/review-ledger recall --all 订单
```

After your review, you may explicitly approve, archive, retire, or revoke one card. Rejecting a
candidate writes status `archived`, retiring writes `retired`, revoking writes `revoked`, and
superseding writes `superseded`. The one card that keeps `candidate` is the pre-promotion
snapshot in `archive/ID.candidate.md` — it records the card exactly as it was reviewed:

```bash
./bin/review-ledger approve SCR-YYYYMMDD-XXXXXX
./bin/review-ledger archive SCR-YYYYMMDD-XXXXXX
./bin/review-ledger retire SCR-YYYYMMDD-XXXXXX '不再适用的原因'
./bin/review-ledger revoke SCR-YYYYMMDD-XXXXXX '确认错误的原因'
```

## Tests

```bash
./tests/run.sh        # 74 assertions
./tests/run.sh -v     # also print each passing assertion
```

The suite runs entirely against a temporary store via `SCRIBE_DATA_DIR`, `SCRIBE_SETTINGS`,
and `SCRIBE_NATIVE_MEMORY`; it never reads or writes the real ledger, `settings.json`, or
native project memory. Card ids are captured from command output rather than by listing the
directory — guessing ids by listing silently tested the wrong card three times while this
harness was being built.

It covers write validation, `@global` and project scoping, dedup, the full lifecycle
(approve / supersede / retire / revoke / archive, plus re-validation at approval), recall and
session-hook injection, spot-check rotation, ledger repair checks, migration, and install
idempotency. Verified by mutation: breaking the replacement type table, the archive status
write, the evidence anchor, the write-side `--replaces` guard, migration overwrite protection,
the repair check, deny generation, or global-card injection each turns the suite red.

## Ledger repair check

`approve` is several file operations; a crash partway through can leave the ledger inconsistent.

```bash
./scribe doctor --repair-check
```

It reports approved cards whose status is not `active`, ids present in both `approved/` and
`candidates/`, replacement sources that were never retired, two active cards on one
replacement chain, and retired cards still marked active.

## Legacy native memory

Projects that used Claude Code's built-in memory before Scribe still hold files under
`~/.claude/projects/*/memory/`, now unreadable by Claude. `migrate` surfaces them; it copies
into `~/.claude/scribe/imported/` and **never deletes the originals**:

```bash
./scribe migrate            # dry run: what exists, with each file's description
./scribe migrate --apply    # copy into imported/ for review
```

`--apply` never overwrites: a file already present in `imported/` is skipped and reported, so
annotations you added while triaging survive a second run.

Importing is not promotion. Read each file, decide what still holds, and re-record the
survivors as candidates with real evidence.

## Snapshots

The data store is a Git repository, but nothing commits automatically. Commit when you want a
restore point:

```bash
./scribe snapshot 'after weekly review'
```

`backups/` and `imported/` are git-ignored: one holds verbatim copies of `settings.json`, the
other holds unreviewed legacy content. Neither is ledger material, and neither should leave the
machine if this repository is ever pushed. `install` also untracks them if an earlier snapshot
captured them.

## Deferred deliberately

No vector retrieval, automatic expiry detection, automatic promotion, automatic commits, or
automatic edits to project documentation are included in v1. Assess real use after three tasks
for friction and after roughly ten varied tasks for reduced background repetition and rework.
