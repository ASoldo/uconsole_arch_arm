# uConsole Arch Linux ARM

Unofficial, reproducible Arch Linux ARM setup for the ClockworkPi uConsole. The goal is to take the official Arch Linux ARM Raspberry Pi aarch64 root filesystem, add the ClockworkPi/uConsole boot and support files, and configure the result with Ansible so the final card boots into a usable uConsole system.

This is not an official ClockworkPi, Arch Linux, or Arch Linux ARM image. The scripts are destructive when pointed at a disk. Read them before running them.

## What This Builds

The recommended path is `prepare-arch-uconsole-btrfs-sd.sh`. It creates:

- A bootable uConsole microSD from the Arch Linux ARM Raspberry Pi aarch64 rootfs.
- A FAT32 boot partition labeled `ALARMBOOT`.
- A Btrfs root partition labeled `ALARMROOT` with `@`, `@home`, and `@snapshots`.
- uConsole vendor firmware, overlays, and kernel modules from the ClockworkPi image.
- ClockworkPi support files for audio, shutdown audio cleanup, backlight, charging rules, and CM4 4G power control.
- A configured Arch Linux ARM userspace managed by Ansible.

The Ansible playbook installs and configures:

- NetworkManager, ModemManager, OpenSSH, LightDM, i3, Rofi, Alacritty, and bumblebee-status.
- A configurable first user, defaulting to `uconsole`.
- zsh as the first user's login shell.
- Oh My Zsh in the first user's home with `ZSH_THEME="agnoster"`.
- An i3 session with uConsole display rotation and a bumblebee-status `powerline` bar.
- The ClockworkPi audio services and uConsole 4G service when the support files are present.

There is also an older ext4 writer, `prepare-arch-uconsole-sd.sh`. Use the Btrfs writer unless you specifically want ext4.

## Repository Layout

```text
.
├── ansible/
│   ├── playbooks/uconsole-rootfs.yml
│   ├── roles/uconsole_rootfs/
│   └── vault/uconsole-secrets.example.yml
├── scripts/test-ansible.sh
├── prepare-arch-uconsole-btrfs-sd.sh
├── prepare-arch-uconsole-sd.sh
├── finish-uconsole-target.sh
├── cache/
└── backups/clockworkpi-20260430/
```

`cache/`, `backups/`, `work/`, and local Vault files are ignored by git. The repo should contain automation and documentation, not downloaded root filesystems, vendor archives, or secrets.

## Host Requirements

Use a Linux host. On Arch Linux:

```sh
sudo pacman -S --needed \
  ansible ansible-core yamllint \
  arch-install-scripts dosfstools btrfs-progs libarchive util-linux \
  qemu-user-static qemu-user-static-binfmt
sudo systemctl restart systemd-binfmt
```

The setup uses only `ansible-core` modules and normal host commands. It does not require a Galaxy collection. The playbook is host-side: it configures a mounted ARM rootfs through `arch-chroot`, with `qemu-aarch64-static` copied into the target rootfs by the script.

## Prepare Inputs

Download the Arch Linux ARM Raspberry Pi aarch64 root filesystem:

```sh
mkdir -p cache backups/clockworkpi-20260430
curl -L -o cache/ArchLinuxARM-rpi-aarch64-latest.tar.gz \
  http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz
curl -L -o cache/ArchLinuxARM-rpi-aarch64-latest.tar.gz.md5 \
  http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz.md5
curl -L -o cache/ArchLinuxARM-rpi-aarch64-latest.tar.gz.sig \
  http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz.sig
```

Verify the download if your Arch Linux ARM key trust is configured:

```sh
md5sum -c cache/ArchLinuxARM-rpi-aarch64-latest.tar.gz.md5
gpg --verify cache/ArchLinuxARM-rpi-aarch64-latest.tar.gz.sig \
  cache/ArchLinuxARM-rpi-aarch64-latest.tar.gz
```

Create the ClockworkPi support archive from a mounted stock uConsole image. From the root of that filesystem:

