#!/usr/bin/env bash
# Tests for the scp -Z resume protocol, run against hpnscp from a build tree.
#
# usage: tests/scp-resume.sh <path-to-hpnscp> <work-dir>
#
# The sender (scp -f) and the sink (scp -t) are connected with pipes, so no
# server or privileges are needed, and bad records can be written by hand.
set -u

SCP="${1:?usage: scp-resume.sh <hpnscp> <workdir>}"
W="${2:?usage: scp-resume.sh <hpnscp> <workdir>}"
rm -rf "$W"; mkdir -p "$W"
failures=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }
same() { cmp -s "$1" "$2"; }

# pair <sender args> -- <sink args>: wire a sender to a sink; sets PAIR_RC
#
# A coprocess gives the sink two ends (its stdin and stdout) and lets the
# sender be wired to them the other way round, with no FIFOs to deadlock on.
pair() {
    local -a snd=() snk=()
    while [ "$1" != "--" ]; do snd+=("$1"); shift; done
    shift
    snk=("$@")
    coproc SINK { eval "${SINK_PRE:-:}"; timeout 30 "$SCP" -t "${snk[@]}" 2>"$W/sink.err"; }
    # shellcheck disable=SC2153 # SINK_PID is set by coproc
    local sink_pid=$SINK_PID sink_in=${SINK[1]} sink_out=${SINK[0]}
    # bash does not pass the coprocess descriptors on to background jobs, so
    # copy them to ordinary numbers for the sender
    eval "exec 7<&${sink_out} 8>&${sink_in}"
    if [ -n "${HOLD:-}" ]; then
        # pass on the sender's first line (the record for the file) at once and the rest after $HOLD seconds, so that
        # something can happen to the destination file between the reply and the data
        { timeout 30 "$SCP" -f "${snd[@]}" <&7 2>"$W/src.err" | { IFS= read -r line; printf '%s\n' "$line"; sleep "$HOLD"; cat; } >&8; } &
    elif [ -n "${CUT:-}" ]; then
        # pass on only the first $CUT bytes the sender writes: the connection is cut there
        { timeout 30 "$SCP" -f "${snd[@]}" <&7 2>"$W/src.err" | head -c "$CUT" >&8; } &
    else
        timeout 30 "$SCP" -f "${snd[@]}" <&7 >&8 2>"$W/src.err" &
    fi
    local sp=$!
    # the sender has its own copies now; close ours so the sink sees end of
    # file as soon as the sender is gone
    eval "exec 7<&- 8>&- ${sink_in}>&- ${sink_out}<&-"
    wait $sp; local rc=$?
    wait "$sink_pid"; PAIR_RC=$((rc + $?))
}

head -c 3000000 /dev/urandom > "$W/big"
mkdir -p "$W/d"

# 1: resume into an existing plain file (destination is not a directory)
head -c 1200000 "$W/big" > "$W/d/part"
pair -Z "$W/big" -- -Z "$W/d/part"
if [ $PAIR_RC -eq 0 ] && same "$W/big" "$W/d/part"; then pass "resume into a plain-file destination"; else fail "resume into a plain-file destination (rc $PAIR_RC)"; fi
left=$(find "$W/d" -mindepth 1 -printf '%f ')
if [ "$left" = "part " ]; then pass "no temporary file is left behind"; else fail "temporary file left behind: $left"; fi

# 2: several files in one sender call; a is new, b exists with the same size and other content
head -c 500000 /dev/urandom > "$W/a"; head -c 500000 /dev/urandom > "$W/b"
mkdir -p "$W/m"; head -c 500000 /dev/urandom > "$W/m/b"
pair -Z "$W/a" "$W/b" -- -Z -d "$W/m"
if [ $PAIR_RC -eq 0 ] && same "$W/a" "$W/m/a" && same "$W/b" "$W/m/b"; then pass "a stale match status does not leak from one file to the next"; else fail "several files in one call (rc $PAIR_RC)"; fi

# 3: destination larger than the source is overwritten
head -c 2000000 /dev/urandom > "$W/d/larger"; head -c 400000 /dev/urandom > "$W/small"
pair -Z "$W/small" -- -Z "$W/d/larger"
if [ $PAIR_RC -eq 0 ] && same "$W/small" "$W/d/larger"; then pass "a larger destination is overwritten"; else fail "larger destination (rc $PAIR_RC)"; fi

# 4: identical file is skipped
cp "$W/big" "$W/d/same"
pair -Z "$W/big" -- -Z "$W/d/same"
if [ $PAIR_RC -eq 0 ] && same "$W/big" "$W/d/same"; then pass "an identical file is skipped"; else fail "identical file (rc $PAIR_RC)"; fi

