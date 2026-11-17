#!/usr/bin/env bash
# Checks that need a running hpnsshd, made against a built tree without installing it.
#
# usage: tests/daemon-checks.sh <build-tree>
#
# It starts hpnsshd from the tree as the current user on a free loopback port, with a throwaway key and
# configuration, and points it at the tree's hpnsshd-session and hpnsshd-auth. Nothing is installed and
# nothing outside a temporary directory is written. Exits non-zero if a check fails.
set -euo pipefail

TREE="$(cd "${1:?usage: tests/daemon-checks.sh <build-tree>}" && pwd)"
for f in hpnssh hpnsshd hpnsshd-session hpnsshd-auth; do
    [ -x "$TREE/$f" ] || { echo "daemon-checks: $TREE/$f is not built" >&2; exit 2; }
done

D="$(mktemp -d)"
PORT=$((20000 + RANDOM % 20000))
trap '[ -s "$D/sshd.pid" ] && kill "$(cat "$D/sshd.pid")" 2>/dev/null; rm -rf "$D"' EXIT

fail() { echo "FAIL - $*" >&2; [ ! -s "$D/sshd.log" ] || tail -n 15 "$D/sshd.log" >&2; exit 1; }
pass() { echo "ok   - $*"; }

ssh-keygen -q -t ed25519 -N '' -f "$D/key"
ssh-keygen -q -t ed25519 -N '' -f "$D/hostkey"
cp "$D/key.pub" "$D/authorized_keys"
cat >"$D/sshd.conf" <<CONF
Port $PORT
ListenAddress 127.0.0.1
HostKey $D/hostkey
AuthorizedKeysFile $D/authorized_keys
PidFile $D/sshd.pid
StrictModes no
UsePAM no
NoneEnabled yes
NoneMacEnabled yes
SshdSessionPath $TREE/hpnsshd-session
SshdAuthPath $TREE/hpnsshd-auth
LogLevel DEBUG1
CONF

"$TREE/hpnsshd" -f "$D/sshd.conf" -E "$D/sshd.log" || fail "hpnsshd did not start"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$D/sshd.pid" ] && break; sleep 0.3; done

# run the client against the daemon: client <options...> -- <command>
client() {
    local opts=() 
    while [ "$1" != -- ]; do opts+=("$1"); shift; done; shift
    "$TREE/hpnssh" -i "$D/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -o BatchMode=yes "${opts[@]}" -o LogLevel=ERROR 127.0.0.1 "$@"
}

out="$(client -- 'echo hello')" || fail "the client could not log in to the test daemon"
[ "$out" = hello ] || fail "unexpected output from the test daemon: $out"
pass "a client logs in to a daemon started from the build tree"

# When a client dies without a disconnect, the server loop ended and wrote the throughput line twice (0.7.1)
sleep 1
before="$(grep -c 'LType: Throughput' "$D/sshd.log" || true)"
client -- 'sleep 30' >/dev/null 2>&1 &
victim=$!
sleep 1.5
kill -9 "$victim" 2>/dev/null || true
wait "$victim" 2>/dev/null || true
sleep 1.5
after="$(grep -c 'LType: Throughput' "$D/sshd.log" || true)"
[ $((after - before)) = 1 ] || fail "the server logged the throughput line $((after - before)) times for a session that was cut off, not once"
pass "the server logs the throughput line once for a session that was cut off"

# Metrics are only collected where the system has tcp_info
if [ "$(uname -s)" = Linux ]; then
    # An unwritable MetricsPath used to end the session with fatal() at the first reply (0.6.7)
    out="$(client -o Metrics=yes -o MetricsInterval=1 -o MetricsPath=/nonexistent/dir/m -- 'sleep 3; echo alive' 2>/dev/null)" \
        || fail "the session ended when MetricsPath could not be written"
    [ "$out" = alive ] || fail "the session did not finish with an unwritable MetricsPath"
    pass "a session survives a MetricsPath that cannot be written"

    client -o Metrics=yes -o MetricsInterval=1 -o "MetricsPath=$D/m" -- 'sleep 3' >/dev/null 2>&1 \
        || fail "the session failed with Metrics=yes"
    [ "$(wc -l <"$D/m.remote")" -ge 3 ] || fail "no remote metrics were written"
    [ "$(wc -l <"$D/m.local")" -ge 3 ] || fail "no local metrics were written"
    pass "Metrics=yes writes the remote and local metrics files"
