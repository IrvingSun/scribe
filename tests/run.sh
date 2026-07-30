#!/bin/bash
# Regression suite for Scribe. Runs entirely against a throwaway store: it never reads or
# writes ~/.claude/scribe, ~/.claude/settings.json, or native project memory.
#
#   ./tests/run.sh          run everything
#   ./tests/run.sh -v       also print each passing assertion
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

# Physical, normalized path: TMPDIR may end in a slash and /var is a symlink to
# /private/var on macOS. The tools resolve() their paths, so assertions must compare
# against the resolved form or they fail for reasons that have nothing to do with Scribe.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/scribe-tests.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

export SCRIBE_DATA_DIR="$WORK/store"
export SCRIBE_SETTINGS="$WORK/settings.json"
export SCRIBE_NATIVE_MEMORY="$WORK/native"
RECORD="$ROOT/bin/record-candidate"
LEDGER="$ROOT/bin/review-ledger"

# Resolve the interpreter the same way the tools do. common.sh turns on -e; this suite
# deliberately runs without it so a failing assertion does not abort the whole file.
source "$ROOT/lib/common.sh"
set +e
scribe_require_python || exit 1

pass=0
fail=0
current=""

ok() {
  pass=$((pass + 1))
  [ "$VERBOSE" = 1 ] && echo "  ok   $1"
  return 0
}

bad() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  [ -n "${2:-}" ] && echo "       $2"
  return 0
}

section() {
  current="$1"
  echo "== $1"
}

# expect_rc DESC WANT CMD...  — run CMD, compare exit status
expect_rc() {
  local desc="$1" want="$2"
  shift 2
  local out
  out=$("$@" 2>&1)
  local got=$?
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc" "want rc=$want got=$got: $out"; fi
}

# expect_match DESC PATTERN CMD... — run CMD, require PATTERN in combined output
expect_match() {
  local desc="$1" pattern="$2"
  shift 2
  local out
  out=$("$@" 2>&1)
  if printf '%s' "$out" | grep -q -- "$pattern"; then ok "$desc"
  else bad "$desc" "missing /$pattern/ in: $out"; fi
}

# expect_absent DESC PATTERN CMD...
expect_absent() {
  local desc="$1" pattern="$2"
  shift 2
  local out
  out=$("$@" 2>&1)
  if printf '%s' "$out" | grep -q -- "$pattern"; then bad "$desc" "unexpected /$pattern/ in: $out"
  else ok "$desc"; fi
}

# run_in DIR CMD... — BSD env has no -C, so use a subshell
run_in() {
  local dir="$1"
  shift
  (cd "$dir" && "$@")
}

# file_has DESC FILE PATTERN
file_has() {
  if [ -f "$2" ] && grep -q -- "$3" "$2"; then ok "$1"
  else bad "$1" "missing /$3/ in $2"; fi
}

# Capture the card id from stdout. Never guess ids by listing the directory: doing that
# silently tested the wrong card three times during development.
new_card() {
  "$RECORD" "$@" 2>/dev/null | sed -n 's/^已写入候选记录: \([A-Z0-9-]*\) .*/\1/p'
}

FACT=(--scope charging服务 --not-covered 退款链路 --invalidated-by 入口迁移 --future-use 排查结算)
PREF=(--scope 全局范围 --not-covered 代码标识符 --invalidated-by 用户改口 --future-use 回复语言)

mkdir -p "$WORK/projA" "$WORK/projB"

# ---------------------------------------------------------------- write validation
section "写入校验"
expect_rc "缺必填字段被拒" 1 "$RECORD" --type project_fact --claim '只有主张没有其他'
expect_rc "未知字段被拒" 1 "$RECORD" --type project_fact --claim '入口在 pay.py:42' \
  --evidence 'pay.py:42 handler' "${FACT[@]}" --project "$WORK/projA" --bogus x