# 5: a hash field that is too short is a protocol error, not a read past the record
head -c 100000 /dev/urandom > "$W/sinkfile.dat"
printf 'C0644 5 shorthash name\n' | timeout 20 "$SCP" -t -Z "$W/d" >"$W/out5" 2>"$W/err5"; rc=$?
# a sink in -t mode reports protocol errors on its protocol output (stdout)
if [ $rc -ne 0 ] && grep -aq 'hash too short' "$W/out5"; then pass "a short hash field is rejected for being short"; else fail "short hash field (rc $rc): $(tr -d '\000\001' <"$W/out5" | head -c 200)"; fi

# 6: a truncated resume response makes the sender stop, not carry on with garbage
head -c 200000 /dev/urandom > "$W/t6"
printf '\000R0644 ' | timeout 20 "$SCP" -f -Z "$W/t6" >"$W/out6" 2>"$W/err6"; rc=$?
if [ $rc -ne 0 ] && grep -q 'resume response' "$W/err6"; then pass "a truncated resume response is rejected"; else fail "truncated resume response (rc $rc): $(head -c 200 "$W/err6")"; fi

# 7: a remote size larger than the local file cannot match: the whole file is sent again
head -c 200000 /dev/urandom > "$W/t7"
hash0=$(printf '%0128d' 0)
{ printf '\000'; printf '%-191s' "R0644 99999999 $hash0"; printf '\000'; } | timeout 20 "$SCP" -f -Z "$W/t7" >"$W/out7" 2>"$W/err7"; rc=$?
sz=$(stat -c %s "$W/out7")
if [ "$sz" -ge 200000 ]; then pass "an impossible remote size sends the whole file again"; else fail "impossible remote size: sender wrote only $sz bytes (rc $rc)"; fi

# 8: the tail arrives but appending it to the existing file fails (the file would grow past the size limit).
# The sink must fail and put the existing file back as it was, not leave the part of the tail that fitted.
# SINK_PRE limits the sink's file size, and ignores SIGXFSZ so that the write fails with an error and does not
# end the process. The same limit raised is a control: it must succeed, so the limit is what causes the failure.
head -c 1200000 "$W/big" > "$W/d/part8c"
SINK_PRE='ulimit -f 4000; trap "" XFSZ' pair -Z "$W/big" -- -Z "$W/d/part8c"
unset SINK_PRE
if [ $PAIR_RC -eq 0 ] && same "$W/big" "$W/d/part8c"; then pass "the append works when the size limit is high enough"; else fail "control for the size limit failed (rc $PAIR_RC)"; fi
head -c 1200000 "$W/big" > "$W/d/part8"
SINK_PRE='ulimit -f 1953; trap "" XFSZ' pair -Z "$W/big" -- -Z "$W/d/part8"
unset SINK_PRE
if [ $PAIR_RC -ne 0 ]; then pass "a failed append of the resumed tail is reported"; else fail "failed append was not reported"; fi
if [ "$(stat -c %s "$W/d/part8")" = 1200000 ] && cmp -s "$W/d/part8" <(head -c 1200000 "$W/big"); then pass "a failed append leaves the existing file as it was"; else fail "existing file changed by a failed append: $(stat -c %s "$W/d/part8") bytes"; fi
left=$(find "$W/d" -name 'part8' -o -name '.*part8*' -o -name '*part8.*' | wc -l)
if [ "$left" = 1 ]; then pass "a failed append leaves no temporary file"; else fail "temporary file left after a failed append ($left names)"; fi

# 9: the tail itself cannot be written (it is bigger than the size limit), so nothing may be appended
head -c 1200000 "$W/big" > "$W/d/part9"
SINK_PRE='ulimit -f 976; trap "" XFSZ' pair -Z "$W/big" -- -Z "$W/d/part9"
unset SINK_PRE
if [ $PAIR_RC -ne 0 ]; then pass "a tail that cannot be written is reported"; else fail "unwritable tail was not reported"; fi
if [ "$(stat -c %s "$W/d/part9")" = 1200000 ] && cmp -s "$W/d/part9" <(head -c 1200000 "$W/big"); then pass "an unwritable tail leaves the existing file as it was"; else fail "existing file changed: $(stat -c %s "$W/d/part9") bytes"; fi

# 10: the connection ends after the sink has asked to resume, before the match byte: the sink must stop, and not go
# on to create a temporary file with the match status that was left on its stack
mkdir -p "$W/d10"
printf 'C0644 5 %0128d name\n' 0 | timeout 20 "$SCP" -t -Z "$W/d10" >"$W/out10" 2>"$W/err10"; rc=$?
if [ $rc -ne 0 ] && [ -z "$(find "$W/d10" -mindepth 1)" ]; then pass "a connection lost before the match byte leaves no temporary file"; else fail "lost match byte: rc $rc, left: $(find "$W/d10" -mindepth 1 -printf '%f ')"; fi

