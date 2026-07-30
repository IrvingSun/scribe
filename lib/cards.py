"""Shared card parsing for Scribe. One place owns the on-disk field vocabulary."""
from __future__ import annotations

import pathlib

GLOBAL = "@global"

# On-disk label -> internal key. Adding a field means adding it here, not in a caller.
FIELDS = {
    "状态": "status",
    "类型": "type",
    "创建时间": "created",
    "项目": "project",
    "主张": "claim",
    "证据": "evidence",
    "适用范围": "scope",
    "不涵盖": "not_covered",
    "失效条件": "invalidated_by",
    "未来用途": "future_use",
    "替代/复核的旧记录": "replaces",
    "用户最新表述": "new_statement",
    "审核时间": "approved_at",
    "替代来源": "superseded_from",
    "被替代者": "superseded_by",
    "被替代时间": "superseded_at",
    "停用时间": "retired_at",
    "停用原因": "retired_reason",
    "撤销时间": "revoked_at",
    "撤销原因": "revoked_reason",
    "归档时间": "archived_at",
}

LABEL = {key: label for label, key in FIELDS.items()}

# Order used when writing a new card. Anything absent from values is skipped.
WRITE_ORDER = (
    "status", "type", "created", "project", "claim", "evidence", "scope",
    "not_covered", "invalidated_by", "future_use", "replaces", "new_statement",
)


def field_line(key, value):
    return f"- {LABEL[key]}: {value}"


def replace_status(lines, expected, new):
    """Rewrite the status line. Raises when the card is not in the expected state,
    so a vocabulary change fails loudly instead of silently producing a stateless card."""
    out, found = [], False
    for line in lines:
        if line == field_line("status", expected):
            out.append(field_line("status", new))
            found = True
        else:
            out.append(line)
    if not found:
        raise ValueError(f"card is not in status {expected!r}")
    return out


def parse(path):
    path = pathlib.Path(path)
    lines = path.read_text(encoding="utf-8").splitlines()
    card = {"id": path.stem, "path": path, "lines": lines}
    for line in lines:
        if not line.startswith("- "):
            continue
        label, sep, value = line[2:].partition(": ")
        if sep and label in FIELDS:
            card.setdefault(FIELDS[label], value.strip())
    return card


def load_all(directory):
    directory = pathlib.Path(directory)
    if not directory.is_dir():
        return []
    return [parse(card) for card in sorted(directory.glob("*.md"))]


def project_root(card):
    """Resolved project path, or None for global cards and unusable values."""
    project = card.get("project", "")
    if not project or project == GLOBAL:
        return None
    try:
        return pathlib.Path(project).expanduser().resolve()
    except OSError:
        return None


def applies_to(card, cwd):
    """A card is in scope when it is global, or cwd sits inside its project root."""
    project = card.get("project", "")
    if not project:
        return False
    if project == GLOBAL:
        return True
    root = project_root(card)
    if root is None:
        return False
    try:
        cwd.relative_to(root)
    except ValueError:
        return False
    return True


def scope_key(project):
    """Comparable scope identity. @global is its own namespace, never equal to any path —
    comparing resolved paths alone silently lets a project card replace a global one."""
    if not project:
        return ""
    if project == GLOBAL:
        return GLOBAL
    try:
        return str(pathlib.Path(project).expanduser().resolve())
    except OSError:
        return project


# What each replacement type may supersede. The type itself is included so a second
# correction can chain onto the first.
REPLACEABLE = {
    "decision_change": {"decision", "preference", "correction", "decision_change"},
    "fact_supersession": {"project_fact", "fact_supersession"},
}


def check_replacement(new_type, new_project, old_card):
    """Return an error message, or None when the replacement is well formed."""
    allowed = REPLACEABLE.get(new_type)
    if allowed is None:
        return f"{new_type} cards may not replace another card"
    if scope_key(old_card.get("project", "")) != scope_key(new_project):
        return ("replacement must keep the replaced card's scope: "
                f"{old_card.get('project', '?')} != {new_project}")
    if old_card.get("type", "") not in allowed:
        return (f"{new_type} may only replace {'/'.join(sorted(allowed))}, "
                f"but {old_card['id']} is {old_card.get('type', '?')}")
    return None


def short_project(card, width=28):
    project = card.get("project", "") or "?"
    if project == GLOBAL:
        return project
    if len(project) <= width:
        return project
    return "…" + project[-(width - 1):]
