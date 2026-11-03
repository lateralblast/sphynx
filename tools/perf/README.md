# tools/perf

Compare the throughput of OpenSSH and HPN-SSH over an emulated network. The results in the main README's [Performance](../../README.md#performance) section came from this tool.

It builds two Linux network namespaces joined by a virtual link, adds delay and a rate limit to the link with `tc netem`, runs an OpenSSH server and an HPN-SSH server in one namespace, and times a transfer to each from the other.

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
| `--conds LIST` | `lan,wan50,wan100` | Comma list of conditions. `lan` has no shaping. `wanNN` is an NN ms round trip, half in each direction. |
| `--ciphers LIST` | `default`, `chacha20-poly1305@openssh.com`, `aes256-ctr`, `aes256-gcm@openssh.com` | Comma list. `default` is each side's own default cipher. |
| `--runs N` | 3 | Runs per case. The two implementations alternate within each run. |
| `--mb LIST` | `lan=2048,wan50=512,wan100=384` | Data size in MB, as `cond=MB` pairs. Any other `wanNN` uses 512. |
| `--wmem "A B C"` | the host's value | Set `net.ipv4.tcp_wmem` inside the namespaces. |
| `--rmem "A B C"` | the host's value | Set `net.ipv4.tcp_rmem` inside the namespaces. |
| `--out FILE` | `build/perf/results.csv` | Where to write the CSV. |

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

## How a run works

Each run sends data from `/dev/zero` with `dd if=/dev/zero | ssh host 'cat > /dev/null'` and times the whole pipeline. It also times `ssh host true` to measure the time to connect, which is subtracted, so the figure is the steady transfer rate. There is no compression, and the data goes in one direction over one connection.

## Limits

This measures the effect of delay, rate and buffer limits on an otherwise clean path. It does not cover packet loss or jitter, scp or sftp, an HPN-SSH client against an OpenSSH server or the reverse, or different numbers of cipher threads. The CPU figures include the `dd` that feeds the pipe, which is small. CPU use varies a little between runs, so read the CPU range that `analyze` prints as well as the median.
