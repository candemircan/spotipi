# spotipi

A Raspberry Pi 1 Model B (RBCA000) acting as a Spotify Connect speaker: pick
`spotipi` under Devices in the Spotify app and it plays on the cabled analog
speakers. The phone is only the remote; playback continues if the phone leaves.

## Hardware

| Part | Notes |
|---|---|
| Raspberry Pi 1 Model B/B+ (RBCA000) | ARMv6, 512 MB RAM, no WiFi |
| 32 GB microSD | in a full-size SD adapter (Model B has the big slot) |
| TP-Link TL-WN823N v2/v3 USB adapter | Realtek RTL8192EU, works with the in-kernel `rtl8xxxu` driver, 2.4 GHz only |
| USB-C audio adapter (+ USB-A→C adapter) | GeneralPlus 1b3f:2008 chip, card `Device`, drives the speakers' 3.5 mm AUX |
| Powered speakers | connected to the USB audio adapter's jack |

Wiring: Pi USB → A→C adapter → USB-C audio adapter → speakers AUX.
Power: micro-USB, ≥5V/2A.

## Setup (done, reproducible)

### 1. Flash the OS

Raspberry Pi OS Lite (Trixie, 32-bit armhf — the variant supporting Pi 1/Zero):

```bash
sudo ./flash.sh        # writes 2026-06-18-raspios-trixie-armhf-lite.img to $CARD (default /dev/mmcblk0)
./secrets.sh           # prompts for Pi user/password, WiFi SSID/password; writes cloud-init files
```

`secrets.sh` writes `user-data` + `network-config` into the boot partition —
byte-equivalent to what Raspberry Pi Imager produces for Trixie (verified against
rpi-imager's `customization_generator.cpp`; the image consumes them via
cloud-init's NoCloud datasource). Secrets exist only on the SD card, never in
this repo. No passwords or SSIDs are stored here.

Resulting Pi config: hostname `spotipi` (reachable as `spotipi.local`),
user with password sudo (no NOPASSWD), SSH with password + `spotipi_ed25519`
key auth, WiFi country DE, 2.4 GHz network, US keyboard, Europe/Berlin timezone.

### 2. Cross-compile librespot for ARMv6

No prebuilt Spotify client exists for ARMv6 (raspotify dropped Pi 1 support;
librespot/spotifyd ship no ARMv6 binaries). Build it in Docker:

```bash
cd cross
curl -sL "https://codeload.github.com/librespot-org/librespot/tar.gz/refs/tags/v0.8.0" -o librespot-0.8.0.tar.gz
tar xzf librespot-0.8.0.tar.gz
docker run --rm --privileged multiarch/qemu-user-static:register --reset
docker build --platform linux/arm/v6 -t librespot-armv6 -f Dockerfile.armv6-qemu librespot-0.8.0
docker create --name extract librespot-armv6
docker cp extract:/src/target/release/librespot ./librespot-v6
docker rm extract
```

**Why QEMU and not a plain Debian cross-build:** Debian's `armhf` toolchain is
built for ARMv7. A binary cross-linked against it crashes the ARMv6 Pi with
`SIGILL` (illegal instruction) — the crash comes from ARMv7-compiled crt/libgcc
objects, even though Rust's own codegen targets ARMv6. Building inside
`balenalib/raspberry-pi-debian` (genuine Raspbian ARMv6) under QEMU emulation
fixes it. Takes ~45 min; see `Dockerfile.armv6` for the fast-but-broken variant
kept as documentation.

Features: `alsa-backend` (no PulseAudio/PipeWire on the Pi), `with-libmdns`
(Spotify Connect discovery on the LAN), `rustls-tls-webpki-roots` (no OpenSSL
cross-compile). Requires a Spotify **Premium** account (Spotify Connect
limitation, not a Pi one).

### 3. Install on the Pi

Copy the binary and set up a **user-level** systemd service (no root daemon):

```bash
scp -i ~/.ssh/spotipi_ed25519 cross/librespot-v6 USER@spotipi.local:~/bin/librespot
ssh -i ~/.ssh/spotipi_ed25519 USER@spotipi.local
loginctl enable-linger          # user services start at boot without a login
mkdir -p ~/.config/systemd/user ~/.cache/librespot
cat > ~/.config/systemd/user/librespot.service <<'EOF'
[Unit]
Description=Librespot (Spotify Connect client)
Documentation=https://github.com/librespot-org/librespot
After=network-online.target

[Service]
ExecStart=%h/bin/librespot --name spotipi --backend alsa --device plughw:CARD=Device --bitrate 320 --cache %h/.cache/librespot
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now librespot.service
```

## Gotchas learned

- **USB dongle volume**: the Generalplus chip starts at 53 % (−21 dB) which is
  nearly inaudible. Fixed once over SSH: `amixer -c 1 set Speaker 100% unmute`.
  Not persisted across replug yet (ALSA mixer state usually persists via
  `alsa-state`; re-run the amixer command if audio goes silent).
- First boot takes 3–5 min: cloud-init, filesystem resize, one reboot, and the
  WiFi dongle associates late — wait for the dongle's green LED to blink.
- The dongle is 2.4 GHz only — pick the non-5G SSID if the router splits bands.
- USB audio card is `plughw:CARD=Device` (card 1, by name — survives reordering).

## Files

| File | Purpose |
|---|---|
| `flash.sh` | Download/verify/flash the OS image to the SD card |
| `secrets.sh` | Interactive: write cloud-init first-boot config to the SD card |
| `cross/Dockerfile.armv6-qemu` | The working ARMv6 build (Raspbian container under QEMU) |
| `cross/Dockerfile.armv6` | The broken Debian cross-build, kept as a warning |
| `cross/build-qemu.log` | Build log (gitignored) |

Not in the repo (gitignored, reproducible): the OS image, the librespot
tarball/source, and the built binary. The working binary also lives on the Pi
at `~/bin/librespot` — copy it back from there if you ever need it.

## Repo hygiene

No secrets are committed: credentials are entered interactively in
`secrets.sh`, the SSH keypair lives in `~/.ssh/`, and user-data/network-config
were written only to the SD card's boot partition. Paths are relative to the
repo (`$CARD`, `PUBKEY`, `WIFI_COUNTRY`, `PI_HOSTNAME` env vars to override).
