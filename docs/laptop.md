# Laptops, Wi-Fi and the MacBook Pro 2016

The image is built for wired desktops, but `PROFILE_LAPTOP=1` (default)
adds a small Wi-Fi and power stack: `iwd` (Wi-Fi daemon with the friendly
`iwctl`), `iw`, `wireless-regdb`, `brightnessctl`, `upower`. Broadcom Wi-Fi
firmware is in `config/packages/firmware.txt`; Intel Wi-Fi firmware
(`linux-firmware-intel-wireless`, ~110 MB) is commented out there, uncomment
it for Intel laptops.

## Connecting to Wi-Fi

```bash
iwctl                            # interactive
  device list
  station wlan0 scan
  station wlan0 get-networks
  station wlan0 connect "Office-WiFi"     # asks for the passphrase, remembered afterwards
  station wlan0 show
  exit
# one-liner
iwctl --passphrase 'secret' station wlan0 connect "Office-WiFi"
```

`iwd` remembers networks in `/var/lib/iwd/*.psk` and reconnects at boot.
DHCP on `wl*` is done by systemd-networkd (`/etc/systemd/network/20-wifi.network`).
Enterprise Wi-Fi (802.1X / PEAP with the AD account): create
`/var/lib/iwd/Office.8021x`:

```ini
[Security]
EAP-Method=PEAP
EAP-Identity=user@corp.example.com
EAP-PEAP-CACert=/usr/local/share/ca-certificates/office-ca.crt
EAP-PEAP-Phase2-Method=MSCHAPV2
EAP-PEAP-Phase2-Identity=CORP\user
EAP-PEAP-Phase2-Password=secret
[Settings]
AutoConnect=true
```

`rfkill list` shows whether the radio is blocked; `rfkill unblock wifi`.

## MacBook Pro 2016 (13" and 15")

What works with this image, from mainline kernel support:

| Part | Status | Notes |
|---|---|---|
| Boot from USB | yes | hold **Option** at power-on, pick "EFI Boot". No Secure Boot on 2016 (no T2 chip). |
| Internal NVMe (Apple) | yes | shows as `/dev/nvme0n1`; the installer picks it. |
| Keyboard / trackpad | yes | `applespi` driver (in-kernel). Trackpad tap-to-click and natural scroll are on in sway. |
| Wi-Fi BCM43602 | yes | `brcmfmac` + `linux-firmware-broadcom-wireless`. Use `iwctl`. |
| Bluetooth | no | not installed on purpose (add `bluez` via Nexus if needed). |
| Display / Intel Iris (13") | yes | i915. |
| AMD Radeon Pro 450/455/460 (15") | yes | amdgpu + `linux-firmware-amd-graphics`. The Intel iGPU drives the panel; the dGPU is available for offload. |
| Audio | usually | Cirrus codec via `snd_hda_intel`; if silent check `dmesg | grep -i cs8409` and try `linux-firmware-misc` (present). |
| Touch Bar (15", 13" four-port) | **no** | needs an out-of-tree driver; the Touch Bar stays dark, so there are **no F-keys and no Esc**. Uncomment `caps:escape` in `~/.config/sway/config` to use Caps Lock as Escape (Helix needs it). Brightness/volume: bind other keys or use `brightnessctl` / `wpctl`. |
| FaceTime camera | no | out-of-tree `facetimehd` driver with extracted firmware; not shipped. |
| Ambient light / keyboard backlight | partial | `brightnessctl -d smc::kbd_backlight set 50%` for the keyboard backlight. |
| Suspend / battery | usually | `upower -i /org/freedesktop/UPower/devices/battery_BAT0`. Lid close suspends via logind. |
| Thunderbolt / USB-C | yes | USB-C to Ethernet adapters (Realtek, Apple) work out of the box. |

Realistic expectation: as a wired-or-Wi-Fi development laptop it works; the
Touch Bar and camera do not. If Esc via Caps Lock is not enough, an external
keyboard is the practical answer.

## Turning the laptop profile off

`PROFILE_LAPTOP=0` in `config/build.env` and remove
`linux-firmware-broadcom-wireless` from `config/packages/firmware.txt` to
save ~20 MB on pure desktop fleets.