fi

# The none switch rekeys after login. It used to drop the user's KexAlgorithms and use the built-in list (0.6.8)
client -o KexAlgorithms=curve25519-sha256 -o NoneEnabled=yes -o NoneSwitch=yes -o LogLevel=DEBUG1 -- 'sleep 2' \
    >/dev/null 2>"$D/none.err" || fail "the session failed with NoneSwitch=yes"
grep -q 'kex: server->client cipher: none' "$D/none.err" || fail "the none switch did not rekey to the none cipher"
algs="$(sed -n 's/^debug1: kex: algorithm: //p' "$D/none.err" | tr -d '\015' | sort -u)"
[ "$algs" = curve25519-sha256 ] || fail "the none rekey used $algs, not the KexAlgorithms the client asked for"
pass "the none switch rekey keeps the client's KexAlgorithms"

# With FallbackPort equal to the default port, a failed connect used to retry the same port for ever (0.6.9).
# It needs a closed default port and timeout(1), so it is skipped when either is missing.
if ! command -v timeout >/dev/null 2>&1; then
    echo "skip - the FallbackPort loop check needs timeout(1)"
elif (exec 3<>/dev/tcp/127.0.0.1/2222) 2>/dev/null; then
    echo "skip - the FallbackPort loop check needs nothing listening on port 2222"
else
    rc=0
    timeout 20 "$TREE/hpnssh" -o FallbackPort=2222 -o BatchMode=yes -o LogLevel=ERROR 127.0.0.1 true >/dev/null 2>&1 || rc=$?
    [ "$rc" = 255 ] || fail "hpnssh with FallbackPort at the default port did not give up on a closed port (status $rc)"
    pass "FallbackPort equal to the default port gives up instead of looping"
fi

# The client loop keeps HUP, INT, QUIT and TERM blocked, and a command started from ~C used to inherit that (0.7.0)
if [ "$(uname -s)" = Linux ] && command -v python3 >/dev/null 2>&1; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$HERE/escape-sigmask.py" "$D/sigblk" "$TREE/hpnssh" -tt -i "$D/key" -p "$PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o BatchMode=yes \
        -o PermitLocalCommand=yes -o EnableEscapeCommandline=yes -o LogLevel=ERROR \
        127.0.0.1 'echo ready; sleep 20' >/dev/null 2>&1 || fail "could not run a command from the ~C command line"
    [ "$(sed -n 's/^SigBlk:[[:space:]]*//p' "$D/sigblk" | tr -d '\015')" = 0000000000000000 ] \
        || fail "a command started from ~C inherited blocked signals: $(cat "$D/sigblk")"
    pass "a command started from the ~C command line has no signals blocked"
fi

# The none MAC could be negotiated with a real cipher, before login, leaving the stream with no integrity check (0.7.2)
if client -o NoneEnabled=yes -o NoneSwitch=yes -o NoneMacEnabled=yes -c aes256-ctr -m none -- true >/dev/null 2>&1; then
    fail "a real cipher was negotiated with the none MAC"
fi
pass "the none MAC is refused with a real cipher"

client -o NoneEnabled=yes -o NoneSwitch=yes -o NoneMacEnabled=yes -o LogLevel=DEBUG1 -c aes256-ctr \
    -m none,hmac-sha2-256-etm@openssh.com -- 'sleep 2' >/dev/null 2>"$D/mac.err" || fail "the session failed when the none MAC was listed first"
