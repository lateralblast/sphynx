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
# scp and sftp are next to ssh unless told otherwise
BASE_SCP="${BASELINE_SCP:-$(dirname "$BASE_SSH")/scp}"
BASE_SFTP="${BASELINE_SFTP:-$(dirname "$BASE_SSH")/sftp}"
HPN_SCP="${HPN_SCP:-$(dirname "$HPN_SSH")/hpnscp}"
HPN_SFTP="${HPN_SFTP:-$(dirname "$HPN_SSH")/hpnsftp}"
# the sftp subsystem of each server
BASE_SFTP_SERVER="${BASELINE_SFTP_SERVER:-$BASELINE_PREFIX/libexec/sftp-server}"
HPN_SFTP_SERVER="${HPN_SFTP_SERVER:-/usr/lib/hpnssh/hpnsftp-server}"

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

# parse_cond COND: sets COND_MS (round trip), COND_LOSS (percent, per direction)
# and COND_JIT (ms, per direction). A condition is lan or wanNN, optionally
# followed by _lossP and _jitJ: lan, wan50, wan50_loss0.5, wan50_loss0.1_jit5.
parse_cond() {
    [[ "$1" =~ ^(lan|wan([0-9]+))(_loss([0-9]+(\.[0-9]+)?))?(_jit([0-9]+))?$ ]] \
        || die "unknown condition '$1' (use lan or wanNN, then optionally _lossPERCENT and _jitMS, for example wan50_loss0.5_jit5)"
    COND_MS="${BASH_REMATCH[2]:-0}"
    COND_LOSS="${BASH_REMATCH[4]:-}"
    COND_JIT="${BASH_REMATCH[7]:-}"
    if [ -n "$COND_JIT" ] && [ "$COND_MS" -eq 0 ]; then
        die "jitter needs a delay: use wanNN_jitMS, not '$1'"
    fi
    return 0
}

# netem_args COND: the netem arguments for one direction of the link, empty for
# an unshaped LAN. Delay is half the round trip, and loss and jitter apply in
# each direction, so a packet crosses the path with that loss once each way.
netem_args() {
    parse_cond "$1"
    local -a a=()
    if [ "$COND_MS" -gt 0 ]; then
        a+=(delay "$((COND_MS / 2))ms")
        [ -z "$COND_JIT" ] || a+=("${COND_JIT}ms")
    fi
    [ -z "$COND_LOSS" ] || a+=(loss "${COND_LOSS}%")
    [ "$COND_MS" -eq 0 ] || a+=(rate "$RATE" limit 100000)
    echo "${a[*]:-}"
}

# net_cond COND: shape both directions of the link
net_cond() {
    local args ns dev pair
    args="$(netem_args "$1")"
    for pair in "$SRV_NS pvs" "$CLI_NS pvc"; do
        read -r ns dev <<<"$pair"
        sudo ip netns exec "$ns" tc qdisc del dev "$dev" root 2>/dev/null || true
    done
    [ -n "$args" ] || return 0
    for pair in "$SRV_NS pvs" "$CLI_NS pvc"; do
        read -r ns dev <<<"$pair"
        # the arguments are separate words on purpose
        # shellcheck disable=SC2086
        sudo ip netns exec "$ns" tc qdisc add dev "$dev" root netem $args
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
    local name port sftp_server out
    for name in base hpn; do
        port=$BASE_PORT; sftp_server=$BASE_SFTP_SERVER
        [ "$name" = hpn ] && { port=$HPN_PORT; sftp_server=$HPN_SFTP_SERVER; }
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
Subsystem sftp $sftp_server
CFG
        # a build without PAM (a build tree rather than the package) rejects UsePAM
        local bin="$BASE_SSHD"; [ "$name" = hpn ] && bin="$HPN_SSHD"
        if [ -x "$bin" ] && out="$("$bin" -t -f "$WORK/sshd_$name.conf" 2>&1)" ; then :
        elif grep -q 'Unsupported option UsePAM' <<<"${out:-}"; then
            sed -i '/^UsePAM no$/d' "$WORK/sshd_$name.conf"
        fi
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

# check_tool_binaries TOOLS: the scp and sftp programs and servers, when used
check_tool_binaries() {
    local f
    case ",$1," in *,scp,*) for f in "$BASE_SCP" "$HPN_SCP"; do
        [ -x "$f" ] || die "$f not found (set BASELINE_SCP and HPN_SCP)"; done ;; esac
    case ",$1," in *,sftp,*) for f in "$BASE_SFTP" "$HPN_SFTP" "$BASE_SFTP_SERVER" "$HPN_SFTP_SERVER"; do
        [ -x "$f" ] || die "$f not found (set BASELINE_SFTP, HPN_SFTP, BASELINE_SFTP_SERVER and HPN_SFTP_SERVER)"; done ;; esac
}

