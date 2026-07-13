#!/bin/bash
#
# Sync this fork with the upstream Atoll repository.
#
#   ./scripts/sync-upstream.sh          merge upstream/main into the current branch
#   ./scripts/sync-upstream.sh --check  only report how far behind upstream we are
#
# The script never pushes; review the merge locally, then `git push origin`.

set -euo pipefail

UPSTREAM_URL="https://github.com/Ebullioscopic/Atoll.git"
UPSTREAM_BRANCH="main"

cd "$(git rev-parse --show-toplevel)"

if ! git remote get-url upstream >/dev/null 2>&1; then
    echo "Adding upstream remote: $UPSTREAM_URL"
    git remote add upstream "$UPSTREAM_URL"
fi

echo "Fetching upstream…"
git fetch upstream --tags --prune

BEHIND=$(git rev-list --count "HEAD..upstream/$UPSTREAM_BRANCH")
AHEAD=$(git rev-list --count "upstream/$UPSTREAM_BRANCH..HEAD")
echo "Fork status: $AHEAD commit(s) ahead, $BEHIND commit(s) behind upstream/$UPSTREAM_BRANCH."

if [[ "${1:-}" == "--check" ]]; then
    exit 0
fi

if [[ "$BEHIND" -eq 0 ]]; then
    echo "Already up to date."
    exit 0
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: you have uncommitted changes. Commit or stash them first." >&2
    exit 1
fi

echo "Merging upstream/$UPSTREAM_BRANCH…"
if git merge --no-edit "upstream/$UPSTREAM_BRANCH"; then
    echo "Merge complete. Build and test, then push with: git push origin $(git branch --show-current)"
else
    cat >&2 <<'EOF'

Merge stopped on conflicts. To finish:
  1. git status                     — list conflicted files
  2. edit each file, keep what you want
  3. git add <file> …               — mark them resolved
  4. git commit                     — complete the merge
Or bail out entirely with: git merge --abort
EOF
    exit 1
fi
