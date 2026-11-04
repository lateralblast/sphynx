#!/usr/bin/env bash
# Tests for tools/tune-tcp.sh.
#
# The checks that need no privileges always run. The macOS checks run on any
# system, against a stand-in for sysctl that keeps its values in files. The Linux
# checks that change kernel settings need Linux and sudo, and run inside a
# throwaway network namespace: its TCP settings are separate from the host's, so
# the host is never touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TUNE="$ROOT/tools/tune-tcp.sh"
failures=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

# --- a stand-in for sysctl and sudo ---------------------------------------------

# Off Linux, and for the macOS checks everywhere, the tool runs as on macOS
# (TUNE_TCP_OS=Darwin) against a sysctl that keeps its values in files, so no
# machine's real settings are read or changed.
stub="$(mktemp -d)"
trap 'rm -rf "$stub"' EXIT
mkdir -p "$stub/bin" "$stub/state"
cat >"$stub/bin/sysctl" <<'STUB'
#!/usr/bin/env bash
state="$STUB_STATE"
case "$1" in
    -n) cat "$state/$2" ;;
    -w) k="${2%%=*}"; printf '%s\n' "${2#*=}" >"$state/$k" ;;
    -p) while IFS= read -r l; do
            case "$l" in \#*|"") ;; *) printf '%s\n' "${l#* = }" >"$state/${l%% = *}" ;; esac
        done <"$2" ;;
    *) exit 1 ;;
esac
STUB
# a stand-in for modprobe: it succeeds, and adds the algorithm to the available list,
# only for a module whose name has a "loadable_<module>" file in the state directory
cat >"$stub/bin/modprobe" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_STATE/modprobe.log"
[ -e "$STUB_STATE/loadable_$1" ] || exit 1
f="$STUB_STATE/net.ipv4.tcp_available_congestion_control"
printf '%s %s\n' "$(cat "$f")" "${1#tcp_}" >"$f"
STUB
chmod +x "$stub/bin/modprobe"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$stub/bin/sudo"
chmod +x "$stub/bin/sysctl" "$stub/bin/sudo"

mac_reset() {
    printf '%s\n' 8388608 >"$stub/state/kern.ipc.maxsockbuf"
    printf '%s\n' 4194304 >"$stub/state/net.inet.tcp.autosndbufmax"
    printf '%s\n' 4194304 >"$stub/state/net.inet.tcp.autorcvbufmax"
}
mac_get() { cat "$stub/state/$1"; }
mac() { STUB_STATE="$stub/state" TUNE_TCP_OS=Darwin PATH="$stub/bin:$PATH" "$TUNE" "$@"; }
mac_reset

linux=0
if [ "$(uname -s)" = Linux ] && [ -r /proc/sys/net/ipv4/tcp_wmem ]; then linux=1; fi
# the checks that need no real settings use the real tool on Linux, the stand-in elsewhere
if [ $linux = 1 ]; then tune() { "$TUNE" "$@"; }; else tune() { mac "$@"; }; fi

# --- no privileges needed ---------------------------------------------------

# the target for N MiB: macOS limits it to 28 MiB (see tools/tune-tcp.sh)
target() { local n=$1; [ $linux = 1 ] || [ "$n" -le 28 ] || n=28; echo "target maximum: $((n * 1048576)) bytes ($n MiB)"; }

out="$(tune show --bandwidth 1gbit --rtt 100ms)"
if grep -qF "$(target 30)" <<<"$out"; then
    pass "1 Gbit/s at 100 ms needs 30 MiB (2.5 x the bandwidth-delay product, rounded up)"
else fail "size estimate: $out"; fi

out="$(tune show --bandwidth 10gbit --rtt 20ms)"
if grep -qF "$(target 60)" <<<"$out"; then
    pass "10 Gbit/s at 20 ms needs 60 MiB"
else fail "size estimate for 10 Gbit/s at 20 ms: $out"; fi

out="$(tune show --bandwidth 10gbit --rtt 100ms)"
if grep -qF "$(target 256)" <<<"$out"; then
    pass "a very large estimate is capped at 256 MiB"
