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
    shellcheck sphynx tests/run-tests.sh tests/scp-resume.sh tests/daemon-checks.sh tests/build-c-test.sh tests/package-lifecycle.sh tools/perf/perf.sh tools/perf/build-baseline.sh tools/tune-tcp.sh tools/suggest-cipher.sh tools/patches.sh tests/tune-tcp.sh packaging/ubuntu/postinst packaging/ubuntu/prerm packaging/ubuntu/postrm
    pass "shellcheck is clean"
else
    echo "skip - shellcheck not installed"
fi

# --- tools/perf ------------------------------------------------------------

# parse it without writing a .pyc file next to the source
python3 -B -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' tools/perf/analyze.py \
    || fail "tools/perf/analyze.py does not parse"
mkdir -p "$TEST_DIR"
cat >"$TEST_DIR/perf-fixture.csv" <<CSV
impl,cipher,cond,run,mb,elapsed,user,sys
base,handshake,lan,1,0,1.0,0.0,0.0
hpn,handshake,lan,1,0,1.0,0.0,0.0
base,default,lan,1,100,2.0,0.5,0.5
hpn,default,lan,1,100,1.5,0.5,0.5
base,handshake,wan50,1,0,2.0,0.0,0.0
hpn,handshake,wan50,1,0,2.0,0.0,0.0
base,aes256-ctr,wan50,1,100,12.0,0.5,0.5
hpn,aes256-ctr,wan50,1,100,7.0,0.5,0.5
CSV
perf_out="$(python3 -B tools/perf/analyze.py "$TEST_DIR/perf-fixture.csv")"
grep -q '^LAN (no shaping)' <<<"$perf_out" || fail "perf analysis: no LAN heading"
grep -q '^50 ms round trip' <<<"$perf_out" || fail "perf analysis: no 50 ms heading"
grep -q ' 2.00x' <<<"$perf_out" || fail "perf analysis: LAN ratio should be 2.00x"
grep -q ' 2.00x' <<<"$(grep aes256-ctr <<<"$perf_out")" || fail "perf analysis: 50 ms ratio should be 2.00x"
pass "tools/perf/analyze.py reports medians, ratios and condition headings"

# a CSV with tools, client and server pairs, thread counts, loss and jitter
cat >"$TEST_DIR/perf-fixture2.csv" <<CSV
impl,cipher,cond,run,mb,elapsed,user,sys,tool,server,threads
base,handshake,wan50_loss0.5,1,0,1.0,0,0,scp,base,-
hpn,handshake,wan50_loss0.5,1,0,1.0,0,0,scp,hpn,-
hpn,handshake,wan50_loss0.5,1,0,1.0,0,0,scp,base,-
base,aes256-ctr,wan50_loss0.5,1,100,11.0,0.5,0.5,scp,base,-
hpn,aes256-ctr,wan50_loss0.5,1,100,6.0,0.5,0.5,scp,hpn,1
hpn,aes256-ctr,wan50_loss0.5,1,100,3.0,0.5,0.5,scp,hpn,4
hpn,aes256-ctr,wan50_loss0.5,1,100,nan,nan,nan,scp,base,1
hpn,aes256-ctr,wan50_loss0.5,1,100,9.0,0.5,0.5,scp,base,4
base,default,lan_loss1,1,100,2.0,0.5,0.5,sftp,base,-
CSV
perf_out2="$(python3 -B tools/perf/analyze.py "$TEST_DIR/perf-fixture2.csv")"
grep -q '^50 ms round trip, 0.5% loss each way, scp' <<<"$perf_out2" || fail "perf analysis: no loss and tool heading"
grep -q '^LAN, 1% loss each way, sftp' <<<"$perf_out2" || fail "perf analysis: no LAN loss heading"
grep -q '^HPN client = ' <<<"$perf_out2" || fail "perf analysis: no legend for mixed pairs"
grep -q 'aes256-ctr, 4 threads .* 5.00x .* 1.25x' <<<"$perf_out2" \
    || fail "perf analysis: 4 threads should show 5.00x for HPN-SSH and 1.25x for the HPN client"
grep -q 'aes256-ctr, 1 thread .* 2.00x .* - ' <<<"$perf_out2" || fail "perf analysis: a failed run should show as -"
pass "tools/perf/analyze.py reads tools, client and server pairs, thread counts, loss and jitter"

