<img src="sphynx.jpg" alt="sphynx" width="110" align="right">

# sphynx

SSH Performance Hacks Yielding Network eXcellence

Version: 0.5.9

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
| On a lossy or jittery path? | `bbr` kept its clean-link speed; `cubic` lost 15 to 62 percent or stalled. | [Packet loss and congestion control](#packet-loss-and-congestion-control) |
| Which cipher? | AES-GCM leads the default multithreaded ChaCha by 5 to 6 percent on CPUs with AES instructions; the top four are within about 10 percent. | [Cipher choice](#cipher-choice-end-to-end), [Choosing a cipher and MAC](#choosing-a-cipher-and-mac) |
| Which MAC? | The default, `umac-64-etm`, is already the fastest. | [Choice of MAC](#choice-of-mac) |
| What limits a connection on a fast LAN? | The sending thread: about 85 percent of it is the kernel and the cipher. | [Where the time goes](#where-the-time-goes) |
| What made no difference? | More cipher threads, rekeying, OpenSSL 3.5 against 4.1, 64 KiB packets, other TCP settings, the hardening flags. | [Settings that made no difference](#settings-that-made-no-difference) |
| What did the work in this repository change? | Patch 0019: `aes256-ctr` 4 to 7 percent faster. Patch 0021: 1 to 4 percent less server CPU. Patch 0020 fixes a crash, not speed. `tools/tune-tcp.sh --cc` and `tools/suggest-cipher.sh` apply the findings. | [Patches](#patches) |

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
- **Not covered:** scp and sftp, and mixed pairs (an HPN-SSH client with an OpenSSH server or the reverse). `tools/perf` can measure both (see its README) but has not been run on Linux yet. Loss and jitter are in [Packet loss and congestion control](#packet-loss-and-congestion-control). These results show the effect of the buffer limit on a clean path, not what a real network will give you.

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

Patches 0001 to 0016 are self-contained bug fixes. Take the ones you want, in order, because later patches build on earlier ones (0003 and 0005 follow 0001 and 0002, 0010 follows 0004, and the `scp` patches follow each other). The commit messages end with a `Co-Authored-By` trailer for the assistant that helped write them. Remove it if you do not want it. Patches 0017 and 0018 are specific to this fork. Patches 0019 and 0021 are performance changes and patch 0020 is a bug fix, and all three stand on their own.

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

The tests check that the version matches in `sphynx`, `README.md` and `CHANGELOG.md`, check the command line, run shellcheck, and build a package and inspect its metadata and contents. They also run the C tests in `tests/c/`, the `scp -Z` tests, a check of the performance analysis script, and the TCP tuning script's tests. The tuning script's tests that change settings need passwordless `sudo` and run only inside a throwaway network namespace; without `sudo` they are skipped.

`tests/package-lifecycle.sh` is not part of that suite. It installs, upgrades, removes, reinstalls and purges the built `.deb` on a machine, and checks the `hpnsshd` user, the host keys, the service and a login on port 2222. It changes the machine it runs on, so run it only in a throwaway VM or container that runs systemd. Its header has the commands for OrbStack.

## Layout

```
sphynx                      wrapper script
packaging/ubuntu/           control template, maintainer scripts, systemd unit, PAM file, conffiles
tests/run-tests.sh          test suite, with its C tests in tests/c/ and the scp -Z tests in tests/scp-resume.sh
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
