#!/bin/bash
# Recreate annotated tag and force-push to trigger CI rebuild
# Usage: bash scripts/retag.sh v1.2.3
#        bash scripts/retag.sh            (interactive, detects latest tag)

set -e

if [ -z "$1" ]; then
    echo "Usage: bash scripts/retag.sh <tag>"
    echo "  e.g.  bash scripts/retag.sh v1.2.3"
    echo ""
    echo "Detecting latest tag..."
    TAG=$(git describe --tags --abbrev=0 HEAD 2>/dev/null)
    if [ -z "$TAG" ]; then
        echo "Error: no tags found"
        exit 1
    fi
else
    TAG="$1"
fi

echo "Tag: $TAG"
echo "Recreating annotated tag..."
git tag -f -a "$TAG" -m "Rebuild $TAG - auto-incremented build number"

# Detect remote (prefer 'origin', fall back to first remote)
REMOTE=$(git remote | grep -m1 origin || git remote | head -1)
if [ -z "$REMOTE" ]; then
    echo "Error: no git remote configured"
    exit 1
fi

echo "Force-pushing tag to $REMOTE..."
git push "$REMOTE" "$TAG" -f
echo "Done. CI will auto-increment build_number on each build."