```sh
sudo tar -czf /tmp/clockworkpi-current-support-files.tar.gz \
  boot/firmware/config.txt \
  boot/firmware/cmdline.txt \
  boot/firmware/overlays/clockworkpi-uconsole.dtbo \
  boot/firmware/overlays/clockworkpi-uconsole-cm3.dtbo \
  boot/firmware/overlays/clockworkpi-uconsole-cm5.dtbo \
  boot/firmware/overlays/clockworkpi-devterm.dtbo \
  boot/firmware/overlays/clockworkpi-devterm-cm5.dtbo \
  boot/firmware/overlays/clockworkpi-custom-battery.dtbo \
  etc/systemd/system/clockworkpi-audio-patch.service \
  etc/systemd/system/clockworkpi-audio-shutdown.service \
  etc/systemd/system/uconsole-4g-cm4.service \
  etc/udev/rules.d/100-backlight.rules \
  etc/udev/rules.d/99-uconsole-charging.rules \
  usr/local/bin/audio_3.5_patch.py \
  usr/local/bin/clockworkpi-audio-shutdown.sh \
  usr/local/bin/rpi-backlight \
  usr/local/bin/rpi-backlight-check \
  usr/local/bin/uconsole-4g-cm4
```

Create the vendor boot/kernel archive. The current scripts expect `lib/modules/6.12.62-v8+`:

```sh
sudo tar -czf /tmp/uconsole-vendor-boot-kernel.tar.gz \
  boot/firmware \
  lib/modules/6.12.62-v8+
```

Copy both archives into place:

```sh
cp /tmp/clockworkpi-current-support-files.tar.gz backups/clockworkpi-20260430/
cp /tmp/uconsole-vendor-boot-kernel.tar.gz backups/clockworkpi-20260430/
```

You can override paths with `TARBALL=`, `SUPPORT_TAR=`, and `VENDOR_BOOT_TAR=`.

## Manage Secrets With Ansible Vault

Do not put passwords in git or shell history. Use Ansible Vault for the first user and password:

```sh
cp ansible/vault/uconsole-secrets.example.yml ansible/vault/uconsole-secrets.yml
vim ansible/vault/uconsole-secrets.yml
ansible-vault encrypt ansible/vault/uconsole-secrets.yml
```

The file should define:

```yaml
uconsole_user: youruser
uconsole_password: your-temporary-first-boot-password
```

Useful Vault commands:

```sh
ansible-vault view ansible/vault/uconsole-secrets.yml
ansible-vault edit ansible/vault/uconsole-secrets.yml
ansible-vault decrypt ansible/vault/uconsole-secrets.yml
ansible-vault encrypt ansible/vault/uconsole-secrets.yml
```

For unattended runs, store the Vault password outside the repo and pass it with `ANSIBLE_VAULT_PASSWORD_FILE=/path/to/vault-pass`. If you omit `ANSIBLE_VAULT_PASSWORD_FILE`, the prep script will ask for the Vault password.

## Test Before Writing a Card

Run the Ansible test gate:

```sh
scripts/test-ansible.sh
```

This performs:

- `ansible-playbook --syntax-check`
- `yamllint ansible`
- A qemu `aarch64` smoke check from the cached Arch Linux ARM tarball when the tarball is present
- An Ansible fixture run against a temporary fake rootfs under `work/`
- A temporary encrypted Ansible Vault vars file to prove encrypted secrets are ingested correctly
- Assertions that generated hostname, console, mkinitcpio, zsh, i3, and helper files are present

The test does not touch a real uConsole or any Tailscale device.

## Write the microSD

Find the correct disk. Use the disk path, not a partition path:

```sh
lsblk -o NAME,PATH,SIZE,TYPE,TRAN,MODEL,FSTYPE,LABEL,MOUNTPOINTS,RM,RO
```

Unmount anything mounted from the card:

```sh
sudo umount /dev/sdX1 /dev/sdX2 2>/dev/null || true
```

Run the Btrfs writer with your encrypted Vault file:

