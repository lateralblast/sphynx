# Changelog

All notable changes to sphynx are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow the rules in `CLAUDE.md`.

## [Unreleased]

## [0.8.2] - 2026-11-05

### Fixed

- `sphynx-ssh` `sshconnect.c`: with `HappyEyes yes` a failed connection was reported as `ssh: connect to host H port : reason`, with no port, because the message used a string that only the address loop fills in. It now prints the port that was asked for. Patch 0037; `tests/run-tests.sh` checks the message names the port.

## [0.8.1] - 2026-11-05

### Added

- `tests/daemon-checks.sh` automates the check of the `scp` to `hpnscp` rewrite (0.2.2): it builds `clientloop.c` with AddressSanitizer into a copy of the tree, starts a control master against the test daemon, runs a session whose command starts with `scp`, and requires the master to still be running. With the old `clientloop.c` the master dies on the heap use after free. The suite runs it on Linux, and it skips itself if the sanitizer build fails.

## [0.8.0] - 2026-11-05

### Added

- `tests/scp-resume.sh` tests the error paths of the `scp -Z` resume: a sink whose file size limit is lower than the file it is resuming (`ulimit -f` with `SIGXFSZ` ignored) must fail, put the existing file back to its length and leave no temporary file, both when the appended tail does not fit and when the tail cannot be written at all; a control with a higher limit succeeds. They run in the Linux suite, with no code change.

## [0.7.9] - 2026-11-05

### Fixed

