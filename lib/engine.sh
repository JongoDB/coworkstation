# shellcheck shell=bash
#===============================================================================
# Engine selection and installation
#
# "Engine" = which Claude Desktop build the appliance runs:
#   official — Anthropic's apt build (Debian-family, KVM-backed Cowork)
#   repo     — this repository's build (bwrap Cowork backend; the
#              portability path when KVM is unavailable)
#
# Sourced by appliance/setup.sh. Sets globals:
#   engine_choice   official|repo
#   engine_reason   one-line human explanation, stored for the doctor
#===============================================================================

appliance_etc="${APPLIANCE_ETC:-/etc/claude-appliance}"

# Decide which engine to install. $1 is the --engine flag (auto by
# default). Pure decision logic — no side effects — so BATS can drive
# it with APPLIANCE_OS_RELEASE / APPLIANCE_DEV_KVM overrides.
select_engine() {
	local override="${1:-auto}"
	local dev_kvm="${APPLIANCE_DEV_KVM:-/dev/kvm}"

	case "$override" in
		official|repo)
			engine_choice="$override"
			engine_reason='forced via --engine'
			return 0
			;;
		auto) ;;
		*)
			log_err "unknown engine '$override' (auto|official|repo)"
			return 1
			;;
	esac

	local distro
	distro=$(appliance_distro_id)
	case "$distro" in
		debian|ubuntu) ;;
		*)
			engine_choice='repo'
			engine_reason="non-Debian distro '$distro':"
			engine_reason+=' official build unavailable'
			return 0
			;;
	esac

	if [[ -e $dev_kvm ]]; then
		engine_choice='official'
		engine_reason='Debian-family with /dev/kvm present'
	else
		engine_choice='repo'
		engine_reason='no /dev/kvm: repo build with bwrap backend'
	fi
}

# Anthropic's official apt repository, per
# https://code.claude.com/docs/en/desktop-linux
_engine_install_official() {
	local keyring='/usr/share/keyrings/claude-desktop-archive-keyring.asc'
	local list='/etc/apt/sources.list.d/claude-desktop.list'
	local key_url='https://downloads.claude.ai/claude-desktop/key.asc'
	local repo_url='https://downloads.claude.ai/claude-desktop/apt/stable'

	if [[ ! -f $keyring ]]; then
		run_cmd curl -fsSLo "$keyring" "$key_url" || return 1
	fi
	printf 'deb [arch=amd64,arm64 signed-by=%s] %s stable main' \
		"$keyring" "$repo_url" | write_file "$list" || return 1
	run_cmd apt-get update || return 1
	pkg_install claude-desktop
}

# This repository's apt repository, per README.md
_engine_install_repo() {
	local keyring='/usr/share/keyrings/claude-desktop.gpg'
	local list='/etc/apt/sources.list.d/claude-desktop.list'
	local base_url='https://pkg.claude-desktop-debian.dev'

	if [[ ! -f $keyring ]]; then
		if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
			printf 'DRY-RUN: curl %s/KEY.gpg | gpg --dearmor -o %s\n' \
				"$base_url" "$keyring"
		else
			curl -fsSL "$base_url/KEY.gpg" \
				| gpg --dearmor -o "$keyring" || return 1
		fi
	fi
	printf 'deb [signed-by=%s arch=amd64,arm64] %s stable main' \
		"$keyring" "$base_url" | write_file "$list" || return 1
	run_cmd apt-get update || return 1
	pkg_install claude-desktop
}

# Install the selected engine and record the decision for the doctor.
# $1 = target user (for the per-session backend override).
install_engine() {
	local user="$1"

	case "$engine_choice" in
		official) _engine_install_official || return 1 ;;
		repo)     _engine_install_repo || return 1 ;;
		*)
			log_err "install_engine before select_engine"
			return 1
			;;
	esac

	local backend='kvm'
	if [[ $engine_choice == 'repo' && ! -e ${APPLIANCE_DEV_KVM:-/dev/kvm} ]]
	then
		backend='bwrap'
		_engine_write_backend_env "$user" || return 1
	fi

	{
		printf 'engine=%s\n' "$engine_choice"
		printf 'reason=%s\n' "$engine_reason"
		printf 'backend=%s\n' "$backend"
	} | appliance_force=1 write_file "$appliance_etc/engine.conf"
}

# Persist COWORK_VM_BACKEND=bwrap into the user's systemd environment
# so every session (kasmVNC, xrdp, console) inherits it.
_engine_write_backend_env() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 1
	local env_dir="$home/.config/environment.d"
	local env_file="$env_dir/60-claude-appliance.conf"

	run_as_user "$user" mkdir -p "$env_dir" || return 1
	if [[ -e $env_file && ${appliance_force:-0} -ne 1 ]]; then
		log_info "keeping existing $env_file"
		return 0
	fi
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: write %s (COWORK_VM_BACKEND=bwrap)\n' "$env_file"
		return 0
	fi
	printf 'COWORK_VM_BACKEND=bwrap\n' > "$env_file" || return 1
	chown "$user:$user" "$env_file"
}