else fail "cap: $out"; fi

out="$(tune show --bandwidth 1mbit --rtt 1ms)"
if grep -q 'target maximum: 4194304 bytes (4 MiB)' <<<"$out"; then
    pass "a tiny path still gets the 4 MiB minimum"
else fail "minimum size: $out"; fi

out="$(tune show --max 16777216)"
if grep -q 'target maximum: 16777216 bytes (16 MiB), from --max' <<<"$out"; then
    pass "--max sets the maximum directly"
else fail "--max: $out"; fi

for bad in "--bandwidth fast --rtt 10ms" "--bandwidth 1gbit" "--rtt 10ms" "--max 12" "--rtt 10ms --bandwidth 1gbit --nonsense"; do
    # shellcheck disable=SC2086 # the options are meant to split
    if tune show $bad >/dev/null 2>&1; then fail "bad input accepted: $bad"; else pass "bad input rejected: $bad"; fi
done

# without a terminal and without --yes it must refuse, before changing anything
if tune apply --max 2147483648 </dev/null >/dev/null 2>&1; then
    fail "apply went ahead with no terminal and no --yes"
else
    pass "apply refuses to go ahead with no terminal and no --yes"
fi

# --- macOS settings, against the stand-in sysctl -------------------------------

out="$(mac show --max 16777216)"
if grep -q 'kern.ipc.maxsockbuf *8388608  ->  18874368' <<<"$out" \
   && grep -q 'net.inet.tcp.autosndbufmax *4194304  ->  16777216' <<<"$out" \
   && grep -q 'net.inet.tcp.autorcvbufmax *4194304  ->  16777216' <<<"$out"; then
    pass "macOS: show plans the send and receive maximums and a socket buffer cap that holds them"
else fail "macOS show: $out"; fi

out="$(mac show --max 100000000)"
if grep -q 'target maximum: 29360128 bytes (28 MiB).*limited to 28 MiB' <<<"$out" \
   && grep -q 'kern.ipc.maxsockbuf *8388608  ->  33030144' <<<"$out"; then
    pass "macOS: a target above 28 MiB is limited, so the socket buffer cap stays under the 32 MiB macOS accepts"
else fail "macOS limit: $out"; fi

mac_reset
mac apply --yes --max 16777216 >/dev/null 2>&1
if [ "$(mac_get net.inet.tcp.autosndbufmax)" = 16777216 ] && [ "$(mac_get net.inet.tcp.autorcvbufmax)" = 16777216 ] \
   && [ "$(mac_get kern.ipc.maxsockbuf)" = 18874368 ]; then
    pass "macOS: apply raises the maximums and the socket buffer cap"
else fail "macOS apply: snd=$(mac_get net.inet.tcp.autosndbufmax) rcv=$(mac_get net.inet.tcp.autorcvbufmax) cap=$(mac_get kern.ipc.maxsockbuf)"; fi

mac_reset
out="$(mac apply --yes --max 16777216 2>&1)"
if grep -q 'sudo sysctl -w net.inet.tcp.autosndbufmax="4194304"' <<<"$out" && grep -q 'sudo sysctl -w kern.ipc.maxsockbuf="8388608"' <<<"$out"; then
    pass "macOS: apply prints the commands that put the old values back"
else fail "macOS restore hints: $out"; fi

mac_reset
printf '%s\n' 100000000 >"$stub/state/net.inet.tcp.autosndbufmax"
printf '%s\n' 200000000 >"$stub/state/kern.ipc.maxsockbuf"
out="$(mac apply --yes --max 16777216 2>&1)"
if [ "$(mac_get net.inet.tcp.autosndbufmax)" = 100000000 ] && [ "$(mac_get kern.ipc.maxsockbuf)" = 200000000 ] \
   && grep -q 'already at least that large' <<<"$out"; then
    pass "macOS: a maximum or cap that is already larger is never lowered"
else fail "macOS lowered a larger value: snd=$(mac_get net.inet.tcp.autosndbufmax) cap=$(mac_get kern.ipc.maxsockbuf)"; fi