- `sphynx-ssh` `happyeyeballs.c`: with `HappyEyes yes`, another open descriptor between two of its sockets made it read an `fd_ai` entry that was never set (a null pointer dereference with this build's zeroed locals), and a connect that failed at once was reported as `failure` because `errno` had been cleared. It now reads the entry only for its own sockets, clears the array and keeps the error. Patch 0036; `tests/c/happyeyeballs_gap.c` crashed the old code with signal 11 and passes, and `tests/run-tests.sh` checks the message.

## [0.7.8] - 2026-11-05

### Fixed

- `sphynx-ssh` `cipher-chachapoly-libcrypto-mt.c`: after a `fork()` in the middle of a session (`~&`, or `ControlPersist` on a control master) the multithreaded ChaCha child tried to join manager threads that only the parent had, and never had the keystream they were making; the guard for it was under `#ifdef SAFETY`, which nothing defines. A `pthread_atfork()` handler now counts forks, and a context copied by a fork regenerates its keystream before it is used. The unit test killed the old child (a crash) and passes now. Patch 0035; `tests/c/chachapoly_mt_fork.c`. Not changed: a `pthread_create` failure in the crypt path still leaves the sequence number advanced, which ends the connection and is benign on glibc.

## [0.7.7] - 2026-11-05

### Fixed

- `sphynx-ssh` `kex.c`, `cipher.c` and `cipher-chachapoly-libcrypto.c`: the key exchange threw away a string from `match_list()` each time (a small real leak), `cipher_init()` loaded the provider and fetched the multithreaded AES-CTR cipher on every start and never released them, and `chachapoly_new()` kept the reference to the POLY1305 MAC. The provider and cipher are now loaded and fetched once, and the MAC reference is released. The OpenSSL objects are cached, so those references were counters and not growing memory, and no test can see them; `tests/c/cipher_leaks.c` counts OpenSSL's allocations over repeated starts and checks the multithreaded AES-CTR bytes, and `tests/daemon-checks.sh` sends data over `aes256-ctr` through the switch. Patch 0034. Also fixes a `const` warning in patch 0029's `kex.c` change.

## [0.7.6] - 2026-11-05

### Fixed

- `sphynx-ssh` `readconf.c` and `packet.c`: `MetricsInterval` and `FallbackPort` accepted any value that parsed, so `MetricsInterval 0` polled on every pass of the client loop and a port above 65535 reached the resolver. They now accept 1 to 86400 and 1 to 65535. `ssh_set_newkeys()` returned a stale 0 when it could not find the multithreaded ChaCha cipher, and now returns an error; that path cannot be reached today. Patch 0033; `tests/run-tests.sh` checks the limits.

## [0.7.5] - 2026-11-05

### Fixed

- `sphynx-ssh` `hpnsshd_config.5`: `DisableMTAES` is documented as covering only the multithreaded AES-CTR cipher, and it does. The review report that it should also stop the server promoting to multithreaded ChaCha is not a bug in the code; the page now says that `DisableMTAES` leaves ChaCha alone and that leaving `chacha20-poly1305-mt@hpnssh.org` out of `Ciphers` keeps the serial ChaCha. Patch 0032.

## [0.7.4] - 2026-11-05

### Fixed

- `sphynx-ssh` `readconf.c`: a `MetricsPath` in a `Host` block that did not match turned metrics on for every connection, and a `MetricsPath` after `Metrics no` overrode it. `MetricsPath` now turns metrics on only in a block that applies and only when `Metrics` is not set. Patch 0031; `tests/run-tests.sh` checks the three cases with `hpnssh -G`.

## [0.7.3] - 2026-11-05

### Fixed

- `sphynx-ssh` `kex.c` and `packet.c`: the flag that turns the MAC off for the none MAC was connection-wide and never cleared, so a none/none result in one direction switched the MAC off in the other, and it stayed off after a rekey back to a real cipher. Each direction now decides from its own MAC name, and the flags are cleared at the start of each negotiation. Patch 0030. The existing none switch checks in `tests/daemon-checks.sh` still pass; the asymmetric case cannot be set up from the client options, so it has no test of its own.

## [0.7.2] - 2026-11-05

### Fixed

- `sphynx-ssh` `kex.c`: with `NoneMacEnabled`, a client that listed `none` in `MACs` negotiated a real cipher such as `aes256-ctr` with the MAC `none` in the first key exchange, so the stream had no integrity check before login. The none MAC is now dropped from the lists unless the cipher is `none` and the connection is authenticated, and the next MAC in the list is used. Patch 0029; `tests/daemon-checks.sh` checks that it is refused with a real cipher and still used after the none switch.

## [0.7.1] - 2026-11-05

### Fixed

- `sphynx-ssh` `serverloop.c` and `packet.c`: the server wrote its `LType: Throughput` log line twice for a session that ended in the server loop (a client that dropped the connection without a disconnect message), and printed `inf` or `nan` rates for a session of zero length. It now writes the line once, after the channels close, and reports a rate of 0 for a zero-length session. Patch 0028; `tests/daemon-checks.sh` kills a client and counts the lines.

## [0.7.0] - 2026-11-05

### Fixed

- `sphynx-ssh` `clientloop.c`: the client loop keeps HUP, INT, QUIT and TERM blocked and unblocks them only inside `ppoll()`, so a command started from `~C` then `!cmd`, and the `xauth` command run for a session opened through a control master, inherited a mask that ignored those signals (`SigBlk: 0000000000004007`). They now start with the loop's original mask. Patch 0027; `tests/escape-sigmask.py` and `tests/daemon-checks.sh` check it on a pseudo terminal.

## [0.6.9] - 2026-11-05

### Fixed

- `sphynx-ssh` `ssh.c`: `hpnssh` with `FallbackPort` set to the default port (2222) retried a failed connection for ever, leaking the resolved addresses on every pass. It now falls back once and exits with status 255. Patch 0026; `tests/daemon-checks.sh` checks it.

## [0.6.8] - 2026-11-05

### Fixed

- `sphynx-ssh` `sshconnect2.c`: the rekey that switches to the none cipher after login (`NoneSwitch yes`) dropped the client's `KexAlgorithms` and used the built-in list, so a client set to `curve25519-sha256` rekeyed with `mlkem768x25519-sha256`. With `NoneMacEnabled` it also leaked the first proposal. It now keeps the setting and builds and frees the proposal once. Patch 0025; `tests/daemon-checks.sh` checks the rekey's algorithm.

## [0.6.7] - 2026-11-05

### Fixed

- `sphynx-ssh` `clientloop.c` and `metrics.c`: `Metrics yes` leaked a buffer on every poll (every 5 s by default) because the local metrics object was never freed, leaked the local file on one error path, and ended the whole session with `fatal()` when `MetricsPath` could not be written. It now frees the object and closes the file on every path, reports a file it cannot open once, and carries on. The output string is zeroed, so a bad object no longer prints garbage. Patch 0024; `tests/daemon-checks.sh` (new, starts a daemon from the build tree) checks that a session survives an unwritable `MetricsPath` and that the metrics files are written.

## [0.6.6] - 2026-11-05

### Fixed

- `sphynx-ssh` `clientloop.c` and `metrics.c`: the HPN-SSH client no longer reads past the packet when the server's metrics reply (`Metrics yes`) is short or malformed. The reply was passed to the binn parser with no size, the result of reading it from the packet was ignored, and an empty reply was parsed anyway. `metrics_blob_valid()` now checks it is one whole binn object of the length received, and a bad reply is reported and skipped. Patch 0023, with `tests/c/metrics_blob.c`, which feeds it truncated and corrupted objects under AddressSanitizer.

## [0.6.5] - 2026-11-05

### Added

- Patch 0022 adds a compression method, `huff0@hpnssh.org`. `Compression yes` (`hpnssh -C`) uses it when both ends have it, and falls back to `zlib@openssh.com` when the other end is an older HPN-SSH or OpenSSH, so nothing changes against them. It codes each packet on its own with the Huffman coder from zstd and keeps no state between packets, so it has no shared dictionary, and it sends the same 65 percent of log text as zlib's Huffman-only mode at about a quarter of the client CPU. On the x86-64 server at 1 Gbit/s over 50 ms it gave 130.7 MB/s on compressible data, against 93.9 with no compression and 51.4 with zlib; on a LAN it is 4.3 times faster than zlib but still slower than no compression, and on 100 and 10 Mbit/s links it matches zlib's speed. `hpnssh -Q compression` lists it. The coder is copied from zstd 1.5.7 into `sphynx-ssh/huff0/` with its licence files. The README "Compression" section has the method, its results and its limits.
- `tests/c/huff0_roundtrip.c` tests the method: round trips from 0 to 256 KiB on four kinds of data, malformed and corrupted streams, clean under AddressSanitizer. The suite runs it and checks that `hpnssh -Q compression` lists the method.

### Changed

- `tools/patches.sh check` counts files that are not committed yet, so a patch that adds files can be checked before the commit.
- The TODO item on better SSH compression is closed. New items cover measuring downloads and the receiver's CPU, shipping the licences in the `.deb`, a daemon-based compression test and an opt-in dictionary mode.

## [0.6.4] - 2026-11-05

### Added

- `tools/perf/huff0-bench.c` times zlib's Huffman-only mode, zlib level 6 and `huff0` (zstd's Huffman coder, which has no dictionary) on 32 KiB packets, and the README "Compression" section reports it: `huff0` sends the same 64 percent of log text as the Huffman-only mode `Compression yes` uses, and compresses 8 to 10 times faster (615 against 78 MB/s on the x86-64 server, 1407 against 148 on an M1 Max). It is a standalone benchmark and is not built into `hpnssh`.

