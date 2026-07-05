# shellcheck shell=bash
#===============================================================================
# Engine selection and installation
#
# "Engine" = which Claude Desktop build the appliance runs:
#   official — Anthropic's apt build. THE DEFAULT: it is Anthropic's own
#              binary, unmodified, and the only engine whose use is
#              squarely within the app's terms. Cowork's VM feature
#              needs /dev/kvm; without it the rest of the app still
#              works and setup says so plainly.
#   repo     — the community claude-desktop-debian packaging. As of
#              its v3.0.0 it repackages Anthropic's OFFICIAL Linux
#              .deb (app.asar byte-identical); what it adds is the
#              hardened launcher (config-wipe backup rotation, GPU
#              recovery), its own doctor, and rpm/AppImage/Nix
#              formats. Its former bwrap Cowork backend is parked —
#              BOTH engines need /dev/kvm for the Cowork VM now.
#              Still explicit opt-in on Debian (unofficial packaging
#              is a choice); the automatic fallback on non-Debian
#              distros where no official build exists.
#
# Sourced by appliance/setup.sh. Sets globals:
#   engine_choice   official|repo
#   engine_reason   one-line human explanation, stored for the doctor
#===============================================================================

appliance_etc="${APPLIANCE_ETC:-/etc/coworkstation}"

# Decide which engine to install. $1 is the --engine flag (auto by
# default). Pure decision logic — no side effects — so BATS can drive
# it with APPLIANCE_OS_RELEASE / APPLIANCE_DEV_KVM overrides.
select_engine() {
	local override="${1:-auto}"
	local dev_kvm="${APPLIANCE_DEV_KVM:-/dev/kvm}"

	case "$override" in
		official)
			engine_choice='official'
			engine_reason='forced via --engine'
			return 0
			;;
		repo)
			engine_choice='repo'
			engine_reason='forced via --engine (community build)'
			log_warn 'engine repo is the community' \
				'claude-desktop-debian packaging (official app' \
				'bytes + a hardened launcher). Unofficial — you' \
				'are opting into that knowingly. Note: it no' \
				'longer provides Cowork without /dev/kvm.'
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
			# No official build outside the Debian family; the repo
			# build is the only path and the operator should know
			# what they are getting.
			engine_choice='repo'
			engine_reason="non-Debian distro '$distro':"
			engine_reason+=' official build unavailable'
			log_warn 'falling back to the community repackaging' \
				"(no official build for '$distro')"
			return 0
			;;
	esac

	# Debian family: ALWAYS the official build. KVM only affects the
	# Cowork VM feature, not the app — never silently swap in a patched
	# binary to gain it.
	engine_choice='official'
	if [[ -e $dev_kvm ]]; then
		engine_reason='official build, /dev/kvm present (Cowork VM ok)'
	else
		engine_reason='official build; no /dev/kvm so the Cowork VM'
		engine_reason+=' feature is unavailable'
		log_warn 'no /dev/kvm: Claude Desktop will run but Cowork'"'"'s' \
			'VM feature will not (every engine needs KVM for it).' \
			'Use a KVM-capable host for the full feature set.'
	fi
}

# Name of the installed Claude Desktop launcher. The official package
# ships /usr/bin/claude-desktop; the community v3 package ships
# /usr/bin/claude-desktop-unofficial (they can coexist). Falls back to
# the official name when neither is installed yet (dry-run, tests).
claude_desktop_binary() {
	if command -v claude-desktop > /dev/null 2>&1; then
		printf 'claude-desktop'
	elif command -v claude-desktop-unofficial > /dev/null 2>&1; then
		printf 'claude-desktop-unofficial'
	else
		printf 'claude-desktop'
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
	# Force: this list file is ours, and an --engine switch must
	# retarget apt rather than silently keep the previous source.
	printf 'deb [arch=amd64,arm64 signed-by=%s] %s stable main' \
		"$keyring" "$repo_url" \
		| appliance_force=1 write_file "$list" || return 1
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
		"$keyring" "$base_url" \
		| appliance_force=1 write_file "$list" || return 1
	run_cmd apt-get update || return 1
	# v3 renamed the package (claude-desktop is now a transitional
	# dummy in their pool); try the real name first.
	pkg_install claude-desktop-unofficial || pkg_install claude-desktop
}

# Install the selected engine and record the decision for the doctor.
install_engine() {
	case "$engine_choice" in
		official) _engine_install_official || return 1 ;;
		repo)     _engine_install_repo || return 1 ;;
		*)
			log_err "install_engine before select_engine"
			return 1
			;;
	esac

	# Cowork backend actually available on this host. Since the
	# community build's v3 parked its bwrap backend, BOTH engines are
	# KVM-or-nothing:
	#   kvm    — /dev/kvm present
	#   none   — the app runs, the Cowork VM feature does not
	#            (recorded so the doctor can say so)
	local backend
	if [[ -e ${APPLIANCE_DEV_KVM:-/dev/kvm} ]]; then
		backend='kvm'
	else
		backend='none'
	fi

	{
		printf 'engine=%s\n' "$engine_choice"
		printf 'reason=%s\n' "$engine_reason"
		printf 'backend=%s\n' "$backend"
	} | appliance_force=1 write_file "$appliance_etc/engine.conf"
}