expect_match "占位值被拒" "placeholder" "$RECORD" --type project_fact --claim '入口在 pay.py:42' \
  --evidence 'pay.py:42 handler' --scope charging --not-covered '无' \
  --invalidated-by 迁移 --future-use 排查结算 --project "$WORK/projA"
expect_match "有标签无内容的证据被拒" "states nothing" "$RECORD" --type project_fact \
  --claim '入口在 pay.py:42' --evidence '命令: 无' "${FACT[@]}" --project "$WORK/projA"
expect_match "时间戳冒充 file:line 被拒" "must include file:line" "$RECORD" --type project_fact \
  --claim '批处理每天早上执行' --evidence '每天 8:30 执行' "${FACT[@]}" --project "$WORK/projA"
expect_rc "Makefile:9 这类无扩展名锚点仍接受" 0 "$RECORD" --type project_fact \
  --claim '构建目标定义在 Makefile 第九行' --evidence 'Makefile:9 的 build 目标' \
  "${FACT[@]}" --project "$WORK/projA"
expect_rc "相对路径项目被拒" 1 "$RECORD" --type project_fact --claim '入口在 pay.py:42' \
  --evidence 'pay.py:42 handler' "${FACT[@]}" --project 'relative/path'
expect_rc "不存在的项目路径被拒" 1 "$RECORD" --type project_fact --claim '入口在 pay.py:42' \
  --evidence 'pay.py:42 handler' "${FACT[@]}" --project "$WORK/nope"
expect_match "非替代类型带 --replaces 在写入端即被拒" "only valid for" "$RECORD" \
  --type project_fact --claim '入口在 pay.py:42' --evidence 'pay.py:42 handler' \
  "${FACT[@]}" --project "$WORK/projA" --replaces SCR-19700101-AAAAAA
expect_match "--new-statement 用错类型被拒" "only valid for decision_change" "$RECORD" \
  --type project_fact --claim '入口在 pay.py:42' --evidence 'pay.py:42 handler' \
  "${FACT[@]}" --project "$WORK/projA" --new-statement '随便'

# ---------------------------------------------------------------- scope rules
section "@global 与项目范围"
expect_match "@global 不接受 project_fact" "@global is limited to" "$RECORD" \
  --type project_fact --claim '某个全局事实在 a.py:1' --evidence 'a.py:1 的定义' \
  "${PREF[@]}" --project '@global'
expect_rc "@global 接受 correction" 0 "$RECORD" --type correction \
  --claim '未验证不得声称已修复' --evidence '用户明确纠正过' "${PREF[@]}" --project '@global'

git init -q "$WORK/repo"
mkdir -p "$WORK/repo/sub"
SUBCARD=$(new_card --type project_fact --claim '子模块配置在 conf.py:3' \
  --evidence 'sub/conf.py:3 的定义' "${FACT[@]}" --project "$WORK/repo/sub")
file_has "子目录范围自动上提到仓库根" "$SCRIBE_DATA_DIR/candidates/$SUBCARD.md" "项目: $WORK/repo$"
EXACT=$(new_card --type project_fact --claim '子模块另一处配置在 other.py:5' \
  --evidence 'sub/other.py:5 的定义' "${FACT[@]}" --project "$WORK/repo/sub" --scope-exact)
file_has "--scope-exact 保留子目录范围" "$SCRIBE_DATA_DIR/candidates/$EXACT.md" "项目: $WORK/repo/sub$"

# ---------------------------------------------------------------- dedup
section "去重"
PF=$(new_card --type project_fact --claim '结算入口在 pay.py:42' \
  --evidence 'pay.py:42 的 handler' "${FACT[@]}" --project "$WORK/projA")
[ -n "$PF" ] && ok "记录项目事实" || bad "记录项目事实" "未拿到卡片 ID"
expect_match "同项目同主张被拒" "duplicate claim" "$RECORD" --type project_fact \
  --claim '结算入口在  PAY.py:42' --evidence 'pay.py:42 的 handler' \
  "${FACT[@]}" --project "$WORK/projA"
