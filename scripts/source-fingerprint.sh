#!/usr/bin/env bash
# Prints a short id for the app's source: the commit, plus a hash of any uncommitted changes.
# build-app.sh stamps it into the app, and the running app compares it to spot updates.
set -euo pipefail
cd "$(dirname "$0")/.."

PATHS=(Sources Resources/Info.plist scripts Package.swift)
head=$(git rev-parse --short=12 HEAD)
if [[ -z "$(git --no-optional-locks status --porcelain --untracked-files=all -- "${PATHS[@]}")" ]]; then
  echo "$head"
  exit 0
fi
changes=$( {
  git diff HEAD -- "${PATHS[@]}"
  git ls-files --others --exclude-standard -z -- "${PATHS[@]}" | xargs -0 shasum 2>/dev/null || true
} | shasum | cut -c1-8)
echo "$head-dirty-$changes"
