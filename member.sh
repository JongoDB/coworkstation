#!/usr/bin/env bash
#===============================================================================
# Coworkstation member management — Phase 2 (multi-user)
#
# Usage:
#   sudo ./member.sh add NAME [--quota-mem 6G] [--quota-cpu 200%]
#                             [--allow EMAIL[,...]] [--dry-run]
#     --allow scopes the member hostname's Access policy to just
#     those identities (forced per-member auth); default = box-wide list
#   sudo ./member.sh remove NAME [--keep-home] [--yes] [--dry-run]
#   ./member.sh list
#
# Each member gets: a Unix account, a systemd user-slice quota, a
# kasmVNC session on their own display/port, a cloudflared ingress
# hostname (NAME.<appliance hostname>), and XDG autostart for Claude
# Desktop. State lives in $APPLIANCE_ETC/members.tsv:
#   name<TAB>display<TAB>port<TAB>quota_mem<TAB>quota_cpu
#
# Spec: docs/phases.md (Phase 2)
#===============================================================================

cws_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "$cws_dir/lib/common.sh"
# shellcheck source=lib/engine.sh
source "$cws_dir/lib/engine.sh"
# shellcheck source=lib/profiles/kasmvnc.sh
source "$cws_dir/lib/profiles/kasmvnc.sh"
# shellcheck source=lib/tunnel-api.sh
source "$cws_dir/lib/tunnel-api.sh"
# shellcheck source=lib/clientsync.sh
source "$cws_dir/lib/clientsync.sh"
# shellcheck source=lib/clientbridge.sh
source "$cws_dir/lib/clientbridge.sh"

registry_file() { printf '%s/members.tsv' "$appliance_etc"; }

# Serialize mutating commands: two concurrent `member.sh add` calls
# could allocate the same display/port and interleave registry writes.
# The lock fd stays open for the life of the process. No flock on the
# system (unusual) degrades to unlocked with a warning.
member_lock() {
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		return 0
	fi
	if ! command -v flock > /dev/null 2>&1; then
		log_warn 'flock unavailable; concurrent member.sh runs may race'
		return 0
	fi
	mkdir -p "$appliance_etc" || return 1
	exec 9> "$appliance_etc/.members.lock" || return 1
	if ! flock -w 30 9; then
		log_err 'another member.sh invocation holds the lock'
		return 1
	fi
}

# --- Registry (pure text; the BATS seam) -------------------------------

# Next free display number given existing registry content on stdin.
# Display 1 is reserved for the setup.sh single-user session.
registry_next_display() {
	local used display=2
	used=$(awk -F'\t' '{print $2}')
	while grep -qx "$display" <<< "$used"; do
		display=$((display + 1))
	done
	printf '%s' "$display"
}

# Append a member row. Args: name display port mem cpu
registry_add_row() {
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"
}

# Filter stdin registry, dropping the named member's row.
registry_drop() {
	local name="$1"
	awk -F'\t' -v n="$name" '$1 != n'
}

# Look up a member's row (tab-separated) or fail.
registry_get() {
	local name="$1"
	local file="$2"
	[[ -f $file ]] || return 1
	awk -F'\t' -v n="$name" '$1 == n { print; found=1 } END { exit !found }' \
		"$file"
}

# --- cloudflared ingress (pure text transforms) ------------------------

# Insert a hostname->port ingress entry before the http_status:404
# catch-all. Reads config.yml on stdin, writes the new one on stdout.
# Idempotent: if the hostname exists, passes input through unchanged.
ingress_add() {
	local hostname="$1"
	local port="$2"
	local input
	input=$(cat)

	local host_re="${hostname//./\\.}"
	if grep -qE "hostname:[[:space:]]*$host_re\$" <<< "$input"; then
		printf '%s\n' "$input"
		return 0
	fi
	awk -v h="$hostname" -v p="$port" '
		/^[[:space:]]*- service: http_status:404/ && !done {
			printf "  - hostname: %s\n", h
			printf "    service: http://127.0.0.1:%s\n", p
			done = 1
		}
		{ print }
	' <<< "$input"
}

