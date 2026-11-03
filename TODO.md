# TODO

Status: `[ ]` open, `[~]` in progress, `[x]` done.

## Open

- [ ] Install the built `.deb` on a clean Ubuntu VM or container and test install, upgrade, remove and purge, including the `hpnsshd` service and key generation.
- [ ] Run `lintian` on the built `.deb` and fix what it reports.
- [ ] Add a Debian target (`--target debian`).
- [ ] Add an RPM target for Fedora and RHEL.
- [ ] Decide whether to ship `/etc/default/hpnssh` (the unit already reads it if present).
- [ ] Decide how `hpn-ssh/` is kept in step with `openssh-portable/` (rebase, patch series, or leave it to the upstream HPN-SSH repo).

### sphynx-ssh review (found in `sphynx-ssh/` at `master` 2c7cc5554)

Bugs, most serious first. The OpenSSL 3 build (the Ubuntu build) uses `cipher-ctr-mt-functions.c`. `cipher-ctr-mt.c` is only built without OpenSSL 3, but it has the same bugs, so fix both.

Items marked `[x]` are committed on branch `fix/aes-ctr-mt-threading` in `sphynx-ssh/`, with one version per fix (see CHANGELOG.md).

- [ ] sphynx-ssh: the non-OpenSSL-3 build does not compile against this system's OpenSSL 3 headers: `cipher-chachapoly-libcrypto-mt.c:575-584` uses OpenSSL 1.1 struct members. That path is meant for OpenSSL 1.1 and LibreSSL, so it needs a test environment with those libraries before it can be checked.
- [ ] sphynx-ssh: the non-OpenSSL-3 cipher (`cipher-ctr-mt.c`) is compile-checked with zero warnings after the fixes, but it has not been run. Test it against OpenSSL 1.1 or LibreSSL.
- [ ] sphynx-ssh: each cipher context allocates about 17MB (33 queues of 512KB each, embedded in the context) even though only `numkq` queues are used. Allocate the queues for the thread count, or lower `MAX_THREADS`.
- [ ] sphynx-ssh: fix the 15 compiler warnings from a default build. Two are in files HPN changes: `scp.c:1798` (`-Wformat-truncation`) and `clientloop.c:2146` (`-Wdiscarded-qualifiers`). The others are in `mux.c:239`, `misc.c:866,1482`, `match.c:283`, `hostfile.c:85,510`, `getopt_long.c:441`, `base64.c:212`, `ssh-keygen.c:341`, and `log.c:402,415,471`.
- [ ] sphynx-ssh: review the open `XXX` notes in HPN-added code. `sshkey-xmss.c:126` hard-codes `state->k = 2`, and lines 496, 803 and 1108 say a const is wrong, the stack offset is unchecked, and padding is unchecked.
- [ ] sphynx-ssh: confirm the `strcpy` calls into `buf` in `binn.c:3503,3505` fit the buffer.
- [ ] sphynx-ssh: a full review of the HPN-only changes is still open. I did not read `scp.c` (+753 lines), `clientloop.c` (+299), `packet.c`, `kex.c`, `channels.c` or `sshconnect.c` in depth.

CI and repository hygiene (inherited from OpenSSH):

- [ ] sphynx-ssh: `c-cpp.yml` and `vm.yml` trigger on `master`, `dev_major`, `dev_minor` and `DynamicWindow`. Keep only the branches the fork uses.
- [ ] sphynx-ssh: `github-repo-stats.yml` runs daily and needs the secret `ghrs_github_api_token`, which the fork does not have. Remove it or configure the secret.
- [ ] sphynx-ssh: `cifuzz.yml` builds OSS-Fuzz's `openssh` project, which will not work for the fork. Remove it or retarget it.
- [ ] sphynx-ssh: `selfhosted.yml` and `upstream.yml` only run for `openssh/*` repositories. Remove them to avoid confusion.
- [ ] sphynx-ssh: no workflow sets `permissions:`, so the token has the default scope. Add `permissions: contents: read` at the top level and raise it per job only where needed.
- [ ] sphynx-ssh: pin third-party actions to full commit SHAs. `github-repo-stats` uses `@RELEASE` and the `vmactions/*` actions use `# v1`. The `# main` comments on the SHA pins are misleading.
- [ ] sphynx-ssh: `README.md` and `.github/ci-status.md` still describe upstream OpenSSH and its badges. Rewrite them for the fork.
- [ ] sphynx-ssh: run `make tests` (the `regress/` suite) on the fork and record the result, since the fork's CI does not clearly run HPN-specific tests.

## Done

- [x] sphynx-ssh: `pthread_attr_init` was never paired with `pthread_attr_destroy`. Fixed in both files. (0.1.2)
- [x] sphynx-ssh: unchecked `malloc` of the worker argument array in `cipher-chachapoly-libcrypto-mt.c`, which was then dereferenced. Fixed: the NULL case reports failure through `retval`. (0.1.1)
- [x] sphynx-ssh: `cipher-ctr-mt.c` called `exit(1)` from a worker thread on an invalid key length. Fixed: the key length is validated in init before any thread starts, and failures use `fatal()`. (0.1.0)
- [x] sphynx-ssh: unchecked allocations in the cipher threads. Fixed: `EVP_CIPHER_CTX_new()` results are checked, and the hash allocation is gone. (0.0.9)
- [x] sphynx-ssh: global state drove per-context behaviour. `cipher_threads` and `numkq` were globals that every init rewrote from `SSH_CIPHER_THREADS`, so a rekey could join a different thread count from the one started. Fixed: both are stored per context. The key is also copied into the context, since the caller's buffer need not outlive init. (0.0.8)
- [x] sphynx-ssh: the queue mutex and condition variable were destroyed before `pthread_join` (`cipher-ctr-mt.c`), and never destroyed at all (`cipher-ctr-mt-functions.c`), so each rekey leaked them. Fixed: join first, then destroy in the free path. (0.0.7)
- [x] sphynx-ssh: NULL dereference on the join path, when `HASH_FIND` returned NULL. Fixed by removing the hash lookup. (0.0.6)
- [x] sphynx-ssh: the hash key was a `pthread_t` (8 bytes on glibc), but `HASH_ADD_INT`/`HASH_FIND_INT` hashed and compared only `sizeof(int)` bytes. Fixed by removing the hash. (0.0.5)
- [x] sphynx-ssh: data race on the global `evp_ptrs` hash. Every pregen thread called `HASH_ADD_INT` with no lock. Fixed: the hash is gone. Each context now holds its per-thread EVP contexts, created before the thread starts and freed after the join. Found with ThreadSanitizer: 14 races at `cipher-ctr-mt-functions.c:248` on the original code, none after the fix. (0.0.4)
- [x] Ubuntu `.deb` target for `sphynx build` (0.0.1).
