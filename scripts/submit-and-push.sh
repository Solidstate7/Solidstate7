#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_PREFIX="[tokscale]"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) Push local usage to the Tokscale platform (also refreshes the live embed).
#    Non-fatal: a tokscale platform/network/flag hiccup must never freeze the
#    README — every displayed value below is recomputed from the local reads,
#    which do not depend on submit succeeding.
echo "$LOG_PREFIX Submitting usage data..."
npx --yes tokscale@latest submit \
  || echo "$LOG_PREFIX WARN: submit failed; continuing with local data."

# 2) Harvest ALL relevant data in one pass:
#      - token total   (tokscale --json   → per-client/model entries)
#      - session/time  (tokscale time-metrics --json → concurrency, sessions, hours)
echo "$LOG_PREFIX Harvesting usage + time metrics..."
# stderr → /dev/null: drops the progress spinner (keeps launchd logs clean) and is
# immune to spinner-flag drift; JSON goes to stdout. A real failure still surfaces
# as an empty file → json.load error below under `set -e`.
npx tokscale@latest --json              2>/dev/null > "$TMP/usage.json"
npx tokscale@latest time-metrics --json 2>/dev/null > "$TMP/metrics.json"

# Single source of truth: derive every display value, write the full cache
# (consumed by the GH Actions fallback), and emit shell assignments to source.
python3 - "$TMP/usage.json" "$TMP/metrics.json" "$REPO_DIR/.tokscale-cache.json" \
  > "$TMP/vars.sh" <<'PY'
import json, sys, datetime

now_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

usage   = json.load(open(sys.argv[1]))
metrics = json.load(open(sys.argv[2])).get("metrics", {})

total = sum(
    e.get("input", 0) + e.get("output", 0) +
    e.get("cacheRead", 0) + e.get("cacheWrite", 0) + e.get("reasoning", 0)
    for e in usage.get("entries", [])
)
b = total / 1e9
tokens = f"{b:.0f}B" if b >= 10 else (f"{b:.1f}B" if b >= 1 else f"{total/1e6:.0f}M")

maxc   = int(metrics.get("max_concurrent_sessions", 0))
sess   = int(metrics.get("session_count", 0))
act_h  = int(metrics.get("total_active_time_ms", 0)  // 3_600_000)
strk_h = int(metrics.get("longest_continuous_ms", 0) // 3_600_000)

# Full harvest → cache (visible fields + currently-hidden ones, kept for future use).
cache = {
    "tokens": tokens,
    "max_concurrent_sessions": maxc,
    "session_count": sess,
    "active_hours": act_h,
    "longest_streak_hours": strk_h,
    "raw_total_tokens": total,
    "updated": now_utc,
}
with open(sys.argv[3], "w") as f:
    json.dump(cache, f, indent=2)
    f.write("\n")

# Shell assignments (single-quoted; values are digits / a short token string).
print(f"TOKENS='{tokens}'")
print(f"MAXC='{maxc}'")
print(f"SESS='{sess}'")
print(f"ACTH='{act_h}'")
print(f"STREAKH='{strk_h}'")
PY
# shellcheck disable=SC1090
source "$TMP/vars.sh"

echo "$LOG_PREFIX Tokens=$TOKENS  PeakAgents=$MAXC  Sessions=$SESS  Active=${ACTH}h  Streak=${STREAKH}h"

# 3) Update the README typing-svg tagline (URL-encoded: + is space).
#    Only the values present in the tagline are sed'd; the rest live in the cache.
#    Each pattern is anchored by its trailing label, so the substitutions can't collide.
TOKENS_ESC="${TOKENS//./\\.}"
sed -i '' \
  -e "s|[0-9][0-9.]*[BMK]*+tokens|${TOKENS_ESC}+tokens|g" \
  -e "s|[0-9][0-9]*+parallel+agents|${MAXC}+parallel+agents|g" \
  "$REPO_DIR/README.md"

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
