#!/usr/bin/env bash
# Tests the .deb's install, upgrade, remove, reinstall and purge on a clean Ubuntu
# machine with systemd, including the hpnsshd user, host key generation, the
# service and a login on port 2222.
#
# usage: tests/package-lifecycle.sh path/to/hpn-ssh.deb
#
# It changes the machine it runs on: it installs and purges the package, adds a key to
# ~/.ssh/authorized_keys. It logs in as the current user with a key, so if that user's
# password is locked (the default on cloud images) it also tests that case. Run it
# only in a throwaway VM or container with systemd, never on a machine you use, so
# it is not part of tests/run-tests.sh. A machine of the right kind:
#   orb create ubuntu:resolute sphynx-clean    (OrbStack)
#   orb -m sphynx-clean tests/package-lifecycle.sh dist/hpn-ssh_*.deb
# The messages are one "ok" or "FAIL" line per check, and it exits non-zero on a failure.
# shellcheck disable=SC1091,SC2015,SC2016,SC2024
set -u
DEB="$(readlink -f "$1")"
W="$(mktemp -d)"
export DEBIAN_FRONTEND=noninteractive
pass=0; failed=0
ok()   { echo "ok   - $1"; pass=$((pass+1)); }
bad()  { echo "FAIL - $1"; failed=$((failed+1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
nocheck() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
fp() { for k in rsa ecdsa ed25519; do sudo sha256sum "/etc/hpnssh/ssh_host_${k}_key.pub"; done; }
listening() { ss -ltn 2>/dev/null | grep -q ':2222 '; }
state() { dpkg-query -W -f='${db:Status-Abbrev}' hpn-ssh 2>/dev/null; }
login() { hpnssh -p 2222 -i "$W/id" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR localhost 'echo logged-in-as-$(id -un)' 2>&1; }

echo "== $(. /etc/os-release; echo "$PRETTY_NAME") $(uname -m), systemd: $(systemctl is-system-running)"
ssh-keygen -q -t ed25519 -N '' -f "$W/id"
mkdir -p ~/.ssh; chmod 700 ~/.ssh; cat "$W/id.pub" >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys

echo; echo "== 0. clean machine"
nocheck "no hpn-ssh package"        dpkg -s hpn-ssh
nocheck "no hpnsshd user"           getent passwd hpnsshd
nocheck "no /etc/hpnssh"            test -e /etc/hpnssh
nocheck "nothing on port 2222"      listening

echo; echo "== 1. install"
if sudo apt-get install -y -qq "$DEB" >"$W/install.log" 2>&1; then ok "apt install succeeds"; else bad "apt install failed"; tail -20 "$W/install.log"; fi
[ "$(state)" = "ii " ] && ok "package state is ii" || bad "package state is '$(state)'"
check "hpnsshd user exists"        getent passwd hpnsshd
[ "$(getent passwd hpnsshd | cut -d: -f7)" = /usr/sbin/nologin ] && ok "hpnsshd has nologin shell" || bad "hpnsshd shell is $(getent passwd hpnsshd | cut -d: -f7)"
for k in rsa ecdsa ed25519; do
  check "host key $k and its .pub exist" sudo test -f /etc/hpnssh/ssh_host_${k}_key -a -f /etc/hpnssh/ssh_host_${k}_key.pub
  [ "$(sudo stat -c '%a %U' /etc/hpnssh/ssh_host_${k}_key)" = "600 root" ] && ok "host key $k is 600 root" || bad "host key $k is $(sudo stat -c '%a %U' /etc/hpnssh/ssh_host_${k}_key)"
done
check "keys are valid"             sudo hpnssh-keygen -l -f /etc/hpnssh/ssh_host_ed25519_key.pub
check "hpnsshd -t passes"          sudo hpnsshd -t
check "service is enabled"         systemctl is-enabled hpnsshd
check "service is active"          systemctl is-active hpnsshd
sleep 1
check "listening on 2222"          listening
check "hpnssh -V reports sphynx"   bash -c "hpnssh -V 2>&1 | grep -q _sphynx"
out="$(login)"; [[ "$out" == logged-in-as-* ]] && ok "hpnssh login to port 2222 works ($out)" || bad "login failed: $out"
case "$(sudo passwd -S "$(id -un)" | awk '{print $2}')" in
    L) echo "   (this user's password is locked, so the login above is the locked-account case)" ;;
    *) echo "   (this user's password is not locked, so the locked-account case was not tested)" ;;
esac
check "UsePAM yes is set in the packaged sshd_config" grep -q '^UsePAM yes$' /etc/hpnssh/sshd_config
check "OpenSSH's own ssh untouched" test -x /usr/bin/ssh -o ! -e /usr/bin/hpnssh-sshd
fp > "$W/fp1"; PID1="$(systemctl show -p MainPID --value hpnsshd)"
echo "   host key fingerprints (sha256 of .pub):"; sed 's/^/   /' "$W/fp1"

echo; echo "== 2. upgrade (same files, higher version, plus a marker file)"
OLDV="$(dpkg-query -W -f='${Version}' hpn-ssh)"
mkdir "$W/up" && dpkg-deb -R "$DEB" "$W/up"
sed -i "s/^Version: .*/Version: ${OLDV}.1/" "$W/up/DEBIAN/control"
echo upgraded > "$W/up/usr/share/doc/hpn-ssh/UPGRADE_MARKER"
dpkg-deb -b "$W/up" "$W/hpn-ssh-up.deb" >/dev/null
echo "# local edit survives upgrade" | sudo tee -a /etc/hpnssh/sshd_config >/dev/null
if sudo apt-get install -y -qq "$W/hpn-ssh-up.deb" >"$W/upgrade.log" 2>&1; then ok "apt upgrade succeeds"; else bad "apt upgrade failed"; tail -20 "$W/upgrade.log"; fi
[ "$(dpkg-query -W -f='${Version}' hpn-ssh)" = "${OLDV}.1" ] && ok "version is now ${OLDV}.1" || bad "version is $(dpkg-query -W -f='${Version}' hpn-ssh)"
check "new file from the new package is present" test -f /usr/share/doc/hpn-ssh/UPGRADE_MARKER
check "edited sshd_config is kept"  grep -q 'local edit survives upgrade' /etc/hpnssh/sshd_config
fp > "$W/fp2"; cmp -s "$W/fp1" "$W/fp2" && ok "host keys unchanged by upgrade" || bad "host keys changed by upgrade"
check "service is active after upgrade" systemctl is-active hpnsshd
PID2="$(systemctl show -p MainPID --value hpnsshd)"
[ -n "$PID2" ] && [ "$PID2" != "$PID1" ] && ok "service was restarted (pid $PID1 -> $PID2)" || bad "service was not restarted (pid $PID1 -> $PID2)"
out="$(login)"; [[ "$out" == logged-in-as-* ]] && ok "login works after upgrade" || bad "login after upgrade: $out"
echo "   upgrade with the service disabled stays disabled:"
sudo systemctl disable --now hpnsshd >/dev/null 2>&1
sed -i "s/^Version: .*/Version: ${OLDV}.2/" "$W/up/DEBIAN/control"; dpkg-deb -b "$W/up" "$W/hpn-ssh-up2.deb" >/dev/null
sudo apt-get install -y -qq "$W/hpn-ssh-up2.deb" >"$W/upgrade2.log" 2>&1 && ok "second upgrade succeeds" || { bad "second upgrade failed"; tail -10 "$W/upgrade2.log"; }
nocheck "disabled service stays disabled" systemctl is-enabled hpnsshd
nocheck "disabled service stays stopped"  systemctl is-active hpnsshd
sudo systemctl enable --now hpnsshd >/dev/null 2>&1; sleep 1
check "re-enabled service is active" systemctl is-active hpnsshd

echo; echo "== 3. remove"
sudo apt-get remove -y -qq hpn-ssh >"$W/remove.log" 2>&1 && ok "apt remove succeeds" || { bad "apt remove failed"; tail -10 "$W/remove.log"; }
[ "$(state)" = "rc " ] && ok "package state is rc (config kept)" || bad "package state is '$(state)'"
nocheck "service stopped"          systemctl is-active hpnsshd
nocheck "port 2222 closed"         listening
nocheck "hpnssh binary removed"    test -e /usr/bin/hpnssh
nocheck "hpnsshd binary removed"   test -e /usr/sbin/hpnsshd
nocheck "unit file removed"        test -e /lib/systemd/system/hpnsshd.service
check "sshd_config kept"           test -f /etc/hpnssh/sshd_config
check "host keys kept"             sudo test -f /etc/hpnssh/ssh_host_ed25519_key
check "hpnsshd user kept"          getent passwd hpnsshd

echo; echo "== 4. reinstall after remove"
sudo apt-get install -y -qq "$DEB" >"$W/reinstall.log" 2>&1 && ok "apt install after remove succeeds" || { bad "reinstall failed"; tail -10 "$W/reinstall.log"; }
fp > "$W/fp3"; cmp -s "$W/fp1" "$W/fp3" && ok "the old host keys are reused, not regenerated" || bad "host keys changed on reinstall"
check "edited sshd_config still there" grep -q 'local edit survives upgrade' /etc/hpnssh/sshd_config
sleep 1; check "service is active"  systemctl is-active hpnsshd
out="$(login)"; [[ "$out" == logged-in-as-* ]] && ok "login works again" || bad "login after reinstall: $out"

echo; echo "== 5. purge"
sudo apt-get purge -y -qq hpn-ssh >"$W/purge.log" 2>&1 && ok "apt purge succeeds" || { bad "apt purge failed"; tail -10 "$W/purge.log"; }
nocheck "package is gone from dpkg"  dpkg -s hpn-ssh
nocheck "/etc/hpnssh removed"        test -e /etc/hpnssh
nocheck "no host keys left"          bash -c 'ls /etc/hpnssh/ssh_host_* 2>/dev/null | grep -q .'
nocheck "hpnsshd user removed"       getent passwd hpnsshd
nocheck "hpnsshd group removed"      getent group hpnsshd
nocheck "/etc/pam.d/hpnsshd removed" test -e /etc/pam.d/hpnsshd
nocheck "unit file removed"          test -e /lib/systemd/system/hpnsshd.service
nocheck "no leftover unit state"     bash -c 'systemctl list-unit-files 2>/dev/null | grep -q hpnsshd'
nocheck "/usr/lib/hpnssh removed"    test -e /usr/lib/hpnssh
nocheck "/run/hpnsshd removed"       test -e /run/hpnsshd
nocheck "port 2222 closed"           listening
check "OpenSSH's /etc/ssh untouched" test -f /etc/ssh/ssh_config

echo; echo "== 6. install, then purge directly (no remove first)"
sudo apt-get install -y -qq "$DEB" >"$W/i2.log" 2>&1 && ok "fresh install after purge" || { bad "install after purge failed"; tail -10 "$W/i2.log"; }
fp > "$W/fp4"; cmp -s "$W/fp1" "$W/fp4" && bad "a purge kept the old host keys" || ok "fresh host keys were generated after a purge"
sleep 1; check "service is active"   systemctl is-active hpnsshd
sudo apt-get purge -y -qq hpn-ssh >"$W/p2.log" 2>&1 && ok "purge of an installed package succeeds" || { bad "direct purge failed"; tail -10 "$W/p2.log"; }
nocheck "/etc/hpnssh removed"        test -e /etc/hpnssh
nocheck "hpnsshd user removed"       getent passwd hpnsshd
nocheck "service stopped"            systemctl is-active hpnsshd
nocheck "port 2222 closed"           listening

echo; echo "$pass passed, $failed failed"
rm -rf "$W"
[ "$failed" -eq 0 ]