## [0.6.3] - 2026-11-05

### Changed

- The README "Compression" section now says why the compressor is Huffman-only: OpenSSH commit `1d5340fce` (2026-09-22) did it on purpose to stop a plaintext-recovery attack through the dictionary shared by all channels of a session, at the cost of compression ratio. The earlier text that called the reason unknown, and that said compression "never helped much", is corrected. The open TODO item is rewritten around whether to offer a dictionary or zstd mode as an opt-in.

## [0.6.2] - 2026-11-04

### Added

- The README has a "Compression" section, the first measurement of `Compression yes`. The compressor is zlib at its fastest level with the Huffman-only strategy (`packet.c`), so it cannot beat 8 to 1 and sent 65 percent of log text that `gzip -6` shrinks to 24 percent. It helps only on slow links with compressible data, by about 1.5 times (100 and 10 Mbit/s), does nothing for random data while using 4 to 9 times the CPU, and slows a connection on a fast link (HPN-SSH down 38 to 46 percent at 1 Gbit/s, about 8 to 11 times slower on a LAN). Compressing with `zstd -3` before sending was 3.5 to 4 times faster than plain on slow links. The TODO item on compression is closed.

## [0.6.1] - 2026-11-04

### Added

- The README has a "scp, sftp and mixed pairs" section, the first results from `tools/perf` on Linux (216 runs, none failed). `scp` and `sftp` behave like `ssh`: 2.6 to 2.7 times faster than OpenSSH on a 50 ms path. The gain comes from the server: an OpenSSH client uploading to an HPN-SSH server got 93 to 99 MB/s, and an HPN-SSH client uploading to an OpenSSH server got OpenSSH's 36 to 37. The `sftp` request size and queue depth (`-B`, `-R`) are not a limit at their defaults, and only a small `-R` (16) lowered HPN-SSH, to 72 MB/s. `sftp -B 262144` fails because of the 256 KiB message limit. HPN-SSH takes 60 to 130 ms longer to connect. The TODO item on `scp` and `sftp` is closed.
- `tools/perf/README.md` says what has now been run on Linux and how to test a build tree.

## [0.6.0] - 2026-11-04

### Added

- `tools/perf/perf.sh run` takes `--sftp-opts` and `--scp-opts`, extra options for `sftp` (for example `"-B 131072 -R 256"`) and `scp` (for example `"-X nrequests=128"`). They are part of the tool name in the CSV, as `sftp(-B_131072_-R_256)`, so one CSV can hold several settings. `tests/run-tests.sh` checks the names in a dry run.

### Fixed

