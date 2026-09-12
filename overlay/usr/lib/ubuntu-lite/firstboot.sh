#!/bin/bash
# Runs once on the installed system, before sshd.
set -euo pipefail
mkdir -p /var/lib/ubuntu-lite
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A
touch /var/lib/ubuntu-lite/firstboot.done
echo "<3>lite: first boot setup done" > /dev/kmsg 2>/dev/null || true
