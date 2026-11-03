#!/usr/bin/env bash
# Compare OpenSSH and HPN-SSH over an emulated network.
#
#   tools/perf/perf.sh setup       build the test network and start both servers
#   tools/perf/perf.sh run [opts]  run the comparison, write a CSV
#   tools/perf/perf.sh analyze CSV summarise a CSV
#   tools/perf/perf.sh teardown    stop the servers and remove the test network
#
# See tools/perf/README.md for what it needs and what it changes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="$ROOT/tools/perf/perf.sh"
WORK="${PERF_WORK:-$ROOT/build/perf}"

BASELINE_PREFIX="${BASELINE_PREFIX:-$WORK/baseline/inst}"
BASE_SSH="${BASELINE_SSH:-$BASELINE_PREFIX/bin/ssh}"
BASE_SSHD="${BASELINE_SSHD:-$BASELINE_PREFIX/sbin/sshd}"
HPN_SSH="${HPN_SSH:-/usr/bin/hpnssh}"
HPN_SSHD="${HPN_SSHD:-/usr/sbin/hpnsshd}"

SRV_NS=perf_srv
CLI_NS=perf_cli
SRV_IP=10.99.0.1
CLI_IP=10.99.0.2
BASE_PORT=2201
HPN_PORT=2202
RATE="${PERF_RATE:-1gbit}"

die() { echo "perf: error: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

# ---------------------------------------------------------------- network

net_exists() { sudo ip netns list | grep -q "^$SRV_NS\b"; }

net_up() {
    if net_exists; then return 0; fi
    sudo ip netns add "$SRV_NS"
    sudo ip netns add "$CLI_NS"
    sudo ip link add pvs type veth peer name pvc
    sudo ip link set pvs netns "$SRV_NS"
    sudo ip link set pvc netns "$CLI_NS"
    sudo ip -n "$SRV_NS" addr add "$SRV_IP/24" dev pvs
    sudo ip -n "$CLI_NS" addr add "$CLI_IP/24" dev pvc
    sudo ip -n "$SRV_NS" link set lo up
    sudo ip -n "$CLI_NS" link set lo up
    sudo ip -n "$SRV_NS" link set pvs up
    sudo ip -n "$CLI_NS" link set pvc up
}

net_down() {
    sudo ip netns del "$SRV_NS" 2>/dev/null || true
    sudo ip netns del "$CLI_NS" 2>/dev/null || true
}

# net_cond lan | wanNN: NN ms round trip (half in each direction), at $RATE
net_cond() {
    local cond="$1" ms half ns dev
    for pair in "$SRV_NS pvs" "$CLI_NS pvc"; do
        read -r ns dev <<<"$pair"
        sudo ip netns exec "$ns" tc qdisc del dev "$dev" root 2>/dev/null || true
    done
    [ "$cond" = lan ] && return 0
    [[ "$cond" =~ ^wan([0-9]+)$ ]] || die "unknown condition '$cond' (use lan or wanNN, for example wan50)"
    ms="${BASH_REMATCH[1]}"
    half=$((ms / 2))
    for pair in "$SRV_NS pvs" "$CLI_NS pvc"; do
        read -r ns dev <<<"$pair"
        sudo ip netns exec "$ns" tc qdisc add dev "$dev" root netem \
            delay "${half}ms" rate "$RATE" limit 100000
    done
}

# net_sysctl key value: set inside both namespaces only, never on the host
net_sysctl() {
    local ns
    for ns in "$SRV_NS" "$CLI_NS"; do
        sudo ip netns exec "$ns" sysctl -w "$1=$2" >/dev/null
    done
}

# ---------------------------------------------------------------- servers

write_configs() {
    mkdir -p "$WORK"
    [ -f "$WORK/id" ] || ssh-keygen -q -t ed25519 -N "" -f "$WORK/id"
    [ -f "$WORK/host_key" ] || ssh-keygen -q -t ed25519 -N "" -f "$WORK/host_key"
    local name port
    for name in base hpn; do
        port=$BASE_PORT; [ "$name" = hpn ] && port=$HPN_PORT
        cat >"$WORK/sshd_$name.conf" <<CFG
Port $port
ListenAddress $SRV_IP
HostKey $WORK/host_key
AuthorizedKeysFile $WORK/id.pub
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $WORK/sshd_$name.pid
CFG
    done
}

check_binaries() {
    local f
    for f in "$BASE_SSH" "$BASE_SSHD" "$HPN_SSH" "$HPN_SSHD"; do
        [ -x "$f" ] || die "$f not found. See tools/perf/README.md (set BASELINE_PREFIX, HPN_SSH and HPN_SSHD)."
    done
    command -v tc >/dev/null || die "tc not found (install iproute2)"
    [ -x /usr/bin/time ] || die "/usr/bin/time not found (install the time package)"
}

servers_start() {
    check_binaries
    write_configs
    sudo ip netns exec "$SRV_NS" "$BASE_SSHD" -f "$WORK/sshd_base.conf" -E "$WORK/sshd_base.log"
    sudo ip netns exec "$SRV_NS" "$HPN_SSHD" -f "$WORK/sshd_hpn.conf" -E "$WORK/sshd_hpn.log"
}

servers_stop() {
    local f pid
    for f in "$WORK/sshd_base.pid" "$WORK/sshd_hpn.pid"; do
        pid="$(sudo cat "$f" 2>/dev/null || true)"
        [ -n "$pid" ] && sudo kill "$pid" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------- client

# Runs inside the client namespace, as the invoking user.
# prints: elapsed user sys (seconds; user and sys include the dd that feeds the pipe)
client_run() {
    local impl="$1" cipher="$2" mb="$3" bin port tf
    case "$impl" in
        base) bin="$BASE_SSH"; port=$BASE_PORT ;;
        hpn)  bin="$HPN_SSH";  port=$HPN_PORT ;;
        *) exit 2 ;;
    esac
    local -a args=(-F /dev/null -p "$port" -i "$WORK/id")
    [ "$cipher" != default ] && args+=(-c "$cipher")
    args+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
           -o BatchMode=yes -o LogLevel=ERROR "$SRV_IP")
    tf="$(mktemp)"
    if [ "$mb" = 0 ]; then
        /usr/bin/time -f "%e %U %S" -o "$tf" "$bin" "${args[@]}" true
    else
        # the pipeline is for the inner shell, so the single quotes are meant
        # shellcheck disable=SC2016
        /usr/bin/time -f "%e %U %S" -o "$tf" bash -c \
            'dd if=/dev/zero bs=1M count="$0" 2>/dev/null | "$@" "cat > /dev/null"' \
            "$mb" "$bin" "${args[@]}"
    fi
    cat "$tf"
    rm -f "$tf"
}

