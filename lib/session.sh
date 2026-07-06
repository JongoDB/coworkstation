# shellcheck shell=bash
#===============================================================================
# Sessions — concurrent per-device sessions for one member (ADR-010)
#
# "New client = new session": a member can run extra desktop
# sessions beside their primary one, each on its own display/port
# and its own hostname (USER-sN.<base>) behind its own Access
# policy. Extra sessions live on displays :50+ so they can never
# collide with member displays (allocated from 2 upward).
#
# The Claude singleton problem is solved in xstartup: displays :50+
# get their own XDG_CONFIG_HOME (~/.config/cws-sessions/N), so a
# second Claude Desktop runs beside the first with its own sign-in —
# per-session login is the point, not a bug (one person, one
# subscription, N devices).
#
# State: $APPLIANCE_ETC/sessions.tsv (user, display, port, hostname).
# Sourced by cws with common.sh, fleet.sh, tunnel-api.sh, and
# profiles/kasmvnc.sh loaded.
#===============================================================================

session_base_display=50

session_registry() {
	printf '%s/sessions.tsv' "${appliance_etc:-/etc/coworkstation}"
}

session_base_hostname() {
	local conf="${appliance_etc:-/etc/coworkstation}/appliance.conf"
	[[ -r $conf ]] || return 1
	grep -m1 '^hostname=' "$conf" | cut -d= -f2
}

# Next free extra-session display, from the registry.
session_next_display() {
	local reg
	reg=$(session_registry)
	local max=$((session_base_display - 1)) d
	if [[ -f $reg ]]; then
		while IFS=$'\t' read -r _ d _ _; do
			[[ $d =~ ^[0-9]+$ && $d -gt $max ]] && max=$d
		done < "$reg"
	fi
	printf '%s' $((max + 1))
}

# Per-session unit: explicit display + websocket port (the shared
# ~/.vnc/kasmvnc.yaml carries the PRIMARY session's port, so extra
# sessions override it on the command line).
session_unit() {
	local display="$1"
	local port="$2"
	cat << EOF
[Unit]
Description=kasmVNC extra session :${display} (Coworkstation)
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/vncserver :${display} -websocketPort ${port} \\
	-select-de manual
ExecStop=/usr/bin/vncserver -kill :${display}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

# Add an extra session for a member. $1 = user, $2 = allow_csv ('' =
# the box-wide list).
session_add() {
	local user="$1"
	local allow="${2:-}"
	if [[ -z $user ]] || ! id "$user" > /dev/null 2>&1; then
		log_err "no such user: '${user:-}'"
		return 1
	fi
	if [[ -n $allow ]] && ! validate_access_allow "$allow"; then
		return 1
	fi
	local home
	home=$(user_home "$user") || return 1
	if [[ ! -f $home/.config/systemd/user/kasmvnc.service ]]; then
		log_err "'$user' has no primary session; run setup or" \
			'member add first'
		return 1
	fi

	local display port
	display=$(session_next_display)
	port=$((${appliance_kasm_base_port:-8443} + display - 1))
	local base hostname=''
	if base=$(session_base_hostname) && [[ -n $base ]]; then
		hostname=$(tunnel_api_child_hostname "${user}-s${display}" \
			"$base")
	fi

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: extra session %s :%s port %s host %s\n' \
			"$user" "$display" "$port" "${hostname:-none}"
		return 0
	fi

	local unit_dir="$home/.config/systemd/user"
	session_unit "$display" "$port" \
		| write_file "$unit_dir/kasmvnc-s${display}.service" || return 1
	chown "$user:$user" "$unit_dir/kasmvnc-s${display}.service"
	user_systemctl "$user" enable --now "kasmvnc-s${display}.service" \
		|| return 1

	if [[ -n $hostname ]]; then
		if [[ $(tunnel_conf_get mode 2> /dev/null) == 'api' ]]; then
			tunnel_api_member_add "$hostname" "$port" "$allow" \
				|| return 1
		else
			log_warn "manual tunnel: route $hostname ->" \
				"http://127.0.0.1:$port and add its Access policy" \
				'yourself'
		fi
	fi

	local reg
	reg=$(session_registry)
	mkdir -p "$(dirname "$reg")"
	printf '%s\t%s\t%s\t%s\n' "$user" "$display" "$port" \
		"${hostname:--}" >> "$reg"
	fleet_audit_record 'session-add' "$user:$display"
	log_info "extra session ready: ${hostname:-port $port}" \
		"(display :$display; its own Claude sign-in)"
}

# Remove an extra session. $1 = user, $2 = display. The session's
# config home (~/.config/cws-sessions/N) is kept — data outlives the
# session; delete it yourself when you're sure.
session_remove() {
	local user="$1"
	local display="$2"
	local reg row
	reg=$(session_registry)
	if [[ ! $display =~ ^[0-9]+$ ]] \
		|| ! row=$(grep -P "^${user}\t${display}\t" "$reg" 2> /dev/null); then
		log_err "no extra session '$user :${display:-?}' registered"
		return 1
	fi
	local hostname
	hostname=$(cut -f4 <<< "$row")

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: remove session %s :%s (%s)\n' \
			"$user" "$display" "$hostname"
		return 0
	fi
	user_systemctl "$user" disable --now "kasmvnc-s${display}.service" \
		2> /dev/null
	local home
	home=$(user_home "$user") \
		&& rm -f "$home/.config/systemd/user/kasmvnc-s${display}.service"
	if [[ $hostname != '-' \
		&& $(tunnel_conf_get mode 2> /dev/null) == 'api' ]]; then
		tunnel_api_member_remove "$hostname" \
			|| log_warn "could not remove tunnel route for $hostname"
	fi
	# grep exits 1 when the last row goes — that's still success here
	grep -vP "^${user}\t${display}\t" "$reg" > "$reg.tmp" || true
	mv "$reg.tmp" "$reg"
	fleet_audit_record 'session-remove' "$user:$display"
	log_info "removed extra session $user :$display" \
		"(config home ~/.config/cws-sessions/$display kept)"
}

session_list() {
	printf 'USER\tDISPLAY\tPORT\tHOSTNAME\n'
	local reg
	reg=$(session_registry)
	[[ -f $reg ]] && cat "$reg"
}
