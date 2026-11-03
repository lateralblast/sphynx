# Changelog

All notable changes to sphynx are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow the rules in `CLAUDE.md`.

## [Unreleased]

## [0.1.2] - 2026-11-03

### Fixed

- `sphynx-ssh` AES-CTR MT cipher: `pthread_attr_init` was never paired with `pthread_attr_destroy` in `cipher-ctr-mt-functions.c` and `cipher-ctr-mt.c`. The attribute is now destroyed once the threads are created.

## [0.1.1] - 2026-11-03

### Fixed

- `sphynx-ssh` ChaCha20-Poly1305 MT cipher: `cipher-chachapoly-libcrypto-mt.c` dereferenced the worker argument array without checking the `malloc`. A failed allocation is now reported through the manager's `retval`.

## [0.1.0] - 2026-11-03

### Fixed

- `sphynx-ssh` AES-CTR MT cipher: an invalid key length called `exit(1)` from a pregen thread (`cipher-ctr-mt.c`), or `fatal()` from inside the thread (`cipher-ctr-mt-functions.c`). The key length is now checked in `ssh_aes_ctr_init` / `aes_mt_start_threads` before any thread starts, and failures use `fatal()` on the calling thread.

## [0.0.9] - 2026-11-03

### Fixed

- `sphynx-ssh` AES-CTR MT cipher: allocations at pregen thread start-up were not checked. `EVP_CIPHER_CTX_new()` results are now checked in `cipher-ctr-mt-functions.c` and `cipher-ctr-mt.c`, and the per-thread hash allocation is gone (see 0.0.4). A failed `aes_mt_newctx` frees what it has already allocated.

## [0.0.8] - 2026-11-03

### Fixed

- `sphynx-ssh` AES-CTR MT cipher: `cipher_threads` and `numkq` were globals, rewritten from `SSH_CIPHER_THREADS` on every init. A rekey could stop and join a different number of threads from the number that were started. Both values are now stored per cipher context. The key is also copied into the context, because the caller's buffer need not outlive init.

## [0.0.7] - 2026-11-03

### Fixed

- `sphynx-ssh` AES-CTR MT cipher: the queue mutexes and condition variables were destroyed before `pthread_join` in `cipher-ctr-mt.c`, which is undefined while threads may still wait on them. In `cipher-ctr-mt-functions.c` they were never destroyed and leaked on every rekey. Threads are now joined first, and the locks are destroyed in the free path.

## [0.0.6] - 2026-11-03

### Fixed

- `sphynx-ssh` AES-CTR MT cipher: the join path freed `ptr->pointer` from a hash lookup without checking for NULL. The hash lookup is removed, so the join path no longer dereferences a lookup result.

## [0.0.5] - 2026-11-03

### Fixed

- `sphynx-ssh` AES-CTR MT cipher: the thread hash used `HASH_ADD_INT` and `HASH_FIND_INT` with a `pthread_t` key. Those macros hash and compare only `sizeof(int)` bytes, which is 4 of the 8 bytes of a glibc `pthread_t`. The hash is removed in 0.0.4, so the key is no longer used.

## [0.0.4] - 2026-11-03

### Fixed

- `sphynx-ssh` AES-CTR MT cipher: every pregen thread inserted into the global `evp_ptrs` hash with no lock, while the join path searched and deleted from it (`cipher-ctr-mt-functions.c`, `cipher-ctr-mt.c`). ThreadSanitizer reported 14 races on the insert. The hash is removed. Each context now owns its per-thread EVP contexts, which are created before their thread starts and freed after the join.

## [0.0.3] - 2026-11-03

### Changed

- The version string now includes the sphynx version: `OpenSSH_10.6p1_hpn18.12.0_sphynx0.0.3`. It is set by `SSH_SPHYNX` in `sphynx-ssh/version.h`, and `hpnssh -V`, `hpnsshd -V` and the SSH banner all show it.
- `sphynx build` stops with an error if `SSH_SPHYNX` in `sphynx-ssh/version.h` does not match the sphynx version.
- The Ubuntu package version now includes the sphynx version, for example `10.6p1+hpn18.12.0+sphynx0.0.3-1~resolute1`.

## [0.0.2] - 2026-11-03

### Changed

- `sphynx build` now defaults `--source` to `sphynx-ssh/`, your HPN-SSH fork, instead of `hpn-ssh/`.
- `sphynx-ssh/` is git-ignored by sphynx, like `hpn-ssh/`.

## [0.0.1] - 2026-11-03

### Added

- `sphynx build --target ubuntu` compiles HPN-SSH from `hpn-ssh/` and writes an Ubuntu `.deb` package to `dist/`.
- `sphynx build` options `--source`, `--out`, `--build-dir`, `--jobs` and `--series`, and the `SPHYNX_MAINTAINER` environment variable.
- `sphynx --version` and `sphynx --help`.
- Package `hpn-ssh` installs alongside OpenSSH, with `hpnssh`/`hpnsshd` programs, configuration in `/etc/hpnssh`, and an `hpnsshd` systemd service that listens on port 2222.
- Maintainer scripts create the `hpnsshd` user, generate any missing host keys on install, and purge host keys and the user on purge.
- `tests/run-tests.sh` checks the version, the command line, shellcheck, and the contents of a built package.