- `tools/perf/perf.sh run` no longer records a client that failed as a measurement. When a client died before timing anything, for example `sftp -B 262144` (`Outbound message too long`), the last line of its output was read as the elapsed time and the CSV got `sftp>` in the number columns. A run is now kept only if it gives three numbers; otherwise it is `nan`, shown as `-` by `analyze`, and reported on standard error.

## [0.5.9] - 2026-11-04

### Changed

- The README's Performance section is reorganised. It opens with a summary table of the questions the measurements answer, and the sections follow in themes: against OpenSSH on a clean path, packet loss and congestion control (loss, jitter and the other TCP settings together, with one set of conclusions), ciphers and MACs, where the time goes, and the settings that made no difference (cipher threads, rekeying, OpenSSL version, packet size), then macOS. Out-of-date statements are corrected (the version strings in the examples, `tune-tcp.sh` not setting the congestion control, loss and jitter "not covered"), and first-person wording is removed.

### Added

- The README gives the server CPU that patch 0021 saves: 0.07 CPU-seconds per GB with `aes256-gcm` (3.8 percent), 0.09 with the multithreaded ChaCha (3.3 percent) and 0.03 with `aes256-ctr` (1.2 percent, probably noise), over 5 transfers of 4 GB per cipher. The figures are also in the patch's commit message and the patch table.

## [0.5.8] - 2026-11-04

### Added

- The README's "Packet loss and congestion control" section has a faster case: an emulated 10 Gbit/s, 30 ms path with loss and jitter. 5 ms of jitter (which reorders packets) with no loss cut `cubic` from 303 to 114 MB/s, while `bbr` stayed at 301; with 0.02 % loss as well, `cubic` fell to 67 MB/s and `bbr` held 298. This closes the jitter part of the earlier TODO item. It is an emulation on one machine, not a real link.

## [0.5.7] - 2026-11-04

### Added

- The README has a "Packet size" section and `RESEARCH.md` records the result for the default cipher: 64 KiB packets do not speed up the multithreaded ChaCha (567 against 570 MB/s on x86-64), and only the serial ChaCha gains (about 9 percent), so the change is not worth making. The TODO item on packet size is closed.

## [0.5.6] - 2026-11-04

### Added

- The README has a "Where the time goes" section: a `perf` profile of the client and server on Linux x86-64 during a loopback transfer. About 85 percent of the sender is the kernel and the cipher. The part the program controls is about 5 percent `memcpy` and 3.5 percent `memset` in the `sshbuf` packet buffers, and a 32 KiB zero-fill in the server (removed in 0.5.5). The TODO item to profile on Linux is closed.

## [0.5.5] - 2026-11-04

### Changed

- `hpnsshd` and `hpnssh` no longer zero a 32 KiB buffer on every pass of their event loop. `channel_handle_efd_read` in `sphynx-ssh/channels.c` declared its read buffer before an early return, and the build's `-ftrivial-auto-var-init=zero` zeroes it where it is declared, so each call wrote 32 KiB for nothing. A `perf` profile of the server put 5.2 percent of its samples there; `memset` fell from 8.5 to 4.8 percent of the server's samples. Throughput did not change in a loopback test, which the sender limits, so this saves server CPU. This is patch 0021.

## [0.5.4] - 2026-11-04

### Added

- `tools/tune-tcp.sh` can set the congestion control on Linux: `--cc bbr` adds `net.ipv4.tcp_congestion_control` to what `show`, `apply` and `persist` do, and `--cc-only` leaves the buffer maximums alone. It loads `tcp_bbr` with `modprobe` if it is not loaded, `persist` writes it to `/etc/sysctl.d/99-hpn-ssh-tcp.conf` with a `/etc/modules-load.d/99-hpn-ssh-tcp.conf` entry for the module, and `revert` puts back the previous algorithm and removes both files. It is refused on macOS. With `bbr`, HPN-SSH kept its speed under loss and jitter where the default `cubic` did not (see the README). `tests/tune-tcp.sh` checks it against a stand-in `sysctl` and `modprobe`, and sets a real congestion control in a throwaway namespace.

## [0.5.3] - 2026-11-04

### Fixed

- HPN-SSH built against OpenSSL 4.1 no longer crashes on `aes128-ctr`, `aes192-ctr` and `aes256-ctr`. `aes_mt_get_ctx_params` and `aes_mt_set_ctx_params` in `sphynx-ssh/cipher-ctr-mt-provider.c` used the `EVP_CIPHER_CTX` libcrypto gave them as the cipher state itself, instead of fetching the state from its app data as the rest of the provider does, so they read 17 MB past the end of a small allocation and wrote the key length into the wrong structure. With OpenSSL 3.5 this went unnoticed. This is patch 0020. The Ubuntu package, built with OpenSSL 3.5, was not affected.

