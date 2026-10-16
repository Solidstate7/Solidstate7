#!/usr/bin/env bash
# Usage: submit-and-push.sh [--dry-run]
#   --dry-run  skip the submit, the commit and the push; print the README change instead.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_PREFIX="[tokscale]"
TS_USER="Solidstate7"                       # tokscale.ai profile / GitHub handle
PLAT_URL="https://tokscale.ai/api/users/${TS_USER}"
# Pinned, not @latest: a floating version has broken this job twice (a dropped flag in June;
# 4.19.x `time-metrics` hangs forever, Oct 2026). Bump by hand after a manual test run.
TOKSCALE="tokscale@4.18.0"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

export GIT_TERMINAL_PROMPT=0                # never wait on a credential prompt (no terminal under launchd)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WARN=""                                     # accumulates non-fatal degradations → recorded in the cache

# with_timeout SECS CMD...: run CMD in its own process group and kill the whole group
# (npx → node → native binary) if it outlives SECS. Returns CMD's exit code (143 on timeout).
with_timeout() {
  local secs=$1; shift
  set -m; "$@" & local pid=$!; set +m
  ( sleep "$secs"; kill -TERM -- "-$pid" 2>/dev/null; sleep 5; kill -KILL -- "-$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watch=$!
  local rc=0; wait "$pid" || rc=$?
  kill "$watch" 2>/dev/null || true; wait "$watch" 2>/dev/null || true
  return "$rc"
}

# 1) Push local usage to the Tokscale platform (also refreshes the live embed and the
#    platform total we read back below). Non-fatal.
if [ "$DRY_RUN" = 1 ]; then
  echo "$LOG_PREFIX Dry run: skipping submit."
else
  echo "$LOG_PREFIX Submitting usage data..."
  with_timeout 600 npx --yes "$TOKSCALE" submit \
    || { echo "$LOG_PREFIX WARN: submit failed; continuing."; WARN="${WARN}submit failed; "; }
fi

# 2) Harvest authoritative stats.
#    - Token total + sessions + active time come from the PLATFORM API — the SAME source
#      as the README's live embed, so the two can never disagree. (The local CLI scan only
#      sees the local session-file retention window, so it UNDERCOUNTS lifetime tokens —
#      that mismatch is what showed 4.0B vs the real 4.7B.)
#    - Peak concurrency + longest streak are NOT on the platform → local `time-metrics`.
echo "$LOG_PREFIX Fetching platform totals + local time-metrics..."
curl -s --fail --max-time 30 "$PLAT_URL" -o "$TMP/plat.json" \
  || { echo "$LOG_PREFIX WARN: platform fetch failed; keeping last known token total."; \
       WARN="${WARN}platform fetch failed (token total may be stale); "; echo '{}' > "$TMP/plat.json"; }
[ -s "$TMP/plat.json" ] || echo '{}' > "$TMP/plat.json"

with_timeout 180 npx --yes "$TOKSCALE" time-metrics --json 2>/dev/null > "$TMP/metrics.json" \
  || { echo "$LOG_PREFIX WARN: time-metrics failed or timed out; keeping last known values."; \
       echo '{}' > "$TMP/metrics.json"; WARN="${WARN}time-metrics failed; "; }
[ -s "$TMP/metrics.json" ] || echo '{}' > "$TMP/metrics.json"

cd "$REPO_DIR"

# 3) Start from what GitHub has. The cloud fallback (.github/workflows/update-readme.yml)
#    commits here too, so an unsynced clone gets every push rejected. Unpushed commits
#    that only change the stats are dropped on a conflict: step 4 rebuilds them.
sync_with_github() {
  git fetch -q origin main || return 1
  git rebase -q --autostash origin/main >/dev/null 2>&1 && return 0
  git rebase --abort >/dev/null 2>&1 || true
  local other
  other=$(git diff --name-only origin/main...HEAD | grep -vxE 'README\.md|\.tokscale-cache\.json' || true)
  other+=$(git diff -U0 origin/main...HEAD -- README.md | grep -E '^[-+][^-+]' \
           | grep -vE '\+tokens|\+parallel\+agents' || true)
  [ -z "$other" ] || return 1               # a hand-made change is in the way: leave it to a human
  echo "$LOG_PREFIX Dropping unpushed stats commits $(git rev-parse --short HEAD) (rebuilt below)."
  cp .tokscale-cache.json "$TMP/cache.json" 2>/dev/null || true
  git reset -q --hard origin/main
  cp "$TMP/cache.json" .tokscale-cache.json 2>/dev/null || true
}
sync_with_github || { echo "$LOG_PREFIX ERROR: could not sync with GitHub; README left as is." >&2; exit 1; }

# Single source of truth: derive every display value, write the full cache (consumed by
# the GH Actions fallback + local monitoring), and emit shell assignments.
python3 - "$TMP/plat.json" "$TMP/metrics.json" "$REPO_DIR/.tokscale-cache.json" "$WARN" \
  "$REPO_DIR/README.md" > "$TMP/vars.sh" <<'PY'
import json, sys, math, datetime, re

now_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def load(p):
    try:
        return json.load(open(p))
    except Exception:
        return {}

plat     = load(sys.argv[1])
stats    = plat.get("stats", {}) or {}
rank     = (plat.get("user", {}) or {}).get("rank")
metrics  = (load(sys.argv[2]) or {}).get("metrics", {}) or {}
prev     = load(sys.argv[3])                     # existing cache → fallback values
warnings = (sys.argv[4] or "").strip()

def fmt_tokens(total):
    # Floor to 1 decimal (matches how tokscale.ai/the embed displays it):
    # 4,765,129,471 -> "4.7B", not a rounded "4.8B".
    b = total / 1e9
    if b >= 10:
        return f"{math.floor(b)}B"
    if b >= 1:
        return f"{math.floor(b * 10) / 10:.1f}B"
    return f"{math.floor(total / 1e6)}M"

def tokens_value(s):
    m = re.fullmatch(r"([0-9][0-9.]*)([BMK]?)", s or "")
    return float(m.group(1)) * {"B": 1e9, "M": 1e6, "K": 1e3, "": 1}[m.group(2)] if m else 0

raw    = stats.get("totalTokens")
tokens = fmt_tokens(int(raw)) if raw else prev.get("tokens", "")   # never regress to local scan

# A lifetime total only grows: never show less than the README already does.
try:
    m = re.search(r"([0-9][0-9.]*[BMK]?)\+tokens", open(sys.argv[5]).read())
    shown = m.group(1) if m else ""
except Exception:
    shown = ""
if shown and tokens_value(tokens) < tokens_value(shown):
    warnings = (warnings + f" new total {tokens or '?'} below shown {shown}; kept {shown};").strip()
    tokens = shown

maxc   = int(metrics.get("max_concurrent_sessions", 0)) or int(prev.get("max_concurrent_sessions", 0) or 0)
strk_h = int(metrics.get("longest_continuous_ms", 0) // 3_600_000) or int(prev.get("longest_streak_hours", 0) or 0)
sess   = int(stats.get("sessionCount", 0) or prev.get("session_count", 0) or 0)
act_h  = int(int(stats.get("totalActiveTimeMs", 0)) // 3_600_000) or int(prev.get("active_hours", 0) or 0)
adays  = int(stats.get("activeDays", 0) or prev.get("active_days", 0) or 0)
rank   = rank if rank is not None else prev.get("rank")

cache = {
    "tokens": tokens,
    "raw_total_tokens": int(raw) if raw else prev.get("raw_total_tokens"),
    "max_concurrent_sessions": maxc,
    "session_count": sess,
    "active_days": adays,
    "active_hours": act_h,
    "longest_streak_hours": strk_h,
    "rank": rank,
    "warnings": warnings,                        # "" on a clean run; non-empty = degraded
    "source": "platform API (tokens/sessions/activeDays/activeTime) + local time-metrics (peak concurrent/longest streak)",
    "updated": now_utc,
}
with open(sys.argv[3], "w") as f:
    json.dump(cache, f, indent=2)
    f.write("\n")

print(f"TOKENS='{tokens}'")
print(f"MAXC='{maxc}'")
PY
# shellcheck disable=SC1090
source "$TMP/vars.sh"

echo "$LOG_PREFIX Tokens=$TOKENS  PeakAgents=$MAXC${WARN:+  WARN: $WARN}"

# 4) Update the README typing-svg tagline (URL-encoded: + is space). Each pattern is
#    anchored by its trailing label, so substitutions can't collide. Guarded so a missing
#    value never blanks out the README.
update_readme() {
  if [ -n "$TOKENS" ]; then
    TOKENS_ESC="${TOKENS//./\\.}"
    sed -i '' "s|[0-9][0-9.]*[BMK]*+tokens|${TOKENS_ESC}+tokens|g" "$REPO_DIR/README.md"
  fi
  if [ -n "$MAXC" ] && [ "$MAXC" != "0" ]; then
    sed -i '' "s|[0-9][0-9]*+parallel+agents|${MAXC}+parallel+agents|g" "$REPO_DIR/README.md"
  fi
}

# Gate the COMMIT on the README actually changing — the cache's timestamp changes every
# run, so committing it unconditionally would spam a daily no-op commit. Returns 1 when
# there was nothing to commit.
commit_stats() {
  git diff --quiet README.md 2>/dev/null && return 1
  git add README.md .tokscale-cache.json
  git commit -q -m "chore: update profile stats → ${TOKENS} tokens · ${MAXC} peak agents [skip ci]"
}

ahead() { [ "$(git rev-list --count origin/main..HEAD)" -gt 0 ]; }

update_readme
if [ "$DRY_RUN" = 1 ]; then
  if git diff --quiet README.md; then
    echo "$LOG_PREFIX Dry run: no change in displayed stats."
  else
    echo "$LOG_PREFIX Dry run: would commit and push this README change:"
    git --no-pager diff README.md
    git checkout -q -- README.md
  fi
  exit 0
fi

commit_stats || echo "$LOG_PREFIX No change in displayed stats — nothing to commit."
ahead || exit 0                             # nothing new, nothing left over from a failed day

# Explicit remote/ref so it works even if 'main' has no upstream configured. One retry
# covers the cloud fallback committing between our fetch and our push: re-sync, and if
# that dropped our commit, rebuild it on top of the cloud's.
push_stats() {
  git push -q origin HEAD:main && return 0
  echo "$LOG_PREFIX Push rejected; re-syncing with GitHub and retrying once."
  sync_with_github || return 1
  if ! ahead; then
    update_readme
    commit_stats || return 0                # GitHub already shows these numbers
  fi
  git push -q origin HEAD:main
}
push_stats || { echo "$LOG_PREFIX ERROR: push failed; the commit stays local for the next run." >&2; exit 1; }

echo "$LOG_PREFIX Done. GitHub shows ${TOKENS} tokens, ${MAXC} peak agents."
