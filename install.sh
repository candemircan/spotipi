#!/bin/bash
# Install/update librespot + shairport-sync on the Pi over SSH: binaries,
# systemd services (with hardware-volume pinning), linger. Idempotent — safe
# to re-run. Run from this desktop with the Pi powered on and on the network.
#
# Usage:            ./install.sh
# Overrides:        PI_USER, PI_HOST, KEY, BIN (env vars)
set -euo pipefail

PI_HOST="${PI_HOST:-spotipi.local}"
PI_USER="${PI_USER:-}"
KEY="${KEY:-$HOME/.ssh/spotipi_ed25519}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${BIN:-$HERE/librespot-v6}"

[ -n "$PI_USER" ] || read -rp "Username on the Pi: " PI_USER
[ -n "$PI_USER" ] || { echo "ERROR: no username"; exit 1; }
[ -f "$BIN" ] || { echo "ERROR: $BIN missing (rebuild it: README step 2)"; exit 1; }

SSH=(ssh -i "$KEY" -o BatchMode=yes "$PI_USER@$PI_HOST")
# -tt variant for commands needing interactive sudo on the Pi.
SSH_TTY=(ssh -i "$KEY" -o BatchMode=yes -tt "$PI_USER@$PI_HOST")

echo "Checking SSH to $PI_HOST ..."
"${SSH[@]}" true

echo "Copying binary ..."
# Upload to a temp name: mv over the running binary works, scp in place
# would fail with ETXTBSY while librespot.service is active.
"${SSH[@]}" 'mkdir -p ~/bin ~/.config/systemd/user ~/.cache/librespot'
scp -q -i "$KEY" "$BIN" "$PI_USER@$PI_HOST:~/bin/.librespot.new"
"${SSH[@]}" 'mv -f ~/bin/.librespot.new ~/bin/librespot'

echo "Installing service ..."
# ExecStartPre: the USB dongle resets to a near-silent -21 dB on every boot
# (alsa-restore.service is not enabled on OS Lite); pin hardware volume and
# let librespot's software volume handle the app's slider.
"${SSH[@]}" 'cat > ~/.config/systemd/user/librespot.service' <<'EOF'
[Unit]
Description=Librespot (Spotify Connect client)
Documentation=https://github.com/librespot-org/librespot
After=network-online.target

[Service]
ExecStartPre=/usr/bin/amixer -c Device set Speaker 100% unmute
ExecStart=%h/bin/librespot --name spotipi --backend alsa --device plughw:CARD=Device --bitrate 320 --cache %h/.cache/librespot
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

"${SSH[@]}" 'loginctl enable-linger
systemctl --user daemon-reload
systemctl --user enable librespot.service
systemctl --user restart librespot.service
sleep 2
systemctl --user is-active librespot.service'

echo "Installing shairport-sync (AirPlay receiver) ..."
scp -q -i "$KEY" "$HERE/shairport-sync.conf" "$PI_USER@$PI_HOST:/tmp/shairport-sync.conf"
# Prompts for the Pi password once (password sudo, no NOPASSWD).
"${SSH_TTY[@]}" 'sudo apt-get install -y shairport-sync
sudo install -m 644 /tmp/shairport-sync.conf /etc/shairport-sync.conf
rm /tmp/shairport-sync.conf
sudo systemctl enable shairport-sync
sudo systemctl restart shairport-sync'
"${SSH[@]}" 'systemctl is-active shairport-sync'

echo "Enabling persistent journal ..."
# Volatile journald loses the log on every power cycle, so a dropout cannot
# be diagnosed after the fact (journalctl -b -1). Idempotent.
"${SSH_TTY[@]}" 'sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald'
"${SSH[@]}" 'test -d /var/log/journal'

echo "Done. spotipi appears in Spotify devices (Connect) and AirPlay pickers."
