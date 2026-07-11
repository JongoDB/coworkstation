#!/usr/bin/env bash
#===============================================================================
# Coworkstation provisioning — Phase 1 (single user)
#
# Takes a fresh Debian 12+/Ubuntu 24.04+ box to a working headless
# Claude Desktop workstation: engine installed, XFCE session over the
# selected profile, cloudflared skeleton, XDG autostart, doctor.
#
# Usage:
#   sudo ./setup.sh [--engine auto|official|repo]
#                   [--profile kasmvnc|xrdp|overlay]
#                   [--user NAME] [--hostname FQDN]
#                   [--cf-api-token-file FILE]
#                   [--access-allow EMAIL_OR_DOMAIN[,...]]
#                   [--dry-run] [--force]
#   sudo ./setup.sh doctor [--user NAME]
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
# shellcheck source=lib/clientsync.sh
source "$cws_dir/lib/clientsync.sh"
# shellcheck source=lib/fleet.sh
source "$cws_dir/lib/fleet.sh"
# shellcheck source=lib/clientbridge.sh
source "$cws_dir/lib/clientbridge.sh"
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

# Tools the provisioning path itself needs but a minimal cloud image
# does not ship: jq (every Cloudflare API call parses with it), openssl
# (per-user kasmVNC cert), gnupg (apt key dearmor for the repo engine),
# curl/ca-certificates (downloads). Installed before any of them run so
# the zero-touch flow doesn't die on a missing tool with a misleading
# error.
install_base_deps() {
	pkg_install jq openssl gnupg curl ca-certificates sshfs
}

# An always-on internet-reachable box must patch itself: install and
# switch on unattended-upgrades (the doctor otherwise WARNs forever).
install_reclaim_timer() {
	fleet_reclaim_service_unit \
		| write_file /etc/systemd/system/cws-reclaim.service \
		|| return 1
	fleet_reclaim_timer_unit \
		| write_file /etc/systemd/system/cws-reclaim.timer \
		|| return 1
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		return 0
	fi
	run_cmd systemctl daemon-reload || return 1
	run_cmd systemctl enable --now cws-reclaim.timer
}

enable_unattended_upgrades() {
	pkg_install unattended-upgrades || return 1
	printf '%s\n' \
		'APT::Periodic::Update-Package-Lists "1";' \
		'APT::Periodic::Unattended-Upgrade "1";' \
		| write_file /etc/apt/apt.conf.d/20auto-upgrades || return 1
}

install_session_stack() {
	pkg_install xfce4 xfce4-terminal dbus-x11 \
		gnome-keyring libsecret-1-0 libpam-gnome-keyring
}

# A kasmVNC/xrdp desktop is not a logind "local"/"active" seat, so
# colord's device/profile actions fall through to the admin-auth rule
# and pop "Authentication is required to create a color managed device"
# on every session start. A headless appliance does no colour
# management, so grant the whole color-manager action group and the
# prompt never appears. Emitted separately so it stays unit-testable.
colord_polkit_rule() {
	cat << 'EOF'
// Coworkstation: silence colord's PolicyKit prompt in headless
// VNC/RDP sessions (they are not local seats, so the default rule
// asks for a password). No colour management is needed here.
polkit.addRule(function(action, subject) {
	if (action.id.indexOf("org.freedesktop.color-manager.") === 0) {
		return polkit.Result.YES;
	}
});
EOF
}

install_polkit_rules() {
	colord_polkit_rule \
		| write_file /etc/polkit-1/rules.d/40-cws-colord.rules
}

