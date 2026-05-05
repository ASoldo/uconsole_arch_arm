#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'error: missing required command: %s\n' "$1" >&2
    exit 1
  }
}

need ansible-playbook
need ansible-vault
need yamllint

ansible-playbook --syntax-check ansible/playbooks/uconsole-rootfs.yml
yamllint ansible

mkdir -p "$BASE_DIR/work"
fixture="$(mktemp -d "$BASE_DIR/work/ansible-fixture.XXXXXX")"
arm_smoke="$(mktemp -d "$BASE_DIR/work/arm-rootfs-smoke.XXXXXX")"
vault_pass="$(mktemp "$BASE_DIR/work/ansible-vault-pass.XXXXXX")"
vault_vars="$(mktemp "$BASE_DIR/work/ansible-vault-vars.XXXXXX.yml")"
cleanup() {
  rm -rf "$fixture"
  rm -rf "$arm_smoke"
  rm -f "$vault_pass" "$vault_vars"
}
trap cleanup EXIT

tarball="$BASE_DIR/cache/ArchLinuxARM-rpi-aarch64-latest.tar.gz"
if [[ -s "$tarball" ]] && command -v qemu-aarch64-static >/dev/null 2>&1; then
  bsdtar --no-same-owner \
    --exclude './dev/*' \
    --exclude 'dev/*' \
    -xf "$tarball" \
    -C "$arm_smoke" \
    usr/bin/uname usr/bin/bash lib usr/lib
  arch="$(qemu-aarch64-static -L "$arm_smoke" "$arm_smoke/usr/bin/uname" -m)"
  test "$arch" = aarch64
  printf 'qemu aarch64 smoke test passed\n'
fi

mkdir -p \
  "$fixture/etc/systemd/system" \
  "$fixture/usr/bin" \
  "$fixture/usr/local/sbin" \
  "$fixture/home" \
  "$fixture/boot"
cat > "$fixture/etc/pacman.conf" <<'PACMAN'
[options]
Architecture = aarch64
PACMAN
touch "$fixture/etc/systemd/system/uconsole-4g-cm4.service"

printf 'fixture-vault-pass\n' > "$vault_pass"
chmod 600 "$vault_pass"
cat > "$vault_vars" <<'VAULTVARS'
---
uconsole_user: demo
uconsole_password: test-password
VAULTVARS
ansible-vault encrypt --vault-password-file "$vault_pass" "$vault_vars" >/dev/null

ansible-playbook ansible/playbooks/uconsole-rootfs.yml \
  --vault-password-file "$vault_pass" \
  -e "@$vault_vars" \
  -e "target_root=$fixture" \
  -e uconsole_run_chroot_commands=false \
  -e uconsole_rootfs_type=btrfs

test -f "$fixture/etc/hostname"
test -f "$fixture/etc/vconsole.conf"
test -f "$fixture/etc/mkinitcpio-uconsole.conf"
test -x "$fixture/usr/local/sbin/uconsole-configure-user"
test -f "$fixture/home/demo/.zshrc"
test -f "$fixture/home/demo/.config/i3/config"
grep -q 'ZSH_THEME="agnoster"' "$fixture/home/demo/.zshrc"
grep -q 'bumblebee-status' "$fixture/home/demo/.config/i3/config"
grep -q 'DisableSandbox' "$fixture/etc/pacman.conf"

printf 'ansible fixture test passed\n'