expect_rc "跨项目同主张允许" 0 "$RECORD" --type project_fact --claim '结算入口在 pay.py:42' \
  --evidence 'pay.py:42 的 handler' "${FACT[@]}" --project "$WORK/projB"

# ---------------------------------------------------------------- lifecycle
section "生命周期"
expect_rc "批准候选" 0 "$LEDGER" approve "$PF"
file_has "批准后状态为 active" "$SCRIBE_DATA_DIR/approved/$PF.md" '^- 状态: active$'
file_has "批准前快照保留 candidate 状态" \
  "$SCRIBE_DATA_DIR/archive/$PF.candidate.md" '^- 状态: candidate$'
expect_match "重复批准报候选不存在" "候选不存在" "$LEDGER" approve "$PF"
cp "$SCRIBE_DATA_DIR/approved/$PF.md" "$SCRIBE_DATA_DIR/candidates/$PF.md"
expect_match "状态不符时批准被拦截" "not in status" "$LEDGER" approve "$PF"
rm -f "$SCRIBE_DATA_DIR/candidates/$PF.md"

GD=$(new_card --type decision --claim '统一用 pytest 而非 unittest' \
  --evidence '用户明确要求' "${PREF[@]}" --project '@global')
"$LEDGER" approve "$GD" >/dev/null 2>&1
expect_match "项目卡不得替代全局卡" "must keep the replaced card's scope" "$RECORD" \
  --type decision_change --claim '改用 unittest 以匹配存量代码' --evidence '用户改口' \
  --new-statement '用 unittest' "${FACT[@]}" --project "$WORK/projA" --replaces "$GD"
expect_match "decision_change 不得替代事实卡" "may only replace" "$RECORD" \
  --type decision_change --claim '以后一律走新的结算入口' --evidence '用户要求' \
  --new-statement '走新入口' "${FACT[@]}" --project "$WORK/projA" --replaces "$PF"

SUP=$(new_card --type fact_supersession --claim '结算入口已迁至 billing.py:10' \
  --evidence 'billing.py:10 的 handler' "${FACT[@]}" --project "$WORK/projA" --replaces "$PF")
expect_rc "批准事实替代" 0 "$LEDGER" approve "$SUP"
file_has "新卡 active" "$SCRIBE_DATA_DIR/approved/$SUP.md" '^- 状态: active$'
file_has "新卡记录替代来源" "$SCRIBE_DATA_DIR/approved/$SUP.md" "^- 替代来源: $PF$"
file_has "旧卡转 superseded" "$SCRIBE_DATA_DIR/retired/$PF.md" '^- 状态: superseded$'
file_has "旧卡记录被替代者" "$SCRIBE_DATA_DIR/retired/$PF.md" "^- 被替代者: $SUP$"
[ -f "$SCRIBE_DATA_DIR/approved/$PF.md" ] && bad "旧卡移出 active" "approved/ 里仍有旧卡" || ok "旧卡移出 active"

STALE=$(new_card --type fact_supersession --claim '结算入口第三次迁移到 c.py:1' \
  --evidence 'c.py:1 的 handler' "${FACT[@]}" --project "$WORK/projA" --replaces "$SUP")
"$LEDGER" retire "$SUP" '先停用以制造冲突' >/dev/null 2>&1
expect_match "批准时重验替代目标" "替代目标不是 active approved 卡" "$LEDGER" approve "$STALE"
file_has "retire 写入 retired 状态" "$SCRIBE_DATA_DIR/retired/$SUP.md" '^- 状态: retired$'
file_has "retire 记录原因" "$SCRIBE_DATA_DIR/retired/$SUP.md" '^- 停用原因: 先停用以制造冲突$'

REV=$(new_card --type project_fact --claim '缓存键格式在 cache.py:8' \
  --evidence 'cache.py:8 的定义' "${FACT[@]}" --project "$WORK/projA")
