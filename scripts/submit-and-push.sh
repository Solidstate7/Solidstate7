#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_PREFIX="[tokscale]"

echo "$LOG_PREFIX Submitting usage data..."
npx --yes tokscale@latest submit --no-spinner

echo "$LOG_PREFIX Computing token total..."
TOTAL=$(npx tokscale@latest --json --no-spinner | python3 -c "
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

if git diff --quiet README.md .tokscale-cache.json 2>/dev/null; then
  echo "$LOG_PREFIX No changes — README already current."
  exit 0
fi

git add README.md .tokscale-cache.json
git commit -m "chore: update token stats → $TOTAL [skip ci]"
git push

echo "$LOG_PREFIX Done. README updated to $TOTAL."
