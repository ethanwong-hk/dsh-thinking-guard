#!/usr/bin/env bash
# 把发布名从 @ethanwong-hk/dsh-thinking-guard 切回 dsh-thinking-guard
#
# 背景：2026-09-27 误删了 unscoped 包，npm 锁定该名 24 小时（至 09-28 03:56 北京），
# 先以 scoped 名应急发布。本脚本在锁定期结束后完成切换。
#
# 顺序是硬性的：B 发布成功且校验通过之前，绝不删除 A。
# 上一次事故就是因为先删后发，导致两个名字同时不可用。
#
# 用法：bash scripts/switch-to-unscoped.sh            # 全流程
#       bash scripts/switch-to-unscoped.sh --check    # 只查状态，不做改动

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SCOPED='@ethanwong-hk/dsh-thinking-guard'
UNSCOPED='dsh-thinking-guard'
VERSION="$(python3 -c 'import json;print(json.load(open("package.json"))["version"])')"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
step() { printf '\n%s── %s ──%s\n' "$DIM" "$*" "$RST"; }

# registry 查询：0=存在 1=不存在
pkg_exists() { curl -s -m 20 -o /dev/null -w '%{http_code}' \
  "https://registry.npmjs.org/$(printf '%s' "$1" | sed 's|/|%2F|')" 2>/dev/null | grep -q '^200$'; }

latest_of() { curl -s -m 20 "https://registry.npmjs.org/$(printf '%s' "$1" | sed 's|/|%2F|')" 2>/dev/null \
  | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("dist-tags",{}).get("latest") or "0")
except Exception:
    print("0")' 2>/dev/null; }

status() {
  step "当前状态"
  local a_latest b_latest
  a_latest="$(latest_of "$SCOPED")"
  b_latest="$(latest_of "$UNSCOPED")"
  if [ "$a_latest" != "0" ]; then ok "A  $SCOPED  → $a_latest"; else warn "A  $SCOPED  → 不存在"; fi
  if [ "$b_latest" != "0" ]; then ok "B  $UNSCOPED  → $b_latest"; else warn "B  $UNSCOPED  → 不存在/锁定"; fi
  printf '  %spackage.json name: %s%s\n' "$DIM" \
    "$(python3 -c 'import json;print(json.load(open("package.json"))["name"])')" "$RST"
}

if [ "${1:-}" = "--check" ]; then
  status
  lock_state="$(curl -s -m 20 "https://registry.npmjs.org/$UNSCOPED" 2>/dev/null | python3 -c '
import json, sys, datetime
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown"); raise SystemExit
if (d.get("dist-tags") or {}).get("latest"):
    print("published"); raise SystemExit
unp = (d.get("time") or {}).get("unpublished")
if not unp:
    print("free"); raise SystemExit
t = datetime.datetime.fromisoformat(unp["time"].replace("Z", "+00:00"))
lock = t + datetime.timedelta(hours=24)
now = datetime.datetime.now(datetime.timezone.utc)
bj = datetime.timezone(datetime.timedelta(hours=8))
print("free" if now >= lock else "locked " + lock.astimezone(bj).strftime("%m-%d %H:%M"))
' 2>/dev/null)"
  printf '\n'
  case "$lock_state" in
    published) printf '  %sB 已发布过，无需切换。%s\n' "$DIM" "$RST" ;;
    free)      printf '  %sB 可发布 —— 跑 `bash %s` 执行切换（需两次 Touch ID）。%s\n' "$GRN" "$0" "$RST" ;;
    locked*)   printf '  %sB 仍锁定：%s 北京。%s\n' "$YEL" "${lock_state#locked }" "$RST" ;;
    *)         printf '  %s无法判定 B 的状态（registry 查询失败）。%s\n' "$YEL" "$RST" ;;
  esac
  exit 0
fi

status

# ── 前置检查：B 必须已经解锁 ────────────────────────────────────────────────
# 判据取自 registry 的 time.unpublished + 24h，而不是 publish --dry-run：
# dry-run 不会真正发请求，用它会得到一个永远通过的假检查。
step "前置检查"
unlock_out="$(curl -s -m 20 "https://registry.npmjs.org/$UNSCOPED" 2>/dev/null | python3 -c '
import json, sys, datetime
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown"); raise SystemExit
unp = (d.get("time") or {}).get("unpublished")
if not unp:
    print("free"); raise SystemExit
t = datetime.datetime.fromisoformat(unp["time"].replace("Z", "+00:00"))
lock = t + datetime.timedelta(hours=24)
now = datetime.datetime.now(datetime.timezone.utc)
bj = datetime.timezone(datetime.timedelta(hours=8))
if now >= lock:
    print("free")