first="$(sed -n 's/^debug1: kex: server->client cipher: aes256-ctr MAC: //p' "$D/mac.err" | head -1 | tr -d '\015')"
[ "${first%% *}" = hmac-sha2-256-etm@openssh.com ] || fail "the first key exchange used MAC ${first%% *}, not hmac-sha2-256-etm@openssh.com"
grep -q 'kex: server->client cipher: none MAC: none' "$D/mac.err" || fail "the none switch no longer reaches the none cipher with the none MAC"
pass "the none MAC is used only with the none cipher after login"

# aes256-ctr switches to the multithreaded cipher after login, which loads the provider; data must survive (0.7.7)
want="$(seq 1 400000 | md5sum | cut -d' ' -f1)"
got="$(seq 1 400000 | client -c aes256-ctr -m hmac-sha2-256-etm@openssh.com -- 'md5sum' | cut -d' ' -f1)" \
    || fail "an aes256-ctr session failed"
[ "$got" = "$want" ] || fail "data sent over aes256-ctr arrived changed ($got, not $want)"
pass "data sent over aes256-ctr after the multithreaded switch arrives intact"

# A control master must survive a session whose command starts with scp. Against an HPN-SSH server the client rewrites
# it to hpnscp, and it used to free the caller's buffer, so the master died with a use after free (0.8.1).
# Needs a compiler: clientloop.c is built with AddressSanitizer into a copy of the tree. Skipped if that fails.
if command -v cc >/dev/null 2>&1; then
    A="$D/asan"
    mkdir "$A"
    cp -R "$TREE/." "$A/"
    cflags="$(sed -n 's/^CFLAGS=[[:space:]]*//p' "$A/Makefile" | head -n 1)"
    ldflags="$(sed -n 's/^LDFLAGS=[[:space:]]*//p' "$A/Makefile" | head -n 1)"
    rm -f "$A/clientloop.o" "$A/hpnssh"
    if (cd "$A" && make clientloop.o CFLAGS="$cflags -fsanitize=address -fno-omit-frame-pointer" >"$D/asan-build.log" 2>&1 &&
        # base64.o is named so that glibc's own __b64_pton, which the sanitizer's libc brings in first, is not used
        make hpnssh LDFLAGS="$ldflags -fsanitize=address openbsd-compat/base64.o" >>"$D/asan-build.log" 2>&1); then
        mux=(-o ControlPath="$D/mux" -o ControlMaster=no)
        # without leak checking: only the use after free matters here
        export ASAN_OPTIONS=detect_leaks=0
        "$A/hpnssh" -i "$D/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR -o ControlPath="$D/mux" -o ControlMaster=yes \
            -N -f 127.0.0.1 || fail "could not start the AddressSanitizer control master"
        "$A/hpnssh" "${mux[@]}" -o LogLevel=ERROR 127.0.0.1 'scp -t /dev/null' </dev/null >/dev/null 2>&1 || true
        sleep 1
        "$A/hpnssh" "${mux[@]}" -O check 127.0.0.1 >/dev/null 2>&1 \
            || fail "the control master did not survive a session that starts with scp"
        "$A/hpnssh" "${mux[@]}" -O exit 127.0.0.1 >/dev/null 2>&1 || true
        unset ASAN_OPTIONS
        pass "a control master survives a session whose command starts with scp (AddressSanitizer build)"
    else
        echo "skip - could not build clientloop.c with AddressSanitizer: $(tail -n 2 "$D/asan-build.log" | tr '\n' ' ')"
    fi
fi

