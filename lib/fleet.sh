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
# Sourced by cws. Read-only: nothing here mutates state.
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