else:
    left = (lock - now).total_seconds() / 3600
    print("locked %.1fh %s" % (left, lock.astimezone(bj).strftime("%m-%d %H:%M")))
' 2>/dev/null)"

case "$unlock_out" in
  free)
    ok "$UNSCOPED 无锁定期，可以发布"
    ;;
  locked*)
    bad "$UNSCOPED 仍在锁定期：${unlock_out#locked }（北京）"
    printf '  %s时间到后再运行本脚本。%s\n' "$DIM" "$RST"
    exit 1
    ;;
  *)
    warn "无法判定锁定期（registry 查询失败），继续但请自行确认已过 09-28 03:56 北京"
    ;;
esac

# ── 步骤 1：切回 unscoped 名 ────────────────────────────────────────────────
# 记录原始包名，供失败时回滚（2026-09-28 实测教训：步骤 1 改了 package.json，
# 若步骤 3 发布失败且不回滚，本地清单会指向一个 npm 上不存在的名字，市场因此
# 回退到 github: 源码安装，README 的安装命令也会 404）
ORIGINAL_NAME="$(python3 -c 'import json;print(json.load(open("package.json"))["name"])')"
ROLLED_BACK=0
TMPDIR_TO_CLEAN=""
cleanup_tmp() { [ -n "$TMPDIR_TO_CLEAN" ] && rm -rf "$TMPDIR_TO_CLEAN"; }
rollback() {
  [ "$ROLLED_BACK" = "1" ] && return
  ROLLED_BACK=1
  printf '\n  %s!%s 回滚 package.json / README 到 %s\n' "$YEL" "$RST" "$ORIGINAL_NAME"
  python3 - "$ORIGINAL_NAME" <<'PYROLLBACK'
import json, sys, re, pathlib
name = sys.argv[1]
p = pathlib.Path('package.json')
d = json.loads(p.read_text(encoding='utf-8'))
if d['name'] != name:
    d['name'] = name
    p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'    ✓ package.json → {name}')
r = pathlib.Path('README.md')
s = r.read_text(encoding='utf-8')
s2 = re.sub(r'dsh plugin add \S*dsh-thinking-guard', f'dsh plugin add {name}', s)
if s2 != s:
    r.write_text(s2, encoding='utf-8')
    print('    ✓ README.md 安装命令已复原')
PYROLLBACK
  # 步骤 2 已经 push 过，工作区现在有未提交的复原改动
  if ! git diff --quiet 2>/dev/null; then
    git add -A
    git -c commit.gpgsign=false commit -q -m "revert: keep the published package name after a failed switch

The switch script renamed package.json before publishing; the publish step
failed, so the manifest is restored to the name that actually exists on the
registry." 2>/dev/null && printf '    ✓ 已提交复原\n'
    git -c http.postBuffer=524288000 push 2>&1 | tail -1 | sed 's/^/    /'
  fi
}
# 单一 EXIT trap —— bash 的 trap 是覆盖而非追加，第二次 trap 会静默取消第一次
trap 'cleanup_tmp; rollback' EXIT

step "1/5 切换 package.json 与 README 到 $UNSCOPED"
python3 - "$UNSCOPED" <<'PY'
import json, sys, re, pathlib
new = sys.argv[1]
p = pathlib.Path('package.json')
d = json.loads(p.read_text(encoding='utf-8'))
old = d['name']
if old == new:
    print(f'  = package.json 已是 {new}')
else:
    d['name'] = new
    p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'  ✓ package.json: {old} → {new}')

r = pathlib.Path('README.md')
s = r.read_text(encoding='utf-8')
s2 = re.sub(r'dsh plugin add @[^\s`]*dsh-thinking-guard', f'dsh plugin add {new}', s)
if s2 != s:
    r.write_text(s2, encoding='utf-8')
    print('  ✓ README.md 安装命令已更新')
else:
    print('  = README.md 无需改动')
PY

# ── 步骤 2：先在 GitHub 上发布，让市场能读到新名字 ──────────────────────────
# 注意：此时 npm 上 B 还不存在，市场会先回退 github: 安装；
# 等 B 发布后，市场在 1 天内（RECHECK_DAYS）自动重新探测并切到 registry。
step "2/5 提交并推送（package.json 是市场的名字来源）"
git add -A
if git diff --cached --quiet; then
  ok "无改动需要提交"
else
  git -c commit.gpgsign=false commit -q -m "release: switch back to unscoped name $UNSCOPED

Restores the canonical package name now that the 24h lock has lifted.
package.json is the name the market resolves against, so this commit must
land before the market probes the repo."
  ok "$(git log --oneline -1)"
