# First boot guide

What to do on a freshly installed ubuntu-lite machine, in order. Everything
here is done once per machine; step 2 can be repeated whenever an address
changes.

## 1. Log in and change the password

Log in on tty1 as the user from `config/build.env` (default `dev`, password
`changeme`). The system forces a new password immediately. sway starts by
itself; `Super+Enter` opens a terminal. `lite-help` prints the cheat sheet.

## 2. Point the machine at the office: `sudo lite-setup`

`lite-setup` asks for every address, shows the value baked into the image in
brackets, and writes the configuration for apt, docker, Kerberos, Chrome and
`/etc/hosts` in one go:

```
sudo lite-setup
  NEXUS_URL             https://nexus.office.local
  NEXUS_APT_REPO        apt-lite
  NEXUS_DOCKER_REGISTRY nexus.office.local:8443
  NEXUS_DOCKER_INSECURE 0
  NEXUS_IP              10.1.1.10         (only when there is no DNS)
  AD_REALM              CORP.EXAMPLE.COM  (the AD domain, upper case)
  AD_DOMAIN             corp.example.com
  AD_KDC                dc1.corp.example.com dc2.corp.example.com
  OWA_URL               https://mail.corp.example.com/owa
  EXTRA_HOSTS           10.1.1.5 dc1.corp.example.com dc1|10.1.1.20 mail.corp.example.com
sudo lite-setup --test
```

`--test` checks Nexus over HTTPS, `apt update`, the docker registry and the
KDC port. If HTTPS fails with a certificate error, the office CA is missing:
copy it to `/usr/local/share/ca-certificates/office-ca.crt` and run
`sudo update-ca-certificates`, or add it to `config/ca/` before the next build.

For many machines, write the answers once to a file and run
`sudo lite-setup --file office.conf` (KEY=value lines). `sudo lite-setup
--show` prints the current values, `--set KEY=VALUE` changes one.

## 3. Fill Nexus (first machine only)

Nexus is empty until the ISO content is uploaded. From this machine, with the
USB stick still at hand:

```bash
sudo mount /dev/sdb /mnt            # the stick, whole device
NEXUS_USER=admin lite-nexus-upload --src /mnt all
sudo umount /mnt
```

Details and the Nexus-side repository settings are in `nexus-setup.md`.

## 4. Verify that software installs from Nexus

```bash
sudo apt update
sudo apt install ncdu               # small test package from pool/extra
docker pull node:22-slim            # through the registry mirror
```

Everything that is not on the image lives in Nexus and installs the same way:

| Need | Install | Notes |
|---|---|---|
| Office documents | `sudo apt install libreoffice-writer libreoffice-calc libreoffice-impress fonts-crosextra-carlito fonts-crosextra-caladea` | ~450 MB |
| Images | `sudo apt install gimp` | ~150 MB |
| Mail client | `sudo apt install thunderbird` | see step 6 |
| Outlook-like mail + calendar | `sudo apt install evolution evolution-ews` | ~400 MB |
| RDP with saved connections | `sudo apt install remmina` | `xfreerdp3` is already on the image |
| File manager with smb:// | `sudo apt install pcmanfm gvfs-backends` | |
| Packet analysis | `sudo apt install termshark` | |

## 5. Kerberos ticket (single sign-on)

```bash
lite-login                # kinit you@CORP.EXAMPLE.COM, asks for the AD password
klist                     # ticket valid 10 h, renewable 7 days
```

Repeat after each reboot (or when `klist` shows nothing). With a ticket,
Chrome opens intranet sites and OWA without a login page, SMB mounts need no
password, and Pidgin can use Kerberos.

## 6. Email

* **OWA**: `Super+m` opens Outlook Web App as an app window. This is the
  full Outlook experience in the browser: mail, calendar, contacts, address
  book, out-of-office.
* **Thunderbird** (after `sudo apt install thunderbird`): Account Settings >
  Add Mail Account > enter name, `you@corp.example.com`, password > Configure
  manually > Exchange. Host `mail.corp.example.com`, username `CORP\you`. If
  auto-discovery fails, use EWS URL
  `https://mail.corp.example.com/EWS/Exchange.asmx`. The calendar appears
  under the same account.

