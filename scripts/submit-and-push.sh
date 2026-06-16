#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_PREFIX="[tokscale]"
TS_USER="Solidstate7"                       # tokscale.ai profile / GitHub handle
PLAT_URL="https://tokscale.ai/api/users/${TS_USER}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) Push local usage to the Tokscale platform (also refreshes the live embed and
#    the platform total we read back below). Non-fatal — a hiccup here must never
#    freeze the README.
echo "$LOG_PREFIX Submitting usage data..."
npx --yes tokscale@latest submit \
  || echo "$LOG_PREFIX WARN: submit failed; continuing."

# 2) Harvest authoritative stats.
#    - Token total + sessions + active time come from the PLATFORM API — the SAME
#      source as the README's live embed, so the two can never disagree. (The local
#      CLI scan only sees session files for the local retention window, so it
#      UNDERCOUNTS lifetime tokens — that mismatch is what showed 4.0B vs the real 4.7B.)
#    - Peak concurrency + longest streak are NOT on the platform, so they come from
#      the local `time-metrics` report.
echo "$LOG_PREFIX Fetching platform totals + local time-metrics..."
curl -s --fail --max-time 30 "$PLAT_URL" -o "$TMP/plat.json" \
  || { echo "$LOG_PREFIX WARN: platform fetch failed; keeping last known token total."; echo '{}' > "$TMP/plat.json"; }
[ -s "$TMP/plat.json" ] || echo '{}' > "$TMP/plat.json"

npx tokscale@latest time-metrics --json 2>/dev/null > "$TMP/metrics.json" \
  || echo '{}' > "$TMP/metrics.json"
[ -s "$TMP/metrics.json" ] || echo '{}' > "$TMP/metrics.json"

# Single source of truth: derive every display value, write the full cache
# (consumed by the GH Actions fallback), and emit shell assignments to source.
python3 - "$TMP/plat.json" "$TMP/metrics.json" "$REPO_DIR/.tokscale-cache.json" \
  > "$TMP/vars.sh" <<'PY'
import json, sys, math, datetime

now_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def load(p):
    try:
        return json.load(open(p))
    except Exception:
        return {}

plat    = load(sys.argv[1])
stats   = plat.get("stats", {}) or {}
rank    = (plat.get("user", {}) or {}).get("rank")
metrics = (load(sys.argv[2]) or {}).get("metrics", {}) or {}
prev    = load(sys.argv[3])                      # existing cache → fallback values

def fmt_tokens(total):
    # Floor to 1 decimal (matches how tokscale.ai/the embed displays it):
    # 4,765,129,471 -> "4.7B", not a rounded "4.8B".
    b = total / 1e9
    if b >= 10:
        return f"{math.floor(b)}B"
    if b >= 1:
        return f"{math.floor(b * 10) / 10:.1f}B"
    return f"{math.floor(total / 1e6)}M"

raw    = stats.get("totalTokens")
tokens = fmt_tokens(int(raw)) if raw else prev.get("tokens", "")   # never regress to local scan
maxc   = int(metrics.get("max_concurrent_sessions", 0)) or int(prev.get("max_concurrent_sessions", 0) or 0)
strk_h = int(metrics.get("longest_continuous_ms", 0) // 3_600_000) or int(prev.get("longest_streak_hours", 0) or 0)
sess   = int(stats.get("sessionCount", 0) or prev.get("session_count", 0) or 0)
act_h  = int(int(stats.get("totalActiveTimeMs", 0)) // 3_600_000) or int(prev.get("active_hours", 0) or 0)
adays  = int(stats.get("activeDays", 0) or prev.get("active_days", 0) or 0)

cache = {
    "tokens": tokens,
    "raw_total_tokens": int(raw) if raw else prev.get("raw_total_tokens"),
    "max_concurrent_sessions": maxc,
    "session_count": sess,
    "active_days": adays,
    "active_hours": act_h,
    "longest_streak_hours": strk_h,
    "rank": rank if rank is not None else prev.get("rank"),
    "source": "platform API (tokens/sessions/activeDays/activeTime) + local time-metrics (peak concurrent/longest streak)",
    "updated": now_utc,
}
with open(sys.argv[3], "w") as f:
    json.dump(cache, f, indent=2)
    f.write("\n")

print(f"TOKENS='{tokens}'")
print(f"MAXC='{maxc}'")
print(f"SESS='{sess}'")
print(f"ACTH='{act_h}'")
print(f"STREAKH='{strk_h}'")
PY
# shellcheck disable=SC1090
source "$TMP/vars.sh"

echo "$LOG_PREFIX Tokens=$TOKENS  PeakAgents=$MAXC  Sessions=$SESS  Active=${ACTH}h  Streak=${STREAKH}h"

# 3) Update the README typing-svg tagline (URL-encoded: + is space). Each pattern is
#    anchored by its trailing label, so substitutions can't collide. Guarded so a
#    missing value never blanks out the README.
if [ -n "$TOKENS" ]; then
  TOKENS_ESC="${TOKENS//./\\.}"
  sed -i '' "s|[0-9][0-9.]*[BMK]*+tokens|${TOKENS_ESC}+tokens|g" "$REPO_DIR/README.md"
fi
if [ -n "$MAXC" ] && [ "$MAXC" != "0" ]; then
  sed -i '' "s|[0-9][0-9]*+parallel+agents|${MAXC}+parallel+agents|g" "$REPO_DIR/README.md"
fi

cd "$REPO_DIR"

# Gate on README only — the cache's timestamp changes every run, so including it
# here would produce a junk commit daily even when the displayed values are flat.
if git diff --quiet README.md 2>/dev/null; then
  echo "$LOG_PREFIX No change in displayed stats — nothing to commit."
  exit 0
fi

git add README.md .tokscale-cache.json
git commit -m "chore: update profile stats → ${TOKENS} tokens · ${MAXC} peak agents [skip ci]"
# Explicit remote/ref so it works even if 'main' has no upstream configured.
git push origin HEAD

echo "$LOG_PREFIX Done. README updated (${TOKENS} tokens, ${MAXC} peak agents)."