fi
git -c http.postBuffer=524288000 push 2>&1 | tail -2 | sed 's/^/    /'

git tag -d "v$VERSION" >/dev/null 2>&1 || true
git tag -a "v$VERSION" main -m "dsh-thinking-guard v$VERSION" 2>/dev/null || true
git -c http.postBuffer=524288000 push --force origin "v$VERSION" 2>&1 | tail -1 | sed 's/^/    /'
ok "tag v$VERSION 已重指向"

# ── 步骤 3：发布 B（需要 Touch ID） ─────────────────────────────────────────
step "3/5 发布 $UNSCOPED@$VERSION"
warn "浏览器会弹认证页，用 Touch ID 确认"
printf '\n'
(printf '\n'; sleep 300) | script -q /dev/null npx -y npm@11 publish --access public > /tmp/switch_publish.log 2>&1 &
pub_pid=$!
sleep 16
url="$(grep -oE 'https://www\.npmjs\.com/auth/cli/[a-z0-9-]+' /tmp/switch_publish.log | head -1)"
[ -n "$url" ] && { printf '  认证地址: %s\n\n' "$url"; open "$url" 2>/dev/null; }

for _ in $(seq 1 24); do
  sleep 10
  ps -p "$pub_pid" >/dev/null 2>&1 || break
done
tail -4 /tmp/switch_publish.log | sed 's/^/    /'

# ── 步骤 4：校验 B 真的可用，否则中止 ──────────────────────────────────────
step "4/5 校验 $UNSCOPED@$VERSION"
launch_ok=0
for _ in $(seq 1 12); do
  [ "$(latest_of "$UNSCOPED")" = "$VERSION" ] && { launch_ok=1; break; }
  sleep 15
done
if [ "$launch_ok" != 1 ]; then
  bad "$UNSCOPED@$VERSION 未上线 —— 中止后续步骤，A 保持原样不动"
  printf '  %s查看 /tmp/switch_publish.log 排查。%s\n' "$DIM" "$RST"
  rollback
  ROLLED_BACK=1   # 已手动回滚，trap 不再重复
  printf '  %s回滚完成：package.json 仍指向 %s，与 registry 一致。%s\n' "$GRN" "$ORIGINAL_NAME" "$RST"
  exit 1
fi
ok "$UNSCOPED@$VERSION 已上线"

tmpd="$(mktemp -d)"; TMPDIR_TO_CLEAN="$tmpd"
curl -s -m 60 -o "$tmpd/p.tgz" "https://registry.npmjs.org/$UNSCOPED/-/$UNSCOPED-$VERSION.tgz" 2>/dev/null
if tar -xzf "$tmpd/p.tgz" -C "$tmpd" 2>/dev/null; then
  if grep -rq '/Users/reiji' "$tmpd/package" 2>/dev/null; then
    bad "tarball 含个人路径 —— 中止，A 保持原样"
    exit 1
  fi
  ok "tarball 内容校验通过（无个人路径）"
fi

# ── 步骤 5：B 确认可用后，删除 A ──────────────────────────────────────────
step "5/5 删除 scoped 包 $SCOPED"
warn "浏览器会再次弹认证页"
printf '\n'
(printf '\n'; sleep 300) | script -q /dev/null npx -y npm@11 unpublish "$SCOPED" --force > /tmp/switch_unpublish.log 2>&1 &
unp_pid=$!
sleep 16
url="$(grep -oE 'https://www\.npmjs\.com/auth/cli/[a-z0-9-]+' /tmp/switch_unpublish.log | head -1)"
[ -n "$url" ] && { printf '  认证地址: %s\n\n' "$url"; open "$url" 2>/dev/null; }

for _ in $(seq 1 24); do
  sleep 10
  ps -p "$unp_pid" >/dev/null 2>&1 || break
done
tail -3 /tmp/switch_unpublish.log | sed 's/^/    /'

sleep 10
if [ "$(latest_of "$SCOPED")" = "0" ]; then
  ok "$SCOPED 已删除"
else
  warn "$SCOPED 仍在（CDN 缓存，稍后复查）"
fi

# ── 收尾 ──────────────────────────────────────────────────────────────────
step "完成"
ROLLED_BACK=1   # 全部成功：禁用 EXIT trap，避免把已完成的切换撤掉
status
printf '\n  安装命令: %sdsh plugin add %s%s\n' "$GRN" "$UNSCOPED" "$RST"
printf '  回滚: %sgit revert HEAD && bash scripts/switch-to-unscoped.sh%s\n\n' "$DIM" "$RST"