# Resolve the session user, minting a default unprivileged account when
# running as root with nothing to fall back on — the fresh-VPS case
# where `curl | sudo bash` has no $SUDO_USER and no non-root account
# exists yet. An explicit --user or a real $SUDO_USER is used as-is; an
# explicit name that does not exist is still an error (handled before
# the root gate). Must run after require_root.
ensure_target_user() {
	local explicit="$1"
	local candidate="${explicit:-${SUDO_USER:-}}"
	if [[ -n $candidate && $candidate != 'root' ]]; then
		printf '%s' "$candidate"
		return 0
	fi
	local default_user="${APPLIANCE_DEFAULT_USER:-cowork}"
	if ! id "$default_user" > /dev/null 2>&1; then
		# This function's stdout IS its return value (captured with
		# $(...)), so the progress line MUST go to stderr — otherwise it
		# pollutes $user and every later user_home lookup fails.
		log_info "no --user given; creating default account" \
			"'$default_user'" >&2
		run_cmd useradd -m -s /bin/bash "$default_user" >&2 || return 1
	fi
	# Match member.sh: a session home is private (0700). The distro
	# umask leaves it 0755/0750; on a box that may gain members later,
	# the control user's home should be no more open than theirs.
	local home
	home=$(user_home "$default_user" 2> /dev/null) \
		&& [[ -d $home ]] && run_cmd chmod 700 "$home"
	printf '%s' "$default_user"
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

# Re-apply the idempotent config a fresh setup writes but a code-only
# `cws update` cannot reach: one user's generated session config
# (xstartup/yaml) + autostart. System policy is handled once in
# run_reconfigure. Touches no packages, tunnel, quotas, or services.
reconfigure_user() {
	local user="$1"
	local port="$2"
	local profile="$3"
	case "$profile" in
		kasmvnc) profile_kasmvnc_write_config "$user" "$port" \
			|| return 1 ;;
	esac
	install_autostart "$user"
}

# `cws reconfigure`: re-apply config to a running box after a `cws
# update` so shipped config fixes (polkit rules, xstartup changes) land
# without a full re-provision. Idempotent; changes take effect on the
# next session start.
run_reconfigure() {
	local user="$1"
	require_root || return 1
	# The whole point is to REPLACE stale config, but write_file keeps
	# existing files unless forced — so force it here (these are all
	# generated files, safe to rewrite). Local so it does not leak.
	local appliance_force=1
	local conf="$appliance_etc/appliance.conf"
	local profile
	profile=$(grep -m1 '^profile=' "$conf" 2> /dev/null | cut -d= -f2)
	profile="${profile:-kasmvnc}"
	log_info "reconfigure: re-applying config (profile: $profile)"
	install_polkit_rules || return 1
	reconfigure_user "$user" "$appliance_kasm_base_port" "$profile" \
		|| return 1
	local reg="$appliance_etc/members.tsv"
	if [[ -f $reg ]]; then
		local name display port _rest
		while IFS=$'\t' read -r name display port _rest; do
			[[ -z $name ]] && continue
			log_info "  member '$name' (display :$display)"
			reconfigure_user "$name" "$port" "$profile" || return 1
		done < "$reg"
	fi
	log_info 'reconfigure complete; effective on next session start'
}

# Exec goes through the cws-launch guardian: it rotates config backups
# (the config-wipe recovery path) and then execs the real launcher.
autostart_entry() {
	cat << 'EOF'
[Desktop Entry]
Type=Application
Name=Claude
Exec=cws-launch
X-GNOME-Autostart-enabled=true
EOF
}

