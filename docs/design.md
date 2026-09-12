# Design notes

Decisions taken with the owner, and why.

* **minbase + own installer instead of Ubuntu Server autoinstall.** Smallest
  possible footprint and complete control over what is on disk. The installer
  is 200 lines of shell: partition, `cp -a` from the squashfs, GRUB. The live
  system and the installed system are the same root filesystem, so what you
  test live is what gets installed.
* **`boot=lite` initramfs script instead of casper/live-boot.** ~60 lines,
  no extra packages, no live user magic. The ISO is found by filesystem label
  `UBUNTU_LITE`, so `dd` to any USB works.
* **Kernel `linux-image-virtual-hwe-24.04`.** Same kernel binary and modules
  as `generic` (on 7.x HWE kernels all drivers are in `linux-modules`; on 6.8
  the build adds `linux-modules-extra`), but the meta package does not drag in
  the full `linux-firmware`. Ubuntu splits firmware per vendor, so
  `config/packages/firmware.txt` picks GPU, audio and wired NIC packages
  (~110 MB). `FIRMWARE_MODE=full` restores everything.
* **Signed shim + GRUB.** Costs ~10 MB, boots with Secure Boot on or off.
  `grub-install --removable` writes the fallback path so no NVRAM entry is
  required across dozens of machines.
* **Docker CE from Docker's repo, not `docker.io`.** Compose v2 and buildx
  plugins, matches the Nexus docker registry workflow.
* **No toolchains on the host.** Node, Python and PostgreSQL run in
  containers, so host updates never touch project dependencies and the host
  stays at ~3 GB installed.
* **sway, not X11 + a WM.** One package family, Wayland native for Chrome
  (`--ozone-platform-hint=auto`), XWayland kept for stragglers. No display
  manager: tty1 login starts sway.
* **Helix instead of VS Code.** VS Code was ~1 GB installed and Electron
  heavy; Helix is a 20 MB static binary with LSP built in. ruff and biome
  (static Rust binaries) provide Python and JS/TS tooling without Node or
  Python on the host; TypeScript type checking runs from the dev container
  (docs/editor.md). VS Code can be re-added with one line.
* **Chromium as Google Chrome `.deb`.** On 24.04 `apt install chromium` is a
  snap. Chrome's deb repo is static and easy to mirror into the pool.
* **mitmproxy in a container.** Avoids ~100 MB of Python on the host. The
  `httpmon` wrapper runs it on the host network, optionally with nftables
  redirect rules so container traffic is captured transparently.
* **Only Nexus in apt sources.** apt never waits on an unreachable mirror.
  The pool on the ISO is exactly the set of packages installed, so Nexus is
  populated from the same artefact that installed the machines.
* **GPG signed apt repo.** `make keys` once; the image trusts the public key,
  Nexus signs with the private one. Without the key the build still works but
  marks the source `Trusted: yes` and warns.
* **Docker seeding on first boot.** The installer copies the bundled image
  tars to `/var/lib/ubuntu-lite/seed`; `lite-seed-images.service` loads them
  with the real Docker on first boot and deletes them, so `docker run
  postgres` works before Nexus is even populated.

* **Firewall as data, not a daemon.** `lite-fw` renders two include files
  for nftables (lists and services); auto-banning of port scanners is a
  dynamic set with a timeout, logging is the kernel log. No fail2ban, no
  python, nothing to keep running.

Things deliberately left out: snapd, cloud-init, unattended-upgrades,
ubuntu-advantage-tools, apport, whoopsie, popularity-contest, NetworkManager,
ModemManager, avahi, cups, bluetooth, Wi-Fi firmware, X11 server, display
manager, GNOME/KDE anything, polkit GUI agents, flatpak.
