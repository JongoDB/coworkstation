# shellcheck shell=bash
#===============================================================================
# Client bridge — browser tier of the client-first-class story
#
# Per user: a loopback node server (bridge/server.js) reachable ONLY
# through the session hostname's /bridge/* path route on the existing
# Cloudflare tunnel — same Access gate, no new hostname, no new DNS.
# The page it serves lets the connecting device share a folder
# (desktop Chrome/Edge) and, with loud per-session consent, its
# screen; the client-screen MCP server hands the live frame to
# Claude and refuses stale ones.
#
# A per-user bearer token (~/.config/cws-bridge/token, 0600) gates
# every non-static endpoint so other local users on the shared box
# cannot inject frames/files over loopback. `cws client bridge-link`
# prints the tokened URL to hand to the user.
#
# Sourced by setup.sh, member.sh, and cws.
#===============================================================================

# Bridge port per member display (display 1 -> 8600). Outside the
# doctor's session-port scan ranges and kasmVNC's 8443+ range.
clientbridge_port() { printf '%s' $((8599 + ${1:-1})); }

clientbridge_install_packages() {
	# xclip powers the clipboard bridge; missing is fine (the server
	# falls back to a file), so don't fail setup over it.
	if ! command -v xclip > /dev/null 2>&1; then
		pkg_install xclip || log_warn 'xclip unavailable;' \
			'clipboard bridge will use the file fallback'
	fi
	if command -v node > /dev/null 2>&1; then
		return 0
	fi
	pkg_install nodejs
}

# systemd user unit for the bridge server.
# Args: bridge_dir port display
clientbridge_unit() {
	local dir="$1"
	local port="$2"
	local display="${3:-1}"
	cat << EOF
[Unit]
Description=Coworkstation client bridge
After=network.target

[Service]
Environment=CWS_BRIDGE_PORT=${port}
Environment=CWS_BRIDGE_DISPLAY=:${display}
ExecStart=/usr/bin/env node ${dir}/server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

# mcpServers fragment for the client-screen server.
clientbridge_mcp_snippet() {
	local dir="$1"
	cat << EOF
{
  "mcpServers": {
    "client-screen": {
      "command": "node",
      "args": ["${dir}/client-screen-mcp.js"]
    }
  }
}
EOF
}

# Merge the client-screen MCP entry into the user's Claude config,
# preserving unrelated keys. $1 = user, $2 = bridge dir
clientbridge_register_mcp() {
	local user="$1"
	local dir="$2"
	local home
	home=$(user_home "$user") || return 1
	local conf_dir="$home/.config/Claude"
	local conf="$conf_dir/claude_desktop_config.json"
	local addition
	addition=$(clientbridge_mcp_snippet "$dir")

	run_as_user "$user" mkdir -p "$conf_dir" || return 1
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: merge client-screen MCP into %s\n' "$conf"
		return 0
	fi
	local base='{}'
	if [[ -s $conf ]]; then
		base=$(cat "$conf")
	fi
	local merged
	merged=$(jq -s '.[0] * .[1]' \
		<(printf '%s' "$base") <(printf '%s' "$addition")) || {
		log_err "existing $conf is not valid JSON; not touching it"
		return 1
	}
	printf '%s\n' "$merged" > "$conf" || return 1
	chown "$user:$user" "$conf"
}

# Provision the bridge for a user. $1 = user, $2 = display number,
# $3 = session hostname ('' = skip the tunnel route).
clientbridge_setup() {
	local user="$1"
	local display="${2:-1}"
	local hostname="${3:-}"
	local port
	port=$(clientbridge_port "$display")

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: clientbridge for %s (port %s, host %s)\n' \
			"$user" "$port" "${hostname:-none}"
		return 0
	fi

	clientbridge_install_packages || return 1

	local home
	home=$(user_home "$user") || return 1
	local bridge_dir
	bridge_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bridge" && pwd)

	# Per-user bearer token, 0600.
	local token_dir="$home/.config/cws-bridge"
	run_as_user "$user" mkdir -p "$token_dir" || return 1
	if [[ ! -f $token_dir/token ]]; then
		head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' \
			| head -c 32 > "$token_dir/token" || return 1
		chmod 600 "$token_dir/token"
		chown "$user:$user" "$token_dir/token"
	fi

	local unit_dir="$home/.config/systemd/user"
	run_as_user "$user" mkdir -p "$unit_dir" || return 1
	clientbridge_unit "$bridge_dir" "$port" "$display" \
		| write_file "$unit_dir/cws-bridge.service" || return 1
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		chown "$user:$user" "$unit_dir/cws-bridge.service"
	fi
	user_systemctl "$user" enable --now cws-bridge.service || return 1

	clientbridge_register_mcp "$user" "$bridge_dir" || return 1

	# Route /bridge/* on the session hostname to this port (api mode).
	if [[ -n $hostname ]]; then
		if [[ $(tunnel_conf_get mode 2> /dev/null) == 'api' ]]; then
			tunnel_api_bridge_route "$hostname" "$port" || return 1
		else
			log_info "manual tunnel: add a /bridge/* path rule for" \
				"$hostname -> http://127.0.0.1:$port yourself"
		fi
	fi
	log_info "client bridge ready for $user;" \
		"share the link from: sudo cws client bridge-link"
}

# The tokened URL to hand to the user. $1 = user, $2 = hostname.
clientbridge_link() {
	local user="$1"
	local hostname="$2"
	local home
	home=$(user_home "$user") || return 1
	local token_file="$home/.config/cws-bridge/token"
	if [[ ! -r $token_file ]]; then
		log_err "no bridge token for $user (run: sudo cws client" \
			'bridge-setup, or re-run setup)'
		return 1
	fi
	printf 'https://%s/bridge/?t=%s\n' "$hostname" "$(cat "$token_file")"
}

# cws client screenshot [DEST] — copy the latest shared frame to DEST so
# Cowork's built-in device tools (device_bash + device_stage_files) can
# stage and view it. Claude Desktop 1.18286.0 does not surface local MCP
# server tools to the Cowork model, so the client_screenshot MCP tool is
# unreachable there; this rides the device-tools path instead. Refuses a
# missing or stale (>20s) frame, matching the client-screen MCP server.
clientbridge_screenshot() {
	local dest="${1:-client-screen.jpg}"
	local runtime
	runtime="${CWS_BRIDGE_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/cws-bridge}"
	local jpg="$runtime/latest.jpg"
	local meta="$runtime/latest.meta"
	if [[ ! -f $meta || ! -f $jpg ]]; then
		log_err 'no client screen is being shared — open the bridge' \
			'page and press "Start screen share"'
		return 1
	fi
	local ts
	ts=$(jq -r '.ts // empty' "$meta" 2> /dev/null)
	if [[ -z $ts ]]; then
		log_err 'client screen frame metadata is unreadable'
		return 1
	fi
	# meta.ts is epoch ms; compare in whole seconds for a portable date.
	local age=$(( $(date +%s) - ts / 1000 ))
	if (( age > 20 )); then
		log_err "client screen share looks stopped (last frame ${age}s" \
			'ago) — restart it and try again'
		return 1
	fi
	cp "$jpg" "$dest" || return 1
	printf '%s\n' "$dest"
}