## 7. Skype for Business chat (Pidgin)

`Super+s` starts Pidgin. Accounts > Manage Accounts > Add:

| Tab | Field | Value |
|---|---|---|
| Basic | Protocol | Office Communicator |
| Basic | Username | `you@corp.example.com` (your SIP address) |
| Basic | Login | `CORP\you` |
| Basic | Password | AD password (leave empty when Authentication = Kerberos) |
| Advanced | Server | empty for auto-discovery, else `sfb-fe.corp.example.com:5061` |
| Advanced | Connection type | TLS |
| Advanced | Authentication scheme | Kerberos (needs `lite-login`) or NTLM |

Chat, presence, group chat and contact search work. Audio and video calls do
not (no Linux client for SfB); use the SfB Web App in Chrome for meetings.

## 8. Windows shares and RDP

```bash
# browse and mount a share (Kerberos ticket, no password prompt)
sudo mkdir -p /mnt/share
sudo mount -t cifs //fileserver.corp.example.com/projects /mnt/share -o sec=krb5,cruid=$USER,uid=$USER
# or with a password
sudo mount -t cifs //fileserver/projects /mnt/share -o user=you,domain=CORP,uid=$USER

# remote desktop, like mstsc
xfreerdp3 /v:winbox.corp.example.com /u:'CORP\you' /dynamic-resolution /clipboard /cert:tofu
```

Add `/drive:home,$HOME` to expose your home directory inside the RDP
session, `/sound` for audio. Persistent shares go into `/etc/fstab` with
`,_netdev,noauto,x-systemd.automount`.

## 9. Daily development

```bash
mkdir ~/work && cd ~/work && git clone ...
hx .                       # Helix editor (Super+c), ruff + biome language servers, see editor.md
# Node / Python / PostgreSQL run in containers, see airgap-workflow.md
docker compose up -d
lazydocker                 # containers on/off, logs
httpmon                    # HTTP(S) traffic like the DevTools Network tab
```

## 10. Firewall: who may reach this machine

Inbound is closed except SSH. `lite-fw` shows who is knocking and lets you
block or allowlist them, all in nftables, no extra daemon:

```bash
sudo lite-fw status              # mode, open ports, blocked/allowed/auto-banned, last hits
sudo lite-fw watch               # live: time, source, destination, protocol, port of every dropped attempt
sudo lite-fw top -24h            # attempts per source IP with the ports they tried
lite-fw ports                    # what is listening on this machine
sudo lite-fw block 10.1.2.3      # persistent blocklist (also CIDR)   / unblock
sudo lite-fw allow 10.1.5.0/24   # allowlist, never auto-banned       / unallow
sudo lite-fw mode allowlist      # only allowlisted IPs may reach open ports (refuses if the list is empty
                                 # or your own ssh client is not in it); `mode open` reverts
sudo lite-fw open 3000           # open a port (3000/udp for UDP)     / close
sudo lite-fw ban-time 2h         # hosts probing closed TCP ports are auto-banned for this long
sudo lite-fw banned              # who is auto-banned right now       / unban IP
```

Published container ports (`-p 8080:80`) are covered by the same block and
allow lists. Office vulnerability scanners will get auto-banned too; put
their IPs in the allowlist if IT complains.

## Where things live

| Path | Purpose |
|---|---|
| `/etc/ubuntu-lite/site.conf` | office addresses written by `lite-setup` |
| `/etc/apt/sources.list.d/nexus.sources` | the only apt source |
| `/etc/docker/daemon.json` | registry mirror |
| `/etc/krb5.conf`, `/etc/opt/chrome/policies/managed/lite-sso.json` | Kerberos + Chrome SSO |
| `/etc/nftables.conf`, `/etc/nftables.d/`, `/etc/ubuntu-lite/fw*.txt` | firewall, rendered by `lite-fw` |
| `~/.config/sway/config` | key bindings |
| `/usr/share/doc/ubuntu-lite/` | these documents |
