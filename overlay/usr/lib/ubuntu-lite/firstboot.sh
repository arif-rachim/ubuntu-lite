#!/bin/bash
# Runs once on the installed system.
set -euo pipefail
mkdir -p /var/lib/ubuntu-lite
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A
if ls /var/lib/ubuntu-lite/seed/*.tar >/dev/null 2>&1; then
	systemctl start docker
	for t in /var/lib/ubuntu-lite/seed/*.tar; do docker load -qi "$t" && rm -f "$t"; done
fi
touch /var/lib/ubuntu-lite/firstboot.done
