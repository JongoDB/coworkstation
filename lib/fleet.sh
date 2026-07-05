# shellcheck shell=bash
#===============================================================================
# Fleet — session visibility and per-member usage analytics (ADR-008)
#
# Phase 1 of the MDM/multi-tenant management layer: read-only
# reporting over what the box already knows. `cws sessions` shows
# every session account, whether its desktop is up, and how many
# clients are attached right now; `cws usage` sums Claude token
# usage per member from the JSONL session logs Claude Code writes
# locally (ADR-007: observe, don't proxy — no API calls, no network).
#
# Caveats stated where they bite: token figures cover Claude Code
# sessions (chat/Cowork don't write local usage logs), and counts
# are approximate (dedup by request id when present).
#
# Phase 2 adds the write side of industry MDM: remote session
# actions (start/stop/restart, each recorded), a local append-only
# ops log, and the audit trail — session unit events from journald
# plus Access login history from the Cloudflare API in api mode.
#
# Sourced by cws (which also sources tunnel-api.sh for the Access
# log fetch).
#===============================================================================

# Session accounts = every user with a provisioned kasmVNC user unit.
# Covers the control user (not in the member registry) and members
# alike, without guessing at uid ranges beyond the human range.
fleet_users() {
	local user home uid
	while IFS=: read -r user _ uid _ _ home _; do
		if (( uid < 1000 || uid >= 60000 )); then
			continue
		fi
		if [[ -f $home/.config/systemd/user/kasmvnc.service ]]; then
			printf '%s\n' "$user"
		fi
	done < <(getent passwd)
}

# Established client connections to a loopback port right now.
fleet_port_clients() {
	local port="$1"
	if ! command -v ss > /dev/null 2>&1; then
		printf '?'
		return 0
	fi
	ss -Htn state established "( sport = :$port )" 2> /dev/null | wc -l
}

# The kasmVNC port for a user: registry row if present, else the
# base port (display 1) used for the control user.
fleet_user_port() {
	local user="$1"
	local registry="${appliance_etc:-/etc/coworkstation}/members.tsv"
	local name port _rest
	if [[ -f $registry ]]; then
		while IFS=$'\t' read -r name _ port _rest; do
			if [[ $name == "$user" ]]; then
				printf '%s' "$port"
				return 0
			fi
		done < "$registry"
	fi
	printf '%s' "${appliance_kasm_base_port:-8443}"
}

# One row per session account: desktop state, attached clients, since.
fleet_sessions() {
	printf 'USER\tDESKTOP\tCLIENTS\tSINCE\n'
	local user state since port
	while read -r user; do
		state=$(user_systemctl "$user" is-active kasmvnc.service \
			2> /dev/null) || state='inactive'
		port=$(fleet_user_port "$user")
		since='-'
		if [[ $state == 'active' ]]; then
			since=$(user_systemctl "$user" show kasmvnc.service \
				-p ActiveEnterTimestamp --value 2> /dev/null)
			since=${since:--}
		fi
		printf '%s\t%s\t%s\t%s\n' "$user" "$state" \
			"$(fleet_port_clients "$port")" "$since"
	done < <(fleet_users)
}