# server_restart NAME THREADS: restart one server with the configs as they are
# now. THREADS is "default" or a number, passed to the server as
# SSH_CIPHER_THREADS: the AES-CTR cipher reads it when a connection starts, so a
# server only changes its thread count when it is restarted.
server_restart() {
    local name="$1" threads="${2:-default}" bin pid
    bin="$BASE_SSHD"; [ "$name" = hpn ] && bin="$HPN_SSHD"
    pid="$(sudo cat "$WORK/sshd_$name.pid" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
        sudo kill "$pid" 2>/dev/null || true
        for _ in $(seq 50); do sudo kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    fi
    local -a e=(-u SSH_CIPHER_THREADS)
    [[ "$threads" =~ ^[0-9]+$ ]] && e=("SSH_CIPHER_THREADS=$threads")
    sudo ip netns exec "$SRV_NS" env "${e[@]}" "$bin" -f "$WORK/sshd_$name.conf" -E "$WORK/sshd_$name.log"
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
# client_run TOOL CLIENT SERVER CIPHER MB
#   TOOL ssh | scp | sftp; CLIENT and SERVER base | hpn; MB 0 measures connecting.
# prints: elapsed user sys (seconds; user and sys include the dd that feeds the
# ssh pipe, and the bash that feeds sftp)
client_run() {
    local tool="$1" client="$2" server="$3" cipher="$4" mb="$5"
    local ssh_bin scp_bin sftp_bin port tf file
    case "$client" in
        base) ssh_bin="$BASE_SSH"; scp_bin="$BASE_SCP"; sftp_bin="$BASE_SFTP" ;;
        hpn)  ssh_bin="$HPN_SSH";  scp_bin="$HPN_SCP";  sftp_bin="$HPN_SFTP" ;;
        *) exit 2 ;;
    esac
    case "$server" in
        base) port=$BASE_PORT ;;
        hpn)  port=$HPN_PORT ;;
        *) exit 2 ;;
    esac
    local -a common=(-F /dev/null -i "$WORK/id")
    [ "$cipher" = default ] || common+=(-c "$cipher")
    common+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
             -o BatchMode=yes -o LogLevel=ERROR)
    tf="$(mktemp)"
    file="$WORK/data-$mb"
    case "$tool" in
    ssh)
        if [ "$mb" = 0 ]; then
            /usr/bin/time -f "%e %U %S" -o "$tf" "$ssh_bin" -p "$port" "${common[@]}" "$SRV_IP" true
        else
            # the pipeline is for the inner shell, so the single quotes are meant
            # shellcheck disable=SC2016
            /usr/bin/time -f "%e %U %S" -o "$tf" bash -c \
                'dd if=/dev/zero bs=1M count="$0" 2>/dev/null | "$@" "cat > /dev/null"' \
                "$mb" "$ssh_bin" -p "$port" "${common[@]}" "$SRV_IP"
        fi ;;
    scp)
        # PERF_SCP_OPTS is a list of extra scp options, split into words on purpose
        # shellcheck disable=SC2086
        /usr/bin/time -f "%e %U %S" -o "$tf" "$scp_bin" -S "$ssh_bin" -P "$port" \
            ${PERF_SCP_OPTS:-} "${common[@]}" "$file" "$SRV_IP:/dev/null" ;;
    sftp)
        # the pipeline is for the inner shell, so the single quotes are meant.
        # PERF_SFTP_OPTS is a list of extra sftp options, split into words on purpose
        # shellcheck disable=SC2016,SC2086
        /usr/bin/time -f "%e %U %S" -o "$tf" bash -c \
            'printf "put %s /dev/null\n" "$0" | "$@"' \
            "$file" "$sftp_bin" -S "$ssh_bin" -P "$port" ${PERF_SFTP_OPTS:-} "${common[@]}" -b - "$SRV_IP" ;;
    *) exit 2 ;;
    esac
    cat "$tf"
    rm -f "$tf"
}