"$LEDGER" approve "$REV" >/dev/null 2>&1
expect_rc "撤销 active 卡" 0 "$LEDGER" revoke "$REV" '当时读错了函数'
file_has "revoke 写入 revoked 状态" "$SCRIBE_DATA_DIR/retired/$REV.md" '^- 状态: revoked$'

expect_rc "归档候选" 0 "$LEDGER" archive "$STALE"
file_has "归档写入 archived 状态" "$SCRIBE_DATA_DIR/archive/$STALE.md" '^- 状态: archived$'
file_has "归档记录时间" "$SCRIBE_DATA_DIR/archive/$STALE.md" '^- 归档时间: '
expect_rc "show 能取回已归档卡" 0 "$LEDGER" show "$STALE"
expect_rc "show 能取回批准前快照" 0 "$LEDGER" show "$PF"
expect_rc "show 不存在的卡报错" 1 "$LEDGER" show SCR-19700101-ZZZZZZ

# ---------------------------------------------------------------- recall
# Fresh fixtures: every card created above has been superseded, retired, revoked or
# archived by the lifecycle section, so none of them is active any more.
section "召回与索引"
IDXA=$(new_card --type project_fact --claim '订单状态机定义在 order.py:15' \
  --evidence 'order.py:15 的枚举' "${FACT[@]}" --project "$WORK/projA")
"$LEDGER" approve "$IDXA" >/dev/null 2>&1
IDXB=$(new_card --type project_fact --claim '库存扣减在 stock.py:20' \
  --evidence 'stock.py:20 的函数' --scope 库存服务 --not-covered 退货 \
  --invalidated-by 逻辑迁移 --future-use 排查库存 --project "$WORK/projB")
"$LEDGER" approve "$IDXB" >/dev/null 2>&1

expect_match "list 在项目内可见项目卡" "$IDXA" run_in "$WORK/projA" "$LEDGER" list
expect_absent "list 不泄露其他项目的卡" "$IDXB" run_in "$WORK/projA" "$LEDGER" list
expect_match "list 始终包含全局卡" "$GD" run_in "$WORK/projA" "$LEDGER" list
expect_match "越界匹配有计数提示" "其他项目的匹配未显示" \
  run_in "$WORK/projA" "$LEDGER" recall 在
expect_match "--all 放开项目过滤" "$IDXB" run_in "$WORK/projA" "$LEDGER" list --all
expect_rc "recall 缺关键词报用法" 2 "$LEDGER" recall
expect_match "review 显示候选总数" "待审核候选" "$LEDGER" review

hook_out() { echo "{\"cwd\":\"$1\"}" | "$ROOT/hooks/session-start.sh" 2>&1; }
expect_match "hook 注入全局卡" "$GD" hook_out "$WORK/projA"
expect_match "hook 注入当前项目卡" "$IDXA" hook_out "$WORK/projA"
expect_absent "hook 不注入其他项目卡" "$IDXB" hook_out "$WORK/projA"
expect_match "无关目录仍注入全局卡" "$GD" hook_out "$WORK"

# ---------------------------------------------------------------- review rotation
section "抽审轮换"
rm -f "$SCRIBE_DATA_DIR/review-state.json"
sample() { "$LEDGER" review | grep '^- 主张' | sort | cksum; }
first=$(sample)
second=$(sample)
if [ "$first" != "$second" ]; then ok "连续两次抽审换卡"
else bad "连续两次抽审换卡" "两次相同: $first"; fi

# ---------------------------------------------------------------- repair check
section "账本自检"
expect_match "健康账本通过自检" "OK ledger" "$ROOT/scribe" doctor --repair-check
cp "$SCRIBE_DATA_DIR/approved/$GD.md" "$SCRIBE_DATA_DIR/candidates/$GD.md"
expect_match "同 ID 同时在 approved/candidates 被检出" "批准中断" \
  "$ROOT/scribe" doctor --repair-check
expect_rc "自检失败时返回非零" 1 "$ROOT/scribe" doctor --repair-check
rm -f "$SCRIBE_DATA_DIR/candidates/$GD.md"