mac_reset
mac apply --yes --send-only --max 16777216 >/dev/null 2>&1
if [ "$(mac_get net.inet.tcp.autosndbufmax)" = 16777216 ] && [ "$(mac_get net.inet.tcp.autorcvbufmax)" = 4194304 ]; then
    pass "macOS: --send-only leaves the receive maximum alone"
else fail "macOS --send-only: snd=$(mac_get net.inet.tcp.autosndbufmax) rcv=$(mac_get net.inet.tcp.autorcvbufmax)"; fi

for c in persist revert; do
    mac_reset
    if out="$(mac $c --yes --max 16777216 2>&1)"; then fail "macOS: $c succeeded"
    elif grep -q "$c works on Linux only" <<<"$out" && [ "$(mac_get net.inet.tcp.autosndbufmax)" = 4194304 ]; then
        pass "macOS: $c is refused with an explanation, and changes nothing"
    else fail "macOS $c: $out"; fi
done

# --- congestion control (Linux), against the stand-in sysctl and modprobe -----------

mkdir -p "$stub/proc" "$stub/modules" "$stub/sysctl.d"
: >"$stub/proc/tcp_wmem"
lin_reset() {
    printf '%s\n' "4096 16384 4194304" >"$stub/state/net.ipv4.tcp_wmem"
    printf '%s\n' "4096 131072 6291456" >"$stub/state/net.ipv4.tcp_rmem"
    printf '%s\n' cubic >"$stub/state/net.ipv4.tcp_congestion_control"
    printf '%s\n' "reno cubic" >"$stub/state/net.ipv4.tcp_available_congestion_control"
    rm -f "$stub/state/modprobe.log" "$stub/state/loadable_tcp_bbr" "$stub/modules/"* "$stub/sysctl.d/"*
}
lin() {
    STUB_STATE="$stub/state" TUNE_TCP_OS=Linux TUNE_TCP_PROC="$stub/proc" TUNE_TCP_MODULES_DIR="$stub/modules" \
        PATH="$stub/bin:$PATH" "$TUNE" "$@"
}
cc_now() { cat "$stub/state/net.ipv4.tcp_congestion_control"; }

lin_reset; printf '%s\n' "reno cubic bbr" >"$stub/state/net.ipv4.tcp_available_congestion_control"
out="$(lin show --cc bbr)"
if grep -q 'net.ipv4.tcp_congestion_control *cubic  ->  bbr' <<<"$out" && grep -q 'net.ipv4.tcp_wmem' <<<"$out" && ! grep -q 'modprobe' <<<"$out"; then
    pass "--cc bbr: show adds the congestion control to the plan, next to the buffers"
else fail "--cc show: $out"; fi
out="$(lin show --cc bbr --cc-only)"
if grep -q 'tcp_congestion_control' <<<"$out" && ! grep -q 'target maximum' <<<"$out" && ! grep -q 'tcp_wmem' <<<"$out"; then
    pass "--cc-only plans the congestion control and nothing else"
else fail "--cc-only show: $out"; fi

lin_reset
out="$(lin show --cc bbr --cc-only)"
if grep -q "bbr is not loaded; apply loads it with 'modprobe tcp_bbr'" <<<"$out"; then
    pass "show says when the module has to be loaded"
else fail "module note: $out"; fi

touch "$stub/state/loadable_tcp_bbr"
out="$(lin apply --yes --cc bbr --cc-only 2>&1)"
if [ "$(cc_now)" = bbr ] && grep -q '^tcp_bbr$' "$stub/state/modprobe.log" \
   && grep -q 'sudo sysctl -w net.ipv4.tcp_congestion_control="cubic"' <<<"$out"; then
    pass "apply loads the module, sets the congestion control and prints how to put cubic back"
else fail "apply --cc: cc=$(cc_now) log=$(cat "$stub/state/modprobe.log" 2>&1) out=$out"; fi
out="$(lin apply --yes --cc bbr --cc-only 2>&1)"
if grep -q 'nothing to change' <<<"$out"; then pass "applying the same congestion control again changes nothing"
else fail "reapply: $out"; fi

