# AGENTS.md — guide for AI coding agents working with ubuntu-lite

You are helping with **ubuntu-lite**: a minimal Ubuntu 24.04 developer
workstation image for an air-gapped office. Read this file fully before
acting. Keep answers short and run commands; do not guess package names,
check them.

There are two places you can be running. Find out first:

```bash
[ -f /etc/ubuntu-lite/build-id ] && echo "INSTALLED MACHINE" || echo "BUILD REPOSITORY"
```

* **Installed machine**: a real workstation. No internet. Software comes only
  from the office Nexus server. Section A applies.
* **Build repository**: the git repo that produces the ISO (has `build/`,
  `config/`, `overlay/`). Internet is available here. Section B applies.

Hard rules in both places:

1. Never add internet apt sources, PPAs, snap, flatpak, pip/npm on the host.
   Toolchains (node, python, postgres) run in Docker containers. The editor
   is Helix (`hx`), not VS Code; see `/usr/share/doc/ubuntu-lite/editor.md`.
2. Never edit files under `/usr/lib/ubuntu-lite/` or `/usr/share/ubuntu-lite/`
   on a machine; they come from the image. Configuration lives in
   `/etc/ubuntu-lite/site.conf` and is applied with `sudo lite-setup`.
3. Before saying something is impossible, check `docs/` (repo) or
   `/usr/share/doc/ubuntu-lite/` (machine).
4. When something fails, open `troubleshooting.md` (same places) first: it
   maps symptoms to the exact check command and fix. Run the check, quote
   its output, then apply the fix. If the symptom is not listed, gather:
   `journalctl -b -p err`, `systemctl --failed`, `sudo lite-setup --test`,
   `sudo lite-fw status`, and `dmesg | tail -50`, and report them.

---

## A. On an installed machine

### A1. Where things are

| Path | What |
|---|---|
| `/etc/ubuntu-lite/site.conf` | Nexus URL, AD realm, KDCs, OWA URL, extra hosts. Edit with `sudo lite-setup`. |
| `/etc/apt/sources.list.d/nexus.sources` | the only apt source (generated, do not hand-edit) |
| `/etc/docker/daemon.json` | docker registry mirror (generated) |
| `/etc/krb5.conf` | Kerberos (generated) |
| `/etc/opt/chrome/policies/managed/lite-sso.json` | Chrome SSO allow-list (generated) |
| `/etc/nftables.conf` + `/etc/nftables.d/` | firewall; never hand-edit, use `sudo lite-fw` (status, watch, top, block, allow, mode, open, close) |
| `~/.config/sway/config` | window manager keys (Super+Enter terminal, Super+c Helix, Super+b Chrome, Super+m OWA, Super+s Pidgin) |
| `~/.config/helix/` | editor config; `languages.toml` wires ruff (Python) and biome (JS/TS) as language servers |
| `/usr/share/doc/ubuntu-lite/*.md` | full docs: first-boot, nexus-setup, airgap-workflow, corporate |

Search: `lite-search` (Super+space) finds apps, settings, docs and files;
`lite-search c` greps file contents; `yazi` (Super+y) is the file manager;
`fd`, `rg`, `fzf`, `locate` are on the image.
Helper commands: `lite-help` (cheat sheet), `sudo lite-setup` (office
addresses), `sudo lite-setup --test` (connectivity check), `sudo lite-fw`
(inbound firewall: watch attempts, block/allow IPs, allowlist mode), `lite-login`
(Kerberos ticket), `lite-owa` (OWA window), `lite-nexus-upload` (push ISO
content into Nexus), `httpmon` (HTTP inspector), `lazydocker`,
`systemctl-tui`, `bandwhich`, `nethogs`.

### A2. Install or remove software

```bash
sudo apt update                          # talks to Nexus only
apt-cache policy <package>               # "Candidate: (none)" = not in Nexus yet
sudo apt install <package>
sudo apt remove --purge <package> && sudo apt autoremove
```

If the package is not in Nexus: it must be added at home in the build repo
(Section B4), rebuilt, and uploaded with `lite-nexus-upload`. Tell the user
exactly which package name to add to `config/packages/nexus-extra.txt`.