# Token usage for one user from Claude Code's local JSONL logs.
# Prints: messages input output cache_read cache_write last_activity
# Reads raw lines and tolerates malformed ones; dedups on requestId
# (or message id) so resumed sessions don't double-count.
fleet_usage_scan() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 1
	local dir="$home/.claude/projects"
	if [[ ! -d $dir ]]; then
		printf '0\t0\t0\t0\t0\t-\n'
		return 0
	fi
	find "$dir" -name '*.jsonl' -type f -print0 2> /dev/null \
		| xargs -0r cat 2> /dev/null \
		| jq -Rrn '
			reduce (inputs | try fromjson catch null) as $l (
				{n:0, i:0, o:0, cr:0, cw:0, last:"", seen:{}};
				($l.message.usage? // null) as $u
				| (($l.requestId // $l.message.id? // "") | tostring)
					as $id
				| if $u == null then .
				  elif $id != "" and .seen[$id] then .
				  else
					.n += 1
					| .i += ($u.input_tokens // 0)
					| .o += ($u.output_tokens // 0)
					| .cr += ($u.cache_read_input_tokens // 0)
					| .cw += ($u.cache_creation_input_tokens // 0)
					| .last = ([.last, ($l.timestamp // "")] | max)
					| if $id != "" then .seen[$id] = true else . end
				  end)
			| [.n, .i, .o, .cr, .cw,
			   (if .last == "" then "-" else .last end)]
			| @tsv'
}

# Idle reclaim (ADR-008 phase 3b), the verified-blueprint version:
# a session is reclaimable only when BOTH signals are cold — no
# established client connections (the WorkSpaces signal) AND no
# bridge activity inside the idle window (the Coder signal) —
# because connection-presence alone under-reclaims (P3-F6).
# Reclaim = stop the kasmVNC unit; /home persists (Coder's
# "Stopped", not "Deleted" — offboarding stays a human decision via
# member remove). Opt-in: idle_hours=0 (the default) disables it.
fleet_reclaim_idle_hours() {
	local conf="${appliance_etc:-/etc/coworkstation}/reclaim.conf"
	local v=''
	if [[ -r $conf ]]; then
		v=$(grep -m1 '^idle_hours=' "$conf" | cut -d= -f2)
	fi
	if [[ ! $v =~ ^[0-9]+$ ]]; then
		v=0
	fi
	printf '%s' "$v"
}

# Newest activity we can see for a user, as epoch seconds (0 = none):
# bridge device hits and the latest shared frame both count.
fleet_last_activity() {
	local user="$1"
	local home
	home=$(user_home "$user" 2> /dev/null) || { printf '0'; return 0; }
	local newest=0 t f
	f="$home/.config/cws-bridge/devices.json"
	if [[ -s $f ]]; then
		t=$(jq -r '[.[].lastSeen // 0] | max / 1000 | floor' "$f" \
			2> /dev/null) || t=0
		[[ $t =~ ^[0-9]+$ && $t -gt $newest ]] && newest=$t
	fi
	local uid run
	uid=$(id -u "$user" 2> /dev/null) || uid=''
	run="/run/user/$uid/cws-bridge"
	if [[ -f $run/latest.meta ]]; then
		t=$(stat -c %Y "$run/latest.meta" 2> /dev/null) || t=0
		[[ $t -gt $newest ]] && newest=$t
	fi
	printf '%s' "$newest"
}

# Stop sessions that are cold on both signals. $1 = 'dry-run' to
# only report. Run from cron/a timer or `cws reclaim`.
fleet_reclaim() {
	local dry="${1:-}"
	local hours
	hours=$(fleet_reclaim_idle_hours)
	if [[ $hours -eq 0 ]]; then
		log_info 'idle reclaim is off (set idle_hours=N in' \
			"${appliance_etc:-/etc/coworkstation}/reclaim.conf)"
		return 0
	fi
	local cutoff=$(($(date +%s) - hours * 3600))
	local user state conns last
	while read -r user; do
		state=$(user_systemctl "$user" is-active kasmvnc.service \
			2> /dev/null) || state='inactive'
		[[ $state == 'active' ]] || continue
		conns=$(fleet_port_clients "$(fleet_user_port "$user")")
		if [[ $conns =~ ^[0-9]+$ && $conns -gt 0 ]]; then
			continue
		fi
		last=$(fleet_last_activity "$user")
		if [[ $last -ge $cutoff ]]; then
			continue
		fi
		if [[ $dry == 'dry-run' ]]; then
			log_info "would reclaim: $user (idle > ${hours}h," \
				'no clients)'
			continue
		fi
		user_systemctl "$user" stop kasmvnc.service || continue
		fleet_audit_record 'session-reclaim' "$user"
		log_info "reclaimed: $user (idle > ${hours}h, no clients;" \
			'home persists — restart with: cws sessions start' \
			"$user)"
	done < <(fleet_users)
}

# Device inventory (ADR-008 phase 3a): every device that touched a
# member's bridge, with the Access identity that used it. Data comes
# from each user's bridge device registry — the bridge records it,
# we only read.
fleet_devices() {
	printf 'USER\tDEVICE\tIDENTITY\tLAST_SEEN\tHITS\tAGENT\n'
	local user home f
	while read -r user; do
		home=$(user_home "$user" 2> /dev/null) || continue
		f="$home/.config/cws-bridge/devices.json"
		[[ -s $f ]] || continue
		jq -r --arg u "$user" 'to_entries[]
			| [$u, (.key | .[0:8]),
			   (.value.identity // "-"),
			   ((.value.lastSeen // 0) / 1000 | floor
			      | todate),
			   (.value.hits // 0),
			   ((.value.ua // "-") | .[0:40])] | @tsv' "$f" \
			2> /dev/null
	done < <(fleet_users)
}

fleet_audit_file() {
	printf '%s/audit.log' "${appliance_etc:-/etc/coworkstation}"
}

# Append one operator action to the local ops log (0600). Best-effort
# by design: reporting must never block the action it records.
fleet_audit_record() {
	local action="$1"
	local target="$2"
	local f
	f=$(fleet_audit_file)
	mkdir -p "$(dirname "$f")" 2> /dev/null
	printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"${SUDO_USER:-$(id -un)}" "$action" "$target" >> "$f" \
		2> /dev/null || return 0
	chmod 600 "$f" 2> /dev/null
	return 0
}

# Remote session action: start|stop|restart a member's desktop.
# Every action lands in the ops log with who ran it.
fleet_session_ctl() {
	local action="$1"
	local user="$2"
	case "$action" in
		start|stop|restart) ;;
		*)
			log_err "unknown session action '$action'" \
				'(start|stop|restart)'
			return 1
			;;
	esac
	if [[ -z $user ]]; then
		log_err "usage: cws sessions $action USER"
		return 1
	fi
	local home
	home=$(user_home "$user") || return 1
	if [[ ! -f $home/.config/systemd/user/kasmvnc.service ]]; then
		log_err "no session provisioned for '$user'"
		return 1
	fi
	user_systemctl "$user" "$action" kasmvnc.service || return 1
	fleet_audit_record "session-$action" "$user"
	log_info "session $action: $user"
}

# Session unit events (started/stopped/failed) from journald, with
# UIDs resolved to names. $1 = days back (default 7).
fleet_audit_unit_events() {
	local days="${1:-7}"
	if ! command -v journalctl > /dev/null 2>&1; then
		log_warn 'journalctl unavailable; no unit events'
		return 0
	fi
	printf 'TIME\tUSER\tEVENT\n'
	local ts uid msg user
	while IFS=$'\t' read -r ts uid msg; do
		user=$(getent passwd "$uid" 2> /dev/null | cut -d: -f1)
		printf '%s\t%s\t%s\n' \
			"$(date -u -d "@$((ts / 1000000))" +%Y-%m-%dT%H:%M:%SZ)" \
			"${user:-uid:$uid}" "$msg"
	done < <(journalctl -q -o json --since "-${days}d" \
		_SYSTEMD_USER_UNIT=kasmvnc.service + USER_UNIT=kasmvnc.service \
		2> /dev/null \
		| jq -r 'select(.MESSAGE | test("Started|Stopped|Failed"))
			| [(.__REALTIME_TIMESTAMP // "0"),
			   (._UID // "0"), .MESSAGE] | @tsv')
}

# Access login history from the Cloudflare API (api mode only):
# who authenticated to which hostname, when, from where. This is the
# identity side of the audit trail — every session connection passed
# through Access first.
fleet_audit_access() {
	local limit="${1:-25}"
	if [[ $(tunnel_conf_get mode 2> /dev/null) != 'api' ]]; then
		log_info 'manual tunnel mode: Access login history lives in' \
			'the Cloudflare dashboard (Zero Trust -> Logs -> Access)'
		return 0
	fi
	local token_file account
	token_file=$(tunnel_conf_get token_file) || return 1
	account=$(tunnel_conf_get account_id) || return 1
	tunnel_api_load_token "$token_file" || return 1
	local rows
	if ! rows=$(cf_call GET \
		"/accounts/$account/access/logs/access_requests?limit=$limit" \
		| jq -r '.result[]?
			| [.created_at, (.user_email // "-"),
			   (.app_domain // "-"),
			   (if .allowed == false then "BLOCKED" else "allowed" end),
			   (.ip_address // "-")] | @tsv'); then
		log_warn 'could not fetch Access logs — the API token may' \
			'need the "Access: Audit Logs : Read" permission'
		return 1
	fi
	printf 'TIME\tIDENTITY\tHOSTNAME\tRESULT\tFROM\n'
	printf '%s\n' "$rows"
}

# The combined audit trail. $1 = days back for unit events.
fleet_audit() {
	local days="${1:-7}"
	printf '=== Access logins (identity, via Cloudflare) ===\n'
	fleet_audit_access 25 || true
	printf '\n=== Session unit events (last %s days) ===\n' "$days"
	fleet_audit_unit_events "$days"
	local f
	f=$(fleet_audit_file)
	printf '\n=== Operator actions (%s) ===\n' "$f"
	if [[ -s $f ]]; then
		tail -n 25 "$f"
	else
		printf '(none recorded yet)\n'
	fi
}

# Usage table across the fleet (or the named users).
# Token figures cover Claude Code sessions only — the chat/Cowork
# tabs do not write local usage logs (see ADR-007).
fleet_usage() {
	local -a users=("$@")
	if [[ ${#users[@]} -eq 0 ]]; then
		mapfile -t users < <(fleet_users)
	fi
	if [[ ${#users[@]} -eq 0 ]]; then
		log_warn 'no session accounts found'
		return 0
	fi
	printf 'USER\tMSGS\tINPUT\tOUTPUT\tCACHE_RD\tCACHE_WR\tLAST\n'
	local user row
	for user in "${users[@]}"; do
		if ! id "$user" > /dev/null 2>&1; then
			log_warn "no such user: $user"
			continue
		fi
		row=$(fleet_usage_scan "$user") || continue
		printf '%s\t%s\n' "$user" "$row"
	done
}