# perf.sh run --dry-run needs no sudo: it prints the cases and the netem settings
dry() { bash tools/perf/perf.sh run --dry-run "$@" 2>&1; }
out="$(dry --conds lan,wan50,wan50_loss0.5,wan100_loss0.1_jit5,lan_loss1)"
grep -q '^cond lan: netem $' <<<"$out" || fail "perf dry run: lan should have no netem settings"
grep -q '^cond wan50: netem delay 25ms rate 1gbit limit 100000$' <<<"$out" || fail "perf dry run: wan50 netem changed"
grep -q '^cond wan50_loss0.5: netem delay 25ms loss 0.5% rate 1gbit limit 100000$' <<<"$out" || fail "perf dry run: loss netem"
grep -q '^cond wan100_loss0.1_jit5: netem delay 50ms 5ms loss 0.1% rate 1gbit limit 100000$' <<<"$out" || fail "perf dry run: jitter netem"
grep -q '^cond lan_loss1: netem loss 1%$' <<<"$out" || fail "perf dry run: lan loss netem"
grep -q 'cond=wan100_loss0.1_jit5 mb=384 ' <<<"$out" || fail "perf dry run: a loss condition should use the size of its wanNN"
out="$(dry --conds wan50 --tools ssh,scp,sftp --pairs base:base,hpn:hpn,hpn:base,base:hpn --ciphers default --runs 1)"
[ "$(grep -c '^case ' <<<"$out")" = 24 ] || fail "perf dry run: 3 tools x 4 pairs x (connect + 1 cipher) should be 24 cases"
grep -q 'tool=sftp client=base server=hpn cipher=default ' <<<"$out" || fail "perf dry run: a mixed pair is missing"
out="$(dry --conds lan --pairs base:base,hpn:hpn --ciphers default,aes256-ctr --threads default,2,4 --runs 1)"
[ "$(grep -c 'cipher=aes256-ctr .*server=hpn\|server=hpn cipher=aes256-ctr' <<<"$out")" = 3 ] \
    || fail "perf dry run: aes256-ctr on HPN-SSH should run once per thread count"
[ "$(grep -c 'client=base server=base cipher=aes256-ctr' <<<"$out")" = 1 ] \
    || fail "perf dry run: OpenSSH should run once, whatever the thread count"
[ "$(grep -c 'cipher=default cond=lan' <<<"$out")" = 2 ] || fail "perf dry run: a cipher that ignores threads should run once"
grep -q '^hpn server SSH_CIPHER_THREADS=4$' <<<"$out" || fail "perf dry run: the server should restart for each thread count"
for bad in "--conds lan_jit5" "--conds wan50_loss" "--tools ftp" "--pairs hpn:ssh" "--threads 0" "--runs 0"; do
    # shellcheck disable=SC2086 # the options are meant to split
    if dry $bad >/dev/null; then fail "perf dry run accepted: $bad"; fi
done
out="$(dry --conds lan --tools sftp,scp --sftp-opts "-B 262144 -R 128" --scp-opts "-X nrequests=64" --pairs hpn:hpn --ciphers default --runs 1)"
if grep -q '^case tool=sftp(-B_262144_-R_128) client=hpn server=hpn cipher=default ' <<<"$out" \
   && grep -q '^case tool=scp(-X_nrequests=64) client=hpn server=hpn cipher=default ' <<<"$out"; then :; else
    fail "perf dry run: the sftp and scp options should be part of the tool name: $out"
fi
out="$(dry --conds lan --tools sftp --pairs hpn:hpn --ciphers default --runs 1)"
grep -q '^case tool=sftp client=hpn ' <<<"$out" || fail "perf dry run: a tool without options keeps its plain name: $out"
pass "perf.sh run --dry-run plans the cases, netem settings and thread counts, and rejects bad input"

# --- tools/tune-tcp.sh -------------------------------------------------------

mkdir -p "$TEST_DIR"
if tests/tune-tcp.sh >"$TEST_DIR/tune-tcp.out" 2>&1; then
    if grep -q '^ok' "$TEST_DIR/tune-tcp.out"; then
        pass "tools/tune-tcp.sh tests pass ($(grep -c '^ok' "$TEST_DIR/tune-tcp.out") checks)"
    else
        pass "tools/tune-tcp.sh tests skipped: $(sed -n 's/^skip - //p' "$TEST_DIR/tune-tcp.out" | head -1)"
    fi
else
    cat "$TEST_DIR/tune-tcp.out" >&2
    fail "tools/tune-tcp.sh tests"
fi

# --- tools/suggest-cipher.sh -------------------------------------------------

