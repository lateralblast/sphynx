# sphynx

Version: 0.1.2

Sphynx is a wrapper that builds HPN-SSH from source and packages it for target operating systems. The first target is Ubuntu (`.deb`).

## Contents

- [Quick start](#quick-start)
- [Command reference](#command-reference)
- [Output](#output)
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

On Ubuntu 26.04 this produces `dist/hpn-ssh_10.6p1+hpn18.12.0+sphynx0.1.2-1~resolute1_amd64.deb`.

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
OpenSSH_10.6p1_hpn18.12.0_sphynx0.1.2
```

- `OpenSSH_10.6p1` is the OpenSSH base in `sphynx-ssh/version.h`.
- `_hpn18.12.0` is the HPN-SSH release.
- `_sphynx0.1.2` is the sphynx version. It is `SSH_SPHYNX` in `sphynx-ssh/version.h`.

`hpnssh -V` and `hpnsshd -V` print the full string, and the SSH banner sent to peers contains it. `sphynx build` stops with an error if `SSH_SPHYNX` does not match the sphynx version, so the two cannot drift apart. When you bump the sphynx version, update `sphynx`, `README.md`, `CHANGELOG.md` and `sphynx-ssh/version.h` together.

The package installs alongside OpenSSH:

- Programs are named `hpnssh`, `hpnscp`, `hpnsftp`, `hpnssh-keygen` and so on, and `hpnsshd` is the server.
- Configuration is in `/etc/hpnssh/`.
- The server runs as the `hpnsshd` systemd service and listens on port 2222 by default.

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
- **Conffiles:** `/etc/hpnssh/ssh_config`, `/etc/hpnssh/sshd_config`, `/etc/hpnssh/moduli` and `/etc/pam.d/hpnsshd`.
- **PAM:** the server uses the `hpnsshd` PAM service, which ships as `/etc/pam.d/hpnsshd`. It is adapted from Ubuntu's `sshd` configuration.

## Tests

```sh
tests/run-tests.sh
SPHYNX_SKIP_BUILD=1 tests/run-tests.sh   # skip the end-to-end build
```

The tests check that the version matches in `sphynx`, `README.md` and `CHANGELOG.md`, check the command line, run shellcheck, and build a package and inspect its metadata and contents.

## Layout

```
sphynx                      wrapper script
packaging/ubuntu/           control template, maintainer scripts, systemd unit, PAM file, conffiles
tests/run-tests.sh          test suite
sphynx-ssh/                HPN-SSH fork used as the source (separate git repo, not tracked by sphynx)
hpn-ssh/                    HPN-SSH clone (separate git repo, not used by default)
openssh-portable/           upstream OpenSSH source (separate git repo, not tracked by sphynx)
build/                      scratch build output (generated)
dist/                       finished packages (generated)
```