# Drop a hostname entry (its two lines) from config.yml on stdin.
ingress_remove() {
	local hostname="$1"
	awk -v h="$hostname" '
		$0 ~ "^[[:space:]]*- hostname: " h "$" { skip = 2 }
		skip > 0 { skip--; next }
		{ print }
	'
}

# Apply a text transform to the live cloudflared config, if present.
# $1 = transform function, remaining args passed to it.
apply_ingress_transform() {
	local transform="$1"
	shift
	local conf='/etc/cloudflared/config.yml'
	local conf_path="${APPLIANCE_CLOUDFLARED_CONF:-$conf}"

	if [[ ! -f $conf_path ]]; then
		log_warn "no $conf_path; skipping ingress update"
		return 0
	fi
	local updated
	updated=$("$transform" "$@" < "$conf_path") || return 1
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: rewrite %s:\n' "$conf_path"
		printf '%s\n' "$updated" | sed 's/^/    /'
		return 0
	fi
	printf '%s\n' "$updated" > "$conf_path"
}

# --- Quotas ------------------------------------------------------------

slice_override() {
	local mem="$1"
	local cpu="$2"
	cat << EOF
[Slice]
MemoryMax=${mem}
CPUQuota=${cpu}
TasksMax=4096
EOF
}

# $1 = user, $2 = mem, $3 = cpu
install_slice_quota() {
	local user="$1"
	local mem="$2"
	local cpu="$3"
	local uid
	uid=$(id -u "$user") || return 1
	local dir="${APPLIANCE_SLICE_DIR:-/etc/systemd/system}"
	dir+="/user-${uid}.slice.d"

	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		mkdir -p "$dir" || return 1
	fi
	slice_override "$mem" "$cpu" \
		| write_file "$dir/50-coworkstation.conf" || return 1
	run_cmd systemctl daemon-reload
}

# --- Autostart (same entry as setup.sh) --------------------------------

member_autostart() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 1
	local dir="$home/.config/autostart"

	run_as_user "$user" mkdir -p "$dir" || return 1
	printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Claude' \
		'Exec=cws-launch' \
		'X-GNOME-Autostart-enabled=true' \
		| write_file "$dir/claude-desktop.desktop" || return 1
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		chown "$user:$user" "$dir/claude-desktop.desktop"
	fi
}

# --- Commands ----------------------------------------------------------

appliance_base_hostname() {
	local conf="$appliance_etc/appliance.conf"
	[[ -f $conf ]] || return 1
	grep -E '^hostname=' "$conf" | head -1 | cut -d= -f2
}

