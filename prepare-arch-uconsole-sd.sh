#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

part_path() {
  local dev="$1" idx="$2"
  if [[ "$dev" =~ [0-9]$ ]]; then
    printf '%sp%s' "$dev" "$idx"
  else
    printf '%s%s' "$dev" "$idx"
  fi
}

DEVICE="${1:-}"
UCONSOLE_USER="${UCONSOLE_USER:-uconsole}"
[[ -n "$DEVICE" ]] || die "usage: ANSIBLE_VAULT_FILE=... [UCONSOLE_USER=uconsole] I_UNDERSTAND_THIS_WIPES=YES $0 /dev/sdX"
[[ "${I_UNDERSTAND_THIS_WIPES:-}" == "YES" ]] || die "set I_UNDERSTAND_THIS_WIPES=YES to allow destructive writes"
[[ -n "${ANSIBLE_VAULT_FILE:-}" || -n "${UCONSOLE_PASSWORD:-}" ]] || die "set ANSIBLE_VAULT_FILE or UCONSOLE_PASSWORD"
[[ "$UCONSOLE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "UCONSOLE_USER must be a simple Linux username"
[[ "$UCONSOLE_USER" != "root" ]] || die "UCONSOLE_USER must not be root"
[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device"
[[ "$DEVICE" != /dev/nvme* ]] || die "refusing to operate on NVMe device $DEVICE"

for cmd in lsblk findmnt wipefs sfdisk partprobe udevadm mkfs.vfat mkfs.ext4 bsdtar tar arch-chroot blkid install qemu-aarch64-static ansible-playbook; do
  need "$cmd"
done

device_type="$(lsblk -ndo TYPE "$DEVICE" | tr -d ' ')"
device_rm="$(lsblk -ndo RM "$DEVICE" | tr -d ' ')"
device_ro="$(lsblk -ndo RO "$DEVICE" | tr -d ' ')"
[[ "$device_type" == "disk" ]] || die "$DEVICE is type $device_type, expected disk"
[[ "$device_ro" == "0" ]] || die "$DEVICE is read-only"
if [[ "$device_rm" != "1" && "${ALLOW_NON_REMOVABLE:-}" != "1" ]]; then
  die "$DEVICE is not marked removable; set ALLOW_NON_REMOVABLE=1 only if this is definitely the microSD"
fi

root_source="$(findmnt -no SOURCE / || true)"
[[ "$root_source" != "$DEVICE"* ]] || die "refusing to operate on root device $DEVICE"
if findmnt -rn -S "$DEVICE" >/dev/null 2>&1 || findmnt -rn | awk -v dev="$DEVICE" '$2 ~ "^" dev { found=1 } END { exit !found }'; then
  die "$DEVICE or one of its partitions is mounted; unmount it first"
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="${TARBALL:-$BASE_DIR/cache/ArchLinuxARM-rpi-aarch64-latest.tar.gz}"
SUPPORT_TAR="${SUPPORT_TAR:-$BASE_DIR/backups/clockworkpi-20260430/clockworkpi-current-support-files.tar.gz}"
VENDOR_BOOT_TAR="${VENDOR_BOOT_TAR:-$BASE_DIR/backups/clockworkpi-20260430/uconsole-vendor-boot-kernel.tar.gz}"
ANSIBLE_VAULT_FILE="${ANSIBLE_VAULT_FILE:-}"
ANSIBLE_VAULT_PASSWORD_FILE="${ANSIBLE_VAULT_PASSWORD_FILE:-}"
[[ -s "$TARBALL" ]] || die "missing Arch Linux ARM tarball: $TARBALL"
[[ -s "$SUPPORT_TAR" ]] || die "missing ClockworkPi support backup: $SUPPORT_TAR"
[[ -s "$VENDOR_BOOT_TAR" ]] || die "missing uConsole vendor boot/kernel backup: $VENDOR_BOOT_TAR"
if [[ -n "$ANSIBLE_VAULT_FILE" ]]; then
  [[ -f "$ANSIBLE_VAULT_FILE" ]] || die "missing Ansible Vault vars file: $ANSIBLE_VAULT_FILE"
fi
if [[ -n "$ANSIBLE_VAULT_PASSWORD_FILE" ]]; then
  [[ -f "$ANSIBLE_VAULT_PASSWORD_FILE" ]] || die "missing Ansible Vault password file: $ANSIBLE_VAULT_PASSWORD_FILE"
fi

run_ansible_rootfs() {
  local rootfs_type="$1"
  local -a ansible_args=(
    ansible-playbook
    -i "$BASE_DIR/ansible/inventory/localhost.yml"
    "$BASE_DIR/ansible/playbooks/uconsole-rootfs.yml"
    -e "target_root=$ROOT_MNT"
    -e "uconsole_rootfs_type=$rootfs_type"
    -e "uconsole_kernel_release=6.12.62-v8+"
  )

  if [[ -n "$ANSIBLE_VAULT_FILE" ]]; then
    ansible_args+=(-e "@$ANSIBLE_VAULT_FILE")
    if [[ -n "$ANSIBLE_VAULT_PASSWORD_FILE" ]]; then
      ansible_args+=(--vault-password-file "$ANSIBLE_VAULT_PASSWORD_FILE")
    else
      ansible_args+=(--ask-vault-pass)
    fi
  fi

  env UCONSOLE_USER="$UCONSOLE_USER" UCONSOLE_PASSWORD="${UCONSOLE_PASSWORD:-}" "${ansible_args[@]}"
}

BOOT_MNT="/mnt/uconsole-arch-boot"
ROOT_MNT="/mnt/uconsole-arch-root"
SUPPORT_DIR="$(mktemp -d /tmp/uconsole-support.XXXXXX)"
cleanup() {
  set +e
  mountpoint -q "$BOOT_MNT" && umount "$BOOT_MNT"
  mountpoint -q "$ROOT_MNT/dev/pts" && umount "$ROOT_MNT/dev/pts"
  mountpoint -q "$ROOT_MNT/dev" && umount "$ROOT_MNT/dev"
  mountpoint -q "$ROOT_MNT/proc" && umount "$ROOT_MNT/proc"
  mountpoint -q "$ROOT_MNT/sys" && umount "$ROOT_MNT/sys"
  mountpoint -q "$ROOT_MNT" && umount "$ROOT_MNT"
  rm -rf "$SUPPORT_DIR"
}
trap cleanup EXIT

printf 'Target device:\n'
lsblk -o NAME,PATH,SIZE,TYPE,TRAN,MODEL,SERIAL,VENDOR,FSTYPE,LABEL,MOUNTPOINTS,RM,RO "$DEVICE"

printf '\nPartitioning %s...\n' "$DEVICE"
wipefs -a "$DEVICE"
sfdisk "$DEVICE" <<'SFDISK'
label: dos
unit: sectors

start=2048, size=2097152, type=c, bootable
start=2099200, type=83
SFDISK
partprobe "$DEVICE"
udevadm settle
sleep 2

BOOT_PART="$(part_path "$DEVICE" 1)"
ROOT_PART="$(part_path "$DEVICE" 2)"
[[ -b "$BOOT_PART" ]] || die "boot partition did not appear: $BOOT_PART"
[[ -b "$ROOT_PART" ]] || die "root partition did not appear: $ROOT_PART"

printf '\nFormatting partitions...\n'
mkfs.vfat -F 32 -n ALARMBOOT "$BOOT_PART"
mkfs.ext4 -F -L ALARMROOT "$ROOT_PART"

mkdir -p "$BOOT_MNT" "$ROOT_MNT"
mount "$ROOT_PART" "$ROOT_MNT"
mkdir -p "$ROOT_MNT/boot"
mount "$BOOT_PART" "$BOOT_MNT"

printf '\nExtracting Arch Linux ARM root filesystem...\n'
bsdtar -xpf "$TARBALL" -C "$ROOT_MNT"
mkdir -p "$BOOT_MNT/archlinuxarm"
if compgen -G "$ROOT_MNT/boot/*" >/dev/null; then
  mv "$ROOT_MNT"/boot/* "$BOOT_MNT/archlinuxarm/"
fi

printf '\nApplying uConsole boot/support files...\n'
tar -xzf "$SUPPORT_TAR" -C "$SUPPORT_DIR"
mkdir -p "$SUPPORT_DIR/vendor"
tar -xzf "$VENDOR_BOOT_TAR" -C "$SUPPORT_DIR/vendor"
cp -a "$SUPPORT_DIR/vendor/boot/firmware/." "$BOOT_MNT/"
mkdir -p "$ROOT_MNT/lib/modules"
cp -a "$SUPPORT_DIR/vendor/lib/modules/6.12.62-v8+" "$ROOT_MNT/lib/modules/"

if [[ -d "$SUPPORT_DIR/etc/NetworkManager/system-connections" ]]; then
  mkdir -p "$ROOT_MNT/etc/NetworkManager/system-connections"
  install -m 600 "$SUPPORT_DIR/etc/NetworkManager/system-connections/"*.nmconnection "$ROOT_MNT/etc/NetworkManager/system-connections/" 2>/dev/null || true
fi

install -Dm644 "$SUPPORT_DIR/etc/systemd/system/clockworkpi-audio-patch.service" "$ROOT_MNT/etc/systemd/system/clockworkpi-audio-patch.service"
install -Dm644 "$SUPPORT_DIR/etc/systemd/system/clockworkpi-audio-shutdown.service" "$ROOT_MNT/etc/systemd/system/clockworkpi-audio-shutdown.service"
install -Dm644 "$SUPPORT_DIR/etc/systemd/system/uconsole-4g-cm4.service" "$ROOT_MNT/etc/systemd/system/uconsole-4g-cm4.service"
install -Dm644 "$SUPPORT_DIR/etc/udev/rules.d/100-backlight.rules" "$ROOT_MNT/etc/udev/rules.d/100-backlight.rules"
install -Dm644 "$SUPPORT_DIR/etc/udev/rules.d/99-uconsole-charging.rules" "$ROOT_MNT/etc/udev/rules.d/99-uconsole-charging.rules"
install -Dm755 "$SUPPORT_DIR/usr/local/bin/audio_3.5_patch.py" "$ROOT_MNT/usr/local/bin/audio_3.5_patch.py"
install -Dm755 "$SUPPORT_DIR/usr/local/bin/clockworkpi-audio-shutdown.sh" "$ROOT_MNT/usr/local/bin/clockworkpi-audio-shutdown.sh"
install -Dm755 "$SUPPORT_DIR/usr/local/bin/rpi-backlight" "$ROOT_MNT/usr/local/bin/rpi-backlight"
install -Dm755 "$SUPPORT_DIR/usr/local/bin/rpi-backlight-check" "$ROOT_MNT/usr/local/bin/rpi-backlight-check"
install -Dm755 "$SUPPORT_DIR/usr/local/bin/uconsole-4g-cm4" "$ROOT_MNT/usr/local/bin/uconsole-4g-cm4"

ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$ROOT_PART")"
cp -a "$BOOT_MNT/config.txt" "$BOOT_MNT/config.txt.vendor-uconsole"
cp -a "$BOOT_MNT/cmdline.txt" "$BOOT_MNT/cmdline.txt.vendor-uconsole"
printf 'console=serial0,115200 console=tty1 root=PARTUUID=%s rootfstype=ext4 rw fsck.repair=yes rootwait cfg80211.ieee80211_regdom=HR\n' "$ROOT_PARTUUID" > "$BOOT_MNT/cmdline.txt"

printf 'LABEL=ALARMROOT / ext4 defaults,noatime 0 1\nLABEL=ALARMBOOT /boot vfat defaults 0 0\n' > "$ROOT_MNT/etc/fstab"
printf 'arch-uconsole\n' > "$ROOT_MNT/etc/hostname"

cp /usr/bin/qemu-aarch64-static "$ROOT_MNT/usr/bin/"
cp /etc/resolv.conf "$ROOT_MNT/etc/resolv.conf"
mount --bind /dev "$ROOT_MNT/dev"
mount -t devpts devpts "$ROOT_MNT/dev/pts"
mount -t proc proc "$ROOT_MNT/proc"
mount -t sysfs sys "$ROOT_MNT/sys"

printf '\nConfiguring Arch Linux ARM rootfs with Ansible...\n'
run_ansible_rootfs ext4

sync
printf '\nPrepared %s for uConsole Arch Linux ARM.\n' "$DEVICE"