# Sessions on one multiplexed aes-ctr connection. After the switch to the multithreaded cipher the second session
# never finished: the process forked for it freed a cipher whose threads it did not have, and waited for them (0.8.8).
# And every session asked for another rekey, though the switch is made once (0.8.7).
if command -v timeout >/dev/null 2>&1; then
    mmux=(-o ControlPath="$D/mux2" -c aes256-ctr -m hmac-sha2-256-etm@openssh.com)
    : >"$D/sshd.log"
    client "${mmux[@]}" -o ControlMaster=yes -N -f -- </dev/null >/dev/null 2>&1 \
        || fail "could not start a control master over aes256-ctr"
    sleep 1
    stuck=0
    for _ in 1 2 3; do
        timeout 15 "$TREE/hpnssh" -i "$D/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR "${mmux[@]}" 127.0.0.1 true </dev/null >/dev/null 2>&1 \
            || stuck=$((stuck + 1))
        sleep 0.5
    done
    "$TREE/hpnssh" -o ControlPath="$D/mux2" -O exit 127.0.0.1 </dev/null >/dev/null 2>&1 || true
    sleep 1
    [ "$stuck" = 0 ] || fail "$stuck of 3 sessions on a multiplexed aes256-ctr connection did not finish"
    pass "three sessions on one multiplexed aes256-ctr connection all finish"
    n="$(grep -c 'SSH2_MSG_KEXINIT sent' "$D/sshd.log" || true)"
    [ "$n" -le 3 ] || fail "the server started $n key exchanges for one connection with three sessions; the first, and a switch to the multithreaded cipher from each end, make three"
    pass "sessions on one connection do not each ask for a rekey"
else
    echo "skip - the multiplexed aes-ctr checks need timeout(1)"
fi

# NoneEnabled and NoneMacEnabled were applied from the global configuration only: "NoneEnabled no" in a Match
# block for the user who logged in had no effect, and the session could still switch to the none cipher (0.8.9).
PORT2=$((PORT + 1))
{ grep -v '^\(Port\|PidFile\)' "$D/sshd.conf"; printf 'Port %s\nPidFile %s\nMatch User %s\n  NoneEnabled no\n  NoneMacEnabled no\n' \
    "$PORT2" "$D/sshd2.pid" "$(id -un)"; } >"$D/sshd2.conf"
"$TREE/hpnsshd" -f "$D/sshd2.conf" -E "$D/sshd2.log" || fail "could not start a second daemon with a Match block"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$D/sshd2.pid" ] && break; sleep 0.3; done
"$TREE/hpnssh" -i "$D/key" -p "$PORT2" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
    -o BatchMode=yes -o NoneEnabled=yes -o NoneSwitch=yes -o NoneMacEnabled=yes -o LogLevel=DEBUG1 127.0.0.1 'sleep 2' \
    >/dev/null 2>"$D/match.err" || true
kill "$(cat "$D/sshd2.pid")" 2>/dev/null || true
grep -q 'kex: server->client cipher: ' "$D/match.err" || fail "the session against the Match daemon did not complete a key exchange"
if grep -q 'kex: server->client cipher: none' "$D/match.err"; then
    fail "a Match block with NoneEnabled no did not stop the switch to the none cipher"
fi
pass "NoneEnabled no in a Match block stops the switch to the none cipher"

# A TCPKeepAlive value that is not in the table was read past the end of it, since the table had no terminator,
# and could be accepted with the value of whatever followed (0.9.0).
# (no-pq-kex belongs to WarnWeakCrypto, whose table follows this one)
for bad in bogus no-pq-kex; do
    printf 'HostKey %s\nTCPKeepAlive %s\n' "$D/hostkey" "$bad" >"$D/bad.conf"
    if "$TREE/hpnsshd" -t -f "$D/bad.conf" >"$D/bad.out" 2>&1; then
        fail "hpnsshd accepted TCPKeepAlive $bad"
    fi
    grep -qi 'unsupported option' "$D/bad.out" || fail "hpnsshd did not say that TCPKeepAlive $bad is unsupported: $(head -c 200 "$D/bad.out")"
done
for v in yes no all transport; do
    printf 'HostKey %s\nTCPKeepAlive %s\n' "$D/hostkey" "$v" >"$D/good.conf"
    "$TREE/hpnsshd" -t -f "$D/good.conf" >/dev/null 2>&1 || fail "hpnsshd rejected TCPKeepAlive $v"
done
pass "TCPKeepAlive rejects a value that is not in its table"

# sshd -T did not list DisableMTAES (0.9.1)
printf 'HostKey %s\nDisableMTAES yes\n' "$D/hostkey" >"$D/mt.conf"
[ "$("$TREE/hpnsshd" -T -f "$D/mt.conf" 2>/dev/null | grep -ci '^disablemtaes yes$')" = 1 ] \
    || fail "hpnsshd -T does not show DisableMTAES"
