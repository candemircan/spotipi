#!/bin/bash
# Install/update librespot on the Pi over SSH: binary, user-level systemd
# service (with hardware-volume pinning), linger. Idempotent — safe to re-run.
# Run from this desktop with the Pi powered on and on the network.
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

echo "Checking SSH to $PI_HOST ..."
"${SSH[@]}" true

echo "Copying binary ..."
"${SSH[@]}" 'mkdir -p ~/bin ~/.config/systemd/user ~/.cache/librespot'
scp -q -i "$KEY" "$BIN" "$PI_USER@$PI_HOST:~/bin/librespot"

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
systemctl --user enable --now librespot.service
sleep 2
systemctl --user is-active librespot.service'

echo "Done. spotipi should appear in your Spotify devices."
