#!/usr/bin/env bash
# Suggest the cipher and MAC settings that suit this machine's CPU.
#
# usage: tools/suggest-cipher.sh [--seconds N] [--no-measure] [--config]
#
# It reads the CPU (does it have AES instructions?), times the AEAD ciphers HPN-SSH
# offers with `openssl speed` when openssl is available, and prints a Ciphers and
# a MACs line to use with hpnssh and hpnsshd. It changes nothing.
#
# Test hooks: SUGGEST_OS, SUGGEST_CPUINFO (a file in place of /proc/cpuinfo) and
# SUGGEST_OPENSSL (the openssl command to time with).
set -euo pipefail

SECONDS_PER_CIPHER=1 MEASURE=1 CONFIG=0

die() { echo "suggest-cipher: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: tools/suggest-cipher.sh [--seconds N] [--no-measure] [--config]

Suggests a Ciphers and MACs setting for this machine and prints it. It changes
nothing.

  --seconds N    time each cipher for N seconds (default 1)
  --no-measure   do not run openssl speed; decide from the CPU features alone
  --config       print only the two lines, as ssh_config and sshd_config take them
  -h, --help     this text
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_PER_CIPHER="${2:?--seconds needs a value}"; shift 2 ;;
        --no-measure) MEASURE=0; shift ;;
        --config) CONFIG=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done
[[ "$SECONDS_PER_CIPHER" =~ ^[0-9]+$ ]] && [ "$SECONDS_PER_CIPHER" -ge 1 ] || die "--seconds must be a whole number, at least 1"

OS="${SUGGEST_OS:-$(uname -s)}"
CPUINFO="${SUGGEST_CPUINFO:-/proc/cpuinfo}"

# ---------------------------------------------------------------- the CPU

MODEL="" AES=unknown

case "$OS" in
    Linux)
        if [ -r "$CPUINFO" ]; then
            MODEL="$(sed -n 's/^[Mm]odel name[[:space:]]*:[[:space:]]*//p' "$CPUINFO" | head -1)"
            [ -n "$MODEL" ] || MODEL="$(uname -m)"
            features="$(grep -m1 -i -E '^(flags|features)[[:space:]]*:' "$CPUINFO" || true)"
            if [ -n "$features" ]; then
                # x86 lists "aes", arm64 lists "aes" among its Features
                if grep -q -w aes <<<"$features"; then AES=yes; else AES=no; fi
            fi
        fi
        ;;
    Darwin)
        MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
        if [ "$(sysctl -n hw.optional.arm.FEAT_AES 2>/dev/null || echo)" = 1 ]; then
            AES=yes
        elif sysctl -n machdep.cpu.features 2>/dev/null | grep -q -w AES; then
            AES=yes
        elif sysctl -n hw.optional.arm.FEAT_AES >/dev/null 2>&1 || sysctl -n machdep.cpu.features >/dev/null 2>&1; then
            AES=no
        fi
        ;;
    *) die "this needs Linux or macOS, not $OS" ;;
esac

# ---------------------------------------------------------------- timing

OPENSSL="${SUGGEST_OPENSSL:-openssl}"
GCM="" CHACHA="" CTR=""

# bench NAME: MB/s of one core encrypting 16 KiB blocks, or nothing
bench() {
    # -mr prints the result as "+F:<n>:<name>:<bytes per second>" on stdout
    "$OPENSSL" speed -mr -elapsed -seconds "$SECONDS_PER_CIPHER" -bytes 16384 -evp "$1" 2>/dev/null |
        awk -F: '/^\+F:/ { rate = $4 } END { if (rate > 0) printf "%.0f", rate / 1e6 }'
}

if [ "$MEASURE" = 1 ] && command -v "$OPENSSL" >/dev/null 2>&1; then
    GCM="$(bench AES-256-GCM || true)"
    CHACHA="$(bench ChaCha20-Poly1305 || true)"
    CTR="$(bench AES-256-CTR || true)"
fi

# ---------------------------------------------------------------- the choice

AES_FIRST="aes256-gcm@openssh.com,aes128-gcm@openssh.com,chacha20-poly1305-mt@hpnssh.org,chacha20-poly1305@openssh.com,aes256-ctr"
CHACHA_FIRST="chacha20-poly1305-mt@hpnssh.org,chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr"
# Only aes-ctr takes a separate MAC. UMAC was the fastest MAC with it in the tests.
MACS="umac-64-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-256-etm@openssh.com"

if [ -n "$GCM" ] && [ -n "$CHACHA" ]; then
    if [ "$GCM" -ge "$CHACHA" ]; then PICK=aes; else PICK=chacha; fi
    BASIS="measured: aes256-gcm $GCM MB/s, chacha20-poly1305 $CHACHA MB/s per core"
elif [ "$AES" = yes ]; then
    PICK=aes; BASIS="the CPU has AES instructions"
elif [ "$AES" = no ]; then
    PICK=chacha; BASIS="the CPU has no AES instructions"
else
    PICK=chacha; BASIS="could not tell, so the HPN-SSH default order is kept"
fi

if [ "$PICK" = aes ]; then CIPHERS="$AES_FIRST"; else CIPHERS="$CHACHA_FIRST"; fi

if [ "$CONFIG" = 1 ]; then
    echo "Ciphers $CIPHERS"
    echo "MACs $MACS"
    exit 0
fi

# ---------------------------------------------------------------- the report

echo "CPU:           $MODEL ($(uname -m))"
echo "AES hardware:  $AES"
if [ -n "$GCM$CHACHA$CTR" ]; then
    echo "Raw speed, one core, 16 KiB blocks (openssl speed):"
    [ -z "$GCM" ] || echo "  aes256-gcm          $GCM MB/s"
    [ -z "$CHACHA" ] || echo "  chacha20-poly1305   $CHACHA MB/s"
    [ -z "$CTR" ] || echo "  aes256-ctr          $CTR MB/s (before the MAC it needs)"
fi
echo
if [ "$PICK" = aes ]; then
    echo "Suggested: AES-GCM first ($BASIS)."
else
    echo "Suggested: ChaCha20-Poly1305 first ($BASIS)."
fi
echo
echo "  Ciphers $CIPHERS"
echo "  MACs $MACS"
echo
echo "Put the Ciphers line in ssh_config for hpnssh, and in sshd_config for hpnsshd. Or per command:"
echo
echo "  hpnssh -c ${CIPHERS%%,*} host"
echo
cat <<'EOF'
Notes:
  - The MACs line only matters with the aes-ctr ciphers. aes-gcm and chacha20-poly1305 carry their own authentication.
  - aes256-ctr is last because, with its MAC, it was slower than aes256-gcm on every machine measured.
  - On a long path the TCP buffer limit, not the cipher, sets the speed; see tools/tune-tcp.sh.
  - This times one core. HPN-SSH's end-to-end speed also depends on the other ends, the network and the MAC.
EOF