sc_dir="$TEST_DIR/suggest"
mkdir -p "$sc_dir"
printf 'processor\t: 0\nmodel name\t: Test CPU\nflags\t\t: fpu sse2 aes avx2\n' >"$sc_dir/aes.cpuinfo"
printf 'processor\t: 0\nmodel name\t: Test CPU\nflags\t\t: fpu sse2 avx2\n' >"$sc_dir/noaes.cpuinfo"
printf 'processor : 0\nFeatures\t: fp asimd aes pmull sha2\n' >"$sc_dir/arm.cpuinfo"
: >"$sc_dir/empty.cpuinfo"
# a stand-in for openssl speed that reports fixed rates: GCM_RATE and CHACHA_RATE, bytes per second
cat >"$sc_dir/openssl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *AES-256-GCM*) echo "+F:25:AES-256-GCM:${GCM_RATE:-5000000000}.00" ;;
    *ChaCha20-Poly1305*) echo "+F:26:ChaCha20-Poly1305:${CHACHA_RATE:-1000000000}.00" ;;
    *AES-256-CTR*) echo "+F:27:AES-256-CTR:8000000000.00" ;;
esac
STUB
chmod +x "$sc_dir/openssl"
sc() { SUGGEST_OS=Linux "$@"; }
first_cipher() { sed -n 's/^  Ciphers \([^,]*\),.*/\1/p' <<<"$1"; }

# sc_expect WHAT FIRST-CIPHER TEXT: the output in $out must lead with that cipher and contain that text
sc_expect() {
    if [ "$(first_cipher "$out")" = "$2" ] && grep -q "$3" <<<"$out"; then :; else
        fail "suggest-cipher: $1: $out"
    fi
}

out="$(sc env SUGGEST_CPUINFO="$sc_dir/aes.cpuinfo" SUGGEST_OPENSSL="$sc_dir/openssl" tools/suggest-cipher.sh)"
sc_expect "AES-GCM should lead when it measures faster" aes256-gcm@openssh.com 'measured: aes256-gcm 5000 MB/s, chacha20-poly1305 1000 MB/s'
out="$(sc env SUGGEST_CPUINFO="$sc_dir/aes.cpuinfo" SUGGEST_OPENSSL="$sc_dir/openssl" GCM_RATE=500000000 tools/suggest-cipher.sh)"
sc_expect "ChaCha should lead when it measures faster" chacha20-poly1305-mt@hpnssh.org 'measured: aes256-gcm 500 MB/s'
out="$(sc env SUGGEST_CPUINFO="$sc_dir/aes.cpuinfo" tools/suggest-cipher.sh --no-measure)"
sc_expect "a CPU with AES should get AES-GCM first" aes256-gcm@openssh.com 'AES hardware:  yes'
out="$(sc env SUGGEST_CPUINFO="$sc_dir/noaes.cpuinfo" tools/suggest-cipher.sh --no-measure)"
sc_expect "a CPU without AES should get ChaCha first" chacha20-poly1305-mt@hpnssh.org 'AES hardware:  no'
out="$(sc env SUGGEST_CPUINFO="$sc_dir/arm.cpuinfo" tools/suggest-cipher.sh --no-measure)"
sc_expect "arm64 Features with aes" aes256-gcm@openssh.com 'AES hardware:  yes'
out="$(sc env SUGGEST_CPUINFO="$sc_dir/empty.cpuinfo" tools/suggest-cipher.sh --no-measure)"
sc_expect "an unreadable CPU should keep the default order" chacha20-poly1305-mt@hpnssh.org 'could not tell'
out="$(sc env SUGGEST_CPUINFO="$sc_dir/aes.cpuinfo" tools/suggest-cipher.sh --no-measure --config)"
if [ "$(wc -l <<<"$out" | tr -d ' ')" = 2 ] && grep -q '^Ciphers aes256-gcm' <<<"$out" && grep -q '^MACs umac-64-etm@openssh.com,' <<<"$out"; then :; else
    fail "suggest-cipher: --config should print the Ciphers and MACs lines only: $out"
fi
if tools/suggest-cipher.sh --nonsense >/dev/null 2>&1 || tools/suggest-cipher.sh --seconds 0 >/dev/null 2>&1; then
    fail "suggest-cipher accepted bad input"
fi
pass "tools/suggest-cipher.sh picks AES-GCM or ChaCha from the measured speeds or the CPU features, and rejects bad input"

# --- patches ---------------------------------------------------------------

base="$(tools/patches.sh base)"
if git -C sphynx-ssh cat-file -e "$base^{commit}" 2>/dev/null; then
    if out="$(tools/patches.sh check 2>&1)"; then
        pass "patches/ applies to upstream and reproduces sphynx-ssh ($(find patches -name '*.patch' | wc -l) patches)"
    else
        echo "$out" >&2
        fail "patches/ does not reproduce sphynx-ssh; regenerate it (see Patches in the README)"
    fi