### Added

- `tests/c/aes_ctr_mt_init.c` starts every AES-CTR key size through `cipher_init()` with threads, for both directions, and checks that the output matches the unthreaded cipher. It crashes without patch 0020 on OpenSSL 4.1 and passes on 3.5 and 4.1 with it.

## [0.5.2] - 2026-11-04

### Fixed

- The README and `tools/suggest-cipher.sh` overstated AES-GCM's lead over HPN-SSH's default cipher. The raw `openssl speed` ratio (1.7 to 3.7 times per core) is against single-threaded ChaCha, and end to end AES-GCM led the default multithreaded ChaCha by only 5 to 6 percent. The text now says so, and `aes256-ctr` is no longer described as slower than AES-GCM on every machine: with the faster XOR loop it was ahead on the Mac and behind on x86-64.

### Added

- The README has a "Cipher choice end to end" table of all five ciphers on macOS arm64 and Linux x86-64.

## [0.5.1] - 2026-11-04

### Added

- The README has an "Other TCP settings" section: `tcp_notsent_lowat`, a larger initial congestion window and an `fq` qdisc did not fix `cubic`'s stalls at 0.1 % loss (one run in four went over 80 seconds with each), and `fq` did not help `bbr`. The TODO item on cheap TCP settings is closed.

## [0.5.0] - 2026-11-04

### Added

- The README has a "Packet loss and congestion control" section. On an emulated 50 ms, 1 Gbit/s path `bbr` held about 68 MB/s from 0.02 % to 0.2 % loss per direction, while the default `cubic` fell to 58 MB/s at 0.05 %, was erratic from 0.1 % and did not finish at 0.5 %. HPN-SSH kept 53 MB/s at 0.5 % against OpenSSH's 24 MB/s with `bbr`. It is a sender-side kernel setting, not an HPN-SSH option. The packet loss part of the TODO item on loss, jitter and congestion control is closed.

## [0.4.9] - 2026-11-04

### Added

- The README has an "OpenSSL version" section comparing HPN-SSH built against OpenSSL 3.5.9 and 4.1.0: the same speed for ChaCha and AES-GCM. It also records that a build against OpenSSL 4.1 crashes on `aes256-ctr`, which is now in `TODO.md`. The TODO item to investigate the OpenSSL 3 provider path is closed.

## [0.4.8] - 2026-11-04

### Added

- The README has a "Rekeying" section: 8 GB transfers with the default `RekeyLimit`, `1G` and `256M` show no stall at a rekey for `aes256-ctr`, ChaCha or AES-GCM, so there is no reason to raise `RekeyLimit` for throughput. The TODO item to investigate rekeying is closed.

## [0.4.7] - 2026-11-04

### Changed

- The README documents `tools/suggest-cipher.sh` in its own section, "Choosing a cipher and MAC", with its options, sample output, how it chooses, how to use the result and its limits. It was a short subsection under Performance.

## [0.4.6] - 2026-11-04

### Added

- `tools/suggest-cipher.sh` reads the CPU, times AES-256-GCM and ChaCha20-Poly1305 with `openssl speed` (or decides from the AES instruction flag with `--no-measure`) and prints the `Ciphers` and `MACs` lines that suit the machine. `--config` prints only those two lines, `--seconds N` sets the timing length. It changes nothing. `tests/run-tests.sh` checks the choice against stand-in CPU and `openssl` output, and that `hpnssh` accepts every name it prints.

## [0.4.5] - 2026-11-04

### Changed

- `aes256-ctr` (and the other multithreaded AES-CTR ciphers) is 4 to 7 percent faster. `aes_mt_do_cipher` in `sphynx-ssh/cipher-ctr-mt-functions.c` XORed the keystream into the data one 16 byte block at a time, with an alignment test and a modulo for each. It now XORs as much as the current keystream queue covers in one pass. Over loopback: macOS arm64 856 to 919 MB/s, Linux x86-64 519 to 541 MB/s. This is patch 0019.

### Added

- `tests/c/aes_ctr_mt_crypt.c` checks the multithreaded AES-CTR cipher against OpenSSL's AES-256-CTR for chunks of assorted sizes across several keystream queue switches. It passes on the old and the new loop.

## [0.4.4] - 2026-11-04

### Added

- The README has a "Cipher threads" section: throughput of `aes256-ctr` with 1 to 8 `SSH_CIPHER_THREADS` on Linux and macOS. More threads did not help, so the default of 1 stays.

## [0.4.3] - 2026-11-04