pass "hpnsshd -T shows DisableMTAES"

# The client loop keeps HUP, INT, QUIT and TERM blocked, so a prompt it runs for a control master ("ControlMaster ask")
# started its askpass program with them blocked, and Ctrl-C did not reach the prompt either (0.9.2).
if [ "$(uname -s)" = Linux ]; then
    cat >"$D/askpass" <<ASK
#!/bin/sh
echo "\$(grep '^SigBlk' /proc/self/status | tr -d '\\t ') \$(tr '\\0' ' ' </proc/\$PPID/cmdline | cut -c1-40)" >>"$D/ask.sigblk"
echo yes
ASK
    chmod +x "$D/askpass"
    rm -f "$D/ask.sigblk"
    askopts=(-i "$D/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes
        -o BatchMode=yes -o LogLevel=ERROR -o ControlPath="$D/mux3")
    SSH_ASKPASS="$D/askpass" SSH_ASKPASS_REQUIRE=force "$TREE/hpnssh" "${askopts[@]}" -o ControlMaster=ask -N -f 127.0.0.1 \
        </dev/null >/dev/null 2>&1 || fail "could not start a ControlMaster ask master"
    sleep 1
    SSH_ASKPASS="$D/askpass" SSH_ASKPASS_REQUIRE=force "$TREE/hpnssh" "${askopts[@]}" 127.0.0.1 true </dev/null >/dev/null 2>&1 || true
    sleep 1
    "$TREE/hpnssh" "${askopts[@]}" -O exit 127.0.0.1 </dev/null >/dev/null 2>&1 || true
    [ -s "$D/ask.sigblk" ] || fail "the askpass program for a ControlMaster ask prompt was not run"
    if grep -v '^SigBlk:0000000000000000 ' "$D/ask.sigblk" | grep -q .; then
        fail "an askpass program inherited blocked signals: $(head -n 3 "$D/ask.sigblk" | tr '\n' ';')"
    fi
    pass "an askpass program started from the client loop has no signals blocked"
fi

# A review report said the attempt on FallbackPort after a timed out connect to the default port had no time limit,
# because the time left is read back as the limit. It does not reproduce: the second attempt also stops at the
# ConnectTimeout. This keeps it that way. Both ports are listeners with a full accept queue, so a connect to them
# hangs; the whole run must end in about two ConnectTimeouts, not after the system's TCP timeout.
if [ "$(uname -s)" = Linux ] && command -v python3 >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    FB=$((PORT + 2))
    cat >"$D/blackhole.py" <<'PY'
import socket, sys, time
socks = []
for port in (2222, int(sys.argv[1])):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
    except OSError:
        print("busy", flush=True)
        sys.exit(0)
    s.listen(0)
    for _ in range(6):
        f = socket.socket()
        f.setblocking(False)
        try:
            f.connect(("127.0.0.1", port))
        except BlockingIOError:
            pass
        socks.append(f)
    socks.append(s)
print("ready", flush=True)
time.sleep(60)
PY
    python3 "$D/blackhole.py" "$FB" >"$D/blackhole.out" 2>&1 &
    bh=$!
    sleep 1.5
    if grep -q ready "$D/blackhole.out"; then
        start=$(date +%s)
        timeout 40 "$TREE/hpnssh" -o ConnectTimeout=2 -o FallbackPort="$FB" -o BatchMode=yes -o LogLevel=ERROR 127.0.0.1 true \
            >/dev/null 2>&1 || true
        took=$(($(date +%s) - start))
        [ "$took" -le 12 ] || fail "the connect to FallbackPort took $took seconds with ConnectTimeout 2"
        pass "the connect to FallbackPort keeps the ConnectTimeout ($took seconds)"
    else
        echo "skip - the FallbackPort timeout check needs port 2222 free"
    fi
    kill "$bh" 2>/dev/null || true
