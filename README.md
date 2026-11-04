# sphynx

Version: 0.4.4

Sphynx is a wrapper that builds HPN-SSH from source and packages it for target operating systems. The first target is Ubuntu (`.deb`).

## Contents

- [Quick start](#quick-start)
- [Command reference](#command-reference)
- [Output](#output)
- [Performance](#performance)
- [Tuning the TCP stack](#tuning-the-tcp-stack)
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

On Ubuntu 26.04 this produces `dist/hpn-ssh_10.6p1+hpn18.12.0+sphynx0.3.6-1~resolute1_amd64.deb`.

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
OpenSSH_10.6p1_hpn18.12.0_sphynx0.3.6
```

- `OpenSSH_10.6p1` is the OpenSSH base in `sphynx-ssh/version.h`.
- `_hpn18.12.0` is the HPN-SSH release.
- `_sphynx0.3.6` is the sphynx version. It is `SSH_SPHYNX` in `sphynx-ssh/version.h`.

`hpnssh -V` and `hpnsshd -V` print the full string, and the SSH banner sent to peers contains it. `sphynx build` stops with an error if `SSH_SPHYNX` does not match the sphynx version, so the two cannot drift apart. When you bump the sphynx version, update `sphynx`, `README.md`, `CHANGELOG.md` and `sphynx-ssh/version.h` together.

The package installs alongside OpenSSH:

- Programs are named `hpnssh`, `hpnscp`, `hpnsftp`, `hpnssh-keygen` and so on, and `hpnsshd` is the server.
- Configuration is in `/etc/hpnssh/`.
- The server runs as the `hpnsshd` systemd service and listens on port 2222 by default.

## Performance

HPN-SSH is faster than OpenSSH on a fast local network, and on long paths it can be several times faster once the kernel's TCP buffer limit allows it. Both results below were measured on Linux (Ubuntu 26.04), in one test setup described after the tables. None of the numbers in this section come from macOS.

### Default kernel settings

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

### With a larger send buffer limit

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

### What to take from it

- On a fast local network, HPN-SSH is faster and uses about the same CPU per GB or less.
- On a long path, raise the TCP send buffer limit or HPN-SSH is limited by the kernel, not by itself.
- **CPU:** with the default limit, the HPN-SSH client uses about 1 to 2 CPU-seconds per GB more than OpenSSH on the long paths (2.6 to 3.3 against 1.1 to 1.9). With the larger limit the two are within about 0.4 of each other (1.35 to 1.87 against 1.11 to 1.83). Before version 0.3.4 the HPN-SSH client spent about a full core on long paths, 19 to 37 CPU-seconds per GB, because its channel loop polled an input it could not read. That is fixed in patch 0016.

### How it was measured

- **Software:** OpenSSH 10.6, built from the same upstream release HPN-SSH is based on, against HPN-SSH 0.3.4. Both were built from source with OpenSSL 3.5.
- **Network:** two Linux network namespaces joined by a virtual link on a 16-core machine. The delay and a 1 Gbit/s rate limit were added with `tc netem`, half of the round trip in each direction. The LAN case has no shaping. The test hosts were otherwise idle.
- **Transfer:** one connection, one direction, 384 to 2048 MB of data from `/dev/zero` (768 MB for the larger-limit runs), sent with `dd if=/dev/zero | ssh host 'cat > /dev/null'`. No compression. The time to connect is measured separately and subtracted. The two implementations were run in turn, and the median of 3 runs is reported. The spread between runs was under 2 percent for the long paths.
- **Not covered:** packet loss and jitter, scp and sftp, mixed pairs (an HPN-SSH client with an OpenSSH server or the reverse), and different numbers of cipher threads. `tools/perf` can measure all of these (see its README), but no results are published here yet. These results show the effect of the buffer limit on an otherwise clean path, not what any real network will give you.

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

### Cipher threads

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

`tools/tune-tcp.sh` does steps 2 to 4 for you. It only ever raises a maximum and never lowers one, it changes nothing else, and it shows you what it will change before it does anything. Run it as yourself: it asks for `sudo` when it needs it.

```sh
tools/tune-tcp.sh show                                          # what would change; needs no privileges
tools/tune-tcp.sh show --bandwidth 1gbit --rtt 100ms            # size the maximum for your path
tools/tune-tcp.sh apply --bandwidth 1gbit --rtt 100ms           # set it now, until the next reboot
tools/tune-tcp.sh persist --bandwidth 1gbit --rtt 100ms         # set it now and keep it across reboots (Linux)
tools/tune-tcp.sh revert                                        # undo persist (Linux)
```

| Command | What it does |
|---|---|
| `show` | Prints the current values and what `apply` would change. Needs no privileges. |
| `apply` | Sets the new maximums with `sysctl -w`. They last until the next reboot. It prints the commands that put the old values back. |
| `persist` | Linux only. Does what `apply` does, and also writes `/etc/sysctl.d/99-hpn-ssh-tcp.conf`, which keeps the setting across reboots. The old values are recorded in that file. |
| `revert` | Linux only. Puts back the values recorded by `persist` and removes the file. |

| Option | Meaning |
|---|---|
| `--bandwidth RATE` | Link speed, for example `1gbit` or `100mbit`. The units are `kbit`, `mbit`, `gbit` and `tbit`. |
| `--rtt TIME` | Round-trip time, for example `100ms` or `0.1s`. Give both this and `--bandwidth`, or neither. |
| `--max BYTES` | Set the maximum directly. This overrides `--bandwidth` and `--rtt`. |
| `--send-only` | Change only the send maximum (`net.ipv4.tcp_wmem`, or `net.inet.tcp.autosndbufmax` on macOS), not the receive one. |
| `--yes` | Do not ask for confirmation. Without a terminal, `apply` and `persist` refuse to run unless you pass this. |
| `--conf-dir DIR` | Where `persist` writes its file. The default is `/etc/sysctl.d`. |

With `--bandwidth` and `--rtt`, the maximum is 2.5 times the bandwidth-delay product, rounded up to a whole MiB, at least 4 MiB and at most 256 MiB. For 1 Gbit/s at 100 ms that is 30 MiB. Without them the maximum is 32 MiB, the same as the example file. If the current maximum is already at least that large, it is left alone and the script says so.

`persist` writes the same file name as the example in `/usr/share/doc/hpn-ssh/examples/`, so the two do not stack up. Running `persist` again with a different size keeps the values from before the first run, so `revert` always goes back to the original. This is a system-wide setting: run the script on both ends of the connection if you want both ends changed.

**macOS.** The script works on Linux and macOS. macOS has no `net.ipv4.tcp_wmem`. Its limits are `net.inet.tcp.autosndbufmax` and `net.inet.tcp.autorcvbufmax` (4 MB by default, the send and receive maximums an auto-tuned connection can grow to) and `kern.ipc.maxsockbuf` (8 MB by default, the cap on any socket buffer). The script raises the first two to the target, and raises `kern.ipc.maxsockbuf` to 9/8 of the target, because the kernel counts overhead against the cap, so a cap equal to the target would hold less than the target. macOS refuses a `kern.ipc.maxsockbuf` above 32 MiB (`Result too large`), so on macOS the target is limited to 28 MiB, and the script says so when it lowers a larger one. That covers the 32 MiB default and a 1 Gbit/s path up to about 90 ms. As on Linux it only raises values. macOS has no `sysctl.d`, so `persist` and `revert` are refused: a setting from `apply` lasts until the next reboot, and to set it at every boot you need to run `tools/tune-tcp.sh apply --yes` from a LaunchDaemon. The effect of the macOS settings on a long path is not measured, see [Performance on macOS](#performance-on-macos).

The script has tests in `tests/tune-tcp.sh`. The macOS checks run on any system, against a stand-in for `sysctl` that keeps its values in files. The checks of the Linux settings run inside a throwaway network namespace, whose TCP settings are separate from the host's, so testing never touches your machine's own settings.

### Things to know

- **Memory:** a buffer only grows for a connection that needs it, but the worst case is the maximum for every such connection at once. On a busy server with many long-path connections, use a smaller maximum, and look at `net.ipv4.tcp_mem`, which limits the total.
- **OpenSSH does not benefit.** Its fixed 2 MB channel window is what limits it, so raising the TCP limits changes nothing for it.
- **`net.core.wmem_max` and `net.core.rmem_max`** only cap a program that sets its buffer size explicitly. They are not what limits autotuned connections, so you do not need to change them for this.
- **HPN-SSH's `TcpRcvBufPoll` option** is on by default and should stay on for Linux, which autotunes buffers.
- **Congestion control, packet loss and jitter** were not part of these measurements. A lossy path behaves differently from the clean path tested here.
- **To undo it,** remove the file from `/etc/sysctl.d/` and set the old values back with `sysctl -w` (or reboot). `sysctl --system` reads the files that remain, but it does not reset a key whose file you removed.

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

Patches 0001 to 0016 are self-contained bug fixes. Take the ones you want, in order, because later patches build on earlier ones (0003 and 0005 follow 0001 and 0002, 0010 follows 0004, and the `scp` patches follow each other). The commit messages end with a `Co-Authored-By` trailer for the assistant that helped write them. Remove it if you do not want it. Patches 0017 and 0018 are specific to this fork.

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
tools/patches.sh            checks and applies the patch series in patches/
HANDOFF.md                  current state and next steps, for picking the work up elsewhere
patches/                    the changes sphynx makes to HPN-SSH, one patch each, applied to the commit in patches/BASE
sphynx-ssh/                HPN-SSH fork used as the source (separate git repo, not tracked by sphynx)
hpn-ssh/                    HPN-SSH clone (separate git repo, not used by default)
openssh-portable/           upstream OpenSSH source (separate git repo, not tracked by sphynx)
build/                      scratch build output (generated)
dist/                       finished packages (generated)
```
