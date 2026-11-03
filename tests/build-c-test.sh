#!/usr/bin/env bash
# Build a C test against a configured and built HPN-SSH tree.
#
# usage: tests/build-c-test.sh <build-tree> <test.c> <output>
set -euo pipefail

TREE="${1:?usage: build-c-test.sh <build-tree> <test.c> <output>}"
SRC="${2:?usage: build-c-test.sh <build-tree> <test.c> <output>}"
OUT="${3:?usage: build-c-test.sh <build-tree> <test.c> <output>}"

cc -g -O1 -I"$TREE" -I"$TREE/openbsd-compat/include" \
    -D_GNU_SOURCE -DHAVE_CONFIG_H -DOPENSSL_API_COMPAT=0x10100000L \
    "$SRC" -o "$OUT" \
    -L"$TREE" -L"$TREE/openbsd-compat" \
    -lssh -lopenbsd-compat -lssh -lopenbsd-compat -lcrypto -lpthread -lz