fi

# The none switch keeps the none cipher off terminal sessions (the client refuses it when it has a tty). A multiplexed
# session asked for a terminal over the master's connection after the switch, and got one in clear text (0.9.8).
if command -v timeout >/dev/null 2>&1; then
    nopts=(-i "$D/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes
        -o BatchMode=yes -o LogLevel=ERROR -o ControlPath="$D/mux4")
    "$TREE/hpnssh" "${nopts[@]}" -o NoneEnabled=yes -o NoneSwitch=yes -o ControlMaster=yes -N -f 127.0.0.1 \
        </dev/null >/dev/null 2>&1 || fail "could not start a control master with the none switch"
    sleep 3
    timeout 15 "$TREE/hpnssh" "${nopts[@]}" 127.0.0.1 true </dev/null >/dev/null 2>&1 \
        || fail "a session without a terminal failed over the none switch connection"
    # the master refuses; the client then makes a connection of its own, which is encrypted, so its status is 0
    timeout 15 "$TREE/hpnssh" "${nopts[@]}" -tt 127.0.0.1 true </dev/null >/dev/null 2>"$D/tty.err" || true
    if ! grep -q 'not allowed on a connection that uses the none cipher' "$D/tty.err"; then
        "$TREE/hpnssh" "${nopts[@]}" -O exit 127.0.0.1 </dev/null >/dev/null 2>&1 || true
        fail "a terminal session was opened over a connection that uses the none cipher"
    fi
    "$TREE/hpnssh" "${nopts[@]}" -O exit 127.0.0.1 </dev/null >/dev/null 2>&1 || true
    pass "a multiplexed session cannot have a terminal over the none cipher"
fi

# With StrictHostKeyChecking=no and a changed host key the client carries on but must not forward ports, since the
# peer may be a man in the middle. Forward requests that arrive later, over the control master or from ~C, were not
# refused (1.0.9, taken from upstream).
if command -v timeout >/dev/null 2>&1; then
    ssh-keygen -q -t ed25519 -N '' -f "$D/otherkey"
    echo "[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$D/otherkey.pub")" >"$D/changed_hosts"
    uopts=(-i "$D/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$D/changed_hosts"
        -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR -o ControlPath="$D/mux8")
    "$TREE/hpnssh" "${uopts[@]}" -o ControlMaster=yes -N -f 127.0.0.1 </dev/null >/dev/null 2>&1 \
        || fail "could not start a control master against a changed host key"
    sleep 1
    fres=0
    timeout 15 "$TREE/hpnssh" "${uopts[@]}" -O forward -L "127.0.0.1:$((PORT + 1)):127.0.0.1:$PORT" 127.0.0.1 \
        </dev/null >"$D/fwd.out" 2>&1 || fres=$?
    "$TREE/hpnssh" "${uopts[@]}" -O exit 127.0.0.1 </dev/null >/dev/null 2>&1 || true
    [ "$fres" -ne 0 ] || fail "a forward was accepted over a connection whose host key is not trusted: $(cat "$D/fwd.out")"
    pass "forwarding is refused after the host key failed verification"
fi

# A host key marked @revoked in known_hosts must never be accepted, whatever else matches. Three entries were
# overlooked: one without a port identifier, when the port is not 22; one for the IP address, when the host name has
# a matching entry; and one found while VerifyHostKeyDNS had a secure match (1.1.0, taken from upstream).
hkey="$(cut -d' ' -f1,2 "$D/hostkey.pub")"
revoked() { # revoked <name> <known_hosts content> <client option>...
    local name=$1 hosts=$2; shift 2
    printf '%s\n' "$hosts" >"$D/revoked_hosts"
    if "$TREE/hpnssh" -i "$D/key" -p "$PORT" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$D/revoked_hosts" \
        -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR "$@" true \
        </dev/null >/dev/null 2>"$D/revoked.err"; then
        fail "a revoked host key was accepted ($name)"
    fi
    grep -q 'REVOKED' "$D/revoked.err" || fail "the connection failed, but not because the key is revoked ($name): $(cat "$D/revoked.err")"
}
revoked "entry without a port" "@revoked 127.0.0.1 $hkey" 127.0.0.1
pass "a host key revoked without a port identifier is refused on another port"
# the address check is skipped for loopback, so this one needs a daemon on the machine's own address
own="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -n 1 || true)"
if [ -n "$own" ]; then
    sed -e "s/^ListenAddress .*/ListenAddress $own/" -e "s/^PidFile .*/PidFile ${D//\//\\/}\\/sshd2.pid/" "$D/sshd.conf" >"$D/sshd2.conf"
    "$TREE/hpnsshd" -f "$D/sshd2.conf" -E "$D/sshd2.log" || fail "the second hpnsshd did not start"
    sleep 0.5
    revoked "entry for the address" "[testhost]:$PORT $hkey