# ---------------------------------------------------------------- run

run_usage() {
    cat <<USAGE
usage: tools/perf/perf.sh run [options]

  --conds LIST     comma list of lan, wanNN (NN ms round trip). Default: lan,wan50,wan100
  --ciphers LIST   comma list; "default" means each side's own.
                   Default: default,chacha20-poly1305@openssh.com,aes256-ctr,aes256-gcm@openssh.com
  --runs N         runs per case (default 3)
  --mb LIST        data sizes in MB as cond=MB pairs. Default: lan=2048,wan50=512,wan100=384,
                   and 512 for any other wanNN
  --wmem "A B C"   set net.ipv4.tcp_wmem inside the test namespaces (not on the host).
  --rmem "A B C"   set net.ipv4.tcp_rmem inside the test namespaces (not on the host).
                   Without these, each run starts from the host's current values.
  --out FILE       CSV to write (default build/perf/results.csv)

The link rate is 1gbit unless PERF_RATE is set (for example PERF_RATE=100mbit).
USAGE
}

run_matrix() {
    local conds=lan,wan50,wan100
    local ciphers=default,chacha20-poly1305@openssh.com,aes256-ctr,aes256-gcm@openssh.com
    local runs=3 out="$WORK/results.csv" wmem="" rmem=""
    local -A mb=([lan]=2048 [wan50]=512 [wan100]=384)
    local pair
    while [ $# -gt 0 ]; do
        case "$1" in
            --conds) conds="${2:?}"; shift 2 ;;
            --ciphers) ciphers="${2:?}"; shift 2 ;;
            --runs) runs="${2:?}"; shift 2 ;;
            --mb) IFS=, read -ra pairs <<<"${2:?}"
                  for pair in "${pairs[@]}"; do mb["${pair%%=*}"]="${pair#*=}"; done
                  shift 2 ;;
            --wmem) wmem="${2:?}"; shift 2 ;;
            --rmem) rmem="${2:?}"; shift 2 ;;
            --out) out="${2:?}"; shift 2 ;;
            -h|--help) run_usage; return 0 ;;
            *) die "unknown option for run: $1" ;;
        esac
    done
    [[ "$runs" =~ ^[1-9][0-9]*$ ]] || die "--runs must be a positive integer"
    net_exists || die "the test network is not up; run: tools/perf/perf.sh setup"

    # Start every run from the host's own TCP limits. The namespaces keep a
    # setting from an earlier run otherwise, and a result would then depend on
    # what was run before it.
    net_sysctl net.ipv4.tcp_wmem "${wmem:-$(sysctl -n net.ipv4.tcp_wmem)}"
    net_sysctl net.ipv4.tcp_rmem "${rmem:-$(sysctl -n net.ipv4.tcp_rmem)}"

    local -a cond_list cipher_list
    IFS=, read -ra cond_list <<<"$conds"
    IFS=, read -ra cipher_list <<<"$ciphers"
    local user cond cipher run impl size e u s
    user="$(id -un)"
    mkdir -p "$(dirname "$out")"
    echo "impl,cipher,cond,run,mb,elapsed,user,sys" >"$out"

    one() { # impl cipher mb -> "elapsed user sys"
        timeout 900 sudo ip netns exec "$CLI_NS" sudo -u "$user" env \
            "BASELINE_PREFIX=$BASELINE_PREFIX" "BASELINE_SSH=$BASE_SSH" "HPN_SSH=$HPN_SSH" \
            "PERF_WORK=$WORK" "$SELF" _client "$@" | tail -1
    }

    for cond in "${cond_list[@]}"; do
        net_cond "$cond"
        size="${mb[$cond]:-512}"
        log "$cond: connect time"
        for run in $(seq "$runs"); do for impl in base hpn; do
            read -r e u s < <(one "$impl" default 0 || true)
            echo "$impl,handshake,$cond,$run,0,${e:-nan},${u:-nan},${s:-nan}" >>"$out"
        done; done
        for cipher in "${cipher_list[@]}"; do
            log "$cond: $cipher ($size MB x $runs)"
            for run in $(seq "$runs"); do for impl in base hpn; do
                read -r e u s < <(one "$impl" "$cipher" "$size" || true)
                echo "$impl,$cipher,$cond,$run,$size,${e:-nan},${u:-nan},${s:-nan}" >>"$out"
            done; done
        done
    done
    net_cond lan
    log "wrote $out"
}

# ---------------------------------------------------------------- main

case "${1:-}" in
    setup)    net_up; servers_start; log "test network and servers are up" ;;
    run)      shift; run_matrix "$@" ;;
    analyze)  shift; exec python3 -B "$ROOT/tools/perf/analyze.py" "$@" ;;
    teardown) servers_stop; net_down; log "test network removed" ;;
    _client)  shift; client_run "$@" ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