### Added

- The README has a "Choice of MAC" section: throughput of `aes256-ctr` with each MAC, on Linux and macOS. The default (`umac-64-etm@openssh.com`) is already the fastest, and `hmac-sha2-512` costs about 40 percent.

## [0.4.2] - 2026-11-04

### Fixed

- `tools/tune-tcp.sh apply` works on macOS for a target above 28 MiB, which includes its 32 MiB default and `--bandwidth 1gbit --rtt 100ms`. macOS refuses a `kern.ipc.maxsockbuf` above 32 MiB (`Result too large`), so the script stopped and changed nothing. The target is now limited to 28 MiB on macOS and the plan says so.

### Added

- The README has a "Performance on macOS" section with loopback results for HPN-SSH against OpenSSH, with and without raised TCP limits, and says what was not measured. `tests/tune-tcp.sh` checks the 28 MiB limit.

## [0.4.1] - 2026-11-04

### Changed

- The README's Performance section now says all its results were measured on Linux (Ubuntu 26.04), none on macOS.

## [0.4.0] - 2026-11-04

### Fixed

- Installing the package again after `apt remove` (not purge) now starts `hpnsshd`. `packaging/ubuntu/postinst` ran `try-restart` whenever dpkg passed an old version, which does nothing to a stopped service, so the service was left enabled but inactive. It now runs `restart`; a service the administrator disabled stays disabled.

## [0.3.9] - 2026-11-03

### Fixed

- The packaged `/etc/hpnssh/sshd_config` now sets `UsePAM yes`, as Ubuntu's `sshd_config` does. It was left at the upstream default of `no`, so `hpnsshd` refused a key login to an account with a locked password (`User ... not allowed because account is locked`), which is the default user on cloud images, and the shipped `/etc/pam.d/hpnsshd` was never used. `sphynx build` sets it while packaging and stops if it cannot; `sphynx-ssh` is unchanged.

## [0.3.8] - 2026-11-03

### Added

- `tools/perf/perf.sh run` can time `scp` and `sftp` (`--tools`), every pairing of OpenSSH and HPN-SSH client and server (`--pairs`, for example `hpn:base`), several `SSH_CIPHER_THREADS` values (`--threads`, restarting `hpnsshd` for each), and packet loss and jitter (`wan50_loss0.5`, `wan100_loss0.1_jit5`). `--dry-run` prints the cases and `netem` settings without `sudo`.
- The results CSV has the columns `tool`, `server` and `threads`, and `tools/perf/analyze.py` prints each tool and condition with a column for every pairing and a row for every thread count. It still reads the older files.
- Both test servers now configure the SFTP subsystem.
- None of this has been run on Linux yet; it is checked only by `--dry-run` and `analyze` tests in `tests/run-tests.sh`.

## [0.3.7] - 2026-11-03

### Added

- `tools/tune-tcp.sh` now works on macOS. `show` and `apply` size and raise `net.inet.tcp.autosndbufmax` and `net.inet.tcp.autorcvbufmax`, and raise `kern.ipc.maxsockbuf` far enough to hold them (the kernel counts about 1/8 of overhead against it). `--send-only` leaves the receive maximum alone. `persist` and `revert` are refused on macOS with an explanation, since macOS has no `sysctl.d`: a setting from `apply` lasts until the next reboot.
- `tests/tune-tcp.sh` runs the macOS code on any system against a stand-in for `sysctl` (`TUNE_TCP_OS=Darwin`), and runs the size and input checks on macOS too. Before, the whole file failed on macOS.

### Fixed

- `tools/tune-tcp.sh` no longer needs bash 4. It failed with "bad substitution" under the bash 3.2 that macOS ships.

## [0.3.6] - 2026-11-03

### Added

- `patches/`, the changes sphynx makes to HPN-SSH as a series of 18 patches on top of upstream HPN-SSH (`patches/BASE` names the commit). Sixteen are bug fixes, each with a message that says what was wrong and how it was checked, and two are specific to this fork. See "Patches" in `README.md`.
- `tools/patches.sh` checks that the series applies to the upstream commit and reproduces `sphynx-ssh/` (`check`), and applies it to any git checkout (`apply`), for example a newer HPN-SSH release.

## [0.3.5] - 2026-11-03

### Fixed

- `tools/perf/perf.sh run` now starts every run from the host's own TCP limits. The test namespaces kept the `--wmem` and `--rmem` of an earlier run, so a run made without them could silently use the larger buffers of the run before it.

## [0.3.4] - 2026-11-03

### Fixed

