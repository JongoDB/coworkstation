# shellcheck shell=bash
#===============================================================================
# Overlay profile — Tailscale break-glass / alternative edge
#
# For teams that can't accept an identity-aware proxy, and as the
# documented recovery path when the tunnel or IdP is down. Installs
# tailscale from the vendor apt repo; joining the tailnet is
# interactive and left to the operator.
#===============================================================================

profile_overlay_apply() {
	local keyring='/usr/share/keyrings/tailscale-archive-keyring.gpg'
	local list='/etc/apt/sources.list.d/tailscale.list'
	local distro codename
	distro=$(appliance_distro_id)
	codename=$(appliance_distro_codename)

	if command -v tailscale > /dev/null 2>&1; then
		log_info 'tailscale already installed'
	else
		if [[ ! -f $keyring ]]; then
			if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
				printf 'DRY-RUN: install tailscale apt key -> %s\n' \
					"$keyring"
			else
				curl -fsSL \
					"https://pkgs.tailscale.com/stable/$distro/$codename.noarmor.gpg" \
					-o "$keyring" || return 1
			fi
		fi
		printf 'deb [signed-by=%s] %s %s main' "$keyring" \
			"https://pkgs.tailscale.com/stable/$distro" \
			"$codename" | write_file "$list" || return 1
		run_cmd apt-get update || return 1
		pkg_install tailscale || return 1
	fi

	log_info 'tailscale installed. Join the tailnet interactively:'
	log_info '  sudo tailscale up --ssh'
	log_info 'Tag the node (tag:cowork-appliance) and scope member'
	log_info 'access with tailnet ACLs.'
}
