#!/usr/bin/env bash
# Tests for tools/tune-tcp.sh.
#
# The checks that need no privileges always run. The ones that change kernel
# settings need sudo, and run inside a throwaway network namespace: its TCP
# settings are separate from the host's, so the host is never touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUNE="$ROOT/tools/tune-tcp.sh"
failures=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

# --- no privileges needed ---------------------------------------------------

out="$("$TUNE" show --bandwidth 1gbit --rtt 100ms)"
if grep -q 'target maximum: 31457280 bytes (30 MiB)' <<<"$out"; then
    pass "1 Gbit/s at 100 ms needs 30 MiB (2.5 x the bandwidth-delay product, rounded up)"
else fail "size estimate: $out"; fi

out="$("$TUNE" show --bandwidth 10gbit --rtt 20ms)"
if grep -q 'target maximum: 62914560 bytes (60 MiB)' <<<"$out"; then
    pass "10 Gbit/s at 20 ms needs 60 MiB"
else fail "size estimate for 10 Gbit/s at 20 ms: $out"; fi

out="$("$TUNE" show --bandwidth 10gbit --rtt 100ms)"
if grep -q 'target maximum: 268435456 bytes (256 MiB)' <<<"$out"; then
    pass "a very large estimate is capped at 256 MiB"
else fail "cap: $out"; fi

out="$("$TUNE" show --bandwidth 1mbit --rtt 1ms)"
if grep -q 'target maximum: 4194304 bytes (4 MiB)' <<<"$out"; then
    pass "a tiny path still gets the 4 MiB minimum"
else fail "minimum size: $out"; fi

out="$("$TUNE" show --max 16777216)"
if grep -q 'target maximum: 16777216 bytes (16 MiB), from --max' <<<"$out"; then
    pass "--max sets the maximum directly"
else fail "--max: $out"; fi

for bad in "--bandwidth fast --rtt 10ms" "--bandwidth 1gbit" "--rtt 10ms" "--max 12" "--rtt 10ms --bandwidth 1gbit --nonsense"; do
    # shellcheck disable=SC2086 # the options are meant to split
    if "$TUNE" show $bad >/dev/null 2>&1; then fail "bad input accepted: $bad"; else pass "bad input rejected: $bad"; fi
done

# without a terminal and without --yes it must refuse, before changing anything
if "$TUNE" apply --max 2147483648 </dev/null >/dev/null 2>&1; then
    fail "apply went ahead with no terminal and no --yes"
else
    pass "apply refuses to go ahead with no terminal and no --yes"
fi

# --- needs sudo: inside a throwaway namespace ---------------------------------

if ! { sudo -n true 2>/dev/null && command -v ip >/dev/null; }; then
    echo "skip - the checks that change settings need passwordless sudo and the ip command"
    echo "$failures failure(s)"
    [ $failures -eq 0 ]
    exit
fi

ns="tunetcp$$"
dir="$(mktemp -d)"
sudo ip netns add "$ns" || { echo "skip - cannot create a network namespace"; exit 0; }
cleanup() { sudo ip netns del "$ns" 2>/dev/null; rm -rf "$dir"; }
trap cleanup EXIT

inns() { sudo ip netns exec "$ns" "$@"; }
get() { inns sysctl -n "$1" | tr -s '[:space:]' ' ' | sed 's/ $//'; }
baseline() {
    inns sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304" net.ipv4.tcp_rmem="4096 131072 6291456" >/dev/null
}
W0="4096 16384 4194304"; R0="4096 131072 6291456"
host_before="$(sysctl -n net.ipv4.tcp_wmem net.ipv4.tcp_rmem)"

baseline
inns "$TUNE" apply --yes --max 33554432 >/dev/null 2>&1
if [ "$(get net.ipv4.tcp_wmem)" = "4096 16384 33554432" ] && [ "$(get net.ipv4.tcp_rmem)" = "4096 131072 33554432" ]; then
    pass "apply raises both maximums and keeps the other numbers"
else fail "apply: wmem=$(get net.ipv4.tcp_wmem) rmem=$(get net.ipv4.tcp_rmem)"; fi

if [ "$(sysctl -n net.ipv4.tcp_wmem net.ipv4.tcp_rmem)" = "$host_before" ]; then
    pass "the host's own settings did not change"
else fail "the host's settings changed"; fi

if inns "$TUNE" revert --conf-dir "$dir" >/dev/null 2>&1; then
    fail "revert succeeded with no file to revert"
else pass "revert with nothing to revert fails with a message"; fi

baseline
inns "$TUNE" persist --yes --max 33554432 --conf-dir "$dir" >/dev/null 2>&1
f="$dir/99-hpn-ssh-tcp.conf"
if [ -f "$f" ] && grep -q '^net.ipv4.tcp_wmem = 4096 16384 33554432$' "$f" \
   && grep -q "^# previous net.ipv4.tcp_wmem = $W0\$" "$f" \
   && grep -q "^# previous net.ipv4.tcp_rmem = $R0\$" "$f" \
   && [ "$(get net.ipv4.tcp_wmem)" = "4096 16384 33554432" ]; then
    pass "persist writes the file with the previous values, and applies it"
else fail "persist: $(cat "$f" 2>/dev/null | tr '\n' '|')"; fi

inns "$TUNE" persist --yes --max 50331648 --conf-dir "$dir" >/dev/null 2>&1
if grep -q "^# previous net.ipv4.tcp_wmem = $W0\$" "$f" && [ "$(get net.ipv4.tcp_wmem)" = "4096 16384 50331648" ]; then
    pass "a second persist keeps the original previous values"
else fail "second persist: $(cat "$f" | tr '\n' '|')"; fi

inns "$TUNE" revert --conf-dir "$dir" >/dev/null 2>&1
if [ ! -f "$f" ] && [ "$(get net.ipv4.tcp_wmem)" = "$W0" ] && [ "$(get net.ipv4.tcp_rmem)" = "$R0" ]; then
    pass "revert restores the original values and removes the file"
else fail "revert: wmem=$(get net.ipv4.tcp_wmem) rmem=$(get net.ipv4.tcp_rmem) file=$([ -f "$f" ] && echo present || echo gone)"; fi

baseline
inns sysctl -w net.ipv4.tcp_wmem="4096 16384 100000000" >/dev/null
out="$(inns "$TUNE" apply --yes --max 33554432 2>&1)"
if [ "$(get net.ipv4.tcp_wmem)" = "4096 16384 100000000" ] && grep -q 'already at least that large' <<<"$out"; then
    pass "a maximum that is already larger is never lowered"
else fail "lowered a larger maximum: $(get net.ipv4.tcp_wmem)"; fi

baseline
inns "$TUNE" apply --yes --send-only --max 33554432 >/dev/null 2>&1
if [ "$(get net.ipv4.tcp_wmem)" = "4096 16384 33554432" ] && [ "$(get net.ipv4.tcp_rmem)" = "$R0" ]; then
    pass "--send-only leaves tcp_rmem alone"
else fail "--send-only: wmem=$(get net.ipv4.tcp_wmem) rmem=$(get net.ipv4.tcp_rmem)"; fi

echo "$failures failure(s)"
[ $failures -eq 0 ]
