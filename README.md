<img src="sphynx.jpg" alt="sphynx" width="110" align="right">

# sphynx

SSH Performance Hacks Yielding Network eXcellence

Version: 0.8.2

Sphynx is a wrapper that builds HPN-SSH from source and packages it for target operating systems. The first target is Ubuntu (`.deb`).

It also includes patches that provide additional bug fixes and performance tweaks.

## Contents

- [Quick start](#quick-start)
- [Command reference](#command-reference)
- [Output](#output)
- [Performance](#performance)
- [Tuning the TCP stack](#tuning-the-tcp-stack)
- [Choosing a cipher and MAC](#choosing-a-cipher-and-mac)
- [Patches](#patches)
- [Build dependencies](#build-dependencies)
- [Packaging details](#packaging-details)
- [Tests](#tests)
- [Layout](#layout)

## Quick start

HPN-SSH source is expected in `sphynx-ssh/`, a clone of your HPN-SSH fork (`origin`), with `upstream` set to https://github.com/rapier1/hpn-ssh.git. Then:

```sh
sudo apt-get install -y autoconf automake make gcc dpkg-dev \
    libssl-dev zlib1g-dev libpam0g-dev
./sphynx build
sudo apt install ./dist/hpn-ssh_*.deb
```

On Ubuntu 26.04 this produces `dist/hpn-ssh_10.6p1+hpn18.12.0+sphynx<version>-1~resolute1_<arch>.deb`.

## Command reference

```
sphynx build [options]
sphynx --version
sphynx --help
```

| Option | Default | Meaning |
|---|---|---|
| `build` | | Compile HPN-SSH and write the package for the target. |
| `--target NAME` | `ubuntu` | Operating system to package for. Supported: `ubuntu`. |
| `--source DIR` | `sphynx-ssh/` | HPN-SSH source tree. It is copied, never modified. |
| `--out DIR` | `dist/` | Directory the finished package is written to. |
| `--build-dir DIR` | `build/` | Scratch directory for the build. It is cleared on each run. |
| `--jobs N` | number of CPUs | Parallel `make` jobs. |
| `--series NAME` | `VERSION_CODENAME` from `/etc/os-release` | Ubuntu series used in the package version, for example `resolute`. |
| `-h`, `--help` | | Show usage and exit. |
| `-V`, `--version` | | Show the sphynx version and exit. |

Environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `SPHYNX_MAINTAINER` | `sphynx <sphynx@localhost>` | Maintainer field written into the package. |

sphynx does not produce machine-readable output. Its only output is progress lines and the path of the built package.

## Output

A build writes one package to `--out`:

```
hpn-ssh_<upstream>+sphynx<version>-1~<series>1_<arch>.deb
```

`<upstream>` comes from `version.h` in the source tree, for example `10.6p1+hpn18.12.0`. `<version>` is the sphynx version.

## Versions

The version string has three parts:

```
OpenSSH_10.6p1_hpn18.12.0_sphynx<version>
```

- `OpenSSH_10.6p1` is the OpenSSH base in `sphynx-ssh/version.h`.
- `_hpn18.12.0` is the HPN-SSH release.
- `_sphynx<version>` is the sphynx version. It is `SSH_SPHYNX` in `sphynx-ssh/version.h`.

`hpnssh -V` and `hpnsshd -V` print the full string, and the SSH banner sent to peers contains it. `sphynx build` stops with an error if `SSH_SPHYNX` does not match the sphynx version, so the two cannot drift apart. When you bump the sphynx version, update `sphynx`, `README.md`, `CHANGELOG.md` and `sphynx-ssh/version.h` together.

The package installs alongside OpenSSH:

- Programs are named `hpnssh`, `hpnscp`, `hpnsftp`, `hpnssh-keygen` and so on, and `hpnsshd` is the server.
- Configuration is in `/etc/hpnssh/`.
- The server runs as the `hpnsshd` systemd service and listens on port 2222 by default.

## Performance

HPN-SSH is faster than OpenSSH on a fast local network, and on long paths it can be several times faster once the kernel's TCP buffer limit allows it. On a path that loses or reorders packets, the kernel's congestion control decides the speed.

### Summary

| Question | Answer | Details |
|---|---|---|
| Is HPN-SSH faster than OpenSSH on a fast LAN? | Yes, 1.1 to 1.7 times, with the same or less CPU per GB. | [Against OpenSSH](#against-openssh-on-a-clean-path) |
| On a long path? | 1.3 times with the default 4 MB send buffer limit, and 2.8 times at 50 ms and 5.1 times at 100 ms with it raised to 32 MB. | [Against OpenSSH](#against-openssh-on-a-clean-path), [Tuning the TCP stack](#tuning-the-tcp-stack) |
| What about `scp`, `sftp` and an OpenSSH peer? | Same as `ssh`: 2.6 to 2.7 times faster on the long path with an HPN-SSH server. An HPN-SSH client alone gains nothing, and the `sftp` defaults are not a limit. | [scp, sftp and mixed pairs](#scp-sftp-and-mixed-pairs) |
| On a lossy or jittery path? | `bbr` kept its clean-link speed; `cubic` lost 15 to 62 percent or stalled. | [Packet loss and congestion control](#packet-loss-and-congestion-control) |
| Which cipher? | AES-GCM leads the default multithreaded ChaCha by 5 to 6 percent on CPUs with AES instructions; the top four are within about 10 percent. | [Cipher choice](#cipher-choice-end-to-end), [Choosing a cipher and MAC](#choosing-a-cipher-and-mac) |
| Which MAC? | The default, `umac-64-etm`, is already the fastest. | [Choice of MAC](#choice-of-mac) |
| Does `Compression yes` help? | With zlib, only on a slow link (100 Mbit/s or less) with compressible data, and then by 1.5 times; it sends 65 percent at best (Huffman-only) and slows a fast link by 38 percent or more. Patch 0022's `huff0@hpnssh.org` method sends the same 65 percent at a quarter of the CPU: 39 percent faster than no compression at 1 Gbit/s over 50 ms, still slower on a LAN. Compressing with `zstd` first is 3.5 to 4 times faster on slow links. | [Compression](#compression) |
| What limits a connection on a fast LAN? | The sending thread: about 85 percent of it is the kernel and the cipher. | [Where the time goes](#where-the-time-goes) |
| What made no difference? | More cipher threads, rekeying, OpenSSL 3.5 against 4.1, 64 KiB packets, other TCP settings, the hardening flags. | [Settings that made no difference](#settings-that-made-no-difference) |
| What did the work in this repository change? | Patch 0019: `aes256-ctr` 4 to 7 percent faster. Patch 0021: 1 to 4 percent less server CPU. Patch 0022: a faster compression method, 2.5 times zlib's speed at 1 Gbit/s over 50 ms. Patch 0020 fixes a crash, not speed. `tools/tune-tcp.sh --cc` and `tools/suggest-cipher.sh` apply the findings. | [Patches](#patches) |

All of it is loopback or emulated networks (namespaces with `tc netem`). Nothing was measured over a real wide-area link. The machines: a 16-core amd64 machine (the comparison with OpenSSH), a 20-core Intel Xeon E5-2630 v4 Ubuntu 26.04 server, a 9-core Ubuntu 26.04 arm64 virtual machine and a 10-core Apple M1 Max Mac.

### Against OpenSSH on a clean path

Measured on a 16-core amd64 machine with network namespaces, HPN-SSH 0.3.4 against OpenSSH 10.6.

#### Default kernel settings

Throughput of one connection, as the median of 3 runs. The maximum for `net.ipv4.tcp_wmem` was 4 MB on the Ubuntu 26.04 machine used for the tests. CPU is the client's user plus system time per GB transferred.

| Path | Cipher | OpenSSH 10.6 | HPN-SSH | Ratio | CPU s/GB, OpenSSH | CPU s/GB, HPN-SSH |
|---|---|---|---|---|---|---|
| LAN | each side's default | 632 MB/s | 1095 MB/s | 1.73x | 1.80 | 1.62 |
| LAN | chacha20-poly1305 (serial) | 628 MB/s | 931 MB/s | 1.48x | 1.80 | 1.33 |
| LAN | aes256-ctr | 839 MB/s | 1072 MB/s | 1.28x | 1.40 | 1.44 |
| LAN | aes256-gcm | 1212 MB/s | 1356 MB/s | 1.12x | 1.01 | 0.96 |
| 50 ms | each side's default | 38 MB/s | 50 MB/s | 1.32x | 1.84 | 3.30 |
| 50 ms | chacha20-poly1305 (serial) | 38 MB/s | 50 MB/s | 1.32x | 1.84 | 3.10 |
| 50 ms | aes256-ctr | 38 MB/s | 50 MB/s | 1.31x | 1.46 | 3.34 |
| 50 ms | aes256-gcm | 38 MB/s | 50 MB/s | 1.33x | 1.14 | 2.68 |
| 100 ms | each side's default | 19 MB/s | 25 MB/s | 1.31x | 1.87 | 2.91 |
| 100 ms | chacha20-poly1305 (serial) | 19 MB/s | 25 MB/s | 1.31x | 1.87 | 2.91 |
| 100 ms | aes256-ctr | 19 MB/s | 25 MB/s | 1.30x | 1.47 | 3.12 |
| 100 ms | aes256-gcm | 19 MB/s | 25 MB/s | 1.32x | 1.20 | 2.64 |

"Each side's default" is serial ChaCha20-Poly1305 for OpenSSH and the multithreaded ChaCha20-Poly1305 for HPN-SSH. On the LAN, HPN-SSH is 1.1 to 1.7 times faster on every cipher. The largest gain is for the default cipher, because the multithreaded version spreads the work over more than one core.

On the long paths both are held back, but by different limits. OpenSSH sits at its fixed 2 MB channel window (2 MB per round trip gives 40 MB/s at 50 ms and 20 MB/s at 100 ms). HPN-SSH grows its window, but the 4 MB kernel send buffer stops it from using a larger one.

#### With a larger send buffer limit

The two long paths with `net.ipv4.tcp_wmem` raised to a 32 MB maximum (see [Tuning the TCP stack](#tuning-the-tcp-stack)). Everything in this table was measured with exactly that setting, 3 runs each.

| Path | Cipher | OpenSSH 10.6 | HPN-SSH | Ratio | CPU s/GB, OpenSSH | CPU s/GB, HPN-SSH |
|---|---|---|---|---|---|---|
| 50 ms | each side's default | 38 MB/s | 107 MB/s | 2.80x | 1.79 | 1.87 |
| 50 ms | chacha20-poly1305 (serial) | 38 MB/s | 107 MB/s | 2.78x | 1.77 | 1.67 |
| 50 ms | aes256-ctr | 38 MB/s | 106 MB/s | 2.76x | 1.40 | 1.80 |
| 50 ms | aes256-gcm | 38 MB/s | 108 MB/s | 2.82x | 1.11 | 1.35 |
| 100 ms | each side's default | 19 MB/s | 99 MB/s | 5.13x | 1.83 | 1.87 |
| 100 ms | chacha20-poly1305 (serial) | 19 MB/s | 99 MB/s | 5.12x | 1.83 | 1.65 |
| 100 ms | aes256-ctr | 19 MB/s | 98 MB/s | 5.03x | 1.44 | 1.77 |
| 100 ms | aes256-gcm | 19 MB/s | 100 MB/s | 5.18x | 1.17 | 1.36 |

OpenSSH does not improve, because its window is the limit. HPN-SSH reaches 78 to 86 percent of the 125 MB/s line rate of a 1 Gbit/s link.

#### What to take from it

- On a fast local network, HPN-SSH is faster and uses about the same CPU per GB or less.
- On a long path, raise the TCP send buffer limit or HPN-SSH is limited by the kernel, not by itself.
- **CPU:** with the default limit, the HPN-SSH client uses about 1 to 2 CPU-seconds per GB more than OpenSSH on the long paths (2.6 to 3.3 against 1.1 to 1.9). With the larger limit the two are within about 0.4 of each other (1.35 to 1.87 against 1.11 to 1.83). Before version 0.3.4 the HPN-SSH client spent about a full core on long paths, 19 to 37 CPU-seconds per GB, because its channel loop polled an input it could not read. That is fixed in patch 0016.

#### How it was measured

- **Software:** OpenSSH 10.6, built from the same upstream release HPN-SSH is based on, against HPN-SSH 0.3.4. Both were built from source with OpenSSL 3.5.
- **Network:** two Linux network namespaces joined by a virtual link on a 16-core machine. The delay and a 1 Gbit/s rate limit were added with `tc netem`, half of the round trip in each direction. The LAN case has no shaping. The test hosts were otherwise idle.
- **Transfer:** one connection, one direction, 384 to 2048 MB of data from `/dev/zero` (768 MB for the larger-limit runs), sent with `dd if=/dev/zero | ssh host 'cat > /dev/null'`. No compression. The time to connect is measured separately and subtracted. The two implementations were run in turn, and the median of 3 runs is reported. The spread between runs was under 2 percent for the long paths.
- **Not covered here:** scp and sftp, and mixed pairs (an HPN-SSH client with an OpenSSH server or the reverse), which are in [scp, sftp and mixed pairs](#scp-sftp-and-mixed-pairs), and loss and jitter, which are in [Packet loss and congestion control](#packet-loss-and-congestion-control). These results show the effect of the buffer limit on a clean path, not what a real network will give you.

To try it yourself, build the two network namespaces, then run a transfer from one to the other:

```sh
sudo ip netns add srv; sudo ip netns add cli
sudo ip link add vs type veth peer name vc
sudo ip link set vs netns srv; sudo ip link set vc netns cli
sudo ip -n srv addr add 10.99.0.1/24 dev vs; sudo ip -n cli addr add 10.99.0.2/24 dev vc
for n in srv cli; do sudo ip -n $n link set lo up; done
sudo ip -n srv link set vs up; sudo ip -n cli link set vc up
# 50 ms round trip at 1 Gbit/s: 25 ms and the rate limit on each side
sudo ip netns exec srv tc qdisc add dev vs root netem delay 25ms rate 1gbit limit 100000
sudo ip netns exec cli tc qdisc add dev vc root netem delay 25ms rate 1gbit limit 100000
```

Run the server inside `srv` (`sudo ip netns exec srv /path/to/sshd ...`) and time the transfer from inside `cli`. Remove everything with `sudo ip netns del srv; sudo ip netns del cli`. Kernel settings such as `tcp_wmem` are per namespace, so you can change them inside the namespaces without touching the host. The tool that automates all of this is in `tools/perf/`; see [tools/perf/README.md](tools/perf/README.md).

### scp, sftp and mixed pairs

The same comparison as `ssh`, with `scp` and `sftp` sending a file, and with every pairing of OpenSSH and HPN-SSH client and server, run with `tools/perf` on Linux (the first run of that harness on Linux). x86-64 server, network namespaces, 1 Gbit/s, 50 ms round trip with the TCP buffer limits raised to 32 MiB on both sides, 3 runs of 1024 MB (LAN) or 256 MB (50 ms), time to connect subtracted, MB/s as the median. Uploads only: the client sends. OpenSSH is the Ubuntu 26.04 package (10.2p1, client and server). HPN-SSH is a build of 0.4.7. The `scp` and `sftp` figures are for files sent to `/dev/null`.

| Tool | Path | Cipher | OpenSSH | HPN-SSH | HPN client, OpenSSH server | OpenSSH client, HPN server |
|---|---|---|---|---|---|---|
| `ssh` | LAN | default | 340 | 665 | 347 | 320 |
| `ssh` | LAN | `aes256-gcm` | 575 | 716 | 599 | 613 |
| `ssh` | 50 ms | default | 37 | 95 | 37 | 97 |
| `ssh` | 50 ms | `aes256-gcm` | 36 | 100 | 37 | 99 |
| `scp` | LAN | default | 331 | 595 | 329 | 321 |
| `scp` | LAN | `aes256-gcm` | 533 | 589 | 520 | 595 |
| `scp` | 50 ms | default | 36 | 93 | 36 | 93 |
| `scp` | 50 ms | `aes256-gcm` | 36 | 97 | 37 | 96 |
| `sftp` | LAN | default | 342 | 592 | 328 | 322 |
| `sftp` | LAN | `aes256-gcm` | 545 | 542 | 528 | 575 |
| `sftp` | 50 ms | default | 36 | 93 | 36 | 93 |
| `sftp` | 50 ms | `aes256-gcm` | 35 | 97 | 36 | 95 |

- **`scp` and `sftp` behave like `ssh`.** On the long path HPN-SSH to HPN-SSH is 2.6 to 2.7 times faster than OpenSSH for all three tools (93 to 100 MB/s against 35 to 37), and on the LAN 1.7 to 1.8 times with the default cipher. With `aes256-gcm` on the LAN the gain is small: 0.99 to 1.24 times.
- **The server is what makes the long path fast.** An OpenSSH client uploading to an HPN-SSH server got 93 to 99 MB/s, the same as HPN-SSH to HPN-SSH, and an HPN-SSH client uploading to an OpenSSH server got 36 to 37, the same as OpenSSH. This is consistent with the sender being held to the window the receiver advertises. Downloads, where the server sends, were not measured.
- **On the LAN a mixed pair is no faster than OpenSSH** (0.94 to 1.12 times). The default cipher is not the multithreaded ChaCha unless both ends are HPN-SSH, which fits the default-cipher rows; with `aes256-gcm` all four pairings are within about 10 percent of each other.
- **CPU:** at 50 ms with the default cipher HPN-SSH to HPN-SSH used 5.3 to 6.0 client CPU-seconds per GB against OpenSSH's 7.4 to 7.9, and with `aes256-gcm` the two were equal (4.5 to 5.1).
- **Connecting is slower.** The time to connect was 150 ms for HPN-SSH against 90 ms for OpenSSH on the LAN (an HPN-SSH client alone 130, an HPN-SSH server alone 120), and about 110 to 130 ms longer at 50 ms. The cause was not investigated, and it is part of every `scp` and `sftp` command. The figures above have it subtracted.
- `scp` to `/dev/null` prints `remote fsetstat: Bad message` at the end, after the data has been sent. It does not change the time.

#### sftp request size and queue depth

`sftp` has its own limits, set with `-B` (the size of each request) and `-R` (the number in flight). They could limit a transfer whatever the cipher, so the same 50 ms path was run with different values (`aes256-gcm`, 256 MB, 3 runs, MB/s):

| `sftp` options | OpenSSH | HPN-SSH | HPN client, OpenSSH server | OpenSSH client, HPN server |
|---|---|---|---|---|
| none (the defaults) | 36 | 97 | 36 | 95 |
| `-R 16` | 35 | 72 | 36 | 71 |
| `-B 65536 -R 128` | 36 | 98 | 37 | 95 |
| `-B 131072 -R 256` | 36 | 97 | 37 | 96 |

- **The defaults are not the limit.** Without `-B` the client takes the request size from the server's advertised limits, up to 255 KiB (the 256 KiB message limit minus 1 KiB), and the default queue is 64 requests in OpenSSH's `sftp` and 1024 in this fork's. That is far more than a 50 ms path holds, and larger values changed nothing.
- **A small queue does limit HPN-SSH.** `-R 16` cut it to 72 MB/s, which fits 16 requests of about 255 KiB (4 MiB) per 50 ms round trip, about 80 MB/s. It did not change OpenSSH, because its 2 MiB channel window is the smaller limit.
- **`-B` has a ceiling.** `sftp -B 262144` fails with `Outbound message too long 262169`, because the 256 KiB message limit has to hold the request header too.
- The harness had a bug that recorded that failure as a result; it is fixed in 0.6.0.
- Not tried: `scp -X nrequests=` and `-X copy_buffer=`, and a larger window than 50 ms.

### Packet loss and congestion control

Every long-path result in the previous section is on a clean link. Real paths lose packets, and then the kernel's congestion control algorithm matters as much as the buffer size. This compares Linux's default, `cubic`, with `bbr`, both with the buffers raised to 32 MiB, on an emulated 50 ms, 1 Gbit/s path (two network namespaces on the x86-64 server with `tc netem`, Linux 7.0). Loss is applied in each direction, so a round trip sees about twice the figure. HPN-SSH, `aes256-gcm`, 192 MB per run, 3 runs (MB/s). The data goes from client to server, so the setting that matters is the sender's. `t/o` is a run that took over 100 seconds, under 2 MB/s.

#### Loss on a 1 Gbit/s path

| Loss per direction | `cubic`, median (runs) | `bbr`, median (runs) |
|---|---|---|
| 0.02 % | 66.9 (66.9, 63.8, 68.2) | 68.7 (67.5, 68.8, 68.7) |
| 0.05 % | 58.6 (58.6, 58.3, 60.5) | 68.6 (68.6, 68.7, 68.2) |
| 0.1 % | 38.0 (t/o, 62.9, 38.0) | 67.8 (68.1, 67.4, 67.8) |
| 0.2 % | 52.2 (56.7, 52.2, 29.5) | 67.7 (67.0, 67.8, 67.7) |

An earlier, smaller run (128 MB, 2 runs, runs over 150 seconds counted as `t/o`) compared both programs:

| Loss per direction | Congestion control | OpenSSH 10.2 (Ubuntu) | HPN-SSH |
|---|---|---|---|
| 0 | `cubic` | 28.9 MB/s | 56.7 MB/s |
| 0 | `bbr` | 29.4 MB/s | 57.3 MB/s |
| 0.1 % | `cubic` | 19.4 MB/s (runs 28.7 and 19.4) | 1.5 MB/s (runs 52.6 and 1.5) |
| 0.1 % | `bbr` | 26.2 MB/s | 55.3 MB/s |
| 0.5 % | `cubic` | t/o (runs 1.1 and t/o) | t/o |
| 0.5 % | `bbr` | 23.9 MB/s | 52.9 MB/s |

#### A faster path, with loss and jitter

The same test on an emulated 10 Gbit/s, 30 ms path (buffers 128 MiB, 512 MB per run, 3 runs, HPN-SSH, `aes256-gcm`, MB/s). Jitter is `netem`'s random delay variation, which also **reorders** packets, applied in each direction. There is no second fast host here, so this is an emulation on one machine (the transfer is short and the ramp-up is part of each figure, which is why these are about half of the loopback speed).

| Jitter | Loss per direction | `cubic`, median (runs) | `bbr`, median (runs) |
|---|---|---|---|
| none | none | 303 (287, 303, 316) | 323 (323, 325, 300) |
| none | 0.02 % | 240 (278, 240, 227) | 303 (301, 303, 313) |
| 5 ms | none | 114 (114, 100, 164) | 301 (303, 301, 293) |
| 5 ms | 0.02 % | 67 (26, 67, 68) | 298 (294, 298, 302) |

#### Other TCP settings

Does anything cheaper than a new congestion control fix the `cubic` stalls? The same emulated path as the first table, with 0.1 % loss per direction, HPN-SSH, 192 MB, 4 runs, `t/o` a run over 80 seconds (MB/s). The median of a set containing a `t/o` is the lower of its two middle values.

| Setting on the sender | Median (runs) |
|---|---|
| `cubic` (the baseline) | 51.7 (t/o, 61.6, 67.4, 51.7) |
| `cubic` and `net.ipv4.tcp_notsent_lowat=1048576` | 65.5 (t/o, 67.1, 65.5, 68.0) |
| `cubic` and an initial congestion window of 100 (`ip route ... initcwnd 100`) | 65.3 (t/o, 70.5, 70.7, 65.3) |
| `cubic` and an `fq` qdisc | t/o (t/o, t/o, 3.8, t/o) |
| `bbr` | 68.3 (68.3, 68.7, 68.7, 68.1) |
| `bbr` and an `fq` qdisc | 64.8 (64.0, 64.8, 64.9, 64.9) |

- **None of them fixes `cubic`.** Every `cubic` variant had one run in four go over 80 seconds, and the differences between their medians are the spread of four runs, not an effect. Only `bbr` removed the stalls.
- **`fq` does not help `bbr`** here (64.8 against 68.3), because the kernel already paces `bbr`. With `cubic`, `fq` at its default settings collapsed the transfer. The cause was not investigated: its default per-flow limit of 100 packets is the likely cause with a 32 MiB window, and a larger `flow_limit` was not tried.
- **Not measured:** `tcp_slow_start_after_idle` (it only matters when a connection goes idle), `tcp_mtu_probing` (it needs a path that drops large packets), and on macOS `net.inet.tcp.delayed_ack`, because macOS has no way to emulate delay on loopback.
- `tools/tune-tcp.sh` does not set any of these, and these results give no reason to add them.

#### What to take from it

- **`bbr` held the clean-link speed at every loss rate tried, up to 0.5 % per direction, and under jitter.** `cubic` was 15 percent behind at 0.05 % loss, became erratic from 0.1 % (some runs stalled for over a minute), did not finish at 0.5 % in 150 seconds for either program, and lost 62 percent to 5 ms of jitter alone.
- **Reordering hurts `cubic` more than loss does,** because the kernel can read reordered packets as lost ones. With both, `bbr` was about 4.5 times as fast.
- **Both programs are limited by `cubic` the same way, but HPN-SSH starts from much higher.** With `bbr` at 0.5 % loss HPN-SSH kept 53 MB/s against OpenSSH's 24 MB/s.
- **Nothing cheaper fixes `cubic`:** a larger initial window, `tcp_notsent_lowat` and `fq` did not, and `fq` did not help `bbr`.
- **`bbr` is a setting on the sending host, not an HPN-SSH option.** For an upload it is the client's kernel, for a download the server's. `tools/tune-tcp.sh persist --cc bbr` sets it (see [Congestion control](#congestion-control)).
- **Limits.** Everything here is emulated on one machine, with one flow and 3 or 4 short runs per setting, so the `cubic` figures are rough (it fails in a different way from run to run, which is the finding). It was not tried on a real lossy path or with several flows sharing a link, where `bbr` can take more than its share from `cubic` flows. Test it on your own path before changing a shared server.

### Cipher choice end to end

HPN-SSH to HPN-SSH over loopback, 0.4.7, all five ciphers, median of 5 runs (MB/s). The multithreaded ChaCha is HPN-SSH's default, and the serial one is what an OpenSSH peer would use.

| Cipher | macOS arm64, 10 cores (1024 MB) | Linux x86-64, 20 cores (2048 MB) |
|---|---|---|
| `aes128-gcm@openssh.com` | 985 | 600 |
| `aes256-gcm@openssh.com` | 942 | 594 |
| `aes256-ctr` (with `umac-64-etm`) | 973 | 542 |
| `chacha20-poly1305-mt@hpnssh.org` (default) | 892 | 568 |
| `chacha20-poly1305@openssh.com` (serial) | 639 | 458 |

- The top four are within about 10 percent of each other on both machines. AES-GCM leads the default multithreaded ChaCha by 5 to 6 percent (942 against 892 on the Mac, 594 against 568 on the x86-64 server). The serial ChaCha is far behind (about 30 percent), which is why multithreading it matters.
- `aes256-ctr` is ahead of AES-256-GCM on the Mac and behind it on x86-64. It includes the faster XOR loop from 0.4.5. Which is best changes with the machine, so do not read a lead of a few percent as a rule.
- One machine of each kind, loopback only, so the client and server share CPUs.
- An earlier version of the cipher tables in this README, and of `tools/suggest-cipher.sh`, compared with the serial ChaCha or with raw single-threaded speed. That overstated AES-GCM's lead over the default.

### Choice of MAC

With `aes256-ctr` the connection also needs a MAC (the AEAD ciphers `aes256-gcm` and `chacha20-poly1305` do not). The MAC runs in the main thread, so it can cap a connection that the cipher threads would not. HPN-SSH to HPN-SSH over loopback, one cipher thread, median of 5 runs of 1024 MB (Mac) or 2048 MB (Linux). Linux is an Ubuntu 26.04 arm64 virtual machine with 9 cores, the Mac is a 10-core MacBook Pro.

| MAC | Linux | macOS |
|---|---|---|
| `umac-64-etm@openssh.com` (the default) | 1073 MB/s | 782 MB/s |
| `umac-64@openssh.com` | 1082 MB/s | 831 MB/s |
| `umac-128-etm@openssh.com` | 1017 MB/s | 808 MB/s |
| `umac-128@openssh.com` | 979 MB/s | 818 MB/s |
| `hmac-sha2-256` | 819 MB/s | 666 MB/s |
| `hmac-sha2-256-etm@openssh.com` | 770 MB/s | 641 MB/s |
| `hmac-sha1` | 758 MB/s | 662 MB/s |
| `hmac-sha1-etm@openssh.com` | 772 MB/s | 646 MB/s |
| `hmac-sha2-512` | 600 MB/s | 542 MB/s |
| `hmac-sha2-512-etm@openssh.com` | 659 MB/s | 524 MB/s |

- The default is already the fastest choice. The `umac` MACs are 25 to 40 percent faster than the `hmac-sha2` ones with `aes256-ctr`, and `hmac-sha2-512` is the slowest. The `-etm` and plain forms of one MAC are within the spread between runs of each other.
- The `-etm` forms are the safer design (they check the MAC before decrypting), and cost nothing measurable, so there is no reason to prefer the plain ones.
- If you must use `hmac-sha2-256` for policy, expect about a quarter less throughput than the default on a fast link. On a link below a few hundred MB/s none of this matters.
- Loopback only: the client and server share CPUs, and a long path is limited by the buffers, not the MAC.
- To get a suggestion for your own CPU, see [Choosing a cipher and MAC](#choosing-a-cipher-and-mac).

### Compression

`Compression yes` (`hpnssh -C`) does less than its name suggests: in this code the compressor is zlib set to its fastest level with the **Huffman-only strategy** (`deflateInit2(..., Z_BEST_SPEED, Z_DEFLATED, 15, 8, Z_HUFFMAN_ONLY)` in `packet.c`). That codes each byte on its own and does no string matching, so it cannot do better than 8 to 1 (a bit per byte) however repetitive the data is. Ubuntu's OpenSSH 10.2 does the same. Measured with SSH's own byte counter, 20 MB of zeros became 2.5 MB, one line repeated 20 MB worth became 12 MB, and 20 MB of log text that `gzip -6` shrinks to 24 percent became 64 percent. A `strace` of the client showed each 32 KiB packet of zeros leaving as 4164 bytes.

**Why it is Huffman-only.** It is deliberate, and it is a security fix from OpenSSH, not a speed choice. OpenSSH commit `1d5340fce` (22 September 2026, by `job@openbsd.org`, OK `djm@` and `dtucker@`) changed `start_compression_out` from `deflateInit(..., level 6)` to the call above. Its message says a chosen-plaintext attack can recover secrets from one channel by sending data through another channel of the same session. All channels share one compression dictionary, and LZ77 replaces repeated strings with back-references into it, so attacker-controlled input changes the length of the encrypted packets in a way that reveals whether it matched a secret. It cites Bäumer and Brinkmann, "Crossing the Streams: SSH Plaintext Recovery via a Common Compression Context in Multiplexed Channels" (arXiv 2609.07709). Huffman coding has no dictionary, so it avoids this, and the message admits "this results in a reduction of compression effectiveness". The `ssh_config(5)` page already advised against compression on connections that carry trusted and untrusted traffic. This fork inherits the change from upstream, with no edit of its own. The Ubuntu OpenSSH 10.2 measured above gave the same 65 percent, so Ubuntu has presumably backported the fix; I did not check its changelog.

**A faster coder with no dictionary.** zlib's Huffman-only mode is slow for what it does, because it still runs the whole deflate machinery. `huff0`, the Huffman coder inside zstd, does the same job with the same kind of code (order 0, no history, a fresh table for each 32 KiB packet, so no state is shared between packets or channels). Compressing the same 64 MiB of log text and of random data in 32 KiB packets with `tools/perf/huff0-bench.c` (zstd 1.5.7, one thread, in memory, no SSH):

| Machine and data | zlib Huffman-only | `huff0` | zlib level 6, with dictionary (for reference) |
|---|---|---|---|
| x86-64 Xeon E5-2630 v4, log text: size sent | 64.2% | 64.0% | 23.8% |
| x86-64, log text: compress / decompress MB/s | 78 / 217 | 615 / 821 | 37 / 291 |
| x86-64, random data: compress MB/s | 100 | 1918 | 39 |
| M1 Max, log text: compress / decompress MB/s | 148 / 446 | 1407 / 1601 | 55 / 885 |
| M1 Max, random data: compress MB/s | 192 | 4228 | 58 |

- The ratio is the same, so a dictionary-free coder gives the same 35 percent saving. It compresses 8 to 10 times faster on log text, and 19 to 22 times faster on random data, because `huff0` notices it cannot shrink a packet and stores it. The `huff0` decompress figure includes a byte-for-byte check of the result, so it is understated.
- At 78 MB/s the x86 server spends about 13 CPU-seconds per GB compressing with zlib; at 615 MB/s it would spend about 1.6. That is the cost that made `Compression yes` slow a 1 Gbit/s connection by 38 to 46 percent. These figures are in-memory and single-threaded and leave out the cipher, the kernel and the network, so they show the compressor alone and do not predict an SSH transfer.
- It does not make compression better than the 64 percent that Huffman coding allows. That needs the dictionary the security fix removed.
- Using it needs a new compression method in the SSH protocol that both ends support, since the compression name is negotiated, and part of zstd copied into the tree (`huff0` is not a public interface of the library). Patch 0022 does both, as [below](#the-huff0hpnsshorg-method).

#### The huff0@hpnssh.org method

Patch 0022 adds it as a compression method named `huff0@hpnssh.org`, next to `none` and `zlib@openssh.com`. `hpnssh -Q compression` lists it.

- **Wire format.** Each packet's payload is split into blocks of up to 128 KiB, and each block is `huff0`-coded with a table of its own, or stored if that would not make it smaller. Nothing is kept from one packet to the next, so there is still no dictionary and no state shared between channels. The format is written at the top of `compress-huff0.c`.
- **Negotiation.** With `Compression yes` the client lists `huff0@hpnssh.org` first, then `zlib@openssh.com`, then `none`. With `Compression no` it lists `none` first, as before, and `hpnsshd` accepts all three, so nothing changes unless compression is asked for. The server takes the first name in the client's list that it knows. Tested on loopback: a new client against a server without the method, and the reverse, both chose `zlib@openssh.com`, and so did a new client against the Mac's OpenSSH. Both ends need patch 0022 (and so 0.6.5 or later) to use it. As with zlib, it starts only after authentication, so the decoder cannot be reached before login. It does not need zlib to build.
- **Source.** The coder is copied from zstd 1.5.7 into `sphynx-ssh/huff0/` (about 8,000 lines, BSD or GPLv2, both licence files copied, a `README.md` listing the three small changes made so it builds on its own). `compress-huff0.c` is the wrapper, about 160 lines. The decoder checks each block's lengths against the packet size limit before it writes, and handles the one-byte run case itself, because zstd's decoder entry point leaves that to its caller. `tools/patches.sh check` now also counts files that are not committed yet, because new files are untracked until they are.
- **Tests.** `tests/c/huff0_roundtrip.c` round-trips four kinds of data (zeros, text, skewed bytes and random) at sizes from 0 to 256 KiB, checks that text shrinks, zeros collapse and random data grows only by the 5-byte block header, refuses malformed streams (short headers, unknown types, zero and oversized lengths, a coded length not under the raw length, a stream longer than the output limit), and expands 4000 streams with flipped bytes without a crash. It was also run under AddressSanitizer and UBSan, clean. The test first failed on a run of one byte (the decoder case above), and its first two ASan runs found bugs in the test itself. The ssh handshake and data were checked by hand over loopback (`Compression yes` both ways, checksums of 30 MB of text and of random data matched, 64 percent and 100 percent sent). The Linux suite runs the C test and checks that `hpnssh -Q compression` lists the method; it has no daemon-based test of the method.

Measured on the x86-64 server with the same links and data as the next table, HPN-SSH on both ends, `aes256-gcm`, 3 runs, MB/s of source data. "zlib" is `Compression yes` before the patch, "huff0" is `Compression yes` with it:

| Link | Data | No compression | zlib | huff0 | Sent with huff0 | Client CPU-s/GB, zlib and huff0 |
|---|---|---|---|---|---|---|
| LAN | compressible | 580 | 59 | 253 | 65 % | 17.3 and 4.2 |
| LAN | random | 625 | 68 | 417 | 100 % | 15.2 and 2.6 |
| 1 Gbit/s, 50 ms | compressible | 93.9 | 51.4 | **130.7** | 64 % | 18.5 and 4.9 |
| 1 Gbit/s, 50 ms | random | 93.9 | 58.5 | 93.9 | 100 % | 15.9 and 5.2 |
| 100 Mbit/s, 50 ms | compressible | 11.3 | 17.0 | 17.0 | 65 % | 31.2 and 8.8 |
| 100 Mbit/s, 50 ms | random | 11.3 | 11.3 | 11.3 | 100 % | 31.7 and 5.3 |
| 10 Mbit/s, 50 ms | compressible | 1.2 | 1.8 | 1.8 | 66 % | 39.2 and 10.8 |
| 10 Mbit/s, 50 ms | random | 1.2 | 1.2 | 1.2 | 100 % | 33.3 and 7.5 |

- **At 1 Gbit/s over 50 ms it turns compression from a loss into a gain on compressible data:** 130.7 MB/s against 93.9 uncompressed (39 percent faster) and 51.4 with zlib (2.5 times). On incompressible data it costs nothing in speed there (93.9 against 93.9; zlib lost 38 percent).
- **On slow links the speed is the same as zlib's**, because the link is the limit and both send 65 percent, but the client uses about a quarter of the CPU (8.8 against 31.2 seconds per GB at 100 Mbit/s).
- **On a LAN it is still the wrong choice:** 253 MB/s against 580 uncompressed. It is 4.3 times faster than zlib (6.1 times on random data), not faster than sending the bytes.
- **It is the same ratio as zlib's Huffman-only mode, no better.** The `zstd -3` pre-compression below still sends 25 percent and wins on slow links.
- **Receiver cost was not measured separately.** The decoder was faster than the encoder in the in-memory benchmark, and each end only does one of the two for a one-way transfer.
- The CPU figures count the client process and the `head` that feeds it, and are noisy at the slow links where it waits.

The next table is for zlib (`Compression yes` before patch 0022, or against a peer without it). Throughput of one connection on the x86-64 server (network namespaces, `aes256-gcm`, 3 runs, MB/s of source data, 32 MiB buffers). The compressible data is log-like text that `gzip -6` shrinks 4.2 to 1; the other is random bytes.

| Link | Data | OpenSSH off | OpenSSH on | HPN-SSH off | HPN-SSH on | Sent with it on | HPN-SSH client CPU-s/GB, off and on |
|---|---|---|---|---|---|---|---|
| LAN | compressible | 520 | 59 | 645 | 58 | 65 % | 1.70 and 17.6 |
| LAN | random | 526 | 68 | 580 | 67 | 100 % | 1.93 and 15.3 |
| 1 Gbit/s, 50 ms | compressible | 38.5 | 37.1 | 94.3 | 51.3 | 65 % | 3.65 and 18.5 |
| 1 Gbit/s, 50 ms | random | 38.2 | 37.1 | 94.3 | 58.3 | 100 % | 3.60 and 16.0 |
| 100 Mbit/s, 50 ms | compressible | 11.3 | 17.1 | 11.3 | 17.1 | 65 % | 3.33 and 31.2 |
| 100 Mbit/s, 50 ms | random | 11.3 | 11.3 | 11.3 | 11.3 | 100 % | 3.33 and 31.3 |
| 10 Mbit/s, 50 ms | compressible | 1.2 | 1.8 | 1.2 | 1.8 | 66 % | 5.83 and 40.0 |
| 10 Mbit/s, 50 ms | random | 1.2 | 1.2 | 1.2 | 1.2 | 100 % | 5.00 and 33.3 |

- **It only helps on a slow link with compressible data,** and then by about 1.5 times, which is the 65 percent it sends. At 100 and 10 Mbit/s the compressible data went 51 percent faster. Random data gained nothing at any speed and cost 4 to 9 times the CPU.
- **On a fast link it hurts.** Compressing runs at only about 58 to 67 MB/s per connection (15 to 18 CPU-seconds per GB), so at 1 Gbit/s HPN-SSH fell 38 to 46 percent, and on the LAN every case was about 8 to 11 times slower. OpenSSH at 1 Gbit/s over 50 ms barely changed (38.5 to 37.1) because its 2 MiB window, not the compressor, was already the limit.
- **Break-even on this data is about 300 Mbit/s** (estimated, not measured): above roughly 40 MB/s on the wire, the compressor is the limit rather than the link.
- **Compress the data before it goes into SSH instead.** The same compressible data sent through `zstd -3` or `gzip -1` first (MB/s of source data, compression included, the receiver not decompressing):

| Link | Plain | `Compression yes` | `zstd -3` | `gzip -1` | Sent with `zstd -3` |
|---|---|---|---|---|---|
| 1 Gbit/s, 50 ms, OpenSSH | 38.5 | 37.1 | 113.6 | 78.4 | 25 % |
| 1 Gbit/s, 50 ms, HPN-SSH | 94.3 | 51.3 | 114.3 | 78.4 | 25 % |
| 100 Mbit/s, 50 ms | 11.3 | 17.1 | 39.7 | 34.4 | 25 % |
| 10 Mbit/s, 50 ms | 1.2 | 1.8 | 4.7 | 3.9 | 25 % |

  `zstd -3` sent a quarter of the bytes, so the slow links went 3.5 to 4 times faster than plain, against 1.5 times for `Compression yes`. On the long 1 Gbit/s path it even took OpenSSH from 38.5 to 113.6 MB/s, presumably because OpenSSH's window then holds compressed bytes, and HPN-SSH from 94.3 to 114.3 (one `zstd` thread was then the limit). The cost is client CPU (about 10 to 21 CPU-seconds per GB against 3.3 to 5.8 for plain), and the numbers leave out decompressing at the far end, which a real transfer must do, for example `zstd -3 < file | hpnssh host 'zstd -d > file'`. `rsync -z` was not tried.
- **Nothing here is specific to HPN-SSH:** OpenSSH and HPN-SSH compress identically. HPN-SSH is faster at 1 Gbit/s only because of its window.
- **Limits.** One compressible data set (synthetic log text, 4.2 to 1) and one incompressible one, so another kind of data will differ. One connection, emulated links, one cipher. The comparison with `zstd` and `gzip` shows what the dictionary coder would have saved, which is the part the security fix gave up. The `huff0` figures are a standalone benchmark, not run inside SSH.

### Where the time goes

A `perf` profile of the client (`hpnssh`) and the server session (`hpnsshd-session`) during a loopback transfer on the x86-64 server, `aes256-gcm`, with DWARF call graphs. Each figure is a share of the samples of that process in one run, so treat differences of a point or two as noise. (The cipher threads of `aes256-ctr` and the multithreaded ChaCha add to this; the profile was taken for AES-GCM, which has none, and the other two ciphers showed the same pattern for the copy and clear costs below.)

| Where | Client (sender) | Server (receiver) |
|---|---|---|
| Kernel | 53 % | 46 % |
| `libcrypto` (the cipher and its authentication) | 32 % | 36 % |
| `libc` (`memcpy`, `memset`) | 10 % | 13 % |
| `hpnssh` or `hpnsshd-session` itself | 4 % | 5 % |

The biggest single items, and who calls them:

| Cost | Client | Server |
|---|---|---|
| Kernel copy between the program and the socket (`rep_movs_alternative`) | 9.2 % | 8.2 % |
| `memcpy` of the channel data into or out of the packet buffer (`sshbuf_put_string` on the client, `sshbuf_put` on the server) | 5.0 % | 4.1 % |
| `memset` zeroing a buffer, all callers | 3.6 % | 8.9 % |
| of which `recallocarray`, from `sshbuf_allocate` on the client and `sshbuf_reset` on the server | 3.5 % | 2.3 % |
| of which the 32 KiB zero-fill in `channel_handle_efd_read` | none | 5.2 % (removed in 0.5.5) |
| Kernel zeroing new pages (`kernel_init_pages`) | 4.8 % | 3.7 % |
| System call entry and exit | 1.6 % | 4.6 % |

- **About 85 percent of the sender is the kernel and the cipher,** which the program does not control. The part it does is the copying and clearing: about 5 percent of `memcpy` and about 3.5 percent of `memset`, both in the `sshbuf` packet buffers.
- **`sshbuf_reset` and `sshbuf_allocate` churn.** After each packet the packet buffer is zeroed over its whole size and shrunk back to 256 bytes (`recallocarray`), and the next packet grows it again, so every 32 KiB packet pays a zero-fill and a copy more than it has to. This is OpenSSH's behaviour, and the zeroing is deliberate: the buffers hold plaintext and keys. A change would have to keep clearing what was written. It is in `TODO.md`.
- **`kernel_init_pages` is Ubuntu's `init_on_alloc`,** which zeroes every page the kernel allocates. It is not something `sshd` can change.
- **The sender is the limit in a loopback test.** Taking 5 percent out of the server did not change the throughput (see patch 0021), which is what you would expect if the sender is the limit. A faster transfer would need less work per byte on the sending thread, or more threads on it.
- One run per cipher on one machine, on a stripped `libcrypto`, so the cipher's own time is not split further.

#### What patch 0021 saved

Patch 0021 removed the zero-fill in `channel_handle_efd_read`. Server CPU (user plus system, `hpnsshd` and its session) was measured over 5 transfers of 4 GB per cipher, the build without the patch and the build with it side by side, on the x86-64 server over loopback:

| Cipher | Without 0021 | With 0021 | Saved |
|---|---|---|---|
| `aes256-gcm@openssh.com` | 1.846 CPU-s/GB | 1.775 CPU-s/GB | 0.071 CPU-s/GB (3.8 %) |
| `chacha20-poly1305-mt@hpnssh.org` | 2.690 CPU-s/GB | 2.602 CPU-s/GB | 0.088 CPU-s/GB (3.3 %) |
| `aes256-ctr` | 2.886 CPU-s/GB | 2.853 CPU-s/GB | 0.034 CPU-s/GB (1.2 %) |

- The saving is user-space time (for AES-GCM, user 0.94 to 0.89 and system 0.91 to 0.89 CPU-s/GB), which is what removing a `memset` should do. It matches the profile, where `memset` fell from 8.5 to 4.8 percent of the server's samples.
- Throughput did not change: the sender is the limit, so a cheaper server does not make the transfer faster. The patch saves server CPU only.
- One set of five transfers per cipher, not repeated, so the `aes256-ctr` figure is probably within the noise. A case where the server is the sender was not measured.

### Settings that made no difference

These were tried and none is worth changing. Each is on the machine named in it, over loopback.

#### Cipher threads

`SSH_CIPHER_THREADS` sets how many threads HPN-SSH uses to generate the `aes256-ctr` keystream for one connection. It is read when the connection starts, so set it in the environment of the client and restart the server with it set too. The default is 1 thread in each direction. `chacha20-poly1305` always uses one thread and has no setting. HPN-SSH to HPN-SSH over loopback, `aes256-ctr` with its default MAC, median of 5 runs (1024 MB on the Mac, 2048 MB on Linux):

| Threads | Linux, 9 cores | macOS, 10 cores |
|---|---|---|
| 1 (default) | 1134 MB/s | 920 MB/s |
| 2 | 1112 MB/s | 905 MB/s |
| 3 | 1132 MB/s | 895 MB/s |
| 4 | 1138 MB/s | 892 MB/s |
| 6 | 1111 MB/s | 848 MB/s |
| 8 | 1096 MB/s | 863 MB/s |

- More threads do not help. Throughput is flat from 1 to 4 threads on Linux and falls a little on the Mac, so the default of 1 is the right setting at these speeds. The cipher is not what limits a single connection at about 1 GB/s.
- Loopback only, with the client and server on the same CPUs. A real 10 Gbit/s link or a long path has not been tried, so this does not rule out a gain there.
- The two AES-CTR implementations cap the setting differently (4 threads in `cipher-ctr-mt.c`, 32 in `cipher-ctr-mt-functions.c`, which is the one the OpenSSL 3 build uses). Values above the cap are lowered to it.

#### Rekeying

A long connection renegotiates its keys every `RekeyLimit` bytes. HPN-SSH's AES-CTR cipher throws away its pre-generated keystream and restarts its threads at each rekey, so this looks for a stall. HPN-SSH to HPN-SSH over loopback on the x86-64 server, 8 GB sent per run, throughput recorded every 0.25 seconds, medians of the per-bin rates:

| Cipher | Default rekey (none in 8 GB) | `RekeyLimit 1G` | `RekeyLimit 256M` |
|---|---|---|---|
| `aes256-ctr` | 587 MB/s | 642 MB/s | 625 MB/s |
| `chacha20-poly1305-mt@hpnssh.org` | 667 MB/s | 682 MB/s | 667 MB/s |
| `aes256-gcm@openssh.com` | 709 MB/s | 677 MB/s | 667 MB/s |

- Rekeying costs nothing you can see. No 0.25 second bin fell below 60 percent of the median in any of the nine runs, and the slowest bin was at most about 22 percent below it. The runs with no rekeying have dips of 11 to 17 percent too, so those dips are not from rekeying. A `-v` client confirmed the rekeys happen: 33 rekey-related debug lines in 2 GB at `256M`, none at the default.
- The differences between columns are the run-to-run spread, not an effect of rekeying (the 8 GB runs went one after another, and the machine's speed drifts by about 10 percent).
- A stall shorter than 0.25 seconds would not show, but it would also show up as a lower average, and the averages are the same.
- You do not need to raise `RekeyLimit` to protect throughput.

#### OpenSSL version

The Ubuntu package is built against OpenSSL 3.5. HPN-SSH goes through OpenSSL's provider interface for every packet, so the same source (0.5.3) was built against OpenSSL 3.5.9 and 4.1.0 on a 10-core Mac and compared them over loopback (median of 5 runs of 1024 MB, arm64).

| Cipher | OpenSSL 3.5.9 | OpenSSL 4.1.0 |
|---|---|---|
| `chacha20-poly1305-mt@hpnssh.org` | 860 MB/s | 846 MB/s |
| `aes256-ctr` | 967 MB/s | 951 MB/s |
| `aes256-gcm@openssh.com` | 895 MB/s | 938 MB/s |

- The two versions are the same speed (the spread between runs is 5 to 10 percent), so the provider interface is not a cost worth chasing.
- **Before 0.5.3, HPN-SSH built against OpenSSL 4.1 crashed on every `aes-ctr` connection.** The AES-CTR provider hands OpenSSL an `EVP_CIPHER_CTX` and keeps its real state as that context's app data, but its two parameter functions (`aes_mt_get_ctx_params`, `aes_mt_set_ctx_params`) used the pointer they were given as the state itself. They read a field 17 MB past the end of a small allocation, and wrote the key length over a field of the `EVP_CIPHER_CTX`. With OpenSSL 3.5 a connection did not fault; with 4.1 it died with a bus error, at an address exactly `offsetof(ongoing)` past the context pointer. Patch 0020 fixes it, and `tests/c/aes_ctr_mt_init.c` crashes without it. The Ubuntu package was not affected, but a build against OpenSSL 4, such as Homebrew's current `openssl`, was. The same code is in upstream HPN-SSH.

#### Packet size

HPN-SSH sends 32 KiB packets. Larger packets mean fewer system calls and less per-packet work, but they need `SSH_IOBUFSZ`, `CHAN_SES_PACKET_DEFAULT` and the ChaCha keystream length changed together (a bigger packet alone is refused with `Bad packet length`). 64 KiB packets were built and compared with the current build over loopback on the x86-64 server (median of 5 runs of 2048 MB, MB/s):

| Cipher | 32 KiB (current) | 64 KiB |
|---|---|---|
| `chacha20-poly1305-mt@hpnssh.org` (default) | 567 | 570 |
| `chacha20-poly1305@openssh.com` (serial) | 470 | 511 |
| `aes256-gcm@openssh.com` | 597 | 614 |
| `aes256-ctr` | 566 | 566 |

- **Not worth changing.** The default multithreaded ChaCha does not gain, and the other differences are inside the spread between runs (about 10 percent), except the serial ChaCha, which gained 9 percent here and 9 to 17 percent on two arm64 machines. The serial ChaCha is only used against a peer that lacks the multithreaded one.
- A bigger packet also raises memory per connection, which the code lowers after login on purpose for high bandwidth-delay paths, and an OpenSSH peer would still send 32 KiB.
- Details and the arm64 results are in `RESEARCH.md`.

The hardening compiler flags (`-ftrapv`, `-ftrivial-auto-var-init=zero`) were also compared with a build without them on macOS arm64 and made no measurable difference; see `RESEARCH.md`.

### Performance on macOS

Measured on a 10-core MacBook Pro (macOS 27) with both ends on the loopback interface, so the client and server share the same CPUs and there is no delay. OpenSSH is Homebrew's 10.6 (built with OpenSSL 4.1). HPN-SSH is this repository's 0.4.0, built from source against OpenSSL 3.5. Both servers ran unprivileged, with no PAM. Each figure is the median of 3 runs of 1024 MB, sent with `dd if=/dev/zero | ssh host 'cat > /dev/null'`.

| TCP limits | Cipher | OpenSSH 10.6 | HPN-SSH | Ratio |
|---|---|---|---|---|
| default (4 MB) | chacha20-poly1305 | 477 MB/s | 624 MB/s | 1.31x |
| default (4 MB) | aes256-ctr | 767 MB/s | 926 MB/s | 1.21x |
| default (4 MB) | aes256-gcm | 862 MB/s | 977 MB/s | 1.13x |
| `tune-tcp.sh apply --max 28311552` | chacha20-poly1305 | 508 MB/s | 672 MB/s | 1.32x |
| `tune-tcp.sh apply --max 28311552` | aes256-ctr | 758 MB/s | 900 MB/s | 1.19x |
| `tune-tcp.sh apply --max 28311552` | aes256-gcm | 862 MB/s | 975 MB/s | 1.13x |

- HPN-SSH is ahead by 13 to 32 percent, in the same order as the Linux LAN results above (gcm closest, chacha furthest).
- Raising the TCP limits changes nothing here. The differences between the two settings are within the spread between runs (HPN-SSH with chacha ranged from 428 to 637 MB/s in one set). With no delay the socket buffers never fill, so the limit is CPU and cipher speed.
- **Not measured:** a long path on macOS. The tuning only matters there. macOS has no network namespaces, and the `dnctl` and `pfctl` delay (dummynet) did not delay loopback traffic in any rule form tried (a 50 ms setting left a connection taking the same 70 ms), so the effect needs two machines with a real or emulated delay between them. The OpenSSH and HPN-SSH builds also use different OpenSSL versions, so the gap includes some of that difference.

## Tuning the TCP stack

On a path with a long round-trip time, one connection can only carry as much data as the kernel's send buffer holds, so a small buffer limit caps HPN-SSH however well it behaves. The maximum for `net.ipv4.tcp_wmem` was 4 MB on the Ubuntu 26.04 machine used for the tests. A 1 Gbit/s path with 100 ms of delay holds about 12.5 MB.

The package ships an example that raises the maximum to 32 MB, as an opt-in. The package never changes system-wide TCP settings, and the file is not under `/etc`:

```
/usr/share/doc/hpn-ssh/examples/99-hpn-ssh-tcp.conf
```

### 1. Work out what you need

The amount of data a path holds is its bandwidth times its round-trip time. Measure the round trip with `ping`, then:

| Bandwidth | Round trip | Path holds |
|---|---|---|
| 1 Gbit/s | 10 ms | 1.25 MB |
| 1 Gbit/s | 50 ms | 6.25 MB |
| 1 Gbit/s | 100 ms | 12.5 MB |
| 10 Gbit/s | 100 ms | 125 MB |

Set the buffer maximum to at least that, with headroom. The kernel counts its own overhead against the buffer, so the usable payload is less than the buffer size. In the tests above, a 32 MB maximum let a connection reach 79 to 86 percent of the line rate on paths holding 6.25 and 12.5 MB.

### 2. Look at what you have

```sh
sysctl net.ipv4.tcp_wmem net.ipv4.tcp_rmem
```

Each shows three numbers: the minimum, the default, and the maximum, in bytes. The kernel starts a connection at the default and grows its buffer toward the maximum as the connection needs it. Only the maximum limits a long path. `tcp_wmem` is the send side and `tcp_rmem` is the receive side. On the machine used for the tests the receive maximum was already 32 MB and the send maximum was 4 MB. Linux's built-in receive maximum is often smaller, so check yours.

### 3. Try a new value

This lasts until the next reboot:

```sh
sudo sysctl -w net.ipv4.tcp_wmem="4096 16384 33554432"
```

Change only the last number. Keep the first two as `sysctl` showed them on your machine. If your receive maximum is also below what you need, raise it the same way:

```sh
sudo sysctl -w net.ipv4.tcp_rmem="4096 131072 33554432"
```

New connections use the new limit. Existing ones do not, so start a new transfer.

### 4. Make it permanent

Use the example, or write your own file:

```sh
sudo cp /usr/share/doc/hpn-ssh/examples/99-hpn-ssh-tcp.conf /etc/sysctl.d/
sudo sysctl --system
```

### 5. Set it on both ends

For data going from A to B, A's send buffer and B's receive buffer both have to be large enough. For transfers in both directions, check both settings on both machines. The settings apply to every program on the machine, not just SSH, so set them only where you want that.

### 6. Check that it worked

While a transfer is running, look at the connection:

```sh
ss -tmi dst <the other host>
```

In the `skmem:(...)` line, `tb` is the send buffer size and `rb` is the receive buffer size, in bytes. On a long path with a busy transfer, `tb` should grow well past 4 MB toward your new maximum. If it stops at 4194304, the limit is still in force on that machine.

### Using the script

`tools/tune-tcp.sh` does steps 2 to 4 for you. It only ever raises a maximum and never lowers one, it changes nothing else unless you ask for a congestion control with `--cc`, and it shows you what it will change before it does anything. Run it as yourself: it asks for `sudo` when it needs it.

```sh
tools/tune-tcp.sh show                                          # what would change; needs no privileges
tools/tune-tcp.sh show --bandwidth 1gbit --rtt 100ms            # size the maximum for your path
tools/tune-tcp.sh apply --bandwidth 1gbit --rtt 100ms           # set it now, until the next reboot
tools/tune-tcp.sh persist --bandwidth 1gbit --rtt 100ms         # set it now and keep it across reboots (Linux)
tools/tune-tcp.sh revert                                        # undo persist (Linux)
tools/tune-tcp.sh persist --cc bbr                              # also use bbr, which keeps its speed on a lossy path (Linux)
tools/tune-tcp.sh apply --cc bbr --cc-only                      # only the congestion control, not the buffers
```

| Command | What it does |
|---|---|
| `show` | Prints the current values and what `apply` would change. Needs no privileges. |
| `apply` | Sets the new maximums with `sysctl -w`. They last until the next reboot. It prints the commands that put the old values back. |
| `persist` | Linux only. Does what `apply` does, and also writes `/etc/sysctl.d/99-hpn-ssh-tcp.conf`, which keeps the setting across reboots. The old values are recorded in that file. With `--cc` it also writes `/etc/modules-load.d/99-hpn-ssh-tcp.conf` so the module is loaded at boot. |
| `revert` | Linux only. Puts back the values recorded by `persist` (the buffers and the congestion control) and removes both files. |

| Option | Meaning |
|---|---|
| `--bandwidth RATE` | Link speed, for example `1gbit` or `100mbit`. The units are `kbit`, `mbit`, `gbit` and `tbit`. |
| `--rtt TIME` | Round-trip time, for example `100ms` or `0.1s`. Give both this and `--bandwidth`, or neither. |
| `--max BYTES` | Set the maximum directly. This overrides `--bandwidth` and `--rtt`. |
| `--send-only` | Change only the send maximum (`net.ipv4.tcp_wmem`, or `net.inet.tcp.autosndbufmax` on macOS), not the receive one. |
| `--cc NAME` | Linux only. Also set the congestion control, for example `bbr`. If it is not listed in `net.ipv4.tcp_available_congestion_control`, `apply` and `persist` load `tcp_NAME` with `modprobe` first. See [Congestion control](#congestion-control). |
| `--cc-only` | With `--cc`, change only the congestion control and leave the buffer maximums alone. |
| `--yes` | Do not ask for confirmation. Without a terminal, `apply` and `persist` refuse to run unless you pass this. |
| `--conf-dir DIR` | Where `persist` writes its file. The default is `/etc/sysctl.d`. |

With `--bandwidth` and `--rtt`, the maximum is 2.5 times the bandwidth-delay product, rounded up to a whole MiB, at least 4 MiB and at most 256 MiB. For 1 Gbit/s at 100 ms that is 30 MiB. Without them the maximum is 32 MiB, the same as the example file. If the current maximum is already at least that large, it is left alone and the script says so.

`persist` writes the same file name as the example in `/usr/share/doc/hpn-ssh/examples/`, so the two do not stack up. Running `persist` again with a different size keeps the values from before the first run, so `revert` always goes back to the original. This is a system-wide setting: run the script on both ends of the connection if you want both ends changed.

### Congestion control

On a path that loses or reorders packets, the kernel's congestion control matters as much as the buffer size, and Linux's default, `cubic`, does badly there (see [Packet loss and congestion control](#packet-loss-and-congestion-control): `bbr` kept its clean-link speed where `cubic` lost 15 to 60 percent or stalled). `--cc bbr` sets it:

```sh
tools/tune-tcp.sh show --cc bbr --bandwidth 1gbit --rtt 100ms   # the buffers and the congestion control
tools/tune-tcp.sh persist --cc bbr --cc-only                  # only the congestion control, kept across reboots
```

- It changes `net.ipv4.tcp_congestion_control` for **every connection from this machine**, not only HPN-SSH's, and it changes how the machine shares a link with other traffic. The script says so when it asks to go ahead.
- It is a setting on the **sending** host. For an upload that is the client's kernel and for a download the server's, so set it on whichever sends the bulk data.
- If the algorithm is not loaded, `apply` and `persist` run `modprobe tcp_bbr` first and stop with an error if that fails. `show` only says that it would.
- `persist` writes the setting to the same `/etc/sysctl.d/99-hpn-ssh-tcp.conf`, records the algorithm it replaced (`# previous net.ipv4.tcp_congestion_control = cubic`), and writes `/etc/modules-load.d/99-hpn-ssh-tcp.conf` so `tcp_bbr` is loaded at boot. `revert` puts `cubic` back and removes both files. `reno` and `cubic` are built into the kernel, so no modules file is written for them.
- It does not change the qdisc. The kernel paces `bbr` itself, and `fq` did not help it in the tests.
- On macOS it is refused: macOS has no `bbr`.
- It has not been measured on a real lossy path or against competing flows, where `bbr` can take more than its share from `cubic` flows. Try it on your own path before changing a shared server.

**macOS.** The script works on Linux and macOS. macOS has no `net.ipv4.tcp_wmem`. Its limits are `net.inet.tcp.autosndbufmax` and `net.inet.tcp.autorcvbufmax` (4 MB by default, the send and receive maximums an auto-tuned connection can grow to) and `kern.ipc.maxsockbuf` (8 MB by default, the cap on any socket buffer). The script raises the first two to the target, and raises `kern.ipc.maxsockbuf` to 9/8 of the target, because the kernel counts overhead against the cap, so a cap equal to the target would hold less than the target. macOS refuses a `kern.ipc.maxsockbuf` above 32 MiB (`Result too large`), so on macOS the target is limited to 28 MiB, and the script says so when it lowers a larger one. That covers the 32 MiB default and a 1 Gbit/s path up to about 90 ms. As on Linux it only raises values. macOS has no `sysctl.d`, so `persist` and `revert` are refused: a setting from `apply` lasts until the next reboot, and to set it at every boot you need to run `tools/tune-tcp.sh apply --yes` from a LaunchDaemon. The effect of the macOS settings on a long path is not measured, see [Performance on macOS](#performance-on-macos).

The script has tests in `tests/tune-tcp.sh`. The macOS checks run on any system, against a stand-in for `sysctl` that keeps its values in files. The checks of the Linux settings run inside a throwaway network namespace, whose TCP settings are separate from the host's, so testing never touches your machine's own settings.

### Things to know

- **Memory:** a buffer only grows for a connection that needs it, but the worst case is the maximum for every such connection at once. On a busy server with many long-path connections, use a smaller maximum, and look at `net.ipv4.tcp_mem`, which limits the total.
- **OpenSSH does not benefit.** Its fixed 2 MB channel window is what limits it, so raising the TCP limits changes nothing for it.
- **`net.core.wmem_max` and `net.core.rmem_max`** only cap a program that sets its buffer size explicitly. They are not what limits autotuned connections, so you do not need to change them for this.
- **HPN-SSH's `TcpRcvBufPoll` option** is on by default and should stay on for Linux, which autotunes buffers.
- **The buffer measurements are on a clean path.** A lossy or jittery path behaves differently; see [Packet loss and congestion control](#packet-loss-and-congestion-control) and [Congestion control](#congestion-control).
- **To undo it,** remove the file from `/etc/sysctl.d/` and set the old values back with `sysctl -w` (or reboot). `sysctl --system` reads the files that remain, but it does not reset a key whose file you removed.

## Choosing a cipher and MAC

`tools/suggest-cipher.sh` looks at this machine's CPU and prints the `Ciphers` and `MACs` lines that suit it. It only prints: it changes no file and no setting, and needs no privileges. It works on Linux and macOS.

```sh
tools/suggest-cipher.sh               # time the ciphers (about 3 seconds), explain the choice
tools/suggest-cipher.sh --config      # only the two lines, ready to paste into a config file
tools/suggest-cipher.sh --no-measure  # decide from the CPU features alone, no timing
tools/suggest-cipher.sh --seconds 5   # time each cipher for longer
```

| Option | Meaning |
|---|---|
| `--seconds N` | Time each cipher for N seconds. A whole number, at least 1. The default is 1. |
| `--no-measure` | Do not run `openssl speed`. Choose from the CPU features: `aes` in `/proc/cpuinfo` on Linux, the `hw.optional.arm.FEAT_AES` or `machdep.cpu.features` `sysctl` values on macOS. |
| `--config` | Print only the `Ciphers` and `MACs` lines, with no explanation. |
| `-h`, `--help` | Print the usage. |

An unknown option, or a `--seconds` that is not a whole number of at least 1, is an error. Otherwise the exit status is 0.

### What it prints

On an Apple M1 Max:

```
CPU:           Apple M1 Max (arm64)
AES hardware:  yes
Raw speed, one core, 16 KiB blocks (openssl speed):
  aes256-gcm          6536 MB/s
  chacha20-poly1305   1799 MB/s
  aes256-ctr          9362 MB/s (before the MAC it needs)

Suggested: AES-GCM first (measured: aes256-gcm 6536 MB/s, chacha20-poly1305 1799 MB/s per core).

  Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,chacha20-poly1305-mt@hpnssh.org,chacha20-poly1305@openssh.com,aes256-ctr
  MACs umac-64-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-256-etm@openssh.com
```

It then says how to use the lines and repeats a few notes. With `--config` the output is exactly the last two lines, without the two leading spaces.

### How it chooses

1. **Measured, when it can.** It runs `openssl speed -evp` for AES-256-GCM and ChaCha20-Poly1305 on one core with 16 KiB blocks, and puts the faster one first. This times OpenSSL's single-threaded ChaCha. HPN-SSH's default ChaCha is multithreaded and much faster end to end, so on a CPU with AES instructions the real lead of AES-GCM is a few percent, not the raw ratio. It needs an `openssl` that supports `speed -mr -elapsed -seconds -bytes`. OpenSSL 3.5 and 4.1 were tried. Apple's LibreSSL (`/usr/bin/openssl`) does not support these options, so on a Mac without a Homebrew `openssl` on the path the script falls back to the CPU features.
2. **From the CPU, otherwise.** With `--no-measure`, or no usable `openssl`, a CPU with AES instructions gets AES-GCM first and one without gets ChaCha20-Poly1305 first. If it cannot read the CPU, it keeps HPN-SSH's default order, which is ChaCha first.
3. **`aes256-ctr` is always last.** It needs a separate MAC and, once that is counted, it was ahead of AES-256-GCM on one machine and behind on the other (see [Cipher choice end to end](#cipher-choice-end-to-end)), so it is there only for a peer that offers nothing else. Its raw speed is printed for information, but it does not take part in the choice.
4. **The MAC line is fixed.** Only the `aes-ctr` ciphers use a separate MAC (AES-GCM and ChaCha20-Poly1305 carry their own authentication), and `umac-64-etm@openssh.com` was the fastest in the MAC tests, so it stays first.

The two ciphers it compares come in both orders in the output:

| Order | Ciphers line |
|---|---|
| AES-GCM first | `aes256-gcm@openssh.com,aes128-gcm@openssh.com,chacha20-poly1305-mt@hpnssh.org,chacha20-poly1305@openssh.com,aes256-ctr` |
| ChaCha first | `chacha20-poly1305-mt@hpnssh.org,chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr` |

### Using the result

- **For every connection from this machine:** add the `Ciphers` line (and the `MACs` line if you use `aes-ctr`) to `/etc/hpnssh/ssh_config`, or to `~/.ssh/config` for one user, for example under `Host *`.
- **For a server:** add the same lines to `/etc/hpnssh/sshd_config` and restart `hpnsshd`. Both ends need AES-capable CPUs for AES-GCM to pay off; the client chooses from the server's list in its own order.
- **For one connection:** `hpnssh -c aes256-gcm@openssh.com host`.

`chacha20-poly1305-mt@hpnssh.org` is HPN-SSH's multithreaded ChaCha. A plain OpenSSH peer does not know it and falls through to the next name.

### Limits

- It times **one core**, not a connection. The end-to-end speed also depends on the other end, the network, the MAC and, on a long path, the TCP buffer limit (see [Tuning the TCP stack](#tuning-the-tcp-stack)).
- It was run on an Apple M1 Max and an Intel Xeon E5-2630 v4, both with AES instructions. Raw, AES-GCM led single-threaded ChaCha by 1.7 to 3.7 times per core, but end to end it led HPN-SSH's default multithreaded ChaCha by only 5 to 6 percent (see [Cipher choice end to end](#cipher-choice-end-to-end)), so expect a small gain. The path for a CPU without AES instructions is checked by the tests with stand-in data, not on real hardware, and it is on such a CPU that the choice matters most.
- `aes128-gcm` is in the list but has not been timed.
- Its tests are in `tests/run-tests.sh`: the choice from measured speeds and from CPU features, the `--config` output, bad input, and that `hpnssh` accepts every name it prints.

## Patches

`sphynx-ssh/` is upstream HPN-SSH plus the changes sphynx has made to it. Those changes are kept as a series of patches in `patches/`, one per change, so they can be reviewed one at a time, sent upstream, and applied again to a newer HPN-SSH release.

The series applies to this upstream commit, which is also in `patches/BASE`:

```
2c7cc5554  rapier1/hpn-ssh master, HPN-SSH 18.12.0 on OpenSSH 10.6
```

Apply the patches in order. Each one builds on its own, and each message says what was wrong, how it fails, and how it was checked.

| Patch | Change | sphynx versions | For upstream |
|---|---|---|---|
| 0001 | `aes-ctr-mt`: keep each pregen thread's state in the cipher context. Removes a data race on a shared hash, a hash key that used 4 bytes of an 8-byte thread id, a NULL dereference on join, global thread and queue counts, a pointer to the caller's key, unchecked allocations, and an `exit` from a thread. | 0.0.4, 0.0.5, 0.0.6, 0.0.8, 0.0.9, 0.1.0 | yes |
| 0002 | `aes-ctr-mt`: the same changes in the implementation for builds without OpenSSL 3. | 0.0.4 to 0.1.0, as 0001 | yes |
| 0003 | `aes-ctr-mt`: destroy the queue locks after the threads are joined. | 0.0.7 | yes |
| 0004 | `chachapoly-mt`: check the worker argument allocation. | 0.1.1 | yes |
| 0005 | `aes-ctr-mt`: destroy the thread attributes after use. | 0.1.2 | yes |
| 0006 | `scp`: build the `-Z` temporary name in its own buffer. Fixes a buffer overflow on the caller's argument string. | 0.2.1 | yes |
| 0007 | `clientloop`: edit the command buffer in place when rewriting `scp` to `hpnscp`. Fixes a use after free and double free. | 0.2.2 | yes |
| 0008 | `kex`: insert the serial ChaCha name after the MT entry in `patch_list`. Fixes a corrupted cipher proposal. | 0.2.3 | yes |
| 0009 | `ssh`: do not disable the none switch for `-T`. | 0.2.4 | yes |
| 0010 | `chachapoly-mt`: refuse packets longer than the pregenerated keystream. | 0.2.5 | yes |
| 0011 | `scp`: reset the match status for each file in the sender. | 0.2.6 | yes |
| 0012 | `scp`: report errors when joining the resumed tail. | 0.2.7 | yes |
| 0013 | `scp`: validate the resume response in the sender. | 0.2.8 | yes |
| 0014 | `scp`: check the hash field length and make `calculate_hash` fixed width. | 0.2.9 | yes |
| 0015 | `scp`: release per-file resume state at the top of the loop. | 0.3.0 | yes |
| 0016 | `channels`: arm the input fd only when it can be read. Fixes the client and server spinning at full CPU on long paths. | 0.3.4 | yes |
| 0017 | `version`: add the sphynx version to the release string. | 0.0.3 | fork only |
| 0018 | `ci`: remove the inherited OpenSSH workflows and note the fork in the README. | 0.1.3 to 0.1.9 | fork only |
| 0019 | `cipher-ctr-mt`: XOR the keystream a queue at a time, 4 to 7 percent faster `aes256-ctr` on loopback. | 0.4.5 | self-contained |
| 0020 | `cipher-ctr-mt-provider`: read the cipher state through the `EVP_CIPHER_CTX`, which fixes a crash with OpenSSL 4.1. | 0.5.3 | self-contained |
| 0021 | `channels`: do not zero the 32 KiB extended data buffer on every pass of the event loop. 1 to 4 percent less server CPU. | 0.5.5 | self-contained |
| 0022 | `compression`: add `huff0@hpnssh.org`, a dictionary-free method that sends the same bytes as zlib's Huffman-only mode at a quarter of the CPU. Copies zstd's `huff0` into `huff0/`. | 0.6.5 | HPN-SSH only (a new method name; both ends need it) |
| 0023 | `clientloop`: check the server's metrics reply before reading it. Fixes reads past the packet buffer. | 0.6.6 | yes |
| 0024 | `clientloop`: free the metrics objects and keep the session if a metrics file cannot be written. | 0.6.7 | yes |
| 0025 | `sshconnect2`: keep the user's `KexAlgorithms` in the none switch rekey, and free the proposal. | 0.6.8 | yes |
| 0026 | `ssh`: fall back to `FallbackPort` once, so a closed default port cannot loop. | 0.6.9 | yes |
| 0027 | `clientloop`: give children started from the loop a clean signal mask. | 0.7.0 | yes |
| 0028 | `serverloop`: log the throughput line once, and guard the rate against a zero duration. | 0.7.1 | yes |
| 0029 | `kex`: refuse the none MAC unless the cipher is none and the session is authenticated. | 0.7.2 | yes |
| 0030 | `packet`: decide whether the MAC is enabled per direction, from its name, and clear the none flags on each negotiation. | 0.7.3 | yes |
| 0031 | `readconf`: `MetricsPath` turns metrics on only in an active block and only if `Metrics` is unset. | 0.7.4 | yes |
| 0032 | `hpnsshd_config.5`: say that `DisableMTAES` covers only AES-CTR and how to keep the serial ChaCha. | 0.7.5 | yes |
| 0033 | `readconf`, `packet`: range check `MetricsInterval` and `FallbackPort`, and return an error when the cipher is missing. | 0.7.6 | yes |
| 0034 | `kex`, `cipher`, `chachapoly`: release the string and references that were taken on every key exchange or cipher start. | 0.7.7 | yes |
| 0035 | `chachapoly-mt`: repair the keystream state in a forked child. | 0.7.8 | yes |
| 0036 | `happyeyeballs`: read `fd_ai` only for its own sockets and keep `errno` on failure. | 0.7.9 | yes |
| 0037 | `sshconnect`: name the port in the connect failure message. | 0.8.2 | yes |

Some changelog entries share a patch. The AES-CTR cipher fixes were written as one restructure: removing the shared hash is what fixes the race, the key size and the NULL dereference at once, and moving the counts into the context is entangled with the same functions. Those changes cannot be split into steps that each build, so they are patches 0001 and 0002. The two small independent ones, 0003 and 0005, are separate.

### Apply, check and update

```sh
tools/patches.sh check              # do the patches apply to upstream and reproduce sphynx-ssh/?
tools/patches.sh apply <checkout>   # apply them to a git checkout, for example a newer release
tools/patches.sh base               # print the upstream commit the series applies to
```

`apply` uses `git am --3way`, so a patch that no longer applies cleanly falls back to a three-way merge.

To move to a newer HPN-SSH release:

```sh
cd sphynx-ssh
git fetch upstream --tags
git checkout -b next <new upstream commit or tag>
../tools/patches.sh apply .
```

If a patch does not apply, fix the conflict in the tree, `git add` the files and run `git am --continue`. If an upstream release has already fixed what a patch fixes, run `git am --skip` for it and say so in `CHANGELOG.md`. Then build, run the tests, and write the series out again:

```sh
git format-patch -N --no-signature -o ../patches <new upstream commit>..HEAD
```

Put the new commit in `patches/BASE`. Patch 0017 holds the sphynx version tag, so regenerate it, and the series, whenever the sphynx version changes.

### Sending a patch upstream

Patches 0001 to 0016 are self-contained bug fixes. Take the ones you want, in order, because later patches build on earlier ones (0003 and 0005 follow 0001 and 0002, 0010 follows 0004, and the `scp` patches follow each other). The commit messages end with a `Co-Authored-By` trailer for the assistant that helped write them. Remove it if you do not want it. Patches 0017 and 0018 are specific to this fork. Patches 0019 and 0021 are performance changes and patch 0020 is a bug fix, and all three stand on their own. Patch 0022 adds a feature and files (it copies a part of zstd, with its licence files), and needs the peer to have it too; without it the connection falls back to zlib.

### How the series was made

The fixes were first made as edits to `sphynx-ssh/`. The series was then rebuilt on the upstream commit, one fix at a time, and `tools/patches.sh check` confirms that its end state is exactly the current `sphynx-ssh/`. The `sphynx build` command still builds from `sphynx-ssh/` and does not apply the patches itself.

## Build dependencies

The build needs these packages. `sphynx build` checks for them first and prints the `apt-get` line for any that are missing.

| Package | Used for |
|---|---|
| `autoconf`, `automake`, `make`, `gcc` | Generating and running the build |
| `dpkg-dev` | `dpkg-shlibdeps` for runtime dependencies |
| `libssl-dev` | OpenSSL headers |
| `zlib1g-dev` | zlib headers |
| `libpam0g-dev` | PAM headers (the server is built with PAM) |

## Packaging details

- **Host keys** are not in the package. The postinst script runs `hpnssh-keygen -A`, which creates only the missing key types.
- **Dependencies** are computed from the built binaries with `dpkg-shlibdeps`, plus `adduser`, `init-system-helpers`, `libpam-modules` and `libpam-runtime`.
- **Service:** the postinst script enables and starts `hpnsshd` on a fresh install, and restarts it on upgrade if it is running. The prerm stops it on removal. Purge removes the host keys and the `hpnsshd` user.
- **TCP buffer example:** `/usr/share/doc/hpn-ssh/examples/99-hpn-ssh-tcp.conf` is installed but not enabled. See [Tuning the TCP stack](#tuning-the-tcp-stack).
- **Conffiles:** `/etc/hpnssh/ssh_config`, `/etc/hpnssh/sshd_config`, `/etc/hpnssh/moduli` and `/etc/pam.d/hpnsshd`.
- **PAM:** the server uses the `hpnsshd` PAM service, which ships as `/etc/pam.d/hpnsshd`. It is adapted from Ubuntu's `sshd` configuration. The packaged `sshd_config` sets `UsePAM yes`, as Ubuntu's does, so an account with a locked password (the default user on cloud images) can log in with a key.

## Tests

```sh
tests/run-tests.sh
SPHYNX_SKIP_BUILD=1 tests/run-tests.sh   # skip the end-to-end build
```

The tests check that the version matches in `sphynx`, `README.md` and `CHANGELOG.md`, check the command line, run shellcheck, and build a package and inspect its metadata and contents. They also run the C tests in `tests/c/`, the `scp -Z` tests, the checks in `tests/daemon-checks.sh` (below), a check of the performance analysis script, and the TCP tuning script's tests. The tuning script's tests that change settings need passwordless `sudo` and run only inside a throwaway network namespace; without `sudo` they are skipped.

`tests/daemon-checks.sh <build-tree>` starts `hpnsshd` from a build tree as the current user on a free loopback port, with a throwaway key and configuration, and checks things that need a running server: a client can log in; a session survives an unwritable `MetricsPath`, and `Metrics yes` writes both files; the none switch rekey keeps the client's `KexAlgorithms`; the none MAC is refused with a real cipher and used with the none cipher after login; a command started from `~C` has no signals blocked (`tests/escape-sigmask.py`, on a pseudo terminal); the server logs the throughput line once for a session that was cut off; data sent over `aes256-ctr` arrives intact after the switch to the multithreaded cipher; `FallbackPort` at the default port gives up; and a control master built with AddressSanitizer survives a session that starts with `scp`. It installs nothing and writes only to a temporary directory. The suite runs it on Linux; some checks are skipped on other systems.

`tests/package-lifecycle.sh` is not part of that suite. It installs, upgrades, removes, reinstalls and purges the built `.deb` on a machine, and checks the `hpnsshd` user, the host keys, the service and a login on port 2222. It changes the machine it runs on, so run it only in a throwaway VM or container that runs systemd. Its header has the commands for OrbStack.

## Layout

```
sphynx                      wrapper script
packaging/ubuntu/           control template, maintainer scripts, systemd unit, PAM file, conffiles
tests/run-tests.sh          test suite, with its C tests in tests/c/ and the scp -Z tests in tests/scp-resume.sh
tests/daemon-checks.sh      checks against an hpnsshd started from a build tree
tests/package-lifecycle.sh  install, upgrade, remove and purge of the .deb, for a throwaway systemd machine
tools/perf/                 performance comparison of OpenSSH and HPN-SSH (see tools/perf/README.md)
tools/tune-tcp.sh           applies the TCP buffer tuning described in this file
tools/suggest-cipher.sh     suggests a Ciphers and MACs setting for this CPU
tools/patches.sh            checks and applies the patch series in patches/
CHANGELOG.md                every change, by version
TODO.md                     outstanding work
RESEARCH.md                 ideas tried or considered and not built, with the results
HANDOFF.md                  current state and next steps, for picking the work up elsewhere
patches/                    the changes sphynx makes to HPN-SSH, one patch each, applied to the commit in patches/BASE
sphynx-ssh/                HPN-SSH fork used as the source (separate git repo, not tracked by sphynx)
hpn-ssh/                    HPN-SSH clone (separate git repo, not used by default)
openssh-portable/           upstream OpenSSH source (separate git repo, not tracked by sphynx)
build/                      scratch build output (generated)
dist/                       finished packages (generated)
```
