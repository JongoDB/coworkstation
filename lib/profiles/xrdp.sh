# shellcheck shell=bash
#===============================================================================
# xrdp profile — protocol-native alternative session layer
#
# For members who prefer a real RDP client, or Cloudflare's
# browser-rendered RDP. Binds loopback only; the tunnel or overlay
# carries it. The launcher's XRDP session-type fixes (GPU compositing,
# crash auto-recovery) apply inside these sessions.
#===============================================================================

profile_xrdp_apply() {
	local user="$1"

	pkg_install xrdp xorgxrdp || return 1

	# Loopback-only: raw 3389 must never face a network interface.
	if [[ -f /etc/xrdp/xrdp.ini ]] || [[ ${appliance_dry_run:-0} -eq 1 ]]
	then
		run_cmd sed -i -E \
			's/^(port)=(3389)$/\1=tcp:\/\/127.0.0.1:\2/' \
			/etc/xrdp/xrdp.ini || return 1
	fi

	# xrdp's Xorg sessions need the user in the ssl-cert group on
	# Debian-family for the key material xrdp generates.
	run_cmd adduser xrdp ssl-cert || return 1

	xrdp_startwm "$user" || return 1

	run_cmd systemctl enable xrdp || return 1
	run_cmd systemctl restart xrdp || return 1

	log_info 'xrdp bound to 127.0.0.1:3389.'
	log_info 'Reach it via Cloudflare browser-rendered RDP or the'
	log_info 'overlay profile; never expose 3389 directly.'
}

# Per-user session command so xrdp launches XFCE, not the distro
# default that may not be installed.
xrdp_startwm() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 1

	printf '%s\n%s\n' '#!/bin/sh' 'exec startxfce4' \
		| write_file "$home/.xsession" 755 || return 1
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		chown "$user:$user" "$home/.xsession"
	fi
}
