# Troubleshooting

Symptom → what to check → fix. Commands run on the installed machine unless
marked (repo). For an AI agent: run the check, read the output, then apply
the fix; do not guess.

## Boot and install

| Symptom | Check | Fix |
|---|---|---|
| USB does not boot, firmware skips it | UEFI boot menu (F12/F2/Del), Secure Boot state | The ISO must be written raw (`dd`, Rufus in *DD mode*, Etcher). Choose the UEFI entry of the stick. Secure Boot may stay on (signed shim). |
| GRUB menu shows, then black screen for minutes | Pick "Install with verbose kernel output" entry | Read the last lines; kernel/driver issue. Report the model. |
| `lite: could not find the UBUNTU_LITE medium` | Live boot cannot see the stick | Bad stick or written in ISO mode instead of DD mode; try another USB port (USB 2). |
| Installer stops: "already installed ... powering off" | The disk already has ubuntu-lite | Intentional. Use the GRUB entry "Reinstall" (`lite.force=1`). |
| `no suitable internal disk found` | `lsblk -dno NAME,SIZE,TRAN,RM` from the live shell | Disk is on an unusual controller or reported removable; boot with `lite.disk=/dev/nvme0n1` (edit the GRUB entry with `e`). |
| Installer dropped to a shell after an ERROR | Read the red line; `journalctl -u lite-installer` | Fix the cause (bad disk, full stick), `reboot`. |
| After install the machine boots the stick again | Stick still inserted; firmware boot order | Remove the stick. The installer refuses to wipe an installed system, so nothing is lost. |
| After install: firmware finds no OS | `EFI/BOOT/BOOTX64.EFI` and `EFI/ubuntu-lite/` on the ESP | Both are written. Some firmware needs the boot entry added by hand: boot the stick's "Live" entry, `sudo efibootmgr -c -d /dev/nvme0n1 -p 1 -L ubuntu-lite -l '\EFI\ubuntu-lite\shimx64.efi'`. |

## Login and desktop

| Symptom | Check | Fix |
|---|---|---|
| Password rejected at first login | The default is from `USER_PASSWORD` in `config/build.env` (image default `changeme`) | Log in, set the new password when forced. |
| tty1 login works but sway does not start | `cat ~/.sway.log`; `ls /dev/dri` | No GPU device: kernel driver missing, add the vendor package to `config/packages/firmware.txt` (repo). `dev` must be in `video`/`render` groups (`id`). |
| Black screen with cursor, no bar | `swaymsg -t get_outputs` from tty2 (`Ctrl+Alt+F2`) | Output disabled; `swaymsg output '*' enable`. |
| Chrome starts but no window / crashes | `chrome --ozone-platform=wayland` from a terminal to see the error | If Wayland fails: `chrome --ozone-platform=x11` uses XWayland. |
| No sound | `wpctl status`; `aplay -l`; `dmesg | grep -i -E 'sof|snd'` | Missing firmware → `firmware-sof-signed` is on the image; other codecs need `linux-firmware-misc` (present) or a vendor package. Unmute with `alsamixer`. Wrong sink: `wpctl set-default <id>`. |
| Keyboard layout wrong | `/etc/default/keyboard`, sway `input` block | `KEYMAP` in `build.env` (repo) or edit `~/.config/sway/config` (`xkb_layout`). |
| Clipboard between apps fails | `wl-paste` works? | Both apps must run on Wayland; XWayland apps share via sway automatically. |

## Network, Nexus, apt, docker

| Symptom | Check | Fix |
|---|---|---|
| No IP address | `networkctl status`; `ip a` | Cable/DHCP. Static: `/etc/netplan/01-lite.yaml` then `sudo netplan apply`. |
| `apt update`: "Could not resolve nexus..." | `sudo lite-setup --show`; `getent hosts <nexus host>` | No DNS: set `NEXUS_IP` (or `EXTRA_HOSTS`) with `sudo lite-setup`. |
| `apt update`: certificate verify failed | `curl -v https://<nexus>/` | Office CA missing → `/usr/local/share/ca-certificates/office-ca.crt` + `sudo update-ca-certificates`, or `config/ca/` before the next build (repo). |
| `apt update`: NO_PUBKEY / not signed | `/etc/apt/sources.list.d/nexus.sources` | Image built without `make keys`, or key in Nexus differs from `config/nexus/apt-signing.pub.asc`. Rebuild with the right key (repo). |
| `apt update` OK but `apt install x` says not found | `apt-cache policy x` | Not uploaded to Nexus yet: `lite-nexus-upload --src /mnt apt` from the stick, or add to `nexus-extra.txt` (repo). |
| `docker pull` hangs then fails | `sudo lite-setup --test`; `curl https://<registry>:8443/v2/` | Registry unreachable or image not pushed. Push from a machine that has it, or `--src` upload. Insecure HTTP registry → `NEXUS_DOCKER_INSECURE=1`. |
| `docker: permission denied` | `id` shows `docker` group? | Log out and in again (group added at build). |
| Bundled images missing after install | `docker images`; `systemctl status lite-seed-images` | Seeds load on first boot from `/var/lib/ubuntu-lite/seed`; `sudo systemctl start lite-seed-images`. |
| Container cannot reach the internet | Expected: air-gap. | Use Nexus for npm/pip mirrors (docs/airgap-workflow.md). |