cmd_add() {
	local name="$1"
	local mem="$2"
	local cpu="$3"
	# Optional per-member Access allow list: scopes this member's
	# hostname policy to just their identity (forced per-member auth,
	# ADR-008 phase 2) instead of the box-wide allow list.
	local allow="${4:-}"
	local registry
	registry=$(registry_file)

	if [[ -n $allow ]] && ! validate_access_allow "$allow"; then
		return 1
	fi

	if [[ -f $registry ]] && registry_get "$name" "$registry" \
		> /dev/null; then
		log_err "member '$name' already registered"
		return 1
	fi

	local display port
	display=$(registry_next_display < <(cat "$registry" 2> /dev/null))
	port=$((appliance_kasm_base_port + display - 1))

	if ! id "$name" > /dev/null 2>&1; then
		run_cmd useradd -m -s /bin/bash "$name" || return 1
	else
		log_info "account '$name' already exists; adopting it"
	fi

	# Members share 127.0.0.1; isolation between them leans on file
	# modes, so keep each home private (the distro default can be 0755).
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		local mhome
		mhome=$(user_home "$name") && chmod 700 "$mhome" 2> /dev/null
	fi

	install_slice_quota "$name" "$mem" "$cpu" || return 1
	if [[ -e ${APPLIANCE_DEV_KVM:-/dev/kvm} ]]; then
		run_cmd usermod -aG kvm "$name" || return 1
	fi
	# Mirror profile_kasmvnc_apply exactly: the cert and control user are
	# mandatory. Without them write_service's `enable --now` starts a
	# vncserver that either exits 1 (no cert) or loops forever on the
	# interactive control-user prompt (no ~/.kasmpasswd) — a member whose
	# session never binds a listener.
	profile_kasmvnc_setup_cert "$name" || return 1
	profile_kasmvnc_write_config "$name" "$port" || return 1
	profile_kasmvnc_setup_auth "$name" || return 1
	profile_kasmvnc_write_service "$name" "$display" || return 1
	member_autostart "$name" || return 1
	# Compute the member hostname BEFORE the client-bridge setup so
	# the /bridge path route lands on the member's hostname too.
	local base member_host=''
	if base=$(appliance_base_hostname) && [[ -n $base ]]; then
		member_host=$(tunnel_api_child_hostname "$name" "$base")
	fi

	clientsync_setup "$name" "$display" \
		|| log_warn "client sync setup failed for $name (non-fatal);" \
			"re-run with: sudo cws client setup --user $name"
	clientbridge_setup "$name" "$display" "$member_host" \
		|| log_warn "client bridge setup failed for $name (non-fatal)"

	if [[ -n $member_host ]]; then
		if [[ $(tunnel_conf_get mode 2> /dev/null) == 'api' ]]; then
			if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
				printf 'DRY-RUN: api ingress+dns+access for %s\n' \
					"$member_host"
			else
				tunnel_api_member_add "$member_host" "$port" \
					"$allow" || return 1
			fi
		else
			if [[ -n $allow ]]; then
				log_warn '--allow needs api tunnel mode; add the' \
					"Access policy for $member_host yourself"
			fi
			apply_ingress_transform ingress_add "$member_host" \
				"$port" || return 1
		fi
	else
		log_warn 'no appliance hostname recorded; skipping ingress'
	fi

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: append %s to %s\n' "$name" "$registry"
	else
		mkdir -p "$(dirname "$registry")" || return 1
		registry_add_row "$name" "$display" "$port" "$mem" "$cpu" \
			>> "$registry"
	fi

	log_info "member '$name' added (display :$display, port $port)"
	if [[ -n $member_host ]]; then
		if [[ $(tunnel_conf_get mode 2> /dev/null) == 'api' ]]; then
			log_info "  hostname: $member_host (Access app provisioned)"
		else
			log_warn "$member_host is served by the tunnel with NO" \
				"Cloudflare Access policy yet — it is PUBLIC until you" \
				"create one. Add an Access application for it before" \
				"the member signs in."
		fi
	fi
	log_info "  first login: they sign into Claude and the keyring"
	log_warn 'multi-user note: each member MUST sign in with their' \
		"OWN Claude account (Anthropic's terms; shared sign-ins also" \
		'trip account-security defenses from a datacenter IP)'
}

