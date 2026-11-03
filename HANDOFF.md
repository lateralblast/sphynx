# Handoff

State of the project as of 2026-11-03, version 0.3.6, for picking the work up on another machine or in a new session. Outstanding work is in [TODO.md](TODO.md), history in [CHANGELOG.md](CHANGELOG.md), usage in [README.md](README.md).

## What exists

- `sphynx build --target ubuntu` builds the HPN-SSH fork in `sphynx-ssh/` into a `.deb` (`hpn-ssh`, binaries `hpnssh`, `hpnsshd`, `hpnscp`; config in `/etc/hpnssh`).
- `sphynx-ssh/` is a separate git repo (origin `richardatlateralblast/sphynx-ssh`, `upstream` = `rapier1/hpn-ssh`). It is git-ignored by sphynx, so clone it next to the sphynx checkout.
- Upstream base is `2c7cc5554` (HPN-SSH 18.12.0 on OpenSSH 10.6), recorded in `patches/BASE`.
- `patches/` holds 18 patches, one per modification, which apply to the base and reproduce `sphynx-ssh/`. `tools/patches.sh check` proves it. Patch 0017 contains the sphynx version string, so regenerate the series whenever the version changes (README, "Patches").
- Tests: `tests/run-tests.sh` (25 checks; `SPHYNX_SKIP_BUILD=1` skips the slow build). The OpenSSH `regress/` suite passed on the 0.3.4 fix build (87 checks).
- Version must agree in `sphynx` (`SPHYNX_VERSION`), the README `Version:` line, the newest CHANGELOG heading and `sphynx-ssh/version.h` (`SSH_SPHYNX`).

## Uncommitted work (the user commits; do not commit)

- sphynx: modified `CHANGELOG.md README.md TODO.md sphynx tests/run-tests.sh tools/perf/README.md tools/perf/perf.sh`; new `patches/`, `tools/patches.sh`, `HANDOFF.md`.
- If `tools/perf/__pycache__/analyze.cpython-314.pyc` was staged earlier, unstage it: `git rm --cached tools/perf/__pycache__/analyze.cpython-314.pyc`.
- sphynx-ssh, branch `fix/round2-bugs`: 15 changed files (`channels.c scp.c clientloop.c kex.c ssh.c cipher-chachapoly-libcrypto-mt.c version.h README.md`, plus the `.github` cleanup). The cipher-threading fixes are already committed on `fix/aes-ctr-mt-threading`.

## Findings worth remembering

- The full-CPU spin on long paths was in `channels.c`: `channel_pre_open` armed the input fd with `sshbuf_check_reserve()` while the read used `sshbuf_avail()`, which keeps 1/21 headroom, so `ppoll` returned at once with no read. Fixed in 0.3.4 (patch 0016).
- On long paths both clients are held back by the kernel send buffer limit (default `tcp_wmem` max 4 MB). With 32 MB, HPN-SSH reaches 107 MB/s at 50 ms and 99 MB/s at 100 ms against 38 and 19 for OpenSSH. `tools/tune-tcp.sh` applies and reverts this; nothing in the package changes system TCP settings.
- The perf tool needs `sudo` (network namespaces and `tc netem`). `tools/perf/README.md` has the commands.
- Shell pitfalls hit earlier: the shell is zsh, so write test scripts for bash; never `pkill -f` with a pattern that appears in your own command line.

## Suggested next steps

1. Commit the work above.
2. Test the `.deb` on a clean Ubuntu VM (install, upgrade, remove, purge) and run `lintian`.
3. Investigate the remaining 1 to 2 CPU-s/GB extra HPN client CPU at the default 4 MB limit.
4. Triage the unconfirmed round 2 items in TODO.md, writing a failing test first for each.
5. Debian and RPM targets.
