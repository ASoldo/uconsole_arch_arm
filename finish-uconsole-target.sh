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

pacman -S --needed --noconfirm sudo networkmanager modemmanager openssh linux-firmware btrfs-progs mkinitcpio xorg-server xorg-xinit xorg-xrandr xorg-xsetroot xorg-xinput xterm alacritty lightdm lightdm-gtk-greeter i3-wm i3status rofi python python-gobject ttf-dejavu terminus-font vim nano git zsh inetutils
pacman -S --needed --noconfirm powerline-fonts || true
pacman -S --needed --noconfirm raspberrypi-utils || true
if ! pacman -S --needed --noconfirm bumblebee-status; then
  pacman -S --needed --noconfirm python-pip
  python -m pip install --break-system-packages bumblebee-status
fi

groups_to_add=()
for group in wheel audio video input render storage power uucp users; do
  if getent group "$group" >/dev/null; then
    groups_to_add+=("$group")
  fi
done
group_csv="$(IFS=,; printf '%s' "${groups_to_add[*]}")"
if ! id "$UCONSOLE_USER" >/dev/null 2>&1; then
  useradd -m -G "$group_csv" -s /usr/bin/zsh "$UCONSOLE_USER"
else
  usermod -aG "$group_csv" "$UCONSOLE_USER"
  usermod -s /usr/bin/zsh "$UCONSOLE_USER"
fi
printf 'root:%s\n%s:%s\n' "$UCONSOLE_PASSWORD" "$UCONSOLE_USER" "$UCONSOLE_PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

user_home="/home/$UCONSOLE_USER"
if [[ ! -d "$user_home/.oh-my-zsh" ]]; then
  git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$user_home/.oh-my-zsh"
fi
cat > "$user_home/.zshrc" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
export LANG="${LANG:-C.UTF-8}"
[[ "$LANG" = "C" ]] && export LANG="C.UTF-8"
export LC_CTYPE="${LC_CTYPE:-C.UTF-8}"
ZSH_THEME="agnoster"
plugins=(git)

if [[ -s "$ZSH/oh-my-zsh.sh" ]]; then
  source "$ZSH/oh-my-zsh.sh"
fi

export EDITOR="vim"
export VISUAL="vim"
export PAGER="less"
path=("$HOME/.local/bin" "$HOME/bin" $path)
typeset -U path PATH
EOF

install -d -m 0755 "$user_home/.config/i3"
cat > "$user_home/.xinitrc" <<'EOF'
exec i3
EOF
cat > "$user_home/.config/i3/config" <<'EOF'
set $mod Mod1
font pango:DejaVu Sans Mono 9

exec_always --no-startup-id xrandr --output DSI-1 --primary --rotate right

bindsym $mod+Return exec alacritty
bindsym $mod+KP_Enter exec alacritty
bindsym $mod+space exec rofi -show drun
bindsym $mod+d exec rofi -show drun
bindsym $mod+f fullscreen toggle
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
  position top
  status_command bumblebee-status -m cpu memory battery date time -t powerline -p time.format="%H:%M" date.format="%Y-%m-%d"
}
EOF
chown -R "$UCONSOLE_USER:$UCONSOLE_USER" "$user_home/.config" "$user_home/.xinitrc" "$user_home/.zshrc" "$user_home/.oh-my-zsh"

services=(sshd NetworkManager lightdm clockworkpi-audio-patch.service clockworkpi-audio-shutdown.service)
if systemctl list-unit-files ModemManager.service >/dev/null 2>&1; then
  services+=(ModemManager.service)
fi
if [[ -x /usr/local/bin/uconsole-4g-cm4 && -f /etc/systemd/system/uconsole-4g-cm4.service ]]; then
  services+=(uconsole-4g-cm4.service)
fi
systemctl enable "${services[@]}"
