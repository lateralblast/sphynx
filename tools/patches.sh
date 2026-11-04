#!/usr/bin/env bash
# Check or apply the sphynx-ssh patch series in patches/.
#
#   tools/patches.sh check [sphynx-ssh-dir]   does the series reproduce sphynx-ssh?
#   tools/patches.sh apply <git-tree>         apply the series to a checkout
#   tools/patches.sh base                     print the upstream commit it applies to
#
# See "Patches" in the README.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES="$ROOT/patches"
BASE="$(awk '{print $1; exit}' "$PATCHES/BASE")"

die() { echo "patches: error: $*" >&2; exit 1; }

shopt -s nullglob
series=("$PATCHES"/*.patch)
[ ${#series[@]} -gt 0 ] || die "no patches in $PATCHES"

am() { # am <tree>
    git -C "$1" -c user.name=patches -c user.email=patches@localhost am -q --3way "${series[@]}"
}

cmd_check() {
    local src="${1:-$ROOT/sphynx-ssh}" tmp want got f
    [ -e "$src/.git" ] || die "$src is not a git checkout"
    git -C "$src" cat-file -e "$BASE^{commit}" 2>/dev/null \
        || die "$src does not have the upstream commit $BASE (git fetch the upstream remote)"
    tmp="$(mktemp -d)"
    # expand the path now: tmp is local, and gone when the trap runs
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    git clone -q --shared --no-checkout "$src" "$tmp/t"
    git -C "$tmp/t" checkout -q -b check "$BASE"
    am "$tmp/t" || die "the series does not apply to $BASE"

    # the result must be the same files as sphynx-ssh's working tree
    # files not committed yet count too, since a new file is untracked until it is
    want="$({ git -C "$src" diff --name-only "$BASE"; git -C "$src" ls-files --others --exclude-standard; } | sort -u)"
    got="$(git -C "$tmp/t" diff --name-only "$BASE" HEAD | sort)"
    [ "$want" = "$got" ] || die "the series and $src change different files:
$(diff <(echo "$want") <(echo "$got") || true)"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -e "$src/$f" ]; then
            cmp -s "$src/$f" "$tmp/t/$f" || die "$f differs between the series and $src"
        else
            [ ! -e "$tmp/t/$f" ] || die "$f exists in the series but not in $src"
        fi
    done <<<"$got"
    echo "ok: ${#series[@]} patches apply to ${BASE:0:9} and reproduce $(basename "$src")"
}

cmd_apply() {
    local tree="${1:?usage: tools/patches.sh apply <git-tree>}"
    [ -e "$tree/.git" ] || die "$tree is not a git checkout"
    am "$tree" || die "a patch did not apply; fix it in $tree, then 'git am --continue'"
    echo "applied ${#series[@]} patches to $tree"
}

case "${1:-}" in
    check) shift; cmd_check "$@" ;;
    apply) shift; cmd_apply "$@" ;;
    base) echo "$BASE" ;;
    *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