@revoked [$own]:$PORT $hkey" -o CheckHostIP=yes -o HostKeyAlias=testhost "$own"
    kill "$(cat "$D/sshd2.pid")" 2>/dev/null || true
    pass "a host key revoked for the address is refused though the host name has an entry"
fi

# A marker in known_hosts that was followed by a tab, not a space, was cut at the first space after it, so the marker
# was not recognised and the line, a revocation, was ignored (1.1.1, taken from upstream).
revoked "marker followed by a tab" "@revoked"$'\t'"127.0.0.1 $hkey" 127.0.0.1
pass "a marker in known_hosts followed by a tab is recognised"

# ConnectTimeout also bounds the key exchange. A server that sends its banner and then says nothing used to hold
# the client for ever (1.1.2, taken from upstream). Needs python3 and timeout(1).
if command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    python3 -I - "$D/mute.port" <<'PY' &
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept()
    c.sendall(b"SSH-2.0-OpenSSH_10.6\r\n")
    time.sleep(60)
PY
    mute=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$D/mute.port" ] && break; sleep 0.3; done
    start=$SECONDS
    timeout 30 "$TREE/hpnssh" -p "$(cat "$D/mute.port")" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR 127.0.0.1 true </dev/null >/dev/null 2>&1 || true
    took=$((SECONDS - start))
    kill "$mute" 2>/dev/null || true
    [ "$took" -le 10 ] || fail "ConnectTimeout did not stop a key exchange that never started (took ${took}s)"
    pass "ConnectTimeout bounds a key exchange that gets no answer (${took}s)"
fi

# The ProxyCommand's pid is forgotten once the SIGCHLD handler has reaped it, so a later kill cannot hit a process
# that was given the same pid (1.1.3, taken from upstream). The race itself cannot be made to happen here; this checks
# that a login through a ProxyCommand, and one whose command dies at once, still behave.
if command -v nc >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    out="$(timeout 20 "$TREE/hpnssh" -i "$D/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR -o ProxyCommand="nc 127.0.0.1 $PORT" proxied echo via-proxy \
        </dev/null 2>/dev/null)" || fail "a login through a ProxyCommand failed"
    [ "$out" = via-proxy ] || fail "unexpected output through a ProxyCommand: $out"
    rc=0
    timeout 20 "$TREE/hpnssh" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR \
        -o ProxyCommand=false proxied true </dev/null >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 255 ] || fail "a ProxyCommand that exits at once gave status $rc, not 255"
    pass "a ProxyCommand logs in, and one that exits at once fails cleanly"
fi

