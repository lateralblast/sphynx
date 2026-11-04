#!/usr/bin/env bash
# Raise the TCP buffer maximums so HPN-SSH can use long, fast network paths.
#
#   tools/tune-tcp.sh show      what would change (needs no privileges)
#   tools/tune-tcp.sh apply     set the new maximums now, until the next reboot
#   tools/tune-tcp.sh persist   apply, and keep them across reboots
#   tools/tune-tcp.sh revert    put back what persist replaced
#
# It only ever raises a maximum, never lowers one, and changes nothing else,
# unless you ask for a congestion control with --cc (Linux only, for example
# bbr, which keeps its speed on a lossy path where the default cubic does not).
# It works on Linux (net.ipv4.tcp_wmem and tcp_rmem) and on macOS
# (net.inet.tcp.autosndbufmax, autorcvbufmax and kern.ipc.maxsockbuf). On macOS
# there is no persist or revert: a setting lasts until the next reboot.
# See "Tuning the TCP stack" in the README.
set -euo pipefail

CONF_NAME=99-hpn-ssh-tcp.conf
CONF_DIR=/etc/sysctl.d
# persist also lists the congestion control's module here, so it is loaded at boot
MODULES_DIR="${TUNE_TCP_MODULES_DIR:-/etc/modules-load.d}"
CC_KEY=net.ipv4.tcp_congestion_control
DEFAULT_MAX=33554432   # 32 MiB, covers 1 Gbit/s up to about 200 ms
MIB=1048576

die() { echo "tune-tcp: error: $*" >&2; exit 1; }

usage() {
    cat <<USAGE
usage: tools/tune-tcp.sh <command> [options]

commands:
  show      show the current values and what apply would change
  apply     set the new maximums now; lasts until the next reboot
  persist   apply, and write $CONF_DIR/$CONF_NAME so they survive a reboot (Linux only)
  revert    restore the values persist replaced, and remove that file (Linux only)

options:
  --bandwidth RATE   link speed, for example 1gbit or 100mbit (units: kbit, mbit, gbit, tbit)
  --rtt TIME         round-trip time, for example 100ms or 0.1s
  --max BYTES        set the maximum directly; overrides --bandwidth and --rtt
  --send-only        change only the send maximum (net.ipv4.tcp_wmem, or
                     net.inet.tcp.autosndbufmax on macOS), not the receive one
  --cc NAME          also set the congestion control, for example bbr (Linux only). It loads
                     the tcp_NAME module if needed. The default, cubic, slows badly on a lossy
                     path; bbr does not. It changes how this machine shares a link.
  --cc-only          with --cc, change only the congestion control, not the buffer maximums
  --yes              do not ask for confirmation
  --conf-dir DIR     where persist writes its file (default $CONF_DIR)

With --bandwidth and --rtt the maximum is 2.5 times the bandwidth-delay product,
rounded up to a whole MiB (at least 4 MiB, at most 256 MiB). Without them it is
$((DEFAULT_MAX / MIB)) MiB. A maximum that is already at least that large is left alone.
USAGE
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# TUNE_TCP_OS overrides the detected system. The tests use it to run the macOS
# code on any machine with a stand-in for sysctl.
OS="${TUNE_TCP_OS:-$(uname -s)}"
case "$OS" in
    Linux) [ -r "${TUNE_TCP_PROC:-/proc/sys/net/ipv4}/tcp_wmem" ] || die "no /proc/sys/net/ipv4/tcp_wmem" ;;
    Darwin) ;;
    *) die "this needs Linux or macOS, not $OS" ;;
esac

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------- parsing

rate_to_bps() {
    local v; v="$(lower "$1")"
    [[ "$v" =~ ^([0-9]+(\.[0-9]+)?)(bit|kbit|mbit|gbit|tbit)?$ ]] || die "cannot read bandwidth '$1' (try 1gbit or 100mbit)"
    awk -v n="${BASH_REMATCH[1]}" -v u="${BASH_REMATCH[3]:-bit}" \
        'BEGIN{m["bit"]=1;m["kbit"]=1e3;m["mbit"]=1e6;m["gbit"]=1e9;m["tbit"]=1e12; printf "%.0f", n*m[u]}'
}

