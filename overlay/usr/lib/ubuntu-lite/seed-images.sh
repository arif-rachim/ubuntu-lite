#!/bin/bash
# Loads the docker images bundled on the ISO into the local docker store, once.
set -uo pipefail
n=0
for t in /var/lib/ubuntu-lite/seed/*.tar; do
	[ -f "$t" ] || continue
	if docker load -qi "$t"; then rm -f "$t"; n=$((n + 1)); else echo "failed to load $t" >&2; fi
done
rmdir /var/lib/ubuntu-lite/seed 2>/dev/null || true
echo "<3>lite: seed images done ($n loaded)" > /dev/kmsg 2>/dev/null || true