else
    echo "skip - sphynx-ssh does not have the upstream commit $base, so the patch series cannot be checked"
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

# the packaged sshd_config must turn PAM on, so that the shipped PAM service is used
# and a key login to an account with a locked password works
conf="$(dpkg-deb --fsys-tarfile "$deb" | tar -xOf - ./etc/hpnssh/sshd_config)"
grep -q '^UsePAM yes$' <<<"$conf" || fail "the packaged sshd_config does not set UsePAM yes"
pass "the packaged sshd_config sets UsePAM yes"

extract="$TEST_DIR/extract"
dpkg-deb -x "$deb" "$extract"
banner="$("$extract/usr/bin/hpnssh" -V 2>&1 || true)"
case "$banner" in
    *"OpenSSH_10.6p1_hpn18.12.0_sphynx$script_version"*) pass "hpnssh -V reports OpenSSH_10.6p1_hpn18.12.0_sphynx$script_version" ;;
    *) fail "hpnssh -V does not report sphynx $script_version: $banner" ;;
esac

grep -q ' \./usr/share/doc/hpn-ssh/examples/99-hpn-ssh-tcp.conf$' <<<"$contents" || fail "package is missing the TCP buffer example"
if grep -q 'etc/sysctl\.d' <<<"$contents"; then
    fail "package must not install system-wide TCP settings"
fi
pass "package ships the TCP buffer example under /usr/share/doc and does not apply it"

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

# --- regression tests that run against the build tree ---------------------

tree="$TEST_DIR/build/ubuntu/src"

for t in chachapoly_mt_bounds patch_list aes_ctr_mt_crypt aes_ctr_mt_init huff0_roundtrip metrics_blob cipher_leaks chachapoly_mt_fork happyeyeballs_gap aes_ctr_mt_fork; do
    tests/build-c-test.sh "$tree" "tests/c/$t.c" "$TEST_DIR/$t" >"$TEST_DIR/$t.build" 2>&1 \
        || { tail -n 20 "$TEST_DIR/$t.build" >&2; fail "could not build tests/c/$t.c"; }
    "$TEST_DIR/$t" >"$TEST_DIR/$t.out" 2>&1 \
        || { cat "$TEST_DIR/$t.out" >&2; fail "tests/c/$t.c"; }
    pass "tests/c/$t.c passes"
done

if [ "$("$tree/hpnssh" -G -T -oNoneSwitch=yes -oNoneEnabled=yes localhost | grep -c '^noneswitch yes$')" != 1 ]; then
    fail "ssh -T must not turn off NoneSwitch"
fi
pass "ssh -T leaves NoneSwitch alone"

# MetricsPath turns metrics on, but not from a Host block that does not match, and not over Metrics no (0.7.4)
printf 'Host elsewhere\n  MetricsPath /tmp/x\n' >"$TEST_DIR/metrics-host.conf"
printf 'Metrics no\nMetricsPath /tmp/x\n' >"$TEST_DIR/metrics-no.conf"
printf 'MetricsPath /tmp/x\n' >"$TEST_DIR/metrics-path.conf"
[ "$("$tree/hpnssh" -F "$TEST_DIR/metrics-host.conf" -G localhost 2>/dev/null | grep -c '^metrics no$')" = 1 ] \
    || fail "a MetricsPath in a Host block that does not match turned metrics on"
[ "$("$tree/hpnssh" -F "$TEST_DIR/metrics-no.conf" -G localhost 2>/dev/null | grep -c '^metrics no$')" = 1 ] \
    || fail "MetricsPath turned metrics on after Metrics no"
[ "$("$tree/hpnssh" -F "$TEST_DIR/metrics-path.conf" -G localhost 2>/dev/null | grep -c '^metrics yes$')" = 1 ] \
    || fail "MetricsPath no longer turns metrics on"
pass "MetricsPath obeys Host blocks and Metrics no"

# MetricsInterval and FallbackPort have limits (0.7.6)
for bad in "MetricsInterval 0" "MetricsInterval 86401" "FallbackPort 0" "FallbackPort 65536"; do
    echo "$bad" >"$TEST_DIR/bounds.conf"
    if "$tree/hpnssh" -F "$TEST_DIR/bounds.conf" -G localhost >/dev/null 2>&1; then
        fail "hpnssh accepted $bad"
    fi
