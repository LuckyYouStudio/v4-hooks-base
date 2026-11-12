#!/usr/bin/env bash
# Fetches the four dependencies into lib/ at the exact pinned commits (lib/ is not committed).
# Needs git and network access to github.com. Idempotent: a dependency already at its pinned commit is
# left alone; one at a different commit, or a lib/<name> that is not a git checkout, is an error.
#
#   script/install-deps.sh
#
# Only the top-level checkout of each dependency is fetched. Their own nested submodules
# (v4-periphery/lib/*, v4-core/lib/*, solmate/lib/*) are deliberately NOT initialised: remappings.txt
# points every import at the single copy of each library in this repository's lib/, so there is exactly
# one v4-core in the build.
set -euo pipefail
cd "$(dirname "$0")/.."

# name | repository | commit | note
DEPS='
forge-std|https://github.com/foundry-rs/forge-std|dc647cc030d9d65910d8f1172a0cde48d7106e32|master at 2026-11-02, ten commits after tag v1.17.0
v4-core|https://github.com/Uniswap/v4-core|59d3ecf53afa9264a16bba0e38f4c5d2231f80bc|the commit v4-periphery pins (npm @uniswap/v4-core 1.0.2)
v4-periphery|https://github.com/Uniswap/v4-periphery|c6e4754dab11bd38c6f08ac51c3c868569e93d64|main at 2026-10-26 (the repository has no tags)
solmate|https://github.com/transmissions11/solmate|4b47a19038b798b4a33d9749d25e570443520647|the commit v4-core pins
'

mkdir -p lib
echo "$DEPS" | while IFS='|' read -r name url sha note; do
  [ -n "$name" ] || continue
  dir="lib/$name"
  if [ -d "$dir/.git" ]; then
    have=$(git -C "$dir" rev-parse HEAD)
    if [ "$have" = "$sha" ]; then echo "ok       $name @ $sha"; continue; fi
    echo "error: $dir is at $have, expected $sha. Remove it and run again." >&2; exit 1
  elif [ -e "$dir" ]; then
    echo "error: $dir exists but is not a git checkout. Remove it and run again." >&2; exit 1
  fi
  git init -q "$dir"
  git -C "$dir" remote add origin "$url"
  git -C "$dir" fetch -q --depth 1 origin "$sha"
  git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  have=$(git -C "$dir" rev-parse HEAD)
  [ "$have" = "$sha" ] || { echo "error: $name checked out $have, expected $sha" >&2; exit 1; }
  echo "fetched  $name @ $sha ($note)"
done