lin_reset
if out="$(lin apply --yes --cc bbr --cc-only 2>&1)"; then fail "apply succeeded with a module that will not load: $out"
elif [ "$(cc_now)" = cubic ] && grep -q 'could not load tcp_bbr' <<<"$out"; then
    pass "a congestion control that will not load is an error, and nothing is changed"
else fail "unloadable cc: cc=$(cc_now) out=$out"; fi

lin_reset; touch "$stub/state/loadable_tcp_bbr"
lin persist --yes --cc bbr --conf-dir "$stub/sysctl.d" >/dev/null 2>&1
f="$stub/sysctl.d/99-hpn-ssh-tcp.conf"
if [ "$(cc_now)" = bbr ] && grep -q '^net.ipv4.tcp_congestion_control = bbr$' "$f" \
   && grep -q '^# previous net.ipv4.tcp_congestion_control = cubic$' "$f" \
   && grep -q '^net.ipv4.tcp_wmem = 4096 16384 ' "$f" \
   && grep -q '^tcp_bbr$' "$stub/modules/99-hpn-ssh-tcp.conf"; then
    pass "persist writes the congestion control and the previous one, and a modules-load file for it"
else fail "persist --cc: cc=$(cc_now) file=$(cat "$f" 2>&1) modules=$(cat "$stub/modules/"* 2>&1)"; fi
lin revert --conf-dir "$stub/sysctl.d" >/dev/null 2>&1
if [ "$(cc_now)" = cubic ] && [ ! -e "$f" ] && [ ! -e "$stub/modules/99-hpn-ssh-tcp.conf" ] \
   && [ "$(cat "$stub/state/net.ipv4.tcp_wmem")" = "4096 16384 4194304" ]; then
    pass "revert puts the congestion control and the buffers back and removes both files"
else fail "revert --cc: cc=$(cc_now) wmem=$(cat "$stub/state/net.ipv4.tcp_wmem") files=$(ls "$stub/sysctl.d" "$stub/modules")"; fi

lin_reset
lin persist --yes --cc cubic --cc-only --conf-dir "$stub/sysctl.d" >/dev/null 2>&1
if [ -z "$(ls "$stub/modules")" ]; then pass "persist writes no modules-load file for a built-in congestion control"
else fail "cubic module file: $(ls "$stub/modules")"; fi

for bad in "--cc Bad;name" "--cc-only"; do
    # shellcheck disable=SC2086 # the options are meant to split
    if lin show $bad >/dev/null 2>&1; then fail "accepted: $bad"; else pass "rejected: $bad"; fi
done
if mac show --cc bbr >/dev/null 2>&1; then fail "--cc accepted on macOS"; else pass "--cc is refused on macOS"; fi

# --- Linux, needs sudo: inside a throwaway namespace -----------------------------

if [ $linux = 0 ]; then
    echo "skip - the checks of the Linux settings need Linux"
    echo "$failures failure(s)"
    [ $failures -eq 0 ]
    exit
fi
if ! { sudo -n true 2>/dev/null && command -v ip >/dev/null; }; then
    echo "skip - the checks that change settings need passwordless sudo and the ip command"
    echo "$failures failure(s)"
    [ $failures -eq 0 ]
    exit
fi

ns="tunetcp$$"
dir="$(mktemp -d)"
sudo ip netns add "$ns" || { echo "skip - cannot create a network namespace"; exit 0; }
cleanup() { sudo ip netns del "$ns" 2>/dev/null; rm -rf "$dir" "$stub"; }
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

# reno is built into every kernel, so this sets a real congestion control without loading a module
host_cc="$(sysctl -n net.ipv4.tcp_congestion_control)"
inns sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
inns "$TUNE" apply --yes --cc reno --cc-only >/dev/null 2>&1
if [ "$(get net.ipv4.tcp_congestion_control)" = reno ] && [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "$host_cc" ]; then
    pass "--cc sets the congestion control in the namespace and not on the host"
else fail "--cc in a namespace: ns=$(get net.ipv4.tcp_congestion_control) host=$(sysctl -n net.ipv4.tcp_congestion_control) (was $host_cc)"; fi

echo "$failures failure(s)"
[ $failures -eq 0 ]