time_to_seconds() {
    local v; v="$(lower "$1")"
    [[ "$v" =~ ^([0-9]+(\.[0-9]+)?)(us|ms|s)?$ ]] || die "cannot read round-trip time '$1' (try 100ms or 0.1s)"
    awk -v n="${BASH_REMATCH[1]}" -v u="${BASH_REMATCH[3]:-ms}" \
        'BEGIN{m["us"]=1e-6;m["ms"]=1e-3;m["s"]=1; printf "%.9f", n*m[u]}'
}

# ---------------------------------------------------------------- state

DARWIN_MAX_TARGET=$((28 * MIB))
BANDWIDTH="" RTT="" MAX="" SEND_ONLY=0 ASSUME_YES=0 CC="" CC_ONLY=0 CC_MODULE=""
TARGET="" TARGET_NOTE=""

compute_target() {
    if [ -n "$MAX" ]; then
        [[ "$MAX" =~ ^[0-9]+$ ]] && [ "$MAX" -ge 65536 ] || die "--max must be a number of bytes, at least 65536"
        TARGET="$MAX"; TARGET_NOTE="from --max"
    elif [ -n "$BANDWIDTH" ] || [ -n "$RTT" ]; then
        [ -n "$BANDWIDTH" ] && [ -n "$RTT" ] || die "give both --bandwidth and --rtt, or neither"
        local bps rtt bdp
        bps="$(rate_to_bps "$BANDWIDTH")"
        rtt="$(time_to_seconds "$RTT")"
        bdp="$(awk -v b="$bps" -v r="$rtt" 'BEGIN{printf "%.0f", b/8*r}')"
        TARGET="$(awk -v b="$bdp" -v m="$MIB" 'BEGIN{
            q=b*2.5/m; t=(q==int(q))?q:int(q)+1; t*=m
            if (t<4*m) t=4*m; if (t>256*m) t=256*m; printf "%d", t}')"
        TARGET_NOTE="2.5 x the bandwidth-delay product of $(awk -v b="$bdp" 'BEGIN{printf "%.2f", b/1e6}') MB, rounded up to whole MiB"
    else
        TARGET="$DEFAULT_MAX"; TARGET_NOTE="the default"
    fi
    # macOS refuses a kern.ipc.maxsockbuf above 32 MiB ("Result too large"), and
    # that cap has to hold the target plus 1/8 of overhead, so the target stops
    # at 28 MiB.
    if [ "$OS" = Darwin ] && [ "$TARGET" -gt "$DARWIN_MAX_TARGET" ]; then
        TARGET_NOTE="$TARGET_NOTE; limited to $((DARWIN_MAX_TARGET / MIB)) MiB, the most macOS accepts"
        TARGET="$DARWIN_MAX_TARGET"
    fi
}

# plan: one line per setting, "key|prefix|current|new". On Linux a setting is
# three numbers (minimum, default, maximum) and the prefix is the first two. On
# macOS it is one number and the prefix is empty. Only the last number changes.
PLAN=()
CHANGES=0

# plan_add KEY PREFIX CURRENT NEW
plan_add() {
    PLAN+=("$1|$2|$3|$4")
    [ "$4" = "$3" ] || CHANGES=$((CHANGES + 1))
}

# raised_max CURRENT: the new maximum, never lower than the current one
raised_max() { if [ "$TARGET" -gt "$1" ]; then echo "$TARGET"; else echo "$1"; fi; }

build_plan() {
    local key min def max
    PLAN=(); CHANGES=0
    if [ "$OS" = Darwin ]; then
        # The socket buffer cap has to hold the largest buffer, with the overhead
        # the kernel counts against it (a 2304 byte buffer per 2048 of payload).
        local need
        max="$(sysctl -n kern.ipc.maxsockbuf)"
        need=$(((TARGET * 9 + 7) / 8))
        [ "$need" -gt "$max" ] || need="$max"
        plan_add kern.ipc.maxsockbuf "" "$max" "$need"
        max="$(sysctl -n net.inet.tcp.autosndbufmax)"
        plan_add net.inet.tcp.autosndbufmax "" "$max" "$(raised_max "$max")"
        if [ "$SEND_ONLY" != 1 ]; then
            max="$(sysctl -n net.inet.tcp.autorcvbufmax)"
            plan_add net.inet.tcp.autorcvbufmax "" "$max" "$(raised_max "$max")"
        fi
        return 0
    fi
    if [ "$CC_ONLY" != 1 ]; then
        for key in net.ipv4.tcp_wmem net.ipv4.tcp_rmem; do
            [ "$key" = net.ipv4.tcp_rmem ] && [ "$SEND_ONLY" = 1 ] && continue
            read -r min def max < <(sysctl -n "$key")
            plan_add "$key" "$min $def" "$max" "$(raised_max "$max")"
        done
    fi
    if [ -n "$CC" ]; then
        local avail; avail="$(sysctl -n net.ipv4.tcp_available_congestion_control)"
        # a congestion control that is not listed is a module that is not loaded yet
        if grep -qw -- "$CC" <<<"$avail"; then CC_MODULE=""; else CC_MODULE="tcp_$CC"; fi
        plan_add "$CC_KEY" "" "$(sysctl -n "$CC_KEY")" "$CC"
    fi
}

