# Air-gap workflow

```
 internet (home / GitHub Actions)          office network (no internet)
 ┌──────────────────────────────┐          ┌────────────────────────────────────┐
 │ make build  -> ISO           │  USB     │ Nexus (apt-lite, docker-lite,       │
 │   pool/   every .deb         │ ───────► │        raw-lite)                    │
 │   seed/   images, vsix, bins │          │    ▲ lite-nexus-upload              │
 │                              │          │    │                                │
 │                              │          │ machines: boot USB -> auto install  │
 │                              │          │           apt / docker via Nexus    │
 └──────────────────────────────┘          └────────────────────────────────────┘
```

## Installing a machine

1. Write the ISO to a USB stick (`dd`), boot the machine from it (UEFI, Secure
   Boot off or on; the image ships the signed shim).
2. Wait. The installer wipes the largest internal disk, copies the system,
   installs GRUB, seeds the docker images, and reboots. About 5 minutes.
3. Remove the stick. Log in as the configured user, set a new password. On
   tty1 sway starts automatically.

Dozens of machines: same stick, same steps. Hostnames are derived from the
first NIC's MAC (`lite-a1b2c3`) unless `lite.hostname=` is given at the GRUB
prompt.

## Updating packages (security or new tools)

There is no `unattended-upgrades`. Updates are a deliberate act:

1. At home: `git pull`, adjust `config/packages/*.txt` if needed, `make build`.
   The pool now contains the current Ubuntu security updates plus the latest
   Docker / Chrome / VS Code.
2. Carry the ISO to the office, `lite-nexus-upload --src /mnt apt` (and
   `docker`, `raw` when images or extensions changed).
3. On each machine: `sudo apt update && sudo apt upgrade`.

Because the machines only know the Nexus source, `apt` never tries the
internet and never hangs on a timeout.

Kernel updates arrive the same way (`linux-image-virtual-hwe-24.04` is marked
manual so `apt upgrade` pulls in the new kernel; reboot afterwards).

## Reinstalling / upgrading whole machines

Boot the new ISO and pick "Reinstall" in GRUB. The default entry refuses to
wipe a disk that already has ubuntu-lite on it, so a stick left in a machine
cannot cause an install loop.

## Adding a package that is not in the pool

```bash
# at home, on any Ubuntu 24.04 (or the build chroot): resolve deps against the image
echo termshark >> config/packages/nexus-extra.txt   # downloaded, not installed
make build                                          # pool/extra now has it and its deps
```

Then upload and `sudo apt install termshark` in the office.

## Docker images

`config/docker-images.txt` lists what is bundled. In the office:

```bash
docker pull node:22-slim                       # via registry-mirrors -> Nexus
docker pull nexus.office.local:8443/library/postgres:16-alpine
```

For images you build yourself, push them to Nexus from any machine:
`docker tag myapp nexus.office.local:8443/myapp:1 && docker push ...`.

## Editor tooling

Helix, ruff, biome, lazydocker, bandwhich, systemctl-tui and opencode are
static binaries listed in `config/github-binaries.txt`; a rebuild picks up
their newest release and the ISO's `seed/bin` (uploaded to `raw-lite/lite/bin/`)
lets machines fetch them without a reinstall.

## Node / Python / PostgreSQL

The host has none of these. Use containers, for example a `compose.yaml`:

```yaml
services:
  app:
    image: node:22-slim
    working_dir: /app
    volumes: [".:/app"]
    command: sh -c "npm ci && npm run dev"
    ports: ["3000:3000"]
  db:
    image: postgres:16-alpine
    environment: { POSTGRES_PASSWORD: dev }
    ports: ["5432:5432"]
```

npm packages need a registry: create an npm
(hosted) repository in Nexus, publish what you need, and set
`npm config set registry https://nexus.office.local/repository/npm-lite/`.
