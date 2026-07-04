#!/usr/bin/env bash
#===============================================================================
# Remote-backed storage — Phase 2.5
#
# Mounts a member's cloud storage (Google Drive, OneDrive, Dropbox,
# ...) under ~/CloudDrives/<name> via rclone with a BOUNDED local
# cache, so Cowork/Code project folders live in the provider and the
# appliance only holds hot data. This mirrors the macOS pattern of
# pointing Cowork at a synced Drive folder.
#
# Usage:
#   sudo ./storage.sh add --user NAME --provider gdrive|onedrive|dropbox
#        --name REMOTE [--token-file FILE] [--cache-max 10G] [--dry-run]
#   sudo ./storage.sh remove --user NAME --name REMOTE [--dry-run]
#   ./storage.sh list --user NAME
#
# OAuth: run `rclone authorize "<provider>"` on any machine with a
# browser (the member's laptop), then paste the token JSON when the
# wizard prompts — or pass it via --token-file. The token is written
# to the member's own ~/.config/rclone/rclone.conf, never argv.
#
# Spec: docs/phases.md (Phase 2.5)
#===============================================================================

cws_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "$cws_dir/lib/common.sh"

storage_mount_root='CloudDrives'

# Map friendly provider names to rclone backend types.
storage_backend_for() {
	case "$1" in
		gdrive)   printf 'drive' ;;
		onedrive) printf 'onedrive' ;;
		dropbox)  printf 'dropbox' ;;
		*)
			log_err "unknown provider '$1'" \
				'(gdrive|onedrive|dropbox; others via raw rclone)'
			return 1
			;;
	esac
}

install_storage_packages() {
	if command -v rclone > /dev/null 2>&1; then
		return 0
	fi
	pkg_install rclone fuse3
}

# Write the member's rclone remote directly into their own 0600
# rclone.conf. The OAuth token must NOT reach argv: `rclone config
# create … token <JSON>` would put the refresh-capable provider token on
# the child's command line, readable via /proc/<pid>/cmdline by every
# other member on this shared box. Instead the token travels by env
# (readable only by the owner and root, via /proc/<pid>/environ) into a
# child that writes it to the config file and nowhere else.
# Args: user name backend token_json
storage_write_remote() {
	local user="$1"
	local name="$2"
	local backend="$3"
	local token_json="$4"

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: write rclone remote %s (%s) to %s rclone.conf\n' \
			"$name" "$backend" "$user"
		return 0
	fi
	# shellcheck disable=SC2016  # $1/$2/env expand in the child shell
	RCLONE_TOKEN_JSON="$token_json" runuser -u "$user" -- bash -c '
		set -u
		umask 077
		name="$1"; backend="$2"
		conf="$HOME/.config/rclone/rclone.conf"
		mkdir -p "$(dirname "$conf")" || exit 1
		if [[ -f $conf ]] && grep -qxF "[$name]" "$conf"; then
			printf "remote %s already exists; remove it first\n" \
				"$name" >&2
			exit 3
		fi
		{
			printf "[%s]\n" "$name"
			printf "type = %s\n" "$backend"
			printf "token = %s\n" "$RCLONE_TOKEN_JSON"
			printf "config_refresh_token = false\n"
		} >> "$conf"
		chmod 600 "$conf"
	' rclone-add "$name" "$backend"
}

# systemd user unit for the mount. Bounded VFS cache keeps disk use
# capped while giving near-local read/write semantics.
# Args: name cache_max
storage_unit() {
	local name="$1"
	local cache_max="$2"
	cat << EOF
[Unit]
Description=rclone mount: ${name} (Claude appliance cloud storage)
After=network-online.target

[Service]
Type=notify
ExecStartPre=/usr/bin/mkdir -p %h/${storage_mount_root}/${name}
ExecStart=/usr/bin/rclone mount ${name}: %h/${storage_mount_root}/${name} \\
	--vfs-cache-mode full \\
	--vfs-cache-max-size ${cache_max} \\
	--vfs-cache-max-age 24h \\
	--dir-cache-time 5m \\
	--umask 077
ExecStop=/bin/fusermount -uz %h/${storage_mount_root}/${name}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
}

# Args: user name cache_max
storage_install_unit() {
	local user="$1"
	local name="$2"
	local cache_max="$3"
	local home
	home=$(user_home "$user") || return 1
	local unit_dir="$home/.config/systemd/user"
	local unit="$unit_dir/rclone-$name.service"

	run_as_user "$user" mkdir -p "$unit_dir" || return 1
	storage_unit "$name" "$cache_max" | write_file "$unit" || return 1
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		chown "$user:$user" "$unit"
	fi
	user_systemctl "$user" enable --now "rclone-$name.service"
}