```sh
sudo -E env \
  ANSIBLE_VAULT_FILE="$PWD/ansible/vault/uconsole-secrets.yml" \
  ANSIBLE_VAULT_PASSWORD_FILE="/secure/path/uconsole-vault-pass" \
  I_UNDERSTAND_THIS_WIPES=YES \
  ./prepare-arch-uconsole-btrfs-sd.sh /dev/sdX
```

If you want an interactive Vault prompt, omit `ANSIBLE_VAULT_PASSWORD_FILE`:

```sh
sudo -E env \
  ANSIBLE_VAULT_FILE="$PWD/ansible/vault/uconsole-secrets.yml" \
  I_UNDERSTAND_THIS_WIPES=YES \
  ./prepare-arch-uconsole-btrfs-sd.sh /dev/sdX
```

Replace `/dev/sdX` with the actual removable disk. The script refuses NVMe devices and refuses non-removable disks unless `ALLOW_NON_REMOVABLE=1` is explicitly set.

The legacy environment fallback still exists for quick local experiments:

```sh
sudo -E env \
  UCONSOLE_USER='uconsole' \
  UCONSOLE_PASSWORD='change-this-password' \
  I_UNDERSTAND_THIS_WIPES=YES \
  ./prepare-arch-uconsole-btrfs-sd.sh /dev/sdX
```

Prefer Ansible Vault for any real setup.

## Run Only the Playbook

If you already have an extracted and mounted rootfs, run the playbook directly:

```sh
ansible-playbook ansible/playbooks/uconsole-rootfs.yml \
  --vault-password-file /secure/path/uconsole-vault-pass \
  -e @ansible/vault/uconsole-secrets.yml \
  -e target_root=/mnt/uconsole-arch-root \
  -e uconsole_rootfs_type=btrfs
```

For non-mutating template/render checks against a fixture:

```sh
ansible-playbook ansible/playbooks/uconsole-rootfs.yml \
  --vault-password-file /secure/path/uconsole-vault-pass \
  -e @ansible/vault/uconsole-secrets.yml \
  -e target_root=/path/to/rootfs-fixture \
  -e uconsole_rootfs_type=btrfs \
  -e uconsole_run_chroot_commands=false
```

## First Boot Checks

After booting the uConsole:

```sh
passwd
systemctl status NetworkManager ModemManager uconsole-4g-cm4
mmcli -L
ip addr
rpi-backlight-check
```

Expected defaults:

- Hostname: `arch-uconsole`
- User: value of `uconsole_user` from Vault, or `uconsole`
- Shell: zsh with Oh My Zsh and `ZSH_THEME="agnoster"`
- Desktop: LightDM into i3
- Terminal launcher: Alacritty
- App launcher: Rofi
- Status bar: bumblebee-status with its built-in `powerline` theme
- Network: NetworkManager
- 4G: ModemManager plus `uconsole-4g-cm4.service`

If the modem does not appear:

```sh
sudo systemctl restart uconsole-4g-cm4
journalctl -u uconsole-4g-cm4 -b
mmcli -L
```

## What the Disk Script Does

The Btrfs writer:

1. Refuses ambiguous or dangerous targets.
2. Wipes and partitions the selected disk.
3. Formats boot as FAT32 and root as Btrfs.
4. Creates Btrfs subvolumes.
5. Extracts the Arch Linux ARM rootfs.
6. Copies uConsole vendor boot firmware and kernel modules.
7. Copies ClockworkPi support files.
8. Writes `cmdline.txt`, `fstab`, and base boot configuration.
9. Mounts the target rootfs for chroot operation.
10. Calls `ansible-playbook` to configure userspace, packages, user shell, desktop, initramfs, and services.

## Notes for Maintainers

- Keep secrets in Ansible Vault, not in git.
- Keep downloaded ALARM and vendor artifacts out of git.
- Prefer editing the Ansible role over adding more inline shell to the disk writers.
- The live reference setup was checked on `archiechokie`, but this repo must not require access to that device.
- Official Ansible references used for this structure: `ansible-playbook --syntax-check`, check/diff mode, and `ansible.builtin.copy`/template behavior.
