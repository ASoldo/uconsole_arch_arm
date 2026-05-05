#!/usr/bin/env bash
set -euo pipefail

: "${UCONSOLE_PASSWORD:?UCONSOLE_PASSWORD is required}"
UCONSOLE_USER="${UCONSOLE_USER:-uconsole}"
[[ "$UCONSOLE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
  printf 'error: UCONSOLE_USER must be a simple Linux username\n' >&2
  exit 1
}
[[ "$UCONSOLE_USER" != "root" ]] || {
  printf 'error: UCONSOLE_USER must not be root\n' >&2
  exit 1
}

printf 'KEYMAP=us\nFONT=ter-v16n\n' > /etc/vconsole.conf
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
mkinitcpio -k 6.12.62-v8+ -g /boot/initramfs-uconsole.img

groups_to_add=()
for group in wheel audio video input render storage power uucp users; do
  if getent group "$group" >/dev/null; then
    groups_to_add+=("$group")
  fi
done
group_csv="$(IFS=,; printf '%s' "${groups_to_add[*]}")"
if ! id "$UCONSOLE_USER" >/dev/null 2>&1; then
  useradd -m -G "$group_csv" -s /bin/bash "$UCONSOLE_USER"
else
  usermod -aG "$group_csv" "$UCONSOLE_USER"
fi
printf 'root:%s\n%s:%s\n' "$UCONSOLE_PASSWORD" "$UCONSOLE_USER" "$UCONSOLE_PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

install -d -m 0755 "/home/$UCONSOLE_USER/.config/i3"
cat > "/home/$UCONSOLE_USER/.xinitrc" <<'EOF'
exec i3
EOF
cat > "/home/$UCONSOLE_USER/.config/i3/config" <<'EOF'
set $mod Mod4
font pango:DejaVu Sans Mono 9

bindsym $mod+Return exec alacritty
bindsym $mod+d exec rofi -show drun
bindsym $mod+Shift+q kill
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'Exit i3?' -b 'Yes' 'i3-msg exit'"

floating_modifier $mod
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right

bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+5 workspace number 5
bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4
bindsym $mod+Shift+5 move container to workspace number 5

bar {
  status_command bumblebee-status -m cpu memory battery date time -p time.format="%H:%M" date.format="%Y-%m-%d"
}
EOF
chown -R "$UCONSOLE_USER:$UCONSOLE_USER" "/home/$UCONSOLE_USER/.config" "/home/$UCONSOLE_USER/.xinitrc"

services=(sshd NetworkManager lightdm clockworkpi-audio-patch.service clockworkpi-audio-shutdown.service)
if systemctl list-unit-files ModemManager.service >/dev/null 2>&1; then
  services+=(ModemManager.service)
fi
if [[ -x /usr/local/bin/uconsole-4g-cm4 && -f /etc/systemd/system/uconsole-4g-cm4.service ]]; then
  services+=(uconsole-4g-cm4.service)
fi
systemctl enable "${services[@]}"
