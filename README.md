# ubuntu-lite

A minimal, air-gap friendly Ubuntu 24.04 (amd64, UEFI) image for a developer
workstation. It boots from a USB stick, installs itself fully unattended, and
afterwards gets everything else from the office Nexus Repository, never from
the internet.

What is on the machine and nothing else:

| Area | What | Why |
|---|---|---|
| Base | Ubuntu 24.04 `minbase`, HWE kernel, systemd, networkd, ssh, nftables | no snapd, no cloud-init, no unattended-upgrades, no Ubuntu Pro |
| Containers | Docker CE + compose + buildx | all toolchains (node, python, postgres) run in containers |
| Desktop | sway (Wayland), foot, fuzzel, pipewire audio, clipboard | one compositor, no desktop environment, no display manager, no Electron |
| Apps | Helix editor with ruff (Python) and biome (JS/TS) language servers, Google Chrome (native Wayland) | docs/editor.md |
| Traffic | `httpmon` (mitmproxy in a container), `bandwhich`, `nethogs`, `tcpdump` | DevTools-like network view in the terminal |
| On/off | `lazydocker` (containers), `systemctl-tui` (services) | friendly TUIs |
| Office | Kerberos SSO (`lite-login`), OWA in Chrome (`Super+m`), Skype for Business chat via `pidgin-sipe`, `xfreerdp3`, `cifs-utils` | see docs/corporate.md |
| Setup | `lite-setup` (Nexus, AD, OWA addresses), `lite-nexus-upload` | docs/first-boot.md |
| Firewall | `lite-fw`: log and watch inbound attempts, auto-ban port scanners, block/allow lists, allowlist mode | nftables only, no daemon |
| Laptop | `iwd`/`iwctl` Wi-Fi, Broadcom firmware, brightness keys | docs/laptop.md (MacBook Pro 2016 notes) |
| Search & files | `lite-search` (Super+space: apps, settings, docs, files, contents), `yazi` file manager, `fd`, `rg`, `fzf`, `plocate` | no indexing daemon beyond plocate's daily updatedb |
| AI agent | `opencode` binary, `AGENTS.md` in the home directory explains this machine to it | docs/opencode.example.json |

Everything installed comes from a package pool that is also shipped on the ISO,
so the same set of `.deb` files, docker images and static binaries can be
uploaded to Nexus with one script.

## Quick start

```bash
# 0. once: generate the apt signing key for the Nexus apt repository
make keys                     # commits config/nexus/apt-signing.pub.asc, keeps the private key local

# 1. edit config/build.env (Nexus URL, user name, kernel flavour...) and drop the
#    office CA into config/ca/*.crt, your ssh public key into config/authorized_keys

# 2. build (Ubuntu 24.04 host with sudo, or `make docker-build`)
sudo apt install mmdebstrap squashfs-tools xorriso grub-efi-amd64-bin grub-pc-bin mtools dosfstools gnupg curl jq apt-utils ovmf qemu-system-x86
make build                    # -> out/ubuntu-lite-<build-id>.iso

# 3. test in QEMU
make test                     # unattended install into out/test-disk.qcow2
make test-boot                # boot the installed disk to the login prompt

# 4. write to USB and boot the target machine from it (UEFI)
sudo dd if=out/ubuntu-lite-latest.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Building on Windows: use WSL2 (Ubuntu 24.04) for the same commands, or
`make docker-build` with Docker Desktop, or let GitHub Actions build it and
download the artifact. Write the ISO with Rufus in DD mode. Details in
`AGENTS.md` section B6; problems in `docs/troubleshooting.md`.

The installer picks the largest internal disk, wipes it, and reboots. If it
finds an existing ubuntu-lite install it powers off instead, unless you pick
the "Reinstall" GRUB entry. Kernel options: `lite.disk=/dev/nvme0n1`,
`lite.hostname=name`, `lite.force=1`.

First login: user from `USERNAME` (default `dev`) with `USER_PASSWORD`, which
must be changed immediately. Logging in on tty1 starts sway. Then
`sudo lite-setup` points the machine at Nexus and the AD domain; see
`docs/first-boot.md` for the whole first-day checklist. `lite-help` prints
the cheat sheet.

## Layout

```
config/            build.env, package lists, firmware allow-list, docker images, vsix, binaries
overlay/           files copied into the root filesystem (installer, units, sway config, wrappers)
build/build.sh     mmdebstrap -> apt in chroot -> customize -> squashfs -> grub-mkrescue ISO
build/keys.sh      GPG key for the Nexus apt repository
scripts/           nexus-upload.sh (also on the ISO and installed as lite-nexus-upload), test-qemu.sh
docs/              first-boot.md, troubleshooting.md, laptop.md, editor.md, nexus-setup.md, airgap-workflow.md, corporate.md, design.md
out/               build output (git-ignored): iso, pool/, seed/, size-report.txt
```

ISO contents: `lite/` (kernel, initrd, squashfs), `pool/main` (every deb in the
image), `pool/extra` (optional packages for Nexus), `seed/docker`, `seed/vsix`,
`seed/bin`, and `nexus/` (upload script and docs).

## Adding or removing software

* Edit `config/packages/*.txt`, rebuild. Anything in `nexus-extra.txt` is only
  downloaded to the pool, not installed.
* Docker images: `config/docker-images.txt`. Static binaries (Helix, ruff,
  biome, lazydocker, opencode...): `config/github-binaries.txt`.
* Firmware: `config/packages/firmware.txt` (or `FIRMWARE_MODE=full` if some
  hardware needs a vendor package that is not listed).
* Resume a partial build: `make resume FROM=customize` (stages: rootfs,
  packages, customize, pool, squashfs, iso).

See `docs/nexus-setup.md` for the office side, `docs/airgap-workflow.md` for
how updates travel from the internet to the machines, and `docs/corporate.md`
for AD / OWA / Skype for Business.
