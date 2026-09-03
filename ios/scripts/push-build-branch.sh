#!/usr/bin/env bash
# Push ONLY the iOS sources + the GitHub Actions workflow to the public build
# repository, as an independent branch, so the web sources never leave the machine.
#
#   bash ios/scripts/push-build-branch.sh [remote] [branch] ["commit message"]
#
# Defaults: remote=hades  branch=claude/ios-build
# The branch is rewritten on every push (single commit, --force) — it is a build
# input, not a history.
set -Eeuo pipefail

REMOTE="${1:-hades}"
BRANCH="${2:-claude/ios-build}"
MSG="${3:-iOS build input}"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url "$REMOTE")"
SRC_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/ios" "$STAGE/.github/workflows"
# Everything under ios/ except local build products.
# Docs/ holds internal contract notes — not needed to build, not for a public branch.
(cd "$REPO_ROOT/ios" && tar --exclude='./build' --exclude='./DerivedData' --exclude='./.build' --exclude='./Docs' -cf - .) | (cd "$STAGE/ios" && tar -xf -)
cp "$REPO_ROOT/.github/workflows/build-ios-ipa.yml" "$STAGE/.github/workflows/build-ios-ipa.yml"
cat > "$STAGE/README.md" <<EOF
# Firas AI — iOS build input

Native SwiftUI client for https://firasai.org (iPhone + iPad). This branch carries only the
\`ios/\` sources and the GitHub Actions workflow that produces an unsigned \`.ipa\`.
Source snapshot: $SRC_SHA
EOF
cat > "$STAGE/.gitignore" <<'EOF'
ios/build/
ios/DerivedData/
.DS_Store
EOF

cd "$STAGE"
git init -q
git checkout -q -b "$BRANCH"
git add -A
git -c user.name="Firas" -c user.email="emirdyer13@icloud.com" -c core.autocrlf=input \
  commit -q -m "$MSG (source $SRC_SHA)"
git push -q --force "$REMOTE_URL" "HEAD:refs/heads/$BRANCH"
echo "pushed $BRANCH -> $REMOTE_URL ($(git rev-parse --short HEAD), source $SRC_SHA)"