# ---------------------------------------------------------------- run

run_usage() {
    cat <<USAGE
usage: tools/perf/perf.sh run [options]

  --conds LIST     comma list of conditions. lan is unshaped, wanNN is an NN ms round
                   trip, and either may be followed by _lossPERCENT and _jitMS (loss
                   and jitter apply in each direction; jitter needs a wanNN), for
                   example wan50_loss0.5 or wan50_loss0.1_jit5.
                   Default: lan,wan50,wan100
  --tools LIST     comma list of ssh, scp and sftp. Default: ssh
  --pairs LIST     comma list of CLIENT:SERVER, each base (OpenSSH) or hpn (HPN-SSH).
                   hpn:base is an HPN-SSH client against an OpenSSH server.
                   Default: base:base,hpn:hpn
  --sftp-opts STR  extra options for sftp, for example "-B 262144 -R 128" (the request size
                   and the number of requests in flight). It is part of the tool name in
                   the CSV, as sftp(-B_262144_-R_128).
  --scp-opts STR   extra options for scp, for example "-X nrequests=128 -X copy_buffer=262144".
  --threads LIST   comma list of SSH_CIPHER_THREADS values, each a number or "default"
                   (unset). It only affects the AES-CTR ciphers (*-ctr) when HPN-SSH is
                   on either side; every other case runs once. Default: default
  --ciphers LIST   comma list; "default" means each side's own.
                   Default: default,chacha20-poly1305@openssh.com,aes256-ctr,aes256-gcm@openssh.com
  --runs N         runs per case (default 3)
  --mb LIST        data sizes in MB as cond=MB pairs. Default: lan=2048,wan50=512,wan100=384,
                   and 512 for any other wanNN. A condition with loss or jitter uses the
                   size of its wanNN unless it has its own.
  --wmem "A B C"   set net.ipv4.tcp_wmem inside the test namespaces (not on the host).
  --rmem "A B C"   set net.ipv4.tcp_rmem inside the test namespaces (not on the host).
                   Without these, each run starts from the host's current values.
  --out FILE       CSV to write (default build/perf/results.csv)
  --dry-run        print the cases and the netem settings, and run nothing (no sudo)

The link rate is 1gbit unless PERF_RATE is set (for example PERF_RATE=100mbit).
scp and sftp send a file of the given size from $WORK/data-MB, which is removed after the run.
USAGE
}

# the thread count only matters for the AES-CTR ciphers, when HPN-SSH is on either side
thread_sensitive() { # client server cipher
    { [ "$1" = hpn ] || [ "$2" = hpn ]; } && [[ "$3" == *-ctr ]]
}

make_data() { # MB: a file of zeros, made once
    local f="$WORK/data-$1"
    if [ "$1" = 0 ]; then : >"$f"; return 0; fi
    [ "$(wc -c <"$f" 2>/dev/null || echo 0)" -eq $(($1 * 1048576)) ] \
        || dd if=/dev/zero of="$f" bs=1M count="$1" 2>/dev/null
}

