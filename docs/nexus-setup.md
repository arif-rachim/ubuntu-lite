# Nexus setup (office side)

Nexus Repository OSS has no internet access in the office, so it does not
proxy anything. It only hosts what we upload from the ISO. Do this once; later
ISOs only need step 5.

Prerequisites on your side:

* The GPG key pair from `make keys` (`config/nexus/apt-signing.key.asc` is the
  private half, keep it on your laptop and in a password manager).
* Nexus reachable over HTTPS with a certificate issued by the office CA. The CA
  certificate is in the image (`config/ca/*.crt`). If Nexus is plain HTTP, set
  `NEXUS_URL=http://...` and `NEXUS_DOCKER_INSECURE=1` before building.
* The hostname in `NEXUS_URL` / `NEXUS_DOCKER_REGISTRY` resolves on the
  air-gapped network. There is no internal DNS, so set `NEXUS_IP` in
  `config/build.env`; the image gets an `/etc/hosts` entry.

## 1. Anonymous read access

Machines pull without credentials.

* Administration > Security > Anonymous Access: enable "Allow anonymous users
  to access the server".
* Administration > Security > Realms: add "Docker Bearer Token Realm" to the
  active list (needed for anonymous docker pull).

## 2. apt (hosted) repository

Administration > Repositories > Create repository > **apt (hosted)**

| Field | Value |
|---|---|
| Name | `apt-lite` (must match `NEXUS_APT_REPO`) |
| Distribution | `noble` |
| Signing Key | paste the whole content of `config/nexus/apt-signing.key.asc` |
| Passphrase | leave empty (key generated without one) |
| Deployment policy | Disable redeploy |

The public half is already baked into the image at
`/etc/apt/keyrings/nexus-apt.asc`, and the only apt source on the machines is
`<NEXUS_URL>/repository/apt-lite noble main`.

## 3. docker (hosted) repository

Administration > Repositories > Create repository > **docker (hosted)**

| Field | Value |
|---|---|
| Name | `docker-lite` |
| HTTPS connector | port `8443` (must match `NEXUS_DOCKER_REGISTRY=host:8443`) |
| Allow anonymous docker pull | checked |

Docker registries need their own port. Either enable HTTPS on Nexus itself
(Jetty, `nexus.properties` + the office certificate in a keystore) or
terminate TLS on a reverse proxy in front of Nexus and forward `:8443` to the
repository's HTTP connector. Open the port in the office firewall.

The machines have `registry-mirrors: ["https://<NEXUS_DOCKER_REGISTRY>"]` in
`/etc/docker/daemon.json`, so `docker pull node:22-slim` resolves through Nexus
when the image was pushed as `library/node:22-slim` (the upload script does
that). Images can also be pulled with the full name
`<NEXUS_DOCKER_REGISTRY>/library/node:22-slim`.

## 4. raw (hosted) repository

Administration > Repositories > Create repository > **raw (hosted)**, name
`raw-lite`. It holds VS Code `.vsix` files, the static binaries, the apt public
key and the ISO itself under `lite/`. Files are fetched with plain `curl` from
`<NEXUS_URL>/repository/raw-lite/lite/...`.

## 5. Upload the content of an ISO

On any machine on the office network with the USB stick (a freshly installed
ubuntu-lite box works, it has docker and the script):

```bash
sudo mount /dev/sdb /mnt              # the USB stick (whole device, not a partition)
NEXUS_USER=admin lite-nexus-upload --src /mnt all
```

`all` = `apt` (every deb in `pool/`), `docker` (every image in `seed/docker`),
`raw` (vsix, binaries, ISO). Re-running is safe, existing files are skipped.
The script is also at `/mnt/nexus/nexus-upload.sh` if you run it from another
Linux machine (`docker` and `curl` needed).

## 6. Verify from an installed machine

```bash
sudo apt update && apt policy htop        # source must be the Nexus URL
sudo apt install ncdu                     # something from pool/extra
docker pull node:22-slim                  # through the mirror
curl -O https://nexus.office.local/repository/raw-lite/lite/vsix/<file>.vsix
code --install-extension <file>.vsix
```

## Troubleshooting

* `apt update` says "certificate verify failed": the office CA is not in
  `config/ca/`, or the certificate's hostname does not match `NEXUS_URL`.
* `apt update` says "NO_PUBKEY": the image was built before `make keys`, or
  the key in Nexus differs from `config/nexus/apt-signing.pub.asc`. Rebuild.
* `docker pull` hangs then fails: registry-mirrors falls back to Docker Hub
  when the image is not in Nexus. Push it first.
* Nexus returns HTTP 400 on upload: the component already exists (deployment
  policy). Harmless.
