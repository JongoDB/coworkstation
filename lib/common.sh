# shellcheck shell=bash
#===============================================================================
# Appliance common helpers
#
# Sourced by: appliance/setup.sh, appliance/member.sh, and the BATS suite.
#
# Globals consumed (set by the entry points before sourcing):
#   appliance_dry_run   0|1  echo mutating commands instead of running them
#   appliance_force     0|1  overwrite config files that already exist
#
# Overridable roots (BATS points these at a sandbox):
#   APPLIANCE_ETC       default /etc/claude-appliance
#===============================================================================

log_info() { printf '[appliance] %s\n' "$*"; }
log_warn() { printf '[appliance] WARN: %s\n' "$*" >&2; }
log_err()  { printf '[appliance] ERROR: %s\n' "$*" >&2; }

# Run a mutating command, or print it under --dry-run.
# Always call with an argv array — never a shell string.
run_cmd() {
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: %s\n' "$*"
		return 0
	fi
	"$@"
}

# Write stdin to a file, creating parent dirs. Refuses to overwrite an
# existing file unless --force was given (idempotent re-runs must not
# clobber operator edits). Under --dry-run, prints the target and
# content instead.
# Usage: some_generator | write_file /path/to/dest [mode]
write_file() {
	local dest="$1"
	local mode="${2:-644}"
	local content
	content=$(cat)

	if [[ -e $dest && ${appliance_force:-0} -ne 1 ]]; then
		log_info "keeping existing $dest (use --force to overwrite)"
		return 0
	fi
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: write %s (mode %s):\n' "$dest" "$mode"
		printf '%s\n' "$content" | sed 's/^/    /'
		return 0
	fi
	mkdir -p "$(dirname "$dest")" || return 1
	printf '%s\n' "$content" > "$dest" || return 1
	chmod "$mode" "$dest"
}

# Distro ID from /etc/os-release (same approach as scripts/doctor.sh).
appliance_distro_id() {
	local os_release="${APPLIANCE_OS_RELEASE:-/etc/os-release}"
	local id='unknown' line
	if [[ -f $os_release ]]; then
		while IFS= read -r line; do
			if [[ $line == ID=* ]]; then
				id="${line#ID=}"
				id="${id//\"/}"
				break
			fi
		done < "$os_release"
	fi
	printf '%s' "$id"
}

# Distro codename (bookworm, noble, ...) for release-asset URLs.
appliance_distro_codename() {
	local os_release="${APPLIANCE_OS_RELEASE:-/etc/os-release}"
	local codename='' line
	if [[ -f $os_release ]]; then
		while IFS= read -r line; do
			if [[ $line == VERSION_CODENAME=* ]]; then
				codename="${line#VERSION_CODENAME=}"
				codename="${codename//\"/}"
				break
			fi
		done < "$os_release"
	fi
	printf '%s' "$codename"
}

# Debian-style architecture (amd64/arm64), falling back to uname.
appliance_arch() {
	local arch
	if command -v dpkg > /dev/null 2>&1; then
		arch=$(dpkg --print-architecture 2> /dev/null)
	fi
	if [[ -z $arch ]]; then
		case "$(uname -m)" in
			x86_64)  arch='amd64' ;;
			aarch64) arch='arm64' ;;
			*)       arch="$(uname -m)" ;;
		esac
	fi
	printf '%s' "$arch"
}

# Entry points that install packages and create accounts need root.
require_root() {
	if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
		log_err 'this command must run as root (use sudo)'
		return 1
	fi
}

# The account the appliance session belongs to: --user wins, then the
# invoking sudo user, and never root.
resolve_target_user() {
	local explicit="$1"
	local user="${explicit:-${SUDO_USER:-}}"
	if [[ -z $user || $user == 'root' ]]; then
		log_err 'cannot determine target user; pass --user NAME'
		return 1
	fi
	if ! id "$user" > /dev/null 2>&1; then
		log_err "user '$user' does not exist"
		return 1
	fi
	printf '%s' "$user"
}

# Home directory of a user, from the passwd db (not ~ expansion).
user_home() {
	local user="$1"
	local home
	home=$(getent passwd "$user" | cut -d: -f6)
	if [[ -z $home ]]; then
		log_err "no home directory for '$user'"
		return 1
	fi
	printf '%s' "$home"
}

# Install packages non-interactively via the distro package manager.
pkg_install() {
	local distro
	distro=$(appliance_distro_id)
	case "$distro" in
		debian|ubuntu)
			run_cmd env DEBIAN_FRONTEND=noninteractive \
				apt-get install -y "$@"
			;;
		*)
			log_err "unsupported distro '$distro' for package install"
			return 1
			;;
	esac
}

# Run a command as the target user with a clean login-ish environment,
# so files land with the right ownership (see the 0700 app.asar.unpacked
# lesson in docs/learnings/cowork-vm-daemon.md).
run_as_user() {
	local user="$1"
	shift
	run_cmd runuser -u "$user" -- "$@"
}

# Run `systemctl --user <args>` for a user in a HEADLESS context.
#
# In cloud-init / a root shell there is no login session for the target
# user, so a bare `systemctl --user` dies with
#   Failed to connect to bus: No such file or directory
# because the user's systemd manager (and its D-Bus socket under
# /run/user/<uid>) does not exist yet. enable-linger alone does not
# start the manager synchronously. This helper enables linger, starts
# user@<uid>.service, waits for the runtime bus socket, then invokes
# systemctl --user with XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS
# set explicitly.
#
# Usage: user_systemctl <user> enable --now foo.service
user_systemctl() {
	local user="$1"
	shift
	local uid runtime
	uid=$(id -u "$user") || return 1
	runtime="${APPLIANCE_RUNTIME_DIR:-/run/user/$uid}"

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: user_systemctl %s: systemctl --user %s\n' \
			"$user" "$*"
		return 0
	fi

	loginctl enable-linger "$user" || return 1
	if [[ ! -S $runtime/bus ]]; then
		systemctl start "user@$uid.service" || return 1
		local waited=0
		while [[ ! -S $runtime/bus && $waited -lt 30 ]]; do
			sleep 1
			waited=$((waited + 1))
		done
	fi
	if [[ ! -S $runtime/bus ]]; then
		log_err "user systemd bus never appeared for $user" \
			"($runtime/bus)"
		return 1
	fi
	runuser -u "$user" -- env \
		XDG_RUNTIME_DIR="$runtime" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
		systemctl --user "$@"
}