- `sphynx-ssh` `channels.c`: the HPN-SSH client and server could spin at full CPU during bulk transfers. Reading a channel's input is armed with `sshbuf_check_reserve()`, but the read itself (`channel_handle_rfd()`) only goes ahead when `sshbuf_avail()` is non-zero, and for channel input buffers `sshbuf_avail()` keeps about 1/21 of the buffer as headroom that `sshbuf_check_reserve()` does not know about. While the buffer sat in that headroom, `ppoll()` returned at once because the input was readable, the read was skipped, and the loop repeated until the send side drained the buffer. Arming now uses the same test as the read (`channel_input_can_read()`), in `channel_pre_open()` and `channel_pre_mux_client()`.

### Changed

- The `README.md` performance tables are measured again on 0.3.4, with the default TCP limits and with a 32 MB send buffer limit, and the CPU wording is corrected. Over 50 ms and 100 ms paths the HPN-SSH client now uses 1.8 to 3.3 CPU-seconds per GB, against 19 and 37 before, with unchanged throughput.

## [0.3.3] - 2026-11-03

### Added

- `tools/tune-tcp.sh` applies the TCP buffer tuning described in the README. `show` prints what would change and needs no privileges, `apply` sets the new maximums until the next reboot, `persist` also writes `/etc/sysctl.d/99-hpn-ssh-tcp.conf` and records the old values, and `revert` puts them back. With `--bandwidth` and `--rtt` it sizes the maximum from the path (2.5 times the bandwidth-delay product). It only raises a maximum, never lowers one, asks for confirmation unless you pass `--yes`, and refuses to run without a terminal otherwise.
- `tests/tune-tcp.sh` tests it. The checks that change settings run inside a throwaway network namespace and are skipped without passwordless `sudo`.

## [0.3.2] - 2026-11-03

### Added

- `tools/perf/`, a performance comparison of OpenSSH and HPN-SSH. `perf.sh setup` builds two network namespaces joined by a virtual link and starts both servers, `perf.sh run` times transfers under `tc netem` delay and a rate limit and writes a CSV, `perf.sh analyze` summarises it, and `perf.sh teardown` removes everything. `build-baseline.sh` builds vanilla OpenSSH from `openssh-portable/` as the baseline. Nothing is changed on the host's own network or kernel settings. See `tools/perf/README.md`.

### Changed

- The `README.md` performance table shows the range of the HPN-SSH client's CPU use where runs differ. It showed only the median, which hid that the client sometimes uses about a full core and sometimes 2 to 3 CPU-seconds per GB for the same transfer.
- `tests/run-tests.sh` checks `tools/perf` with shellcheck and tests the analysis script against a small fixture.

## [0.3.1] - 2026-11-03

### Added

- The package installs `/usr/share/doc/hpn-ssh/examples/99-hpn-ssh-tcp.conf`, an example that raises the maximum TCP send buffer (`net.ipv4.tcp_wmem`) to 32 MB. It is not enabled: the package never changes system-wide TCP settings, and you copy the file to `/etc/sysctl.d/` yourself to use it.
- `README.md` has a section, "TCP buffers on long, fast paths", that explains why the send buffer limit caps HPN-SSH on long paths, how to enable the example, and measured throughput against OpenSSH 10.6.

## [0.3.0] - 2026-11-03

### Fixed

- `sphynx-ssh` `scp -Z` resume (`scp.c`): per-file resume state is released at the top of every loop pass, so an early `continue` or an error no longer leaves a stale temporary name for the next file to reuse or overwrite. `npstat` is zeroed before `stat()`, so the mode sent to the peer is no longer uninitialised stack data. The unused `stat(cp, &cpstat)` call is removed.

## [0.2.9] - 2026-11-03

### Fixed

- `sphynx-ssh` `scp -Z` resume (`scp.c`): the hash field is checked for its full length before it is read, so a short line can no longer make the receiver read past the end of the record. `calculate_hash` always produces a fixed-width field: it returns 128 `0` characters on any failure (file not readable, digest unavailable, file shorter than requested) instead of an empty or one-space value or uninitialised data. `BUF_AND_HASH` is parenthesised.

## [0.2.8] - 2026-11-03

### Fixed