# ---------------------------------------------------------------- migrate
section "原生记忆迁移"
mkdir -p "$SCRIBE_NATIVE_MEMORY/-Users-someone-proj/memory"
printf 'description: 一条旧记忆\n正文\n' \
  > "$SCRIBE_NATIVE_MEMORY/-Users-someone-proj/memory/note.md"
expect_match "预演不复制" "预演" "$ROOT/scribe" migrate
[ -e "$SCRIBE_DATA_DIR/imported/-Users-someone-proj/note.md" ] \
  && bad "预演不落盘" "imported/ 已出现文件" || ok "预演不落盘"
expect_match "--apply 复制" "已复制 1 个" "$ROOT/scribe" migrate --apply
echo '人工批注' >> "$SCRIBE_DATA_DIR/imported/-Users-someone-proj/note.md"
expect_match "二次导入跳过已存在" "跳过 1 个" "$ROOT/scribe" migrate --apply
file_has "人工批注未被覆盖" "$SCRIBE_DATA_DIR/imported/-Users-someone-proj/note.md" '人工批注'
[ -f "$SCRIBE_NATIVE_MEMORY/-Users-someone-proj/memory/note.md" ] \
  && ok "原生文件保留" || bad "原生文件保留" "原文件被删除"

# ---------------------------------------------------------------- interpreter
section "解释器解析"
REALPY="$SCRIBE_PY"
SHIM="$WORK/shim"
mkdir -p "$SHIM"
# A self-contained PATH: only the interpreters under test plus the few utilities the
# scripts shell out to. Prepending a shim to the real PATH would not work — /usr/bin ships
# a working python3 that masks the case being tested.
for tool in dirname mkdir cat find wc tr git sed grep date rm ls; do
  src=$(command -v "$tool" 2>/dev/null) && ln -sf "$src" "$SHIM/$tool"
done
stub() { printf '#!/bin/sh\nexit 1\n' > "$SHIM/$1"; chmod +x "$SHIM/$1"; }

# python3 present but unusable, python is a real Python 3: must fall back, not give up.
stub python3
ln -sf "$REALPY" "$SHIM/python"
expect_rc "python3 不可用时回退到 python(3.x)" 0 \
  env PATH="$SHIM" SCRIBE_PYTHON= "$LEDGER" list

# A working python3 later on PATH must win even when an earlier one is broken — this is
# not hypothetical: a stale Homebrew symlink did exactly this during development.
mkdir -p "$WORK/goodbin"
ln -sf "$REALPY" "$WORK/goodbin/python3"
rm -f "$SHIM/python"
expect_rc "靠后的可用 python3 仍会被找到" 0 \
  env PATH="$SHIM:$WORK/goodbin" SCRIBE_PYTHON= "$LEDGER" list

# An interpreter that dies on a signal: the shell reports "Killed: 9" on its own stderr,
# which would otherwise land in the SessionStart hook's output every session.
printf '#!/bin/sh\nkill -9 $$\n' > "$SHIM/python3"
chmod +x "$SHIM/python3"
ln -sf "$REALPY" "$SHIM/python"
expect_rc "被信号杀死的解释器不阻断解析" 0 \
  env PATH="$SHIM" SCRIBE_PYTHON= "$LEDGER" list
expect_absent "被信号杀死的解释器不泄漏 Killed 噪音" "Killed" \
  env PATH="$SHIM" SCRIBE_PYTHON= "$LEDGER" list
expect_absent "hook 输出不含 Killed 噪音" "Killed" \
  sh -c "echo '{\"cwd\":\"$WORK\"}' | env PATH='$SHIM' SCRIBE_PYTHON= '$ROOT/hooks/session-start.sh' 2>&1"
rm -f "$SHIM/python"