done
for good in "MetricsInterval 1" "MetricsInterval 86400" "FallbackPort 1" "FallbackPort 65535"; do
    echo "$good" >"$TEST_DIR/bounds.conf"
    "$tree/hpnssh" -F "$TEST_DIR/bounds.conf" -G localhost >/dev/null 2>&1 || fail "hpnssh rejected $good"
done
pass "MetricsInterval and FallbackPort are range checked"

# With HappyEyes a connect that failed at once was reported as "failure": errno had been cleared (0.7.9)
for h in fe80::1 255.255.255.255; do
    msg="$("$tree/hpnssh" -o HappyEyes=yes -o ConnectTimeout=3 -o BatchMode=yes -p 22 "$h" true 2>&1 | tail -n 1 || true)"
    case "$msg" in
        *": failure"|*": Success") fail "HappyEyes reported no reason for a failed connect to $h: $msg" ;;
        *" port 22: "*) ;;
        *) fail "the failed connect to $h did not name the port: $msg" ;;
    esac
done
pass "a failed HappyEyes connect says why, and names the port"

[ "$("$tree/hpnssh" -Q compression | grep -cx 'huff0@hpnssh.org')" = 1 ] \
    || fail "hpnssh -Q compression does not list huff0@hpnssh.org"
[ "$("$tree/hpnssh" -G -oCompression=yes localhost | grep -c '^compression yes$')" = 1 ] \
    || fail "hpnssh does not accept Compression=yes"
pass "hpnssh lists the huff0@hpnssh.org compression method"

# -Q addressfamily was not a query term (1.1.8, taken from upstream)
[ "$("$tree/hpnssh" -Q addressfamily | tr '\n' ' ')" = "inet inet6 any " ] \
    || fail "hpnssh -Q addressfamily does not list inet, inet6 and any"
"$tree/hpnssh" -Q help | grep -qx addressfamily || fail "hpnssh -Q help does not list addressfamily"
pass "hpnssh -Q addressfamily lists the address families"

# The %C hash did not mark where one field ends: host 10.0.0.1 with port 2222 and host 10.0.0.12 with port 222 gave the
# same ControlPath, so two different connections could share a master (1.1.9, taken from upstream)
h1="$("$tree/hpnssh" -G -F /dev/null -o ControlPath=/x/%C -p 2222 10.0.0.1 2>/dev/null </dev/null | grep '^controlpath ')"
h2="$("$tree/hpnssh" -G -F /dev/null -o ControlPath=/x/%C -p 222 10.0.0.12 2>/dev/null </dev/null | grep '^controlpath ')"
[ -n "$h1" ] && [ -n "$h2" ] || fail "hpnssh -G did not print a ControlPath"
[ "$h1" != "$h2" ] || fail "two different connections have the same %C ControlPath hash"
pass "the %C hash tells apart connections whose fields run together"

sc_line="$(tools/suggest-cipher.sh --no-measure --config)"
for opt in Ciphers MACs; do
    value="$(sed -n "s/^$opt //p" <<<"$sc_line")"
    # ssh -G prints the option in lower case, with the names it accepted
    if "$tree/hpnssh" -G -o"$opt=$value" localhost >"$TEST_DIR/sc-$opt.out" 2>&1; then
        got="$(sed -n "s/^$(tr '[:upper:]' '[:lower:]' <<<"$opt") //p" "$TEST_DIR/sc-$opt.out")"
        [ -n "$value" ] && [ "$got" = "$value" ] \
            || fail "hpnssh dropped or reordered names in the $opt line from tools/suggest-cipher.sh: $got"
    else
        fail "hpnssh does not accept the $opt line from tools/suggest-cipher.sh: $(cat "$TEST_DIR/sc-$opt.out")"
    fi
done
pass "hpnssh accepts every name in the Ciphers and MACs lines from tools/suggest-cipher.sh"

tests/scp-resume.sh "$tree/hpnscp" "$TEST_DIR/scp-resume" >"$TEST_DIR/scp-resume.out" 2>&1 \
    || { cat "$TEST_DIR/scp-resume.out" >&2; fail "scp -Z resume tests"; }
pass "scp -Z resume tests pass ($(grep -c '^ok' "$TEST_DIR/scp-resume.out") checks)"

tests/daemon-checks.sh "$tree" >"$TEST_DIR/daemon-checks.out" 2>&1 \
    || { cat "$TEST_DIR/daemon-checks.out" >&2; fail "checks against a running hpnsshd"; }
pass "checks against a running hpnsshd pass ($(grep -c '^ok' "$TEST_DIR/daemon-checks.out") checks)"

echo "$PASSED checks passed"