Docker images: `docker pull <image>` goes through the Nexus mirror. If it
fails, the image is not in Nexus; it has to be added to
`config/docker-images.txt` at home or pushed with
`docker tag <img> <NEXUS_DOCKER_REGISTRY>/library/<img> && docker push ...`
from a machine that has it.

### A3. Connect to the office (Nexus, Active Directory)

```bash
sudo lite-setup            # interactive: Nexus URL, apt repo, docker registry, AD realm, KDCs, OWA, hosts
sudo lite-setup --show     # current values
sudo lite-setup --test     # HTTPS to Nexus, apt update, docker registry, KDC port 88
```

Values the user must provide: `NEXUS_URL` (https://host), `NEXUS_DOCKER_REGISTRY`
(host:port), `AD_REALM` (UPPER.CASE), `AD_DOMAIN` (lower.case), `AD_KDC`
(domain controller names or IPs), `OWA_URL`, and `NEXUS_IP` / `EXTRA_HOSTS`
when the network has no DNS.

Common failures:
* certificate error → office CA missing: copy to
  `/usr/local/share/ca-certificates/office-ca.crt`, `sudo update-ca-certificates`.
* `NO_PUBKEY` on apt → image built without `make keys`; Nexus repo key differs. Rebuild at home.
* `kinit: Cannot find KDC` → set `AD_KDC` and/or `EXTRA_HOSTS` in `lite-setup`.

Kerberos ticket (needed for SSO, SMB with `sec=krb5`, Pidgin Kerberos):
```bash
lite-login          # = kinit $USER@$AD_REALM
klist               # verify
```

### A4. Email (Thunderbird / OWA)

OWA: `Super+m` or `lite-owa` (Chrome app window; needs `OWA_URL`).

Thunderbird (`sudo apt install thunderbird` from Nexus):
1. Thunderbird > Account Settings > Account Actions > Add Mail Account.
2. Name, email `user@<AD_DOMAIN>`, password. Click *Configure manually*.
3. Choose **Exchange**. Hostname: the OWA host (e.g. `mail.<AD_DOMAIN>`).
   Username `<NETBIOS>\user`. If auto-discovery fails, EWS URL is
   `https://mail.<AD_DOMAIN>/EWS/Exchange.asmx`.
4. Done. Calendar appears under the same account.

### A5. Skype for Business chat (Pidgin + SIPE)

`Super+s` or `pidgin`. Accounts > Manage Accounts > Add:

| Field | Value |
|---|---|
| Protocol | Office Communicator |
| Username | `user@<AD_DOMAIN>` (SIP address) |
| Login | `<NETBIOS>\user` |
| Password | AD password (empty if Authentication = Kerberos) |
| Advanced > Server | empty (auto) or `sfb-fe.<AD_DOMAIN>:5061` |
| Advanced > Connection type | TLS |
| Advanced > Authentication scheme | Kerberos (after `lite-login`) or NTLM |

Chat, presence and group chat work. Audio/video do not (no Linux SfB client).

### A5a. Wi-Fi

`iwctl` → `station wlan0 scan`, `station wlan0 get-networks`,
`station wlan0 connect "SSID"`. Details, enterprise (802.1X) config and the
MacBook Pro 2016 hardware table are in `laptop.md`.

### A6a. Firewall (someone is scanning me)

```bash
sudo lite-fw watch                 # live dropped attempts: source, port
sudo lite-fw top -24h              # per-IP summary
sudo lite-fw block 10.1.2.3        # persistent block; unblock to undo
sudo lite-fw allow 10.1.5.0/24 && sudo lite-fw mode allowlist   # only these may reach open ports
sudo lite-fw open 3000             # expose a port (tcp) / close 3000
```
Hosts probing closed TCP ports are auto-banned (default 1h, `ban-time`).
Allowlisted IPs are never banned. `mode allowlist` refuses to lock the user
out (empty list or ssh client not listed).

### A6. Windows shares and RDP

```bash
sudo mount -t cifs //server/share /mnt/x -o sec=krb5,cruid=$USER,uid=$USER   # with ticket
sudo mount -t cifs //server/share /mnt/x -o user=USER,domain=NETBIOS,uid=$USER
xfreerdp3 /v:host /u:'NETBIOS\user' /dynamic-resolution /clipboard /cert:tofu
```

### A7. Running an AI agent (opencode) on this machine

The machine has no internet, so the agent must talk to a model served
inside the office. Two options:

* An internal OpenAI-compatible endpoint (vLLM, llama.cpp server, Ollama on
  a GPU box). Config `~/.config/opencode/opencode.json`:
  ```json
  {
    "$schema": "https://opencode.ai/config.json",
    "provider": {
      "office": {
        "npm": "@ai-sdk/openai-compatible",
        "name": "Office LLM",
        "options": { "baseURL": "http://llm.<AD_DOMAIN>:8000/v1" },
        "models": { "qwen3.5": { "name": "Qwen 3.5" } }
      }
    },
    "model": "office/qwen3.5"
  }
  ```
* Locally with Ollama in Docker (CPU only, small models):
  ```bash
  docker run -d --name ollama -p 11434:11434 -v ollama:/root/.ollama ollama/ollama
  # the model weights must come via Nexus (raw repo) or a docker image built at home,
  # e.g. `docker save` of an image that already contains /root/.ollama
  ```
  then `baseURL: "http://127.0.0.1:11434/v1"`.

`opencode` is pre-installed on the image (`/usr/local/bin/opencode`, from
`config/github-binaries.txt`). An example config is at
`/usr/share/doc/ubuntu-lite/opencode.example.json`; copy it to
`~/.config/opencode/opencode.json` and set the endpoint. Put this
`AGENTS.md` (it is in your home directory) in every project you open so the
agent knows these rules.

---

## B. In the build repository

### B1. Layout

```
config/build.env            all knobs: user, kernel, Nexus/AD defaults, timezone
config/packages/base.txt    boot, systemd, network, ssh, admin tools
config/packages/docker.txt  Docker CE
config/packages/gui.txt     sway, foot, fuzzel, pipewire, Chrome
config/packages/tools.txt   nethogs, tcpdump
config/packages/corporate.txt  krb5-user, pidgin-sipe, cifs-utils, freerdp3-x11
config/packages/firmware.txt   per-vendor firmware packages (Broadcom Wi-Fi on, Intel Wi-Fi commented)
config/packages/laptop.txt     iwd, iw, wireless-regdb, brightnessctl, upower (PROFILE_LAPTOP=1)
config/packages/nexus-extra.txt  downloaded to pool/extra ONLY (not installed): libreoffice, gimp, thunderbird, evolution ...
config/docker-images.txt    images bundled on the ISO and pushed to Nexus
config/github-binaries.txt  static binaries (helix, ruff, biome, lazydocker, bandwhich, systemctl-tui, opencode)
config/vscode-extensions.txt  only used if VS Code is re-added to gui.txt
config/ca/*.crt             office CA certificates baked into the trust store
config/nexus/apt-signing.pub.asc  apt repo key (make keys); private half is git-ignored
config/authorized_keys      ssh public keys for the user
overlay/                    files copied verbatim into the root filesystem
  overlay/usr/lib/ubuntu-lite/install.sh   the unattended installer
  overlay/usr/lib/ubuntu-lite/lite-setup   runtime office configuration
  overlay/etc/initramfs-tools/scripts/lite live boot (boot=lite)
  overlay/etc/skel/.config/sway/config     default key bindings
build/build.sh              stages: rootfs packages customize pool squashfs iso
build/keys.sh               GPG key for the Nexus apt repository
scripts/nexus-upload.sh     ISO content -> Nexus (apt, docker, raw)
scripts/test-qemu.sh        install / boot tests in QEMU
docs/                       first-boot, nexus-setup, airgap-workflow, corporate, design
out/                        build output (git-ignored): ISO, pool/, seed/, size-report.txt
```

### B2. Build and test

```bash
make keys                       # once
sudo apt install mmdebstrap squashfs-tools xorriso grub-efi-amd64-bin grub-pc-bin mtools dosfstools gnupg curl jq apt-utils ovmf qemu-system-x86 qemu-utils
make build                      # ~20 min, needs docker for image seeds
make resume FROM=customize      # after changing overlay/ or config (no package changes)
make resume FROM=packages       # after changing config/packages/*
make test && make test-boot     # QEMU install + boot (slow without /dev/kvm)
cat out/size-report.txt
```

`build/build.sh` must run as root. Stages can be re-run individually with
`--only <stage>`; `--from <stage>` continues to the ISO.

### B3. Add or remove software in the image

* Install on every machine: add the package name to the matching
  `config/packages/*.txt`, then `make resume FROM=packages`.
* Only available in Nexus (installed on demand): add to
  `config/packages/nexus-extra.txt`. This is the preferred place for
  anything large or rarely used.
* Remove: delete the line, `make resume FROM=packages`. The packages stage
  purges packages that are no longer listed (the lists are authoritative).
* Check a package exists in Ubuntu noble before adding it:
  `apt-cache policy <name>` on any Ubuntu 24.04, or
  `chroot out/work/rootfs apt-cache policy <name>` after a build.
* Docker images: `config/docker-images.txt` (use slim/alpine tags).
* Static binaries from GitHub: `config/github-binaries.txt`
  (`name|owner/repo|asset-template|binary-in-archive|tag-prefix|extra-copy`,
  `{tag}`/`{ver}` expand; archives .tar.gz/.tar.xz/.zip or a bare binary).
* Editor language servers: `overlay/etc/skel/.config/helix/languages.toml`.
* Files or configuration on every machine: put them under `overlay/` with
  the final absolute path, `make resume FROM=customize`.

### B4. Bringing a new build to the office

1. `make build` at home, copy `out/ubuntu-lite-latest.iso` to a USB stick (`dd`).
2. In the office, on a machine: mount the stick,
   `NEXUS_USER=admin lite-nexus-upload --src /mnt all`.
3. Machines: `sudo apt update && sudo apt upgrade`, or reinstall from the
   stick (GRUB entry "Reinstall") for a clean image.

### B5. Office defaults in the image

`config/build.env` keys `NEXUS_URL NEXUS_APT_REPO NEXUS_DOCKER_REGISTRY
NEXUS_DOCKER_INSECURE NEXUS_IP AD_REALM AD_DOMAIN AD_KDC OWA_URL EXTRA_HOSTS`
become `/etc/ubuntu-lite/site.conf` in the image and are applied by
`lite-setup --apply` at build time. Users can override them later with
`sudo lite-setup` on the machine. Both paths run the same script:
`overlay/usr/lib/ubuntu-lite/lite-setup`.

### B6. Building on Windows

`build/build.sh` needs a Linux kernel with root (chroot, bind mounts). From
Windows use one of:

* **WSL2 with Ubuntu 24.04** (recommended): `wsl --install -d Ubuntu-24.04`,
  then inside it the same `sudo apt install ...` and `make build` as on
  Linux. Docker for the image seeds: Docker Desktop with WSL integration, or
  `sudo apt install docker.io` inside WSL. `make test` works if
  `/dev/kvm` exists in WSL (Windows 11 with nested virtualization), otherwise
  it is slow; alternatively boot the ISO in a Hyper-V Generation 2 VM
  (Secure Boot off or "Microsoft UEFI Certificate Authority" template).
* **Docker Desktop only**: `make docker-build` runs the build in a
  privileged Linux container; no WSL shell needed. QEMU test not available.
* **GitHub Actions**: every push builds the ISO and runs the QEMU tests
  (`.github/workflows/build.yml`); download the artifact from the run.

Write the ISO to USB with Rufus in *DD image* mode (not ISO mode) or
balenaEtcher.

### B7. Things that look like bugs but are design

* `apt install chromium` would install a snap; the image uses Google Chrome's deb.
* No `linux-modules-extra` on 7.x HWE kernels: all drivers are in `linux-modules`.
* The installer refuses to wipe a disk that already holds ubuntu-lite unless
  booted with the "Reinstall" GRUB entry (`lite.force=1`).
* sshd does not start on the live medium (no host keys); `lite-firstboot`
  generates them on the installed system.