# When a multiplexed session is cancelled the master closes the client's descriptors; it did not close its stderr, so
# the server could go on writing extended data to it (1.1.4, taken from upstream). This checks that cancelling a
# session whose command writes to stderr leaves the master working.
if command -v timeout >/dev/null 2>&1; then
    mopts=(-i "$D/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes
        -o BatchMode=yes -o LogLevel=ERROR -o ControlPath="$D/mux9")
    "$TREE/hpnssh" "${mopts[@]}" -o ControlMaster=yes -N -f 127.0.0.1 </dev/null >/dev/null 2>&1 \
        || fail "could not start a control master"
    sleep 1
    "$TREE/hpnssh" "${mopts[@]}" 127.0.0.1 'while :; do echo err >&2; sleep 0.1; done' </dev/null >/dev/null 2>&1 &
    victim=$!
    sleep 1
    kill "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    sleep 1
    out="$(timeout 15 "$TREE/hpnssh" "${mopts[@]}" 127.0.0.1 'echo still-up' </dev/null 2>/dev/null)" || out=
    # -Z lists the keys it would try and exits; with a master running it used to open a session through it instead (1.1.6)
    zout="$(timeout 15 "$TREE/hpnssh" "${mopts[@]}" -Z 127.0.0.1 </dev/null 2>/dev/null)" || zout=
    "$TREE/hpnssh" "${mopts[@]}" -O exit 127.0.0.1 </dev/null >/dev/null 2>&1 || true
    [ "$out" = still-up ] || fail "the control master stopped working after a session that writes to stderr was cancelled"
    pass "a control master survives the cancel of a session that writes to stderr"
    case "$zout" in *"$D/key"*ED25519*) pass "-Z lists the keys with a control master running" ;;
        *) fail "-Z did not list keys while a control master was running: $zout" ;; esac
fi

# With UpdateHostKeys the client adds the server's keys to the first known_hosts file and deletes the host's entries
# from the others. When the first file could not be written it went on and deleted them from the others anyway, so
# the host's entries were lost without being recorded anywhere (1.1.7, taken from upstream). The server needs a second
# host key, so that there is something new to record.
ssh-keygen -q -t ecdsa -N '' -f "$D/hostkey2"
{ grep -v -e '^HostKey' -e '^PidFile' -e '^Port' "$D/sshd.conf"
    printf 'HostKey %s\nHostKey %s\nPidFile %s\nPort %s\n' "$D/hostkey" "$D/hostkey2" "$D/sshd3.pid" "$((PORT + 2))"
} >"$D/sshd3.conf"
"$TREE/hpnsshd" -f "$D/sshd3.conf" -E "$D/sshd3.log" || fail "the second hpnsshd did not start"
sleep 0.5
printf '[127.0.0.1]:%s %s\n' "$((PORT + 2))" "$hkey" >"$D/second_hosts"
cp "$D/second_hosts" "$D/second_hosts.orig"
"$TREE/hpnssh" -i "$D/key" -p "$((PORT + 2))" -o StrictHostKeyChecking=yes -o UpdateHostKeys=yes \
    -o UserKnownHostsFile="$D/missing_hosts $D/second_hosts" -o GlobalKnownHostsFile=/dev/null -o IdentitiesOnly=yes \
    -o BatchMode=yes -o LogLevel=ERROR 127.0.0.1 true </dev/null >/dev/null 2>&1 || fail "the login for the UpdateHostKeys check failed"
sleep 1
kill "$(cat "$D/sshd3.pid")" 2>/dev/null || true
cmp -s "$D/second_hosts" "$D/second_hosts.orig" || fail "UpdateHostKeys changed a known_hosts file after the first one could not be written"
pass "UpdateHostKeys leaves the other known_hosts files alone when the first cannot be written"

# A cipher list that names the multithreaded ChaCha must also name the serial one, directly after it (patch_list in
# kex.c, patch 0008). Checked on the proposal the client really sends.
prop="$("$TREE/hpnssh" -vv -i "$D/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes -o BatchMode=yes -c aes256-ctr,chacha20-poly1305-mt@hpnssh.org,aes128-ctr 127.0.0.1 true 2>&1 </dev/null \
    | sed -n 's/^debug2: ciphers ctos: //p' | head -n 1 | tr -d '\015')"
[ "$prop" = "aes256-ctr,chacha20-poly1305-mt@hpnssh.org,chacha20-poly1305@openssh.com,aes128-ctr" ] \
    || fail "the serial ChaCha is not directly after the multithreaded one in the proposal: $prop"
pass "the cipher proposal puts the serial ChaCha directly after the multithreaded one"
