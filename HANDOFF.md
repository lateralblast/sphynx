# Handoff

State of the project as of 2026-11-06, version 1.2.4, for picking the work up in a new session or after a restart. Outstanding work is in [TODO.md](TODO.md), history in [CHANGELOG.md](CHANGELOG.md), usage in [README.md](README.md), rejected ideas in [RESEARCH.md](RESEARCH.md). Nothing is committed: the user makes all commits.

## What exists

- `sphynx build --target ubuntu` builds `sphynx-ssh/` into a `.deb` (`hpn-ssh`; binaries `hpnssh`, `hpnsshd`, `hpnscp`, `hpnsftp`; config `/etc/hpnssh`; port 2222).
- `sphynx-ssh/` is OpenSSH master (`3c6ec4c63`, 2026-11-03, after 10.6) with HPN-SSH 18.12.0 merged in as patch 0000, and the sphynx patches on top. It is git-ignored by sphynx. Its git `HEAD` is still the old HPN-based commit, so the move shows as one large uncommitted diff (TODO item).
- `patches/` holds 57 patches and `BASE`. `tools/patches.sh check` clones `sphynx-ssh`, checks out `BASE`, applies the series and compares with the working tree. `BASE` must exist in `sphynx-ssh`'s object store: `git -C sphynx-ssh fetch ../openssh-portable 3c6ec4c637342c51d9c54bbeecef25fd185cfdb8` (once). Steps for taking a newer OpenSSH or HPN-SSH are in the README, "Patches".
- Patch 0042 and 0057 to 0068 were dropped in 1.2.2 because the new base has them. 0069 (`FallbackPort` timeout) fixes a regression the new base exposed.
- Version label: `OpenSSH_10.6p1_snapshot20261103_hpn18.12.0_sphynx1.2.4`; package `10.6p1+snapshot20261103+hpn18.12.0+sphynx1.2.4-1~resolute1`. The snapshot date is edited by hand in patch 0017 and `sphynx-ssh/version.h` when the base moves.
- Version must agree in `sphynx` (`SPHYNX_VERSION`), the README `Version:` line, the newest CHANGELOG heading, `sphynx-ssh/version.h` and patch 0017. `bump.py OLD NEW` (scratchpad) edits them; the series must be regenerated for 0017.

## Tests (last run, 1.2.4)

- Linux suite on the built `.deb` in the VM: 43 checks passed (`tests/run-tests.sh`, `tests/daemon-checks.sh` 29, `tests/scp-resume.sh` 27 for `scp -Z`).
- Mac `SPHYNX_SKIP_BUILD=1 tests/run-tests.sh`: 13 checks passed. `tools/patches.sh check`: ok, 57 patches.
- The Linux run skips the patch-series check because the VM's `sphynx-ssh` lacks the base commit (TODO item).
- Throughput on the merged tree equals the previous build (`aes256-gcm` about 1.1 to 1.2 GB/s, `chacha20-poly1305` about 0.95 GB/s on the VM loopback).

## Environment

- Linux tests run in the OrbStack Ubuntu arm64 VM `sphynx-build` (`orb run -m sphynx-build ...`; the Mac checkout is shared at `/Users/spindler/code/sphynx`). Scratch trees there: `/tmp/lb`, `/tmp/lbi`, `/tmp/lbt` (port 2395), `/tmp/tm`. They are lost if `/tmp` is cleared, so rebuild with `sphynx build`.
- x86-64 server `sysadmin@192.168.1.239` for `tools/perf` (needs `sudo`; network namespaces and `tc netem`). Results from earlier runs are in `~/sphynx-test/*.out` there (`nsloss`, `nsvar`, `nscomp`, `nspre`, and `perfrepo/build/perf/main.log` and `main.csv`). The local waiters that watched them died with the restart; the runs on the server may or may not have finished, so check `pgrep -f 'perf.sh run'` there before starting another.
- Scratchpad helpers (`mkpatch.sh`, `finish.py`, `bump.py`, `lsync.sh`, `tp.sh`) live in the session scratchpad and may be gone in a new session. `mkpatch.sh` makes the next patch from named `sphynx-ssh` files; `finish.py` bumps, writes the CHANGELOG entry and edits TODO and README. Recreate them if needed, or do the same steps by hand per `CLAUDE.md`.
- `sphynx-ssh-before-rebase.tar` in the scratchpad is a backup of `sphynx-ssh/` from before the base move.
- Blocked: the OpenSSL 1.1.1w source build in the VM was denied by the permission classifier. The user has not decided; do not work around it. It would unblock the two non-OpenSSL-3 items.

## Pitfalls hit

- BSD `sed -i` needs `''`; use python for edits. The shell is zsh: write test scripts for bash.
- Never `pkill -f` with a pattern that appears in your own command line; use `pkill -x python3` and the like.
- Heredocs with background jobs hang `orb run`. Wait for `lsync` copies (`sleep 2`) before running.
- `tools/patches.sh check` on macOS sometimes fails at cleanup (`Directory not empty`); rerun (TODO item).

## Suggested next steps

1. Review what the OpenSSH master move brought in (155 commits), reading the files HPN-SSH touches (`channels.c`, `packet.c`, `kex.c`, `sshconnect*.c`, `clientloop.c`, `serverloop.c`, `scp.c`) for regressions like the `FallbackPort` one. Not started.
2. Package the licences (copyright file with zstd and OpenSSH notices) and run `lintian`.
3. Make the Linux suite fetch the base commit or fail instead of skipping, and make the `patches.sh` cleanup retry.
4. The user commits `sphynx` and `sphynx-ssh`; then check `tools/patches.sh check` from the committed state.
5. Remaining performance and measurement items are listed in TODO.md (downloads, real-path `bbr`, connection setup, `IPQoS`).
