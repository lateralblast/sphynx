# tools/perf

Compare the throughput of OpenSSH and HPN-SSH over an emulated network. The results in the main README's [Performance](../../README.md#performance) section came from this tool.

It builds two Linux network namespaces joined by a virtual link, adds delay, a rate limit and optionally packet loss and jitter to the link with `tc netem`, runs an OpenSSH server and an HPN-SSH server in one namespace, and times a transfer from the other. It can time `ssh`, `scp` and `sftp`, every pairing of OpenSSH and HPN-SSH client and server, and different `SSH_CIPHER_THREADS` values.

## What it changes

- It creates the network namespaces `perf_srv` and `perf_cli`, a virtual link between them, and two `sshd` processes inside `perf_srv`. Nothing is added to the host's own network, and no kernel setting is changed on the host. The `--wmem` and `--rmem` options set TCP buffer limits inside the two namespaces only.
- Keys, server configs, logs and results go in `build/perf/`, which is git-ignored.
- `tools/perf/perf.sh teardown` stops the servers and removes the namespaces.
- It needs `sudo`.

## What it needs

- Linux with `iproute2` (the `ip` and `tc` commands) and the `sch_netem` kernel module, `/usr/bin/time`, and `python3`.
- An OpenSSH server installed on the machine, so that the `sshd` privilege separation user and `/run/sshd` exist.
- HPN-SSH, with the `hpnsshd` privilege separation user and its helper programs in `/usr/lib/hpnssh`. The simplest way is to install the package `sphynx build` makes: `sudo apt install ./dist/hpn-ssh_*.deb`. That also starts a normal `hpnsshd` service on port 2222, which does not interfere with the test servers. To test a build tree without installing, set `HPN_SSH` and `HPN_SSHD` to its `hpnssh` and `hpnsshd`, and make sure the helpers from the same build are in `/usr/lib/hpnssh`.
- A baseline OpenSSH. `tools/perf/build-baseline.sh` builds one from `openssh-portable/` under `build/perf/baseline/`, with nothing installed on the system. Set `BASELINE_PREFIX` to use another.

## Quick start

```sh
tools/perf/build-baseline.sh
tools/perf/perf.sh setup
tools/perf/perf.sh run
tools/perf/perf.sh analyze build/perf/results.csv
tools/perf/perf.sh teardown
```

`run` writes a CSV. `analyze` prints, for each condition and cipher, the median throughput of both implementations with the time to connect subtracted, their ratio, the range over the runs, and the client's CPU seconds per GB.

## Options for `run`

