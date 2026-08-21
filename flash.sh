#!/bin/bash
# Flash Raspberry Pi OS Lite (Trixie, 32-bit, armhf) to the SD card.
# Works on the Raspberry Pi 1 Model B/B+ (ARMv6).
#
# Usage:              sudo ./flash.sh
# Override the card:  sudo CARD=/dev/sdX ./flash.sh
set -euo pipefail

CARD="${CARD:-/dev/mmcblk0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="$HERE/2026-06-18-raspios-trixie-armhf-lite.img"
IMG_XZ="$IMG.xz"
URL_BASE="https://downloads.raspberrypi.org/raspios_lite_armhf/images/raspios_lite_armhf-2026-06-19"

[ -b "$CARD" ] || { echo "ERROR: $CARD not found"; exit 1; }

if [ ! -f "$IMG" ]; then
    if [ ! -f "$IMG_XZ" ]; then
        echo "Downloading image (~550 MB)..."
        curl -sL -o "$IMG_XZ" "$URL_BASE/2026-06-18-raspios-trixie-armhf-lite.img.xz"
        curl -sL -o "$IMG_XZ.sha256" "$URL_BASE/2026-06-18-raspios-trixie-armhf-lite.img.xz.sha256"
        (cd "$HERE" && sha256sum -c "$IMG_XZ.sha256")
    fi
    echo "Decompressing image..."
    xz -dk "$IMG_XZ"
fi

# Guard against writing to the wrong disk.
SIZE=$(blockdev --getsize64 "$CARD")
if [ "$SIZE" -lt $((28*1024*1024*1024)) ] || [ "$SIZE" -gt $((34*1024*1024*1024)) ]; then
    echo "ERROR: $CARD is $((SIZE/1024/1024/1024)) GiB, expected the ~30 GiB SD card"
    exit 1
fi

umount ${CARD}p1 ${CARD}p2 2>/dev/null || true

echo "Writing $(numfmt --to=iec $(stat -c%s "$IMG")) to $CARD (takes a few minutes)..."
dd if="$IMG" of="$CARD" bs=4M conv=fsync status=progress
sync

echo ""
echo "Image written. Now run:  $(dirname "${BASH_SOURCE[0]}")/secrets.sh"