# Prompt for the OAuth token when interactive and no file was given.
# Same TTY seam as setup.sh's wizard.
storage_read_token() {
	local provider="$1"
	local token_file="$2"
	if [[ -n $token_file ]]; then
		if [[ ! -f $token_file ]]; then
			log_err "token file not found: $token_file"
			return 1
		fi
		cat "$token_file"
		return 0
	fi
	if [[ ${APPLIANCE_ASSUME_TTY:-0} -ne 1 && ! -t 0 ]]; then
		log_err 'no --token-file and no terminal for the token prompt'
		return 1
	fi
	{
		printf 'On any machine with a browser, run:\n'
		printf '    rclone authorize "%s"\n' \
			"$(storage_backend_for "$provider")"
		printf 'and paste the token JSON here: '
	} >&2
	local token
	read -r token
	if [[ -z $token ]]; then
		log_err 'empty token'
		return 1
	fi
	printf '%s' "$token"
}

cmd_add() {
	local user="$1" name="$2" provider="$3"
	local token_file="$4" cache_max="$5"

	local backend
	backend=$(storage_backend_for "$provider") || return 1
	if [[ ! $name =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
		log_err "invalid remote name '$name'"
		return 1
	fi
	if ! id "$user" > /dev/null 2>&1; then
		log_err "user '$user' does not exist"
		return 1
	fi

	install_storage_packages || return 1
	local token
	token=$(storage_read_token "$provider" "$token_file") || return 1
	storage_write_remote "$user" "$name" "$backend" "$token" \
		|| return 1
	storage_install_unit "$user" "$name" "$cache_max" || return 1

	local home
	home=$(user_home "$user") || return 1
	log_info "cloud storage ready: $home/$storage_mount_root/$name"
	log_info "  point Cowork/Code project folders inside it; only"
	log_info "  a bounded cache (max $cache_max) lives on this disk"
}

cmd_remove() {
	local user="$1" name="$2"
	local home
	home=$(user_home "$user") || return 1

	user_systemctl "$user" disable --now "rclone-$name.service"
	run_cmd rm -f \
		"$home/.config/systemd/user/rclone-$name.service"
	run_as_user "$user" rclone config delete "$name"
	log_info "removed remote '$name' (provider data is untouched;"
	log_info '  only the mount and local cache are gone)'
}

cmd_list() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 1
	if ! command -v rclone > /dev/null 2>&1; then
		log_info 'rclone not installed; no storage configured'
		return 0
	fi
	printf 'REMOTE\tMOUNTPOINT\tUNIT\n'
	local remote unit_state
	while IFS= read -r remote; do
		remote="${remote%:}"
		[[ -z $remote ]] && continue
		unit_state=$(runuser -u "$user" -- \
			env XDG_RUNTIME_DIR="/run/user/$(id -u "$user")" \
			systemctl --user is-active "rclone-$remote.service" \
			2> /dev/null)
		printf '%s\t%s\t%s\n' "$remote" \
			"$home/$storage_mount_root/$remote" \
			"${unit_state:-not-installed}"
	done < <(runuser -u "$user" -- rclone listremotes 2> /dev/null)
}

usage() {
	sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
	local cmd="${1:-}"
	shift || true
	appliance_dry_run=0
	appliance_force=0

	local user='' name='' provider='' token_file='' cache_max='10G'
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--user)       require_value "$@" || return 1
			              user="$2"; shift 2 ;;
			--name)       require_value "$@" || return 1
			              name="$2"; shift 2 ;;
			--provider)   require_value "$@" || return 1
			              provider="$2"; shift 2 ;;
			--token-file) require_value "$@" || return 1
			              token_file="$2"; shift 2 ;;
			--cache-max)  require_value "$@" || return 1
			              cache_max="$2"; shift 2 ;;
			--dry-run)    appliance_dry_run=1; shift ;;
			-h|--help)    usage; return 0 ;;
			*)
				log_err "unknown argument '$1'"
				return 1
				;;
		esac
	done

	# Validate flags before the root gate so usage errors are
	# reported to non-root invocations too (and CI can test them).
	case "$cmd" in
		add)
			if [[ -z $user || -z $name || -z $provider ]]; then
				log_err 'add needs --user, --name, --provider'
				return 1
			fi
			require_root || return 1
			cmd_add "$user" "$name" "$provider" \
				"$token_file" "$cache_max"
			;;
		remove)
			if [[ -z $user || -z $name ]]; then
				log_err 'remove needs --user and --name'
				return 1
			fi
			require_root || return 1
			cmd_remove "$user" "$name"
			;;
		list)
			if [[ -z $user ]]; then
				log_err 'list needs --user'
				return 1
			fi
			cmd_list "$user"
			;;
		-h|--help|'')
			usage
			;;
		*)
			log_err "unknown command '$cmd'"
			usage
			return 1
			;;
	esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