main() {
	local engine='auto' profile='kasmvnc' user='' hostname=''
	local token_file='' access_allow=''
	local mode='setup'
	appliance_dry_run=0
	appliance_force=0

	case "${1:-}" in
		doctor)      mode='doctor'; shift ;;
		reconfigure) mode='reconfigure'; shift ;;
	esac

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--engine)     require_value "$@" || return 1
			              engine="$2"; shift 2 ;;
			--profile)    require_value "$@" || return 1
			              profile="$2"; shift 2 ;;
			--user)       require_value "$@" || return 1
			              user="$2"; shift 2 ;;
			--hostname)   require_value "$@" || return 1
			              hostname="$2"; shift 2 ;;
			--cf-api-token-file)
			              require_value "$@" || return 1
			              token_file="$2"; shift 2 ;;
			--access-allow)
			              require_value "$@" || return 1
			              access_allow="$2"; shift 2 ;;
			--dry-run)    appliance_dry_run=1; shift ;;
			--force)      appliance_force=1; shift ;;
			-h|--help)    usage; return 0 ;;
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

	if [[ -n $hostname && ! $hostname =~ \
		^[a-z0-9]([a-z0-9-]{0,62})(\.[a-z0-9]([a-z0-9-]{0,62}))+$ ]]; then
		log_err "invalid hostname '$hostname' (expected an FQDN like" \
			'cws.example.com)'
		return 1
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
		validate_access_allow "$access_allow" || return 1
		# Fail on a bad token in seconds — not after ten minutes of
		# package installs. Needs no root; curl/jq are preinstalled
		# on the supported distros' cloud images (and rechecked by
		# install_base_deps for the rest of the run).
		if [[ $mode != 'doctor' ]] \
			&& command -v curl > /dev/null 2>&1 \
			&& command -v jq > /dev/null 2>&1; then
			log_info "plan: hostname=$hostname"
			log_info "plan: access allow-list=$access_allow"
			log_info 'preflight: verifying the Cloudflare API token'
			tunnel_api_load_token "$token_file" || return 1
		fi
	fi

	if [[ $mode == 'doctor' ]]; then
		user=$(resolve_target_user "$user") || return 1
		run_appliance_doctor "$user"
		return
	fi

	if [[ $mode == 'reconfigure' ]]; then
		user=$(resolve_target_user "$user") || return 1
		run_reconfigure "$user"
		return
	fi

	# Validate an explicit/sudo candidate before the root gate, so bad
	# input is reported to non-root callers (and CI) as before. With no
	# usable candidate we defer to ensure_target_user, which mints the
	# default account once we are confirmed root.
	local user_candidate="${user:-${SUDO_USER:-}}"
	if [[ -n $user_candidate && $user_candidate != 'root' ]]; then
		user=$(resolve_target_user "$user") || return 1
	fi

	require_root || return 1

	user=$(ensure_target_user "$user") || return 1

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
	install_base_deps || return 1
	enable_unattended_upgrades || return 1
	install_session_stack || return 1
	install_polkit_rules || return 1
	install_engine || return 1

	# Cowork's microVM runs as the session user; /dev/kvm is
	# root:kvm 0660, so group membership is required (found live:
	# device present, user still got permission denied).
	if [[ -e ${APPLIANCE_DEV_KVM:-/dev/kvm} ]]; then
		run_cmd usermod -aG kvm "$user" || return 1
	fi

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

	# Put the cws CLI on PATH so post-install management is one command,
	# and the guardian launch wrapper where autostart entries expect it.
	run_cmd ln -sf "$cws_dir/cws" /usr/local/bin/cws || return 1
	run_cmd ln -sf "$cws_dir/libexec/cws-launch" \
		/usr/local/bin/cws-launch || return 1

	# Client sync is the DEFAULT file path onto the box (the folder on
	# your device IS ~/ClientSync here). Non-fatal: a failure must not
	# sink provisioning — it is re-runnable via cws.
	clientsync_setup "$user" 1 \
		|| log_warn 'client sync setup failed (non-fatal); re-run' \
			'later with: sudo cws client setup'

	# Browser bridge: folder + consented screen share behind the same
	# Access gate, exposed to Claude via the client-screen MCP server.
	clientbridge_setup "$user" 1 "$hostname" \
		|| log_warn 'client bridge setup failed (non-fatal); re-run' \
			'later with: sudo cws client bridge-setup'

	# Hourly idle-reclaim timer: a no-op until reclaim.conf opts in,
	# so installing it unconditionally is safe.
	install_reclaim_timer \
		|| log_warn 'reclaim timer install failed (non-fatal);' \
			'cron "cws reclaim" yourself'

	log_info 'provisioning complete. Next steps:'
	if [[ $profile == 'kasmvnc' ]]; then
		log_info "  - kasmVNC password for '$user':" \
			"sudo cws credentials $user"
	fi
	log_info "  - open https://${hostname:-<hostname>} , pass Cloudflare"
	log_info "    Access, then log in with the kasmVNC credentials above"
	log_info "  - inside the session, sign into Claude (this populates"
	log_info "    the keyring on first use)"
	if [[ ! -e /dev/kvm ]]; then
		log_info '  - note: Cowork VM unavailable on this host (no' \
			'/dev/kvm — nested virt); chat, Code tab, MCP unaffected'
	fi
	log_info "  - health check any time: sudo cws doctor"
	if [[ $profile == 'kasmvnc' && -n $hostname \
		&& $tunnel_mode == 'manual' ]]; then
		log_info '  - finish the cloudflared tunnel steps printed above'
	fi
	log_info 'manage this box any time with the interactive CLI:'
	log_info '  sudo cws            # menu: pair your devices, doctor,'
	log_info '                      # credentials, members, SSH-target'
	log_info "  sudo cws client add-device <ID>   # pair phone/tablet:"
	log_info '                      # their folder <-> ~/ClientSync here'
	log_info '  sudo cws storage add --user NAME --provider gdrive ...'
	log_info '  sudo cws member add NAME     (read the terms note first)'
	log_info '  cws help            # everything else'
}

# Only run when executed, so the BATS suite can source the functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