# 11: a target that is not a regular file (a device, a fifo) has a size of 0, which made the sink treat it as a file
# to resume and try to create "<target>XXXXXXXX" beside it. It must be written as it is, as it was without -Z.
pair -Z "$W/big" -- -Z /dev/null
if [ $PAIR_RC -eq 0 ]; then pass "a device as the destination is written to, not resumed"; else fail "a device as the destination (rc $PAIR_RC)"; fi
left=$(find /dev -maxdepth 1 -name 'null*' ! -name null | wc -l)
if [ "$left" = 0 ]; then pass "no file is created beside a device"; else fail "a file was created beside /dev/null"; fi

# 12: the sink cannot open the target after the resume reply (here a directory is in the way). The sender is already
# sending the file's bytes, so the sink must take them and report the error, and the next file must still arrive.
head -c 300000 /dev/urandom > "$W/first"; head -c 300000 /dev/urandom > "$W/second"
mkdir -p "$W/m12/first"
pair -Z "$W/first" "$W/second" -- -Z -d "$W/m12"
if [ $PAIR_RC -ne 0 ]; then pass "a target that cannot be opened is reported"; else fail "an unopenable target was not reported"; fi
if same "$W/second" "$W/m12/second"; then pass "the file after one that cannot be opened still arrives"; else fail "the next file was lost after an unopenable target"; fi

# 13: the connection is cut in the middle of the resumed tail. What arrived must be kept, and the temporary file must
# not be left, so that the next run resumes from there and does not send it again.
head -c 1200000 "$W/big" > "$W/d/part13"
CUT=900000 pair -Z "$W/big" -- -Z "$W/d/part13"
unset CUT
got=$(stat -c %s "$W/d/part13")
if [ "$PAIR_RC" -ne 0 ]; then pass "a connection cut in the tail is reported"; else fail "a cut connection was not reported"; fi
if [ "$got" -gt 1200000 ] && [ "$got" -lt 3000000 ] && cmp -s "$W/d/part13" <(head -c "$got" "$W/big"); then
    pass "the part of the tail that arrived is kept ($((got - 1200000)) bytes)"
else fail "the part of the tail that arrived was not kept (the file is $got bytes)"; fi
left=$(find "$W/d" -maxdepth 1 -name 'part13*' | wc -l)
if [ "$left" = 1 ]; then pass "a cut connection leaves no temporary file"; else fail "a temporary file is left after a cut connection ($left names)"; fi
pair -Z "$W/big" -- -Z "$W/d/part13"
if [ $PAIR_RC -eq 0 ] && same "$W/big" "$W/d/part13"; then pass "the next run completes the file from where it stopped"; else fail "resuming after a cut connection (rc $PAIR_RC)"; fi

# 14: the reply to a resume request has an S right after the hash. The record's type is its first byte, so this is
# not a request to skip the file: the fragments differ here, and the whole file must be sent.
head -c 200000 /dev/urandom > "$W/t14"
hash0=$(printf '%0128d' 0)
{ printf '\000'; printf '%-191s' "R0644 100 ${hash0}S"; printf '\000'; } | timeout 20 "$SCP" -f -Z "$W/t14" >"$W/out14" 2>"$W/err14"
sz=$(stat -c %s "$W/out14")
if [ "$sz" -ge 200000 ]; then pass "an S after the hash is not taken for a request to skip the file"; else fail "an S after the hash skipped the file (the sender wrote $sz bytes)"; fi

# 15: a destination that cannot be written is skipped, and that is a failure: the file was not updated
head -c 100000 "$W/big" > "$W/d/part15"; chmod 444 "$W/d/part15"
pair -Z "$W/big" -- -Z "$W/d/part15"
chmod 644 "$W/d/part15"
if [ $PAIR_RC -ne 0 ] && [ "$(stat -c %s "$W/d/part15")" = 100000 ]; then pass "an unwritable destination is skipped and reported as a failure"; else fail "unwritable destination (rc $PAIR_RC)"; fi

# 16: the destination file changes after the sink has hashed it and before the tail is appended. Appending would put
# the tail on a file that is no longer the one the sender checked, so it must not be done.
head -c 1200000 "$W/big" > "$W/d/part16"
( sleep 0.5; printf 'changed' >> "$W/d/part16" ) &
HOLD=1.5 pair -Z "$W/big" -- -Z "$W/d/part16"
unset HOLD
wait
if [ $PAIR_RC -ne 0 ] && [ "$(stat -c %s "$W/d/part16")" = 1200007 ]; then pass "a destination that changed during the resume is not appended to"; else fail "changed destination: rc $PAIR_RC, $(stat -c %s "$W/d/part16") bytes"; fi
left=$(find "$W/d" -maxdepth 1 -name 'part16*' | wc -l)
if [ "$left" = 1 ]; then pass "no temporary file is left when the append is refused"; else fail "temporary file left after a refused append ($left names)"; fi

echo "$failures failure(s)"
[ $failures -eq 0 ]