# setting_value PREFIX NUMBER: the string sysctl shows and accepts
setting_value() { echo "${1:+$1 }$2"; }

print_plan() {
    local line key pre cur new
    [ "$CC_ONLY" = 1 ] || echo "target maximum: $TARGET bytes ($((TARGET / MIB)) MiB), $TARGET_NOTE"
    for line in "${PLAN[@]}"; do
        IFS='|' read -r key pre cur new <<<"$line"
        if [ "$new" != "$cur" ]; then
            printf '  %-28s %s  ->  %s\n' "$key" "$(setting_value "$pre" "$cur")" "$(setting_value "$pre" "$new")"
        else
            if [ "$key" = "$CC_KEY" ]; then
                printf '  %-28s %s  (already set)\n' "$key" "$cur"
            else
                printf '  %-28s %s  (already at least that large, left alone)\n' "$key" "$(setting_value "$pre" "$cur")"
            fi
        fi
    done
    [ -z "$CC_MODULE" ] || echo "  $CC is not loaded; apply loads it with 'modprobe $CC_MODULE'"
}

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    [ -t 0 ] || die "not a terminal; pass --yes to go ahead"
    echo "This changes system-wide TCP settings, for every program on this machine."
    [ -z "$CC" ] || echo "The congestion control changes how every connection from this machine behaves on a shared link."
    read -r -p "Proceed? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "nothing changed"; exit 1; }
}

apply_plan() {
    local line key pre cur new
    if [ -n "$CC_MODULE" ]; then
        as_root modprobe "$CC_MODULE" || die "could not load $CC_MODULE, so $CC is not available (see: sysctl net.ipv4.tcp_available_congestion_control)"
        grep -qw -- "$CC" <<<"$(sysctl -n net.ipv4.tcp_available_congestion_control)" \
            || die "$CC is still not in net.ipv4.tcp_available_congestion_control after loading $CC_MODULE"
    fi
    for line in "${PLAN[@]}"; do
        IFS='|' read -r key pre cur new <<<"$line"
        [ "$new" != "$cur" ] || continue
        as_root sysctl -w "$key=$(setting_value "$pre" "$new")" >/dev/null
    done
}

# ---------------------------------------------------------------- commands

conf_file() { echo "$CONF_DIR/$CONF_NAME"; }

# previous_values FILE: prints "key min default max" for each recorded value
previous_values() {
    sed -n 's/^# previous \([^ ]*\) = \(.*\)$/\1 \2/p' "$1"
}

cmd_show() {
    compute_target; build_plan; print_plan
    [ "$CHANGES" -gt 0 ] || echo "nothing to change"
    return 0
}

cmd_apply() {
    compute_target; build_plan; print_plan
    [ "$CHANGES" -gt 0 ] || { echo "nothing to change"; return 0; }
    confirm
    apply_plan
    echo "applied; this lasts until the next reboot."
    local line key pre cur new
    echo "to put the old values back now:"
    for line in "${PLAN[@]}"; do
        IFS='|' read -r key pre cur new <<<"$line"
        [ "$new" != "$cur" ] && echo "  sudo sysctl -w $key=\"$(setting_value "$pre" "$cur")\""
    done
    return 0
}

# macOS reads no sysctl.d, so there is no file to write or to undo
linux_only() {
    [ "$OS" = Linux ] || die "$1 works on Linux only. On macOS a setting from 'apply' lasts until the next reboot; to set it at every boot, run 'tune-tcp.sh apply --yes' from a LaunchDaemon."
}

