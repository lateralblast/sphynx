#!/usr/bin/env bash
# Raise the TCP buffer maximums so HPN-SSH can use long, fast network paths.
#
#   tools/tune-tcp.sh show      what would change (needs no privileges)
#   tools/tune-tcp.sh apply     set the new maximums now, until the next reboot
#   tools/tune-tcp.sh persist   apply, and keep them across reboots
#   tools/tune-tcp.sh revert    put back what persist replaced
#
# It only ever raises a maximum, never lowers one, and changes nothing else.
# See "Tuning the TCP stack" in the README.
set -euo pipefail

CONF_NAME=99-hpn-ssh-tcp.conf
CONF_DIR=/etc/sysctl.d
DEFAULT_MAX=33554432   # 32 MiB, covers 1 Gbit/s up to about 200 ms
MIB=1048576

die() { echo "tune-tcp: error: $*" >&2; exit 1; }

usage() {
    cat <<USAGE
usage: tools/tune-tcp.sh <command> [options]

commands:
  show      show the current values and what apply would change
  apply     set the new maximums now; lasts until the next reboot
  persist   apply, and write $CONF_DIR/$CONF_NAME so they survive a reboot
  revert    restore the values persist replaced, and remove that file

options:
  --bandwidth RATE   link speed, for example 1gbit or 100mbit (units: kbit, mbit, gbit, tbit)
  --rtt TIME         round-trip time, for example 100ms or 0.1s
  --max BYTES        set the maximum directly; overrides --bandwidth and --rtt
  --send-only        change only net.ipv4.tcp_wmem, not tcp_rmem
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

[ -r /proc/sys/net/ipv4/tcp_wmem ] || die "this needs Linux (no /proc/sys/net/ipv4/tcp_wmem)"

# ---------------------------------------------------------------- parsing

rate_to_bps() {
    local v="${1,,}"
    [[ "$v" =~ ^([0-9]+(\.[0-9]+)?)(bit|kbit|mbit|gbit|tbit)?$ ]] || die "cannot read bandwidth '$1' (try 1gbit or 100mbit)"
    awk -v n="${BASH_REMATCH[1]}" -v u="${BASH_REMATCH[3]:-bit}" \
        'BEGIN{m["bit"]=1;m["kbit"]=1e3;m["mbit"]=1e6;m["gbit"]=1e9;m["tbit"]=1e12; printf "%.0f", n*m[u]}'
}

time_to_seconds() {
    local v="${1,,}"
    [[ "$v" =~ ^([0-9]+(\.[0-9]+)?)(us|ms|s)?$ ]] || die "cannot read round-trip time '$1' (try 100ms or 0.1s)"
    awk -v n="${BASH_REMATCH[1]}" -v u="${BASH_REMATCH[3]:-ms}" \
        'BEGIN{m["us"]=1e-6;m["ms"]=1e-3;m["s"]=1; printf "%.9f", n*m[u]}'
}

# ---------------------------------------------------------------- state

BANDWIDTH="" RTT="" MAX="" SEND_ONLY=0 ASSUME_YES=0
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
}

# plan: for each key, "key min def curmax newmax"
PLAN=()
CHANGES=0
build_plan() {
    local key min def max new
    PLAN=(); CHANGES=0
    for key in net.ipv4.tcp_wmem net.ipv4.tcp_rmem; do
        [ "$key" = net.ipv4.tcp_rmem ] && [ "$SEND_ONLY" = 1 ] && continue
        read -r min def max < <(sysctl -n "$key")
        new="$max"
        if [ "$TARGET" -gt "$max" ]; then new="$TARGET"; CHANGES=$((CHANGES + 1)); fi
        PLAN+=("$key $min $def $max $new")
    done
}

print_plan() {
    local line key min def max new
    echo "target maximum: $TARGET bytes ($((TARGET / MIB)) MiB), $TARGET_NOTE"
    for line in "${PLAN[@]}"; do
        read -r key min def max new <<<"$line"
        if [ "$new" != "$max" ]; then
            printf '  %-18s %s %s %s  ->  %s %s %s\n' "$key" "$min" "$def" "$max" "$min" "$def" "$new"
        else
            printf '  %-18s %s %s %s  (already at least that large, left alone)\n' "$key" "$min" "$def" "$max"
        fi
    done
}

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    [ -t 0 ] || die "not a terminal; pass --yes to go ahead"
    echo "This changes system-wide TCP settings, for every program on this machine."
    read -r -p "Proceed? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "nothing changed"; exit 1; }
}

apply_plan() {
    local line key min def max new
    for line in "${PLAN[@]}"; do
        read -r key min def max new <<<"$line"
        [ "$new" != "$max" ] || continue
        as_root sysctl -w "$key=$min $def $new" >/dev/null
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
    local line key min def max new
    echo "to put the old values back now:"
    for line in "${PLAN[@]}"; do
        read -r key min def max new <<<"$line"
        [ "$new" != "$max" ] && echo "  sudo sysctl -w $key=\"$min $def $max\""
    done
    return 0
}

cmd_persist() {
    compute_target; build_plan; print_plan
    local file; file="$(conf_file)"
    [ "$CHANGES" -gt 0 ] || [ -f "$file" ] || { echo "nothing to change"; return 0; }
    confirm
    # keep the values from before the first persist, so revert goes back to them
    local -A prev=()
    local line key min def max new
    if [ -f "$file" ]; then
        while read -r key min def max; do
            prev["$key"]="$min $def $max"
        done < <(previous_values "$file")
    fi
    local tmp; tmp="$(mktemp)"
    {
        echo "# Written by tools/tune-tcp.sh from sphynx on $(date +%Y-%m-%d)."
        echo "# Larger TCP buffer maximums for HPN-SSH on long, fast paths."
        echo "# Undo with: tools/tune-tcp.sh revert"
        for line in "${PLAN[@]}"; do
            read -r key min def max new <<<"$line"
            echo "$key = $min $def $new"
        done
        echo "#"
        echo "# Values before this file, used by 'tune-tcp.sh revert':"
        for line in "${PLAN[@]}"; do
            read -r key min def max new <<<"$line"
            echo "# previous $key = ${prev[$key]:-$min $def $max}"
        done
    } >"$tmp"
    as_root mkdir -p "$CONF_DIR"
    as_root install -m 644 "$tmp" "$file"
    rm -f "$tmp"
    as_root sysctl -p "$file" >/dev/null
    echo "wrote $file and applied it."
}

cmd_revert() {
    local file; file="$(conf_file)"
    [ -f "$file" ] || die "$file does not exist, so there is nothing to revert. For a setting made with 'apply', use the sysctl -w commands it printed, or reboot."
    local key min def max restored=0
    while read -r key min def max; do
        as_root sysctl -w "$key=$min $def $max" >/dev/null
        restored=$((restored + 1))
    done < <(previous_values "$file")
    [ "$restored" -gt 0 ] || die "$file has no recorded previous values; remove it yourself and reboot"
    as_root rm -f "$file"
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
        --yes|-y) ASSUME_YES=1; shift ;;
        --conf-dir) CONF_DIR="${2:?--conf-dir needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done
"cmd_$COMMAND"