run_matrix() {
    local conds=lan,wan50,wan100 tools=ssh pairs=base:base,hpn:hpn threads=default
    local ciphers=default,chacha20-poly1305@openssh.com,aes256-ctr,aes256-gcm@openssh.com
    local runs=3 out="$WORK/results.csv" wmem="" rmem="" dry=0 sftp_opts="" scp_opts=""
    local -A mb=([lan]=2048 [wan50]=512 [wan100]=384)
    local pair
    while [ $# -gt 0 ]; do
        case "$1" in
            --conds) conds="${2:?}"; shift 2 ;;
            --tools) tools="${2:?}"; shift 2 ;;
            --pairs) pairs="${2:?}"; shift 2 ;;
            --threads) threads="${2:?}"; shift 2 ;;
            --sftp-opts) sftp_opts="${2:?}"; shift 2 ;;
            --scp-opts) scp_opts="${2:?}"; shift 2 ;;
            --ciphers) ciphers="${2:?}"; shift 2 ;;
            --runs) runs="${2:?}"; shift 2 ;;
            --mb) IFS=, read -ra mbpairs <<<"${2:?}"
                  for pair in "${mbpairs[@]}"; do mb["${pair%%=*}"]="${pair#*=}"; done
                  shift 2 ;;
            --wmem) wmem="${2:?}"; shift 2 ;;
            --rmem) rmem="${2:?}"; shift 2 ;;
            --out) out="${2:?}"; shift 2 ;;
            --dry-run) dry=1; shift ;;
            -h|--help) run_usage; return 0 ;;
            *) die "unknown option for run: $1" ;;
        esac
    done
    [[ "$runs" =~ ^[1-9][0-9]*$ ]] || die "--runs must be a positive integer"

    local -a cond_list cipher_list tool_list pair_list thread_list
    IFS=, read -ra cond_list <<<"$conds"
    IFS=, read -ra cipher_list <<<"$ciphers"
    IFS=, read -ra tool_list <<<"$tools"
    IFS=, read -ra pair_list <<<"$pairs"
    IFS=, read -ra thread_list <<<"$threads"
    local t
    for t in "${tool_list[@]}"; do
        case "$t" in ssh|scp|sftp) ;; *) die "unknown tool '$t' (use ssh, scp or sftp)" ;; esac
    done
    for t in "${pair_list[@]}"; do
        case "$t" in base:base|base:hpn|hpn:base|hpn:hpn) ;; *) die "unknown pair '$t' (use base:base, hpn:hpn, hpn:base or base:hpn)" ;; esac
    done
    for t in "${thread_list[@]}"; do
        [[ "$t" =~ ^([1-9][0-9]*|default)$ ]] || die "bad --threads value '$t' (a number or default)"
    done
    for t in "${cond_list[@]}"; do parse_cond "$t"; done

    if [ "$dry" = 0 ]; then
        net_exists || die "the test network is not up; run: tools/perf/perf.sh setup"
        check_tool_binaries "$tools"
        # Start every run from the host's own TCP limits. The namespaces keep a
        # setting from an earlier run otherwise, and a result would then depend on
        # what was run before it.
        net_sysctl net.ipv4.tcp_wmem "${wmem:-$(sysctl -n net.ipv4.tcp_wmem)}"
        net_sysctl net.ipv4.tcp_rmem "${rmem:-$(sysctl -n net.ipv4.tcp_rmem)}"
        # the configs may be older than this script (the sftp subsystem line)
        write_configs
        server_restart base
        mkdir -p "$(dirname "$out")"
        echo "impl,cipher,cond,run,mb,elapsed,user,sys,tool,server,threads" >"$out"
    fi

    local user cond cipher size client server thr ti tool label e u s
    user="$(id -un)"

    # the tool's name in the CSV: the extra options are part of it
    tool_label() {
        local o=""
        case "$1" in sftp) o="$sftp_opts" ;; scp) o="$scp_opts" ;; esac
        if [ -n "$o" ]; then echo "$1(${o// /_})"; else echo "$1"; fi
    }

    one() { # tool client server cipher mb threads -> "elapsed user sys"
        local -a envargs=(-u SSH_CIPHER_THREADS)
        [[ "$6" =~ ^[0-9]+$ ]] && envargs=("SSH_CIPHER_THREADS=$6")
        timeout 900 sudo ip netns exec "$CLI_NS" sudo -u "$user" env "${envargs[@]}" \
            "BASELINE_PREFIX=$BASELINE_PREFIX" "BASELINE_SSH=$BASE_SSH" "BASELINE_SCP=$BASE_SCP" \
            "BASELINE_SFTP=$BASE_SFTP" "HPN_SSH=$HPN_SSH" "HPN_SCP=$HPN_SCP" "HPN_SFTP=$HPN_SFTP" \
            "PERF_SFTP_OPTS=$sftp_opts" "PERF_SCP_OPTS=$scp_opts" \
            "PERF_WORK=$WORK" "$SELF" _client "$@" | tail -1
    }

    # measure TOOL COND CIPHER MB THREADS ENTRY...: run one case for each ENTRY
    # (client:server:threads-label), alternating the entries within every run so
    # that drift in the machine affects them all alike. CIPHER "handshake" times
    # connecting with the default cipher and no data.
    measure() {
        local tool="$1" cond="$2" cipher="$3" size="$4" thr="$5" entry c sv lab run use
        shift 5
        use="$cipher"; [ "$cipher" != handshake ] || use=default
        if [ "$dry" = 1 ]; then
            for entry in "$@"; do
                IFS=: read -r c sv lab <<<"$entry"
                echo "case tool=$(tool_label "$tool") client=$c server=$sv cipher=$cipher cond=$cond mb=$size threads=$lab runs=$runs"
            done
            return 0
        fi
        log "$cond: $tool $cipher ($size MB x $runs) $*"
        for run in $(seq "$runs"); do
            for entry in "$@"; do
                IFS=: read -r c sv lab <<<"$entry"
                e="" u="" s=""
                read -r e u s < <(one "$tool" "$c" "$sv" "$use" "$size" "$thr" || true)
                [ -n "$e" ] || echo "perf: warning: $tool $c:$sv $cipher $cond failed (run $run)" >&2
                echo "$c,$cipher,$cond,$run,$size,${e:-nan},${u:-nan},${s:-nan},$(tool_label "$tool"),$sv,$lab" >>"$out"
            done
        done
    }

    if [ "$dry" = 0 ] && { [[ ",$tools," == *,scp,* ]] || [[ ",$tools," == *,sftp,* ]]; }; then
        make_data 0
        for cond in "${cond_list[@]}"; do
            make_data "${mb[$cond]:-${mb[${cond%%_*}]:-512}}"
        done
    fi

    local -a entries
    ti=0
    for thr in "${thread_list[@]}"; do
        if [ "$dry" = 1 ]; then echo "hpn server SSH_CIPHER_THREADS=$thr"
        else server_restart hpn "$thr"; fi
        for cond in "${cond_list[@]}"; do
            if [ "$dry" = 1 ]; then echo "cond $cond: netem $(netem_args "$cond")"
            else net_cond "$cond"; fi
            size="${mb[$cond]:-${mb[${cond%%_*}]:-512}}"
            for tool in "${tool_list[@]}"; do
                if [ "$ti" = 0 ]; then
                    # connecting does not depend on the thread count, so it is timed once
                    entries=()
                    for pair in "${pair_list[@]}"; do entries+=("${pair%%:*}:${pair##*:}:-"); done
                    measure "$tool" "$cond" handshake 0 default "${entries[@]}"
                fi
                for cipher in "${cipher_list[@]}"; do
                    entries=()
                    for pair in "${pair_list[@]}"; do
                        client="${pair%%:*}"; server="${pair##*:}"
                        if thread_sensitive "$client" "$server" "$cipher"; then label="$thr"
                        elif [ "$ti" = 0 ]; then label=-
                        else continue; fi
                        entries+=("$client:$server:$label")
                    done
                    [ ${#entries[@]} -eq 0 ] || measure "$tool" "$cond" "$cipher" "$size" "$thr" "${entries[@]}"
                done
            done
        done
        ti=$((ti + 1))
    done
    if [ "$dry" = 0 ]; then
        net_cond lan
        server_restart hpn default
        rm -f "$WORK"/data-*
        log "wrote $out"
    fi
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
