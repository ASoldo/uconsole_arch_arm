# uConsole Arch Linux ARM

Unofficial Arch Linux ARM setup for ClockworkPi uConsole. This repo documents the process we used to turn the stock uConsole support files plus the Arch Linux ARM Raspberry Pi root filesystem into an Arch-powered uConsole with display, keyboard, audio, backlight, charging rules, NetworkManager, and the CM4 4G module helper enabled.

This is not an official ClockworkPi, Arch Linux, or Arch Linux ARM image. Treat it as a reproducible field guide and inspect the scripts before writing any storage device.

## What This Builds

The recommended path is `prepare-arch-uconsole-btrfs-sd.sh`. It creates:

- A bootable microSD for uConsole using the Arch Linux ARM Raspberry Pi aarch64 root filesystem.
- A FAT32 boot partition labeled `ALARMBOOT`.
- A Btrfs root partition labeled `ALARMROOT` with `@`, `@home`, and `@snapshots` subvolumes.
- uConsole vendor boot firmware and kernel modules from the ClockworkPi image.
- ClockworkPi support files for audio, shutdown audio cleanup, backlight, charging, and 4G module power control.
- A small i3 desktop with LightDM, Alacritty, Rofi, NetworkManager, SSH, ModemManager, and a configurable normal user.

There is also an older ext4 script, `prepare-arch-uconsole-sd.sh`, kept for reference. Use the Btrfs script unless you specifically want ext4.

## Hardware Target

This was built for a ClockworkPi uConsole Raspberry Pi CM4-style setup with the 4G module. The support archive we used contains ClockworkPi uConsole overlays and a `uconsole-4g-cm4` systemd service. CM5 may need adjusted firmware, overlays, or kernel modules.

## Host Requirements

Use a Linux host. The commands below assume Arch Linux on the host:

```sh
sudo pacman -S --needed arch-install-scripts dosfstools btrfs-progs libarchive util-linux qemu-user-static qemu-user-static-binfmt
sudo systemctl restart systemd-binfmt
```

You also need:

- A microSD card or other removable target device.
- The Arch Linux ARM Raspberry Pi aarch64 root filesystem tarball.
- A ClockworkPi/uConsole vendor firmware and kernel-module archive.
- A small ClockworkPi support-file archive.

The scripts are intentionally destructive and refuse to run unless you pass an explicit wipe confirmation.

## Repository Layout

```text
.
├── prepare-arch-uconsole-btrfs-sd.sh   # recommended full image builder
├── prepare-arch-uconsole-sd.sh         # older ext4 image builder
├── finish-uconsole-target.sh           # legacy on-target finishing helper
├── cache/                              # local ALARM tarball goes here
└── backups/clockworkpi-20260430/       # local ClockworkPi support archives go here
```

The `cache/` and `backups/` contents are ignored by git because they are large upstream/vendor artifacts.

## Prepare the Inputs

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

Verify the download if you have the Arch Linux ARM keyring/trust path configured:

```sh
md5sum -c cache/ArchLinuxARM-rpi-aarch64-latest.tar.gz.md5
gpg --verify cache/ArchLinuxARM-rpi-aarch64-latest.tar.gz.sig cache/ArchLinuxARM-rpi-aarch64-latest.tar.gz
```

Create the ClockworkPi support archives from a working stock uConsole image or a mounted copy of one. From the root of that filesystem, the support archive should contain these paths:

```text
boot/firmware/config.txt
boot/firmware/cmdline.txt
boot/firmware/overlays/clockworkpi-uconsole.dtbo
boot/firmware/overlays/clockworkpi-uconsole-cm3.dtbo
boot/firmware/overlays/clockworkpi-uconsole-cm5.dtbo
boot/firmware/overlays/clockworkpi-devterm.dtbo
boot/firmware/overlays/clockworkpi-devterm-cm5.dtbo
boot/firmware/overlays/clockworkpi-custom-battery.dtbo
etc/systemd/system/clockworkpi-audio-patch.service
etc/systemd/system/clockworkpi-audio-shutdown.service
etc/systemd/system/uconsole-4g-cm4.service
etc/udev/rules.d/100-backlight.rules
etc/udev/rules.d/99-uconsole-charging.rules
usr/local/bin/audio_3.5_patch.py
usr/local/bin/clockworkpi-audio-shutdown.sh
usr/local/bin/rpi-backlight
usr/local/bin/rpi-backlight-check
usr/local/bin/uconsole-4g-cm4
```

Example command from inside the mounted stock root filesystem:

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

