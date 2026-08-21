#!/bin/bash
# Prompt for the Pi credentials + WiFi secrets and write the cloud-init
# first-boot files into the flashed card's boot partition.
# Run as your normal user, AFTER flash.sh:  ./secrets.sh
#
# Usage:              ./secrets.sh
# Override the card:  CARD=/dev/sdX ./secrets.sh
# Override SSH key:   PUBKEY=~/.ssh/id_ed25519.pub ./secrets.sh
set -euo pipefail

CARD="${CARD:-/dev/mmcblk0}"
CARDP1="${CARD}p1"
PUBKEY="${PUBKEY:-$HOME/.ssh/spotipi_ed25519.pub}"
COUNTRY="${WIFI_COUNTRY:-DE}"
HOSTNAME="${PI_HOSTNAME:-spotipi}"

[ -f "$PUBKEY" ] || {
    echo "Generating SSH keypair at ${PUBKEY%.*}..."
    ssh-keygen -t ed25519 -N "" -f "${PUBKEY%.*}" -q
}

# --- mount the boot partition if needed -------------------------------------
BOOT=""
if [ -b "$CARDP1" ] && lsblk -no MOUNTPOINT "$CARDP1" | grep -q .; then
    BOOT=$(lsblk -no MOUNTPOINT "$CARDP1" | head -1)
else
    BOOT=$(udisksctl mount -b "$CARDP1" | sed 's/^Mounted .* at //; s/\.*$//')
fi
[ -d "$BOOT" ] || { echo "ERROR: could not mount $CARDP1"; exit 1; }
echo "Boot partition mounted at $BOOT"

# --- prompts ------------------------------------------------------------------
read -rp "Username for the Pi (default: pi): " USERNAME
USERNAME=${USERNAME:-pi}
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "ERROR: invalid username '$USERNAME'"; exit 1
fi

while true; do
    read -rsp "Password for the Pi user (for console/SSH login): " PW1; echo
    read -rsp "Repeat password: " PW2; echo
    [ "$PW1" = "$PW2" ] && [ -n "$PW1" ] && break
    echo "Passwords empty or do not match, try again."
done

read -rp "WiFi network name (SSID): " SSID
[ -n "$SSID" ] || { echo "ERROR: SSID must not be empty"; exit 1; }
read -rsp "WiFi password: " WPASS; echo

read -rp "WiFi country code (default: $COUNTRY): " COUNTRY_IN
COUNTRY=${COUNTRY_IN:-$COUNTRY}
[ -n "$COUNTRY" ] || COUNTRY=DE

# --- derive values ------------------------------------------------------------
# WPA PMK: PBKDF2-SHA1(passphrase, ssid, 4096, 32 bytes), hex — same as the
# Raspberry Pi Imager does. A 64-hex input is used as the PMK directly.
PMK=$(python3 - "$WPASS" "$SSID" <<'EOF'
import hashlib, sys
pw, ssid = sys.argv[1], sys.argv[2]
if len(pw) == 64 and all(c in "0123456789abcdefABCDEF" for c in pw):
    print(pw.lower())
elif 8 <= len(pw) <= 63:
    print(hashlib.pbkdf2_hmac("sha1", pw.encode(), ssid.encode(), 4096, 32).hex())
else:
    sys.exit("WIFI password must be 8-63 characters (or a 64-hex PSK)")
EOF
) || exit 1

HASH=$(printf %s "$PW1" | openssl passwd -6 -stdin)

# YAML double-quoted string escaping for SSID
SSID_YAML=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$SSID")

# --- write cloud-init files ----------------------------------------------------
# This is the byte-equivalent of what Raspberry Pi Imager writes for
# Trixie images (verified against rpi-imager's customization_generator.cpp).
# The image reads these from the boot partition via the NoCloud datasource.
cat > "$BOOT/user-data" <<EOF
#cloud-config
manage_resolv_conf: false

hostname: $HOSTNAME
manage_etc_hosts: true

timezone: Europe/Berlin
keyboard:
  model: pc105
  layout: us

user:
  name: $USERNAME
  shell: /bin/bash
  lock_passwd: false
  passwd: "$HASH"
  ssh_authorized_keys:
  - "$(cat "$PUBKEY")"
  # Explicit null: the image's default user would otherwise inherit
  # NOPASSWD sudo; null keeps normal password-prompted sudo.
  sudo: null

ssh_pwauth: true

runcmd:
- [ systemctl, enable, --now, ssh ]
EOF

cat > "$BOOT/network-config" <<EOF
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      dhcp6: true
      optional: true
  wifis:
    wlan0:
      dhcp4: true
      regulatory-domain: "$COUNTRY"
      access-points:
        $SSID_YAML:
          password: "$PMK"
      optional: true
EOF

echo ""
echo "Written to $BOOT:"
ls -l "$BOOT/user-data" "$BOOT/network-config"

udisksctl unmount -b "$CARDP1" >/dev/null
echo "Boot partition unmounted — you can now remove the SD card and put it in the Pi."