| Option | Default | Meaning |
|---|---|---|
| `--conds LIST` | `lan,wan50,wan100` | Comma list of conditions. `lan` has no shaping. `wanNN` is an NN ms round trip, half in each direction. Either can be followed by `_lossPERCENT` and `_jitMS`, for example `wan50_loss0.5` or `wan100_loss0.1_jit5`. See [Loss and jitter](#loss-and-jitter). |
| `--tools LIST` | `ssh` | Comma list of `ssh`, `scp` and `sftp`. See [scp and sftp](#scp-and-sftp). |
| `--pairs LIST` | `base:base,hpn:hpn` | Comma list of `CLIENT:SERVER`, each `base` (OpenSSH) or `hpn` (HPN-SSH). `hpn:base` is an HPN-SSH client against an OpenSSH server and `base:hpn` is the reverse. |
| `--threads LIST` | `default` | Comma list of `SSH_CIPHER_THREADS` values, each a number or `default` (unset). See [Cipher threads](#cipher-threads). |
| `--ciphers LIST` | `default`, `chacha20-poly1305@openssh.com`, `aes256-ctr`, `aes256-gcm@openssh.com` | Comma list. `default` is each side's own default cipher. |
| `--runs N` | 3 | Runs per case. The two implementations alternate within each run. |
| `--mb LIST` | `lan=2048,wan50=512,wan100=384` | Data size in MB, as `cond=MB` pairs. Any other `wanNN` uses 512. A condition with loss or jitter uses the size of its `wanNN` unless it has its own entry. |
| `--wmem "A B C"` | the host's value | Set `net.ipv4.tcp_wmem` inside the namespaces. |
| `--rmem "A B C"` | the host's value | Set `net.ipv4.tcp_rmem` inside the namespaces. |
| `--out FILE` | `build/perf/results.csv` | Where to write the CSV. |
| `--dry-run` | off | Print the cases and the `netem` settings and run nothing. Needs no `sudo`, and works on any system, so use it to check a long matrix before starting it. |

Every run starts from the host's own TCP limits unless you pass `--wmem` or `--rmem`, so a result never depends on an earlier run. The link rate is 1 Gbit/s. Set `PERF_RATE`, for example `PERF_RATE=100mbit`, to change it.

## Reproducing the README numbers

The default kernel settings, all conditions and ciphers:

```sh
tools/perf/perf.sh run --out build/perf/default.csv
```

With a 32 MB send buffer limit, on the long paths:

```sh
tools/perf/perf.sh run --conds wan50,wan100 --ciphers default,aes256-ctr \
    --mb wan50=768,wan100=768 --wmem "4096 16384 33554432" --out build/perf/tuned.csv
```

## Beyond ssh over a clean path

### scp and sftp

`--tools scp,sftp` times a file sent with `scp` or `sftp` instead of the `dd` pipe. Both send a file of zeros, `build/perf/data-MB`, to `/dev/null` on the server, and the file is removed at the end of the run. Make sure there is room for the largest `--mb`. `sftp` needs the server's SFTP subsystem, which the script now adds to both server configs (`Subsystem sftp`); it restarts the servers at the start of `run` so an older setup picks it up. The time to connect is measured with each tool, with an empty file, and subtracted as before.

The client programs come from the same directory as `ssh` unless you set `BASELINE_SCP`, `BASELINE_SFTP`, `HPN_SCP` and `HPN_SFTP`, and the SFTP servers are `$BASELINE_PREFIX/libexec/sftp-server` and `/usr/lib/hpnssh/hpnsftp-server` unless you set `BASELINE_SFTP_SERVER` and `HPN_SFTP_SERVER`. Each client is run with `-S` so it uses the `ssh` of its own implementation.

OpenSSH's `scp` has used the SFTP protocol by default since 9.0. A run that fails, for example because a client and server do not agree on a protocol, is recorded as `nan`, printed as `-` by `analyze`, and reported on standard error.

### Mixed pairs

`--pairs base:base,hpn:hpn,hpn:base,base:hpn` adds an HPN-SSH client against an OpenSSH server and the reverse. In the CSV, `impl` is the client and `server` is the server. `analyze` shows each pairing as a column, with its ratio to OpenSSH against OpenSSH.

### Cipher threads

`--threads default,1,2,4,8` runs the same cases for each `SSH_CIPHER_THREADS` value. A value is passed to the client's environment and, by restarting `hpnsshd`, to the server's, because the server reads it when a connection starts. Only the multi-threaded AES-CTR cipher uses it (the HPN-SSH ChaCha20 code has a fixed thread count), so it applies to `*-ctr` ciphers when HPN-SSH is on either side, such as `--ciphers aes256-ctr`. Every other case runs once. `default` leaves the variable unset, which is one thread.

The server picking up the setting has not been checked: the server's own debug log should say `SSH thread count is N` (set `LogLevel DEBUG1` in `build/perf/sshd_hpn.conf` after `setup`, and look in `sshd_hpn.log`).

### Loss and jitter

A condition may end in `_lossPERCENT` and `_jitMS`. Both are applied by `netem` in each direction of the link, so `wan50_loss0.5` loses 0.5 percent of packets each way. Jitter is a random variation of each packet's delay of up to that many ms, and it needs a delay, so it works with `wanNN` and not `lan`. `netem` can reorder packets when the delay varies, as a real path does, and TCP treats that like loss. A transfer under loss is much slower than a clean one, so give such conditions a smaller size with `--mb`, for example `--mb wan50_loss0.5=64`; each run is stopped after 15 minutes and recorded as failed.

```sh
tools/perf/perf.sh run --conds wan50,wan50_loss0.1,wan50_loss0.5,wan50_jit10 \
    --mb wan50_loss0.1=128,wan50_loss0.5=64,wan50_jit10=256 --ciphers default,aes256-ctr
```

## How a run works

Each `ssh` run sends data from `/dev/zero` with `dd if=/dev/zero | ssh host 'cat > /dev/null'` and times the whole pipeline. It also times `ssh host true` to measure the time to connect, which is subtracted, so the figure is the steady transfer rate. There is no compression, and the data goes in one direction over one connection. Within each run the pairings take turns, so a change in the machine affects them alike.

The CSV has the columns `impl,cipher,cond,run,mb,elapsed,user,sys,tool,server,threads`. `analyze` also reads the older files that stop at `sys`.

## Limits

The scp, sftp, mixed pair, thread count, loss and jitter options were written on a machine without Linux, so they have been tested only with `--dry-run` and `analyze`, never run. Expect to find problems on the first real run. Loss and jitter are applied in each direction, so the round trip sees about twice the figure. There is one connection and one direction. The CPU figures include the `dd` that feeds the pipe, which is small. CPU use varies a little between runs, so read the CPU range that `analyze` prints as well as the median.