- `sphynx-ssh` `scp -Z` resume (`scp.c`): the sender now checks what the remote sends back. It checks that the 191-byte resume response was read completely (and shows the remote's error message if that is what arrived), checks every field, and treats a remote size larger than the local file as a mismatch instead of computing a negative transfer size. The receiver treats an unexpected `F` match status as a protocol error instead of skipping the file's data.

## [0.2.7] - 2026-11-03

### Fixed

- `sphynx-ssh` `scp -Z` resume (`scp.c`): joining the received tail onto the existing file now reports its errors. A failed open, read, write or close is noted and sent to the sender instead of leaving a truncated destination reported as success, and the existing file is restored to its original length. The copy loop ends at end of file instead of spinning forever, and a tail that was not fully written is no longer appended.

## [0.2.6] - 2026-11-03

### Fixed

- `sphynx-ssh` `scp -Z` resume (`scp.c`): the sender's match status was set once per `source()` call and never reset, so a later file in the same transfer could send an earlier file's `M` or `F`, which desynchronised the protocol. It is reset for every file.

## [0.2.5] - 2026-11-03

### Fixed

- `sphynx-ssh` ChaCha20-Poly1305 MT cipher (`cipher-chachapoly-libcrypto-mt.c`): a packet longer than the pregenerated keystream (about 32 KB) or an additional-data length over 64 bytes now returns `SSH_ERR_INVALID_ARGUMENT` before any keystream is read. Previously the XOR read past `mainStream` into neighbouring state, which gave wrong plaintext or could crash.

## [0.2.4] - 2026-11-03

### Fixed

- `sphynx-ssh` `ssh.c`: `ssh -T` no longer disables the none cipher switch. The none cipher is only allowed on sessions without a tty, which is what `-T` asks for, so `ssh -T -oNoneSwitch=yes` always lost it. The disable now applies to `-t`, the interactive case the comment described.

## [0.2.3] - 2026-11-03

### Fixed

- `sphynx-ssh` `kex.c`: `patch_list` inserted the serial ChaCha cipher name at an offset taken from the wrong string, so a `Ciphers` list where `chacha20-poly1305-mt@hpnssh.org` was not first produced a corrupted proposal. It now finds the MT cipher as a whole entry and inserts the serial name straight after it.

## [0.2.2] - 2026-11-03

### Fixed

- `sphynx-ssh` `clientloop.c`: rewriting `scp` to `hpnscp` freed the caller's command buffer and replaced only its own pointer, leaving the caller with a dangling pointer (a double free on the mux path). The buffer is now edited in place. The command is copied with `sshbuf_dup_string`, so it is always NUL-terminated, and the unchecked `malloc` and `sprintf` are gone.

## [0.2.1] - 2026-11-03

### Fixed

- `sphynx-ssh` `scp -Z` resume (`scp.c`): when the destination was a plain file, the temporary name was built by `strcat` onto the caller's argument string, which has no room for it (a buffer overflow), and the suffix stayed on the destination name for the rest of the transfer. The temporary name is now built in its own allocated buffer, created with `O_EXCL`, and generated with `arc4random_uniform` instead of `rand()` seeded from the clock.

## [0.2.0] - 2026-11-03

### Changed

- `sphynx-ssh` regression suite (`make tests`) was run on the fixed code and passed: all tests passed, exit 0, 87 passing checks. The result is recorded in `TODO.md`. The run used the build from before the CI cleanup versions, so the compiled code is the same as 0.1.2.

## [0.1.9] - 2026-11-03

### Changed

- `sphynx-ssh` README: a fork note at the top explains that the repository is sphynx-ssh, names the version string format, and says which workflows run on which branches. `.github/ci-status.md`, which held upstream OpenSSH badges, is removed.

## [0.1.8] - 2026-11-03

### Changed

- `sphynx-ssh` workflows: the `# main` and `# v1` labels on pinned actions in `c-cpp.yml` and `vm.yml` are replaced with the release tag each SHA was resolved to (for example `# v7.0.0` for `actions/checkout`). Two SHAs have no release tag and are labelled as such. The SHAs themselves are unchanged.

## [0.1.7] - 2026-11-03

### Changed

- `sphynx-ssh` workflows `c-cpp.yml` and `vm.yml` set `permissions: contents: read` at the top level, so the workflow token has read-only access by default.

## [0.1.6] - 2026-11-03

### Removed

- `sphynx-ssh` workflows `selfhosted.yml` and `upstream.yml`, which only ran for `openssh/*` repositories.

## [0.1.5] - 2026-11-03

### Removed

- `sphynx-ssh` workflow `cifuzz.yml`, which built OSS-Fuzz's `openssh` project and would not work for the fork.

## [0.1.4] - 2026-11-03

### Removed

- `sphynx-ssh` workflow `github-repo-stats.yml`, which ran daily and needed a secret the fork does not have.

## [0.1.3] - 2026-11-03

### Changed

- `sphynx-ssh` workflow `c-cpp.yml` runs on pushes and pull requests to `master` only. Previously it also ran on `dev_major`, `dev_minor` and `DynamicWindow`, which do not exist in the fork.

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
