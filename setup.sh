#!/usr/bin/env bash
#===============================================================================
# Claude appliance provisioning — Phase 1 (single user)
#
# Takes a fresh Debian 12+/Ubuntu 24.04+ box to a working headless
# Claude Desktop appliance: engine installed, XFCE session over the
# selected profile, cloudflared skeleton, XDG autostart, doctor.
#
# Usage:
#   sudo appliance/setup.sh [--engine auto|official|repo]
#                           [--profile kasmvnc|xrdp|overlay]
#                           [--user NAME] [--hostname FQDN]
#                           [--cf-api-token-file FILE]
#                           [--access-allow EMAIL_OR_DOMAIN[,...]]
#                           [--dry-run] [--force]
#   appliance/setup.sh doctor [--user NAME]
#
# Zero-touch mode: with --cf-api-token-file (scoped Cloudflare token:
# Tunnel:Edit, Access Apps:Edit, DNS:Edit) the tunnel, DNS record, and
# Access policy are provisioned via the API — no interactive
# `cloudflared tunnel login`. --access-allow is REQUIRED in this mode:
# a tunneled hostname without an Access app is public.
#
# Design: docs/design.md
# Spec:   docs/phases.md
#===============================================================================

cws_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "$cws_dir/lib/common.sh"
# shellcheck source=lib/engine.sh
source "$cws_dir/lib/engine.sh"
# shellcheck source=lib/doctor.sh
source "$cws_dir/lib/doctor.sh"
# shellcheck source=lib/tunnel-api.sh
source "$cws_dir/lib/tunnel-api.sh"
# shellcheck source=lib/profiles/kasmvnc.sh
source "$cws_dir/lib/profiles/kasmvnc.sh"
# shellcheck source=lib/profiles/xrdp.sh
source "$cws_dir/lib/profiles/xrdp.sh"
# shellcheck source=lib/profiles/overlay.sh
source "$cws_dir/lib/profiles/overlay.sh"

usage() {
	sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Interactive wizard: fill missing flags from the terminal so the
# dev bootstrap is just `git clone ... && sudo appliance/setup.sh`.
# Non-interactive runs (cloud-init, CI pipes) skip the prompts and
# rely on flags. Reads/writes main()'s locals via dynamic scoping.
# APPLIANCE_ASSUME_TTY=1 forces the prompts (test seam).
prompt_missing_flags() {
	if [[ ${APPLIANCE_ASSUME_TTY:-0} -ne 1 && ! -t 0 ]]; then
		return 0
	fi
	# printf the prompts explicitly: bash suppresses `read -p` output
	# when stdin is not a terminal, which breaks the test seam.
	if [[ -z $hostname ]]; then
		printf 'Public hostname (blank = skip tunnel setup): ' >&2
		read -r hostname
	fi
	if [[ -n $hostname && -z $token_file ]]; then
		printf 'Cloudflare API token file (blank = manual tunnel): ' \
			>&2
		read -r token_file
	fi
	if [[ -n $token_file && -z $access_allow ]]; then
		printf 'Access allow list (emails/domains, comma-sep): ' >&2
		read -r access_allow
	fi
}

install_session_stack() {
	pkg_install xfce4 xfce4-terminal dbus-x11 \
		gnome-keyring libsecret-1-0 libpam-gnome-keyring
}

# XDG autostart so Claude Desktop launches with the session; upstream
# close-to-tray keeps it alive afterwards.
install_autostart() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 1
	local dir="$home/.config/autostart"

	run_as_user "$user" mkdir -p "$dir" || return 1
	autostart_entry | write_file "$dir/claude-desktop.desktop" || return 1
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		chown "$user:$user" "$dir/claude-desktop.desktop"
	fi
}

autostart_entry() {
	cat << 'EOF'
[Desktop Entry]
Type=Application
Name=Claude
Exec=claude-desktop
X-GNOME-Autostart-enabled=true
EOF
}

main() {
	local engine='auto' profile='kasmvnc' user='' hostname=''
	local token_file='' access_allow=''
	local mode='setup'
	appliance_dry_run=0
	appliance_force=0

	if [[ ${1:-} == 'doctor' ]]; then
		mode='doctor'
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--engine)            engine="$2"; shift 2 ;;
			--profile)           profile="$2"; shift 2 ;;
			--user)              user="$2"; shift 2 ;;
			--hostname)          hostname="$2"; shift 2 ;;
			--cf-api-token-file) token_file="$2"; shift 2 ;;
			--access-allow)      access_allow="$2"; shift 2 ;;
			--dry-run)           appliance_dry_run=1; shift ;;
			--force)             appliance_force=1; shift ;;
			-h|--help)           usage; return 0 ;;
			*)
				log_err "unknown argument '$1'"
				usage
				return 1
				;;
		esac
	done

	case "$profile" in
		kasmvnc|xrdp|overlay) ;;
		*)
			log_err "unknown profile '$profile'"
			return 1
			;;
	esac

	if [[ $mode == 'setup' ]]; then
		prompt_missing_flags
	fi

	local tunnel_mode='manual'
	if [[ -n $token_file ]]; then
		tunnel_mode='api'
		if [[ -z $hostname ]]; then
			log_err '--cf-api-token-file requires --hostname'
			return 1
		fi
		if [[ -z $access_allow ]]; then
			log_err '--cf-api-token-file requires --access-allow'
			log_err '  (a tunneled hostname without an Access' \
				'policy is public)'
			return 1
		fi
	fi

	user=$(resolve_target_user "$user") || return 1

	if [[ $mode == 'doctor' ]]; then
		run_appliance_doctor "$user"
		return
	fi

	require_root || return 1

	local distro
	distro=$(appliance_distro_id)
	case "$distro" in
		debian|ubuntu) ;;
		*)
			log_err "unsupported distro '$distro' (Debian 12+/Ubuntu" \
				'22.04+ required)'
			return 1
			;;
	esac

	log_info "provisioning appliance for user '$user'" \
		"(profile: $profile)"

	select_engine "$engine" || return 1
	log_info "engine: $engine_choice — $engine_reason"

	run_cmd apt-get update || return 1
	install_session_stack || return 1
	install_engine "$user" || return 1

	# Record the deployment shape for member.sh and the doctor.
	{
		printf 'profile=%s\n' "$profile"
		printf 'hostname=%s\n' "$hostname"
	} | appliance_force=1 write_file "$appliance_etc/appliance.conf" \
		|| return 1

	case "$profile" in
		kasmvnc)
			profile_kasmvnc_apply "$user" "$hostname" \
				"$tunnel_mode" "$token_file" "$access_allow" \
				|| return 1
			;;
		xrdp)    profile_xrdp_apply "$user" || return 1 ;;
		overlay)
			profile_overlay_apply || return 1
			# Overlay still needs a session layer; xrdp is the
			# protocol-native fit for tailnet clients.
			profile_xrdp_apply "$user" || return 1
			;;
	esac

	install_autostart "$user" || return 1

	log_info 'provisioning complete. Next steps:'
	log_info "  - log into the session once as '$user' to create the"
	log_info '    keyring and sign into Claude'
	log_info '  - run: ./setup.sh doctor'
	if [[ $profile == 'kasmvnc' && -n $hostname \
		&& $tunnel_mode == 'manual' ]]; then
		log_info '  - finish the cloudflared tunnel steps printed above'
	fi
}

# Only run when executed, so the BATS suite can source the functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
