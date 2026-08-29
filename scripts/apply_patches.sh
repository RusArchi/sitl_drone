#!/usr/bin/env bash
# Re-apply the patches in patches/ to the ArduPilot tree.
# Use after a fresh clone or after a submodule update wiped the working tree.
set -euo pipefail

AP="${AP:-$HOME/ardupilot}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/patches"

[[ -f "$DIR/BASE" ]] && { echo "patches were made against:"; grep -v '^#' "$DIR/BASE"; echo; }

apply() {  # apply <patch name> <target dir>
    local p="$DIR/$1.patch" t="$2"
    [[ -f "$p" ]] || { echo "skip $1 — no patch file"; return; }
    if git -C "$t" apply --check "$p" 2>/dev/null; then
        git -C "$t" apply "$p" && echo "applied $1.patch to $t"
    else
        echo "FAILED to apply $1.patch to $t — the tree has moved; rebase it by hand" >&2
        return 1
    fi
}

apply mavlink   "$AP/modules/mavlink"
apply ardupilot "$AP"