## Office (Kerberos, OWA, Pidgin, shares, RDP)

| Symptom | Check | Fix |
|---|---|---|
| `lite-login`: Cannot find KDC | `sudo lite-setup --show`; `nc -zv dc1 88` | Set `AD_KDC` (and `EXTRA_HOSTS` if no DNS) via `lite-setup`. |
| `kinit`: Clock skew too great | `date`; DC time | Kerberos needs < 5 min skew. `sudo date -s '...'` then `sudo hwclock -w`, or point `systemd-timesyncd` at the DC (`NTP=` in `/etc/systemd/timesyncd.conf`, install `systemd-timesyncd` from Nexus). |
| `kinit`: Preauthentication failed | Password / account | Wrong password or locked account. |
| OWA asks for password despite ticket | Chrome policy | `chrome://policy` must show `AuthServerAllowlist`; set `AD_DOMAIN` via `lite-setup`, restart Chrome. |
| Pidgin: "Read error" / cannot connect | Server, TLS, auth scheme (docs/corporate.md) | Set the front-end server explicitly, TLS, try NTLM if Kerberos fails; login must be `DOMAIN\user`. |
| `mount -t cifs`: Permission denied with `sec=krb5` | `klist`; `cifs-utils` installed | Ticket expired (`lite-login`), or use `user=/domain=` password mount. Add `vers=3.0` for old servers. |
| RDP: certificate error | | `/cert:tofu` accepts the server certificate once. |

## Firewall

| Symptom | Check | Fix |
|---|---|---|
| Locked out over ssh after `lite-fw mode allowlist` | From the console (tty1): `sudo lite-fw list` | `sudo lite-fw allow <your ip>` or `sudo lite-fw mode open`. |
| A colleague or scanner is auto-banned | `sudo lite-fw banned` | `sudo lite-fw unban IP`; `sudo lite-fw allow IP` to exempt permanently. |
| Published container port unreachable | `lite-fw ports`; `sudo lite-fw status` | In allowlist mode only allowed sources reach it; otherwise Docker publishes it directly. |
| `nftables.service` failed | `sudo nft -c -f /etc/nftables.conf` | Shows the bad line; `sudo lite-fw apply` re-renders the include files. |

## Editor and tools

| Symptom | Check | Fix |
|---|---|---|
| Helix: no syntax colours / "runtime not found" | `echo $HELIX_RUNTIME`; `ls /usr/local/share/helix/runtime` | Log out/in (`/etc/profile.d/helix.sh`), or `export HELIX_RUNTIME=/usr/local/share/helix/runtime`. |
| Helix: language server failed | `hx --health python` / `typescript` | ruff/biome must be in PATH; TypeScript type checking comes from the container (docs/editor.md). |
| `httpmon` fails to start | `docker images | grep mitmproxy` | Image not loaded: `docker pull mitmproxy/mitmproxy:11` from Nexus. |
| `bandwhich`: permission | | Needs root: `sudo bandwhich`. |
| `opencode` cannot reach the model | `curl <baseURL>/models` | Endpoint address in `~/.config/opencode/opencode.json`; no internet here. |

## Build (repo)

| Symptom | Check | Fix |
|---|---|---|
| `missing tool: ...` | | Install the listed apt packages (README). |
| `E: Unable to locate package X` | `chroot out/work/rootfs apt-cache policy X` | Typo, or not in Ubuntu 24.04 main/universe; put it in `nexus-extra.txt` only if it exists. |
| `no downloadable release asset for NAME` | The asset template in `config/github-binaries.txt` vs the release page | Fix the template; the fetcher tries the 6 newest tags. |
| `initramfs was not generated` | `out/work/rootfs/boot` | Re-run `make resume FROM=packages`. |
| Build fails mid-way, chroot left mounted | `mount | grep out/work/rootfs` | `sudo umount -l out/work/rootfs/{run,dev,sys,proc}`; re-run the stage. |
| No space left | `du -sh out/*` | `make clean` (keeps `out/pool` and `out/seed` caches). |
| QEMU test very slow | `ls /dev/kvm` | Without KVM the test takes ~40 min; enable virtualization or run it in CI. |
