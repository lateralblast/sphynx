# Research

Ideas considered but not built, so they are not lost and not re-litigated. Open work is in [TODO.md](TODO.md).

## Building without OpenSSH's hardening flags

**Idea:** configure with `--without-hardening`, which drops `-ftrapv`, `-ftrivial-auto-var-init=zero` and `-fzero-call-used-regs=used` (and the retpoline and stack options), on the theory that `-ftrapv` slows the AES-CTR XOR loop in `cipher-ctr-mt-functions.c`.

**Why it might help:** a profile of the client on macOS (2026-11-04) put about 14 percent of the main thread in that loop, and `-ftrapv` adds an overflow check to every signed operation and blocks vectorisation.

**Result:** rejected. On macOS arm64 (clang), loopback, medians of 5 runs of 1024 MB, the default build and the `--without-hardening` build were within the spread between runs: `aes256-ctr` 843 against 818 MB/s, `chacha20-poly1305` 607 against 612, `aes256-gcm` 828 against 873. The hardening is worth keeping.

**Open questions:**
- Not tried with GCC on Linux or on x86-64, where the code generated for `-ftrapv` and `-fzero-call-used-regs` may differ.

## Larger packets to cut the cost of `write`

**Idea:** the client does one `write` of 32 KiB (32796 bytes on the wire), one `ppoll` and about one `read` per packet (`strace` of a 512 MB loopback transfer on Linux: 16401 writes, 16464 `ppoll`, 18290 reads). Larger packets mean fewer syscalls and less per-packet work.

**Why it might help:** the macOS profile put about 48 percent of the main thread in `write`, and ChaCha's keystream is generated per packet.

**What it takes:** raising `CHAN_SES_PACKET_DEFAULT` (`channels.h`) alone breaks the connection: after login `ssh_packet_set_authenticated` lowers `packet_max_size` to `SSH_IOBUFSZ + 1024` (`defines.h`, 32 KiB), so a 64 KiB packet is refused with `Bad packet length 65552`. `SSH_IOBUFSZ` has to change with it, and `cipher-chachapoly-libcrypto-mt.c` sizes its keystream from it too. Both were set to 64 KiB (and 128 KiB on macOS) in a throwaway build.

**Results** (loopback, medians of 5 runs, 1024 MB on macOS and 2048 MB on Linux, a different cipher per row, current 32 KiB against the larger size):

| System | Packets | chacha20-poly1305 (serial) | aes256-ctr | aes256-gcm |
|---|---|---|---|---|
| macOS arm64 | 64 KiB | 600 to 701 MB/s | 794 to 765 | 852 to 797 |
| macOS arm64 | 128 KiB | 604 to 688 | 819 to 716 | 835 to 764 |
| Linux arm64, 9 cores | 64 KiB | 880 to 959 | 1053 to 976 | 1096 to 1139 |
| Linux x86-64, 20 cores | 64 KiB | 465 to 508 | 529 to 556 | 684 to 641 |

ChaCha gained 9 to 17 percent on all three systems (this is the serial `chacha20-poly1305@openssh.com`; HPN-SSH's default multithreaded ChaCha was not tested, and it may not behave the same), and on x86-64 the runs were tight (465 ± 5 against 508 ± 4 MB/s). AES-CTR and AES-GCM moved by -7 to +4 percent, inside the spread between runs on Linux (the spread across the 5 runs was larger than the difference), and fell a little on macOS at 128 KiB.

**Open questions:**
- Is the ChaCha gain real on a real link? A run from a Mac over Wi-Fi to the x86-64 server was limited by the link to about 50 MB/s for both OpenSSH and HPN-SSH, so it showed nothing; it needs a link faster than the ciphers (the server has 10 Gbit/s). Loopback makes `write` look dearer than it is, because the receiver's work is done inside the sender's `write`.
- Does a bigger packet hurt AES through cache use? A larger working set per packet would explain the small drop, but this was not checked.
- An OpenSSH peer limits packets to what it advertises in the channel open (32 KiB), so only HPN-SSH to HPN-SSH would use larger packets.
- Larger packets raise memory use per connection, which `ssh_packet_set_authenticated` was written to keep low on high bandwidth-delay paths.
- A change has to keep `CHAN_SES_PACKET_DEFAULT`, `SSH_IOBUFSZ` and the ChaCha keystream length in step, and the window is 64 packets (`CHAN_SES_WINDOW_DEFAULT`), so it also changes the default window.

**Result for the default cipher (2026-11-04, Linux x86-64, 20 cores, median of 5 runs of 2048 MB):** with the multithreaded ChaCha, `chacha20-poly1305-mt@hpnssh.org`, 64 KiB packets made no difference (567 to 570 MB/s). The serial ChaCha gained 9 percent again (470 to 511), AES-GCM 3 percent (597 to 614) and `aes256-ctr` nothing (566 to 566), the last two inside the spread. **Rejected for the default build:** the cipher that is the default does not gain, the gain is confined to the serial ChaCha, and the packet size would also have to change in three places and raise memory use per connection.

## `-O3`, LTO and PGO instead of the default `-O2`

**Idea:** build with `-O3`, link-time optimisation or profile-guided optimisation in place of the default `-O2` with the hardening flags kept.

**Why it might help:** the cipher loops and the packet path are hot, so better inlining and vectorisation might lift throughput. `-march=native` is not an option for a package that is installed on other machines.

**Result:** rejected, 2026-11-05. On the x86-64 server (gcc 15.2), loopback, 5 interleaved rounds of 3 GiB, `-O3` and `-O2 -flto` were within 2 percent of `-O2`, with overlapping ranges: `aes256-gcm` 649, 656 and 651 MB/s for `-O2`, `-O3` and `-O2 -flto`; `chacha20-poly1305` 503, 495 and 501; `aes256-ctr` with UMAC 587, 576 and 586. On a Mac (clang, 3 rounds) the CTR cipher looked 7 to 9 percent faster, but the `-O2` runs themselves ranged over 15 percent, so that was noise. PGO was not tried: with nothing to gain from the other two, it would add a profile step to every build for no expected result.

**Open questions:**
- Only if a profile shows a hot spot that the compiler could improve, as in the `-ftrapv` case above.

## Pinning the cipher threads, NUMA and interrupt affinity

**Idea:** place the client, the server and the cipher threads on chosen cores (`taskset`, NUMA binding, interrupt affinity) to cut cache and scheduler cost at high throughput.

**Why it might help:** the multithreaded ciphers run helper threads next to the main thread, and on a large server the scheduler might put them on cores that share caches badly.

**Result:** rejected, 2026-11-05. On the x86-64 server (1 socket, 1 NUMA node, 10 cores with 2 threads each), loopback, 5 rounds of 3 GiB with `taskset`: unpinned and pinned to separate cores were within 4 percent (`aes256-gcm` 646 against 623 MB/s; `aes256-ctr` with 4 threads 531 against 541). Pinning the client and server to the two SMT threads of one core cut `aes256-gcm` to 430 MB/s, but the scheduler does not choose that by itself, so there is nothing for a package to add.

**Open questions:**
- Not tested: NUMA (the machine has one node), interrupt affinity (loopback has no NIC), many concurrent transfers, and the CPU governor (`schedutil`, running at about 51 percent of the clock). Reopen this for a multi-socket server or a real NIC.
