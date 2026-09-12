# Build container for hosts that are not Ubuntu 24.04. Needs --privileged (chroot, loop, mounts).
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    mmdebstrap squashfs-tools xorriso grub-efi-amd64-bin grub-pc-bin grub-common mtools dosfstools \
    gnupg curl jq ca-certificates ubuntu-keyring apt-utils openssl git docker.io \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
ENTRYPOINT ["/bin/bash"]
