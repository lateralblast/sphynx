#!/usr/bin/env bash
# Build vanilla OpenSSH from openssh-portable/ as the baseline for perf.sh.
#
# usage: tools/perf/build-baseline.sh [source-dir]
#
# The default source is the openssh-portable/ clone next to sphynx. The build
# and install go under build/perf/baseline/ (or $BASELINE_PREFIX's parent), so
# nothing is installed on the system.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${1:-$ROOT/openssh-portable}"
WORK="${PERF_WORK:-$ROOT/build/perf}"
PREFIX="${BASELINE_PREFIX:-$WORK/baseline/inst}"
BUILD="$(dirname "$PREFIX")/src"

[ -f "$SRC/configure.ac" ] || { echo "build-baseline: $SRC is not an OpenSSH source tree" >&2; exit 1; }
for tool in autoreconf make gcc; do
    command -v "$tool" >/dev/null || { echo "build-baseline: $tool not found" >&2; exit 1; }
done

rm -rf "$BUILD"
mkdir -p "$BUILD" "$PREFIX"
echo "==> copying $SRC to $BUILD"
(cd "$SRC" && tar --exclude=.git -cf - .) | tar -C "$BUILD" -xf -
cd "$BUILD"
echo "==> configuring"
autoreconf -f -i >../autoreconf.log 2>&1
./configure --prefix="$PREFIX" --sysconfdir="$PREFIX/etc" \
    --with-privsep-path=/run/sshd --with-privsep-user=sshd >../configure.log 2>&1
echo "==> building"
make -j"$(nproc)" >../make.log 2>&1
make install-nokeys >../install.log 2>&1
echo "==> built: $("$PREFIX/bin/ssh" -V 2>&1 | head -1)"
