#!/bin/bash
# Applies unmerged upstream fix PRs (engines/<engine>/patches/series, downloaded with
# `gh pr diff`) on a local branch "triptych-fixes" in each submodule, on top of the
# pinned upstream commit. Re-run after updating a submodule; drop PRs that merge upstream.
# (Henge is now in-tree at engines/gesso/; cherry-pick fixes directly, see engines/gesso/UPSTREAM.md.)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
apply() { # submodule patches-dir
  local sm=$ROOT/upstreams/$1 dir=$ROOT/engines/$2/patches
  [ -f "$dir/series" ] || return 0
  local base; base=$(git -C "$ROOT" ls-tree HEAD "upstreams/$1" | awk '{print $3}')
  git -C "$sm" checkout -q -B triptych-fixes "$base"
  while read -r p; do
    [ -n "$p" ] || continue
    git -C "$sm" apply --3way "$dir/$p" 2>/dev/null || git -C "$sm" apply "$dir/$p"
    git -C "$sm" -c user.name=triptych -c user.email=triptych@localhost commit -qam "${p%.patch} (unmerged upstream PR)"
    echo "$1: applied $p"
  done < "$dir/series"
}
apply madeira windows
