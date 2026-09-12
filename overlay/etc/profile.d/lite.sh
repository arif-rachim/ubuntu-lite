# ubuntu-lite: one-time per-user setup, and auto-start sway on tty1
if [ -n "${BASH_VERSION:-}" ] && [ "$(id -u)" != 0 ]; then
	[ -x /usr/lib/ubuntu-lite/firstlogin.sh ] && /usr/lib/ubuntu-lite/firstlogin.sh
	if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && command -v sway >/dev/null; then
		export XDG_CURRENT_DESKTOP=sway
		export ELECTRON_OZONE_PLATFORM_HINT=auto
		export MOZ_ENABLE_WAYLAND=1
		exec sway >"$HOME/.sway.log" 2>&1
	fi
fi