# A working interpreter that reports an unsupported version — what a real Python 2 would
# look like. It fails only the version probe and otherwise execs a real Python 3, so if the
# version floor were removed this double would be accepted and the assertion below would
# flip to rc=0. That coupling to the probe's text is deliberate: it is what makes this
# assertion able to detect the floor being dropped.
rm -f "$SHIM/python3"
printf '#!/bin/sh\ncase "$*" in *version_info*) exit 1 ;; esac\nexec %s "$@"\n' "$REALPY" \
  > "$SHIM/python"
chmod +x "$SHIM/python"
expect_rc "版本过低的解释器被拒（而非降级使用）" 1 \
  env PATH="$SHIM" SCRIBE_PYTHON= "$LEDGER" list

# Nothing usable anywhere.
stub python3
stub python
expect_rc "无可用 Python 3 时拒绝运行" 1 \
  env PATH="$SHIM" SCRIBE_PYTHON= "$LEDGER" list
expect_match "拒绝时给出可执行指引" "SCRIBE_PYTHON" \
  env PATH="$SHIM" SCRIBE_PYTHON= "$LEDGER" list
expect_absent "拒绝时不产生 Python 语法错误" "SyntaxError" \
  env PATH="$SHIM" SCRIBE_PYTHON= "$LEDGER" list

# The hook degrades instead of failing the whole session.
hook_no_python() {
  echo '{"cwd":"'"$WORK"'"}' | env PATH="$SHIM" SCRIBE_PYTHON= \
    "$ROOT/hooks/session-start.sh" 2>&1
}
expect_rc "无解释器时 hook 仍返回 0" 0 hook_no_python
expect_match "无解释器时 hook 仍输出契约文本" "Scribe records only reusable candidates" hook_no_python
expect_match "无解释器时 hook 说明索引被跳过" "跳过记忆索引" hook_no_python
rm -f "$SHIM/python" "$SHIM/python3"

expect_rc "SCRIBE_PYTHON 显式指定生效" 0 \
  env SCRIBE_PYTHON="$REALPY" "$LEDGER" list
expect_match "SCRIBE_PYTHON 指向无效解释器时回退到 python3" "active 已确认记忆" \
  env SCRIBE_PYTHON=/nonexistent/python "$LEDGER" list

# ---------------------------------------------------------------- install
section "安装与注册"
expect_rc "install 成功" 0 "$ROOT/scribe" install claude-code
expect_rc "重复 install 成功" 0 "$ROOT/scribe" install claude-code
"$SCRIBE_PY" - "$SCRIBE_SETTINGS" "$ROOT" "$SCRIBE_DATA_DIR" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
root, store = pathlib.Path(sys.argv[2]), sys.argv[3]
session = str(root / "hooks" / "session-start.sh")
hooks = [h["command"] for g in data["hooks"]["SessionStart"] for h in g["hooks"]]
allow, deny = data["permissions"]["allow"], data["permissions"]["deny"]
checks = [
    ("hook 只注册一次", hooks.count(session) == 1),
    ("allow 无重复", len(allow) == len(set(allow))),
    ("deny 无重复", len(deny) == len(set(deny))),
    ("deny 覆盖四个放行动词",
     sum(f"review-ledger {v}" in d for v in ("approve", "archive", "retire", "revoke")
         for d in deny) == 4),
    ("deny 跟随实际数据目录", any(store in d for d in deny)),
    ("record-candidate 在 allow 中", any("record-candidate" in a for a in allow)),
]
for desc, good in checks:
    print(("ok   " if good else "FAIL ") + desc)
raise SystemExit(0 if all(good for _, good in checks) else 1)
PY
if [ $? -eq 0 ]; then pass=$((pass + 6)); else fail=$((fail + 1)); echo "  FAIL 注册内容校验"; fi
expect_rc "doctor 通过" 0 "$ROOT/scribe" doctor
expect_rc "uninstall 成功" 0 "$ROOT/scribe" uninstall claude-code
expect_rc "uninstall 后 doctor 失败" 1 "$ROOT/scribe" doctor
[ -d "$SCRIBE_DATA_DIR/approved" ] && ok "uninstall 保留数据" || bad "uninstall 保留数据" "数据目录消失"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