cmd_persist() {
    linux_only persist
    compute_target; build_plan; print_plan
    local file; file="$(conf_file)"
    [ "$CHANGES" -gt 0 ] || [ -f "$file" ] || { echo "nothing to change"; return 0; }
    confirm
    # keep the values from before the first persist, so revert goes back to them
    local -A prev=()
    local line key value new pre cur
    if [ -f "$file" ]; then
        while read -r key value; do
            prev["$key"]="$value"
        done < <(previous_values "$file")
    fi
    local tmp; tmp="$(mktemp)"
    {
        echo "# Written by tools/tune-tcp.sh from sphynx on $(date +%Y-%m-%d)."
        echo "# Larger TCP buffer maximums for HPN-SSH on long, fast paths."
        echo "# Undo with: tools/tune-tcp.sh revert"
        for line in "${PLAN[@]}"; do
            IFS='|' read -r key pre cur new <<<"$line"
            echo "$key = $(setting_value "$pre" "$new")"
        done
        echo "#"
        echo "# Values before this file, used by 'tune-tcp.sh revert':"
        for line in "${PLAN[@]}"; do
            IFS='|' read -r key pre cur new <<<"$line"
            echo "# previous $key = ${prev[$key]:-$(setting_value "$pre" "$cur")}"
        done
    } >"$tmp"
    as_root mkdir -p "$CONF_DIR"
    as_root install -m 644 "$tmp" "$file"
    if [ -n "$CC_MODULE" ]; then
        as_root modprobe "$CC_MODULE" || die "could not load $CC_MODULE, so $CC is not available"
    fi
    as_root sysctl -p "$file" >/dev/null
    echo "wrote $file and applied it."
    # reno and cubic are built in; any other congestion control is a module to load at boot
    if [ -n "$CC" ] && [ "$CC" != cubic ] && [ "$CC" != reno ]; then
        local mfile="$MODULES_DIR/$CONF_NAME"
        printf '# Written by tools/tune-tcp.sh from sphynx: loads tcp_%s at boot.\ntcp_%s\n' "$CC" "$CC" >"$tmp"
        as_root mkdir -p "$MODULES_DIR"
        as_root install -m 644 "$tmp" "$mfile"
        echo "wrote $mfile so tcp_$CC is loaded at boot."
    fi
    rm -f "$tmp"
}

cmd_revert() {
    linux_only revert
    local file; file="$(conf_file)"
    [ -f "$file" ] || die "$file does not exist, so there is nothing to revert. For a setting made with 'apply', use the sysctl -w commands it printed, or reboot."
    local key value restored=0
    while read -r key value; do
        as_root sysctl -w "$key=$value" >/dev/null
        restored=$((restored + 1))
    done < <(previous_values "$file")
    [ "$restored" -gt 0 ] || die "$file has no recorded previous values; remove it yourself and reboot"
    as_root rm -f "$file"
    local mfile="$MODULES_DIR/$CONF_NAME"
    if [ -f "$mfile" ]; then
        as_root rm -f "$mfile"
        echo "removed $mfile."
    fi
    echo "restored $restored setting(s) and removed $file."
}

# ---------------------------------------------------------------- main

[ $# -gt 0 ] || { usage; exit 2; }
COMMAND="$1"; shift
case "$COMMAND" in
    -h|--help) usage; exit 0 ;;
    show|apply|persist|revert) ;;
    *) die "unknown command '$COMMAND' (try --help)" ;;
esac
while [ $# -gt 0 ]; do
    case "$1" in
        --bandwidth) BANDWIDTH="${2:?--bandwidth needs a value}"; shift 2 ;;
        --rtt) RTT="${2:?--rtt needs a value}"; shift 2 ;;
        --max) MAX="${2:?--max needs a value}"; shift 2 ;;
        --send-only) SEND_ONLY=1; shift ;;
        --cc) CC="${2:?--cc needs a name, for example bbr}"; shift 2 ;;
        --cc-only) CC_ONLY=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --conf-dir) CONF_DIR="${2:?--conf-dir needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done
if [ -n "$CC" ]; then
    [[ "$CC" =~ ^[a-z0-9_]+$ ]] || die "cannot read congestion control '$CC' (a name such as bbr or cubic)"
    [ "$OS" = Linux ] || die "--cc works on Linux only"
fi
[ "$CC_ONLY" != 1 ] || [ -n "$CC" ] || die "--cc-only needs --cc"
"cmd_$COMMAND"