The vendor boot/kernel archive should contain the vendor boot firmware and the matching kernel modules. The script currently expects the module directory `lib/modules/6.12.62-v8+`:

```sh
sudo tar -czf /tmp/uconsole-vendor-boot-kernel.tar.gz \
  boot/firmware \
  lib/modules/6.12.62-v8+
```

Copy both archives into the expected local paths:

```sh
cp /tmp/clockworkpi-current-support-files.tar.gz backups/clockworkpi-20260430/
cp /tmp/uconsole-vendor-boot-kernel.tar.gz backups/clockworkpi-20260430/
```

You can use different paths by setting `TARBALL=`, `SUPPORT_TAR=`, and `VENDOR_BOOT_TAR=` when running the prep script.

## Write the microSD

Find the correct target disk. Use the disk path, not a partition path:

```sh
lsblk -o NAME,PATH,SIZE,TYPE,TRAN,MODEL,FSTYPE,LABEL,MOUNTPOINTS,RM,RO
```

Unmount anything mounted from the card:

```sh
sudo umount /dev/sdX1 /dev/sdX2 2>/dev/null || true
```

Run the Btrfs builder:

```sh
sudo -E env \
  UCONSOLE_PASSWORD='change-this-password' \
  UCONSOLE_USER='uconsole' \
  I_UNDERSTAND_THIS_WIPES=YES \
  ./prepare-arch-uconsole-btrfs-sd.sh /dev/sdX
```

Replace `/dev/sdX` with the actual removable disk. The script refuses NVMe devices and refuses non-removable disks unless `ALLOW_NON_REMOVABLE=1` is explicitly set.

`UCONSOLE_USER` is optional and defaults to `uconsole`. The password is applied to both `root` and that normal user. Change both passwords on first boot:

```sh
passwd
passwd uconsole
```

## First Boot

Insert the card into the uConsole and boot. Expected defaults:

- Hostname: `arch-uconsole`
- User: `uconsole` by default, or whatever you set with `UCONSOLE_USER`
- Desktop: LightDM into i3
- Terminal: Alacritty
- SSH: enabled
- Networking: NetworkManager enabled
- 4G management: ModemManager and `uconsole-4g-cm4.service` enabled

Useful checks on the uConsole:

```sh
systemctl status NetworkManager ModemManager uconsole-4g-cm4
mmcli -L
ip addr
rpi-backlight-check
```

If the 4G modem does not appear, check the power helper and logs:

```sh
sudo systemctl restart uconsole-4g-cm4
journalctl -u uconsole-4g-cm4 -b
mmcli -L
```

## What the Script Changes

The prep script:

1. Wipes and repartitions the target disk.
2. Formats boot as FAT32 and root as Btrfs.
3. Extracts the Arch Linux ARM root filesystem.
4. Moves the original ALARM boot files under `/boot/archlinuxarm`.
5. Copies ClockworkPi vendor boot firmware into `/boot`.
6. Copies vendor kernel modules for `6.12.62-v8+`.
7. Writes `cmdline.txt` for the new root `PARTUUID`.
8. Writes `/etc/fstab`, hostname, and console defaults.
9. Uses `arch-chroot` plus `qemu-aarch64-static` to initialize pacman and install packages.
10. Generates a Btrfs-capable initramfs for the vendor kernel.
11. Creates the normal user and enables sudo for `wheel`.
12. Installs a minimal i3 session.
13. Enables SSH, NetworkManager, ModemManager, LightDM, ClockworkPi audio services, and the uConsole 4G power service.

## Troubleshooting

If `arch-chroot` cannot execute `/bin/bash`, make sure qemu binfmt support is active on the host:

```sh
sudo systemctl restart systemd-binfmt
ls /proc/sys/fs/binfmt_misc
```

If pacman fails during the chroot, check host networking and DNS. The script copies the host `/etc/resolv.conf` into the target before chrooting.

If Btrfs boot fails, confirm `/boot/config.txt` contains:

```text
initramfs initramfs-uconsole.img followkernel
```

And confirm `/boot/cmdline.txt` contains:

```text
rootfstype=btrfs rootflags=subvol=@
```

If display, keyboard, battery, audio, or 4G controls are missing, the ClockworkPi support archives are probably incomplete or from a mismatched vendor image.

## Publishing Notes

Do not commit the downloaded ALARM root filesystem or ClockworkPi/vendor tarballs. Keep this repository to scripts and documentation, and let users obtain upstream/vendor artifacts themselves.