cmd_remove() {
	local name="$1"
	local keep_home="$2"
	local assume_yes="${3:-0}"
	local registry row
	registry=$(registry_file)

	if ! row=$(registry_get "$name" "$registry"); then
		log_err "member '$name' is not in the registry"
		return 1
	fi

	# userdel -r wipes the member's home (Claude config, keyring, cache).
	# Confirm interactively unless --keep-home, --yes, or --dry-run.
	if [[ $keep_home -ne 1 && $assume_yes -ne 1 \
		&& ${appliance_dry_run:-0} -ne 1 ]]; then
		if [[ -t 0 ]]; then
			local reply
			printf "Delete member '%s' AND their home directory? [y/N] " \
				"$name" >&2
			read -r reply
			if [[ $reply != [yY] && $reply != [yY][eE][sS] ]]; then
				log_info 'aborted'
				return 1
			fi
		else
			log_err "refusing to delete '$name' home" \
				'non-interactively; pass --yes or --keep-home'
			return 1
		fi
	fi

	run_cmd loginctl terminate-user "$name"
	run_cmd loginctl disable-linger "$name"
	# terminate-user is async; userdel races the dying user manager
	# ('user X is currently used by process') — seen live. Give it a
	# moment, then force what's left.
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		local tries=0
		while pgrep -u "$name" > /dev/null 2>&1 && [[ $tries -lt 10 ]]; do
			sleep 1
			tries=$((tries + 1))
		done
		pgrep -u "$name" > /dev/null 2>&1 && run_cmd pkill -9 -u "$name"
		sleep 1
	fi

	local base member_host
	if base=$(appliance_base_hostname) && [[ -n $base ]]; then
		member_host=$(tunnel_api_child_hostname "$name" "$base")
		if [[ $(tunnel_conf_get mode 2> /dev/null) == 'api' ]]; then
			if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
				printf 'DRY-RUN: api ingress+dns+access removal for %s\n' \
					"$member_host"
			else
				tunnel_api_member_remove "$member_host" || return 1
			fi
		else
			apply_ingress_transform ingress_remove "$member_host" \
				|| return 1
		fi
	fi

	local uid
	if uid=$(id -u "$name" 2> /dev/null); then
		local dir="${APPLIANCE_SLICE_DIR:-/etc/systemd/system}"
		dir+="/user-${uid}.slice.d"
		run_cmd rm -rf "$dir"
	fi

	if [[ $keep_home -eq 1 ]]; then
		run_cmd userdel "$name"
	else
		run_cmd userdel -r "$name"
	fi

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: drop %s from %s\n' "$name" "$registry"
	else
		local updated
		updated=$(registry_drop "$name" < "$registry")
		printf '%s\n' "$updated" > "$registry"
	fi
	log_info "member '$name' removed (row was: $row)"
}

cmd_list() {
	local registry
	registry=$(registry_file)
	if [[ ! -f $registry ]]; then
		log_info 'no members registered'
		return 0
	fi
	printf 'NAME\tDISPLAY\tPORT\tMEM\tCPU\tACCOUNT\n'
	local name display port mem cpu state
	while IFS=$'\t' read -r name display port mem cpu; do
		[[ -z $name ]] && continue
		if id "$name" > /dev/null 2>&1; then
			state='present'
		else
			state='MISSING'
		fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$name" "$display" "$port" "$mem" "$cpu" "$state"
	done < "$registry"
}

usage() {
	sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
	local cmd="${1:-}"
	shift || true
	appliance_dry_run=0
	appliance_force=0

	local name='' mem='6G' cpu='200%' keep_home=0 assume_yes=0
	local allow=''
	if [[ $cmd == 'add' || $cmd == 'remove' ]]; then
		name="${1:-}"
		if [[ -z $name || $name == --* ]]; then
			log_err "usage: member.sh $cmd NAME [flags]"
			return 1
		fi
		shift
		if [[ ! $name =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
			log_err "invalid member name '$name'"
			return 1
		fi
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--quota-mem) require_value "$@" || return 1
			             mem="$2"; shift 2 ;;
			--quota-cpu) require_value "$@" || return 1
			             cpu="$2"; shift 2 ;;
			--allow)     require_value "$@" || return 1
			             allow="$2"; shift 2 ;;
			--keep-home) keep_home=1; shift ;;
			--yes)       assume_yes=1; shift ;;
			--dry-run)   appliance_dry_run=1; shift ;;
			-h|--help)   usage; return 0 ;;
			*)
				log_err "unknown argument '$1'"
				return 1
				;;
		esac
	done

	case "$cmd" in
		add)
			require_root || return 1
			member_lock || return 1
			cmd_add "$name" "$mem" "$cpu" "$allow"
			;;
		remove)
			require_root || return 1
			member_lock || return 1
			cmd_remove "$name" "$keep_home" "$assume_yes"
			;;
		list)
			cmd_list
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

# Only run when executed, so the BATS suite can source the functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
