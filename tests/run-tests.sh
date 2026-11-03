#!/usr/bin/env bash
# Tests for sphynx. Usage: tests/run-tests.sh
#
# Set SPHYNX_SKIP_BUILD=1 to skip the slow end-to-end build test.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TEST_DIR="$ROOT_DIR/build/test"
PASSED=0

pass() {
    PASSED=$((PASSED + 1))
    echo "ok   - $1"
}

fail() {
    echo "FAIL - $*" >&2
    exit 1
}

# --- versions -------------------------------------------------------------

script_version="$(sed -n 's/^SPHYNX_VERSION="\(.*\)"$/\1/p' sphynx)"
readme_version="$(sed -n 's/^Version: \([0-9.]*\)$/\1/p' README.md | head -1)"
changelog_version="$(sed -n 's/^## \[\([0-9.]*\)\] - .*/\1/p' CHANGELOG.md | head -1)"

[ -n "$script_version" ] || fail "no SPHYNX_VERSION in sphynx"
[ "$script_version" = "$readme_version" ] || fail "README.md Version '$readme_version' != sphynx '$script_version'"
[ "$script_version" = "$changelog_version" ] || fail "CHANGELOG.md newest version '$changelog_version' != sphynx '$script_version'"
pass "version $script_version matches sphynx, README.md and CHANGELOG.md"

header_tag="$(sed -n 's/^#define SSH_SPHYNX[[:space:]]*"_sphynx\([^"]*\)".*/\1/p' sphynx-ssh/version.h 2>/dev/null || true)"
[ "$header_tag" = "$script_version" ] || fail "sphynx-ssh/version.h SSH_SPHYNX '$header_tag' != sphynx '$script_version'"
pass "sphynx-ssh/version.h reports sphynx $script_version"

[ "$(./sphynx --version)" = "sphynx $script_version" ] || fail "sphynx --version does not report $script_version"
pass "sphynx --version reports $script_version"

# --- command line ---------------------------------------------------------

./sphynx --help >/dev/null || fail "sphynx --help should exit 0"
pass "sphynx --help exits 0"

if ./sphynx build --target nosuch >/dev/null 2>&1; then
    fail "unsupported target should exit non-zero"
fi
pass "unsupported --target is rejected"

if ./sphynx build --jobs 0 >/dev/null 2>&1; then
    fail "--jobs 0 should be rejected"
fi
pass "--jobs must be positive"

# --- lint -----------------------------------------------------------------

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck sphynx tests/run-tests.sh packaging/ubuntu/postinst packaging/ubuntu/prerm packaging/ubuntu/postrm
    pass "shellcheck is clean"
else
    echo "skip - shellcheck not installed"
fi

# --- end-to-end build -----------------------------------------------------

if [ "${SPHYNX_SKIP_BUILD:-0}" = "1" ]; then
    echo "skip - end-to-end build (SPHYNX_SKIP_BUILD=1)"
    echo "$PASSED checks passed"
    exit 0
fi

rm -rf "$TEST_DIR"
./sphynx build --build-dir "$TEST_DIR/build" --out "$TEST_DIR/dist" >"$TEST_DIR.log" 2>&1 \
    || { tail -n 20 "$TEST_DIR.log" >&2; fail "sphynx build failed"; }
pass "sphynx build --target ubuntu succeeds"

shopt -s nullglob
debs=("$TEST_DIR"/dist/hpn-ssh_*.deb)
shopt -u nullglob
[ ${#debs[@]} -eq 1 ] || fail "expected one .deb in $TEST_DIR/dist, found ${#debs[@]}"
deb="${debs[0]}"

[ "$(dpkg-deb -f "$deb" Package)" = "hpn-ssh" ] || fail "package name is not hpn-ssh"
pass "package is named hpn-ssh"

# shellcheck source=/dev/null
codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
version="$(dpkg-deb -f "$deb" Version)"
case "$version" in
    10.6p1+hpn18.12.0+sphynx"$script_version"-1~"$codename"1) pass "version $version follows the upstream, sphynx and series scheme" ;;
    *) fail "unexpected package version: $version" ;;
esac

contents="$(dpkg-deb -c "$deb")"
for path in ./usr/bin/hpnssh ./usr/sbin/hpnsshd ./usr/lib/hpnssh/hpnsftp-server \
            ./etc/hpnssh/sshd_config ./etc/pam.d/hpnsshd ./lib/systemd/system/hpnsshd.service; do
    grep -q " $path\$" <<<"$contents" || fail "package is missing $path"
done
pass "package contains the binaries, config, PAM service and systemd unit"

extract="$TEST_DIR/extract"
dpkg-deb -x "$deb" "$extract"
banner="$("$extract/usr/bin/hpnssh" -V 2>&1 || true)"
case "$banner" in
    *"OpenSSH_10.6p1_hpn18.12.0_sphynx$script_version"*) pass "hpnssh -V reports OpenSSH_10.6p1_hpn18.12.0_sphynx$script_version" ;;
    *) fail "hpnssh -V does not report sphynx $script_version: $banner" ;;
esac

if grep -q 'ssh_host_' <<<"$contents"; then
    fail "package must not contain host keys"
fi
pass "package ships no host keys"

if grep -q ' \./run/' <<<"$contents"; then
    fail "package must not contain /run"
fi
pass "package ships no /run directory"

if grep -q 'openssh' <<<"$contents"; then
    fail "package must not contain openssh-named files"
fi
pass "package does not clash with OpenSSH file names"

depends="$(dpkg-deb -f "$deb" Depends)"
for dep in libssl3t64 libpam0g zlib1g adduser; do
    grep -q "$dep" <<<"$depends" || fail "Depends is missing $dep: $depends"
done
pass "Depends includes the libraries and helpers the binaries need"

ctl="$TEST_DIR/control"
dpkg-deb -e "$deb" "$ctl"
grep -qx '/etc/hpnssh/sshd_config' "$ctl/conffiles" || fail "sshd_config is not a conffile"
pass "config files are marked as conffiles"

echo "$PASSED checks passed"
