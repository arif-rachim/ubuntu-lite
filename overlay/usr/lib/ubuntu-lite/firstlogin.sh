#!/bin/bash
# Per-user one-time setup, called from /etc/profile.d/lite.sh.
set -u
mark="$HOME/.config/ubuntu-lite/firstlogin.done"
[ -f "$mark" ] && exit 0
mkdir -p "$(dirname "$mark")"
if command -v code >/dev/null && ls /usr/share/ubuntu-lite/vsix/*.vsix >/dev/null 2>&1; then
	echo "[lite] installing bundled VS Code extensions (one time) ..."
	for v in /usr/share/ubuntu-lite/vsix/*.vsix; do
		code --install-extension "$v" --force >/dev/null 2>&1 || echo "[lite] failed: $v"
	done
fi
touch "$mark"
