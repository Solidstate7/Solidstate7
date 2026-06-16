#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_PREFIX="[tokscale]"

echo "$LOG_PREFIX Submitting usage data..."
# Non-fatal: a tokscale platform/network/flag hiccup must never freeze the README.
# The displayed count below is computed from the local --json read, which does not
# depend on submit succeeding.
npx --yes tokscale@latest submit \
  || echo "$LOG_PREFIX WARN: submit failed; continuing with local data."

echo "$LOG_PREFIX Computing token total..."
TOTAL=$(npx tokscale@latest --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
total = sum(
    e.get('input', 0) + e.get('output', 0) +
    e.get('cacheRead', 0) + e.get('cacheWrite', 0) + e.get('reasoning', 0)
    for e in data.get('entries', [])
)
b = total / 1e9
if b >= 10:
    print(f'{b:.0f}B')
elif b >= 1:
    print(f'{b:.1f}B')
else:
    print(f'{total/1e6:.0f}M')
")

echo "$LOG_PREFIX Total: $TOTAL"

# Write cache for GH Actions fallback
echo "{\"tokens\": \"$TOTAL\", \"updated\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
  > "$REPO_DIR/.tokscale-cache.json"

# Update typing-svg tagline — replace e.g. "3.9B+tokens" with new count
# The URL-encoded form in the README uses + for spaces
ESCAPED="${TOTAL//./\\.}"
sed -i '' \
  "s|[0-9][0-9.]*[BMK]*+tokens|${ESCAPED}+tokens|g" \
  "$REPO_DIR/README.md"

cd "$REPO_DIR"

# Gate on README only — the cache file's timestamp changes every run, so
# including it here would produce a junk commit daily even when the count is flat.
if git diff --quiet README.md 2>/dev/null; then
  echo "$LOG_PREFIX No change in displayed token count — nothing to commit."
  exit 0
fi

git add README.md .tokscale-cache.json
git commit -m "chore: update token stats → $TOTAL [skip ci]"
# Explicit remote/ref so it works even if 'main' has no upstream configured.
git push origin HEAD

echo "$LOG_PREFIX Done. README updated to $TOTAL."
