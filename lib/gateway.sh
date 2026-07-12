# shellcheck shell=bash
#===============================================================================
# Kiosk gateway — branded cookie login in front of a kasmVNC session
#
# Per user: a loopback node server (gateway/server.js) that serves a
# branded login page + PWA assets and proxies the kasm client and its
# /websockify WebSocket upstream once a signed session cookie is set.
# kasmVNC is HTTP Basic-auth only (no login page to theme), so the shim
# is how the phone/tablet PWA gets a clean "enter password -> land in the
# app" entry instead of the browser's Basic auth dialog.
#
# The Cloudflare tunnel routes the session hostname to the gateway port
# (see the kiosk wiring in setup.sh/member.sh); the gateway proxies to the
# kasm port on loopback. When the gateway fronts kasm, kasm's own Basic
# auth is disabled (gate moves to the shim — operator choice).
#
# Sourced by setup.sh and member.sh.
#===============================================================================

# Gateway port per member display (display 1 -> 8701). Clear of kasmVNC
# (8443+) and the client bridge (8600+).
gateway_port() { printf '%s' $((8700 + ${1:-1})); }

gateway_install_packages() {
	if command -v node > /dev/null 2>&1; then
		return 0
	fi
	pkg_install nodejs
}

# systemd user unit for the gateway server.
# Args: dir port upstream cred secret www scale_file
gateway_unit() {
	local dir="$1" port="$2" upstream="$3" cred="$4"
	local secret="$5" www="$6" scale_file="$7"
	cat << EOF
[Unit]
Description=Coworkstation kiosk gateway (branded login)
After=network.target

[Service]
Environment=CWS_GW_PORT=${port}
Environment=CWS_GW_UPSTREAM=${upstream}
Environment=CWS_GW_CRED=${cred}
Environment=CWS_GW_SECRET=${secret}
Environment=CWS_GW_WWW=${www}
Environment=CWS_GW_SCALE_FILE=${scale_file}
ExecStart=/usr/bin/env node ${dir}/server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

# Provision the gateway for a user. $1 = user, $2 = display number,
# $3 = kasm websocket (upstream) port.
gateway_setup() {
	local user="$1"
	local display="${2:-1}"
	local kasm_port="$3"
	local port
	port=$(gateway_port "$display")

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: gateway for %s (port %s -> kasm %s)\n' \
			"$user" "$port" "$kasm_port"
		return 0
	fi

	gateway_install_packages || return 1

	local home
	home=$(user_home "$user") || return 1
	local gw_dir
	gw_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../gateway" && pwd)

	# Per-user signing secret for session cookies, 0600.
	local conf_dir="$home/.config/cws-gateway"
	run_as_user "$user" mkdir -p "$conf_dir" || return 1
	local secret="$conf_dir/secret"
	if [[ ! -f $secret ]]; then
		head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' \
			| head -c 43 > "$secret" || return 1
		chmod 600 "$secret"
		chown "$user:$user" "$secret"
	fi

	local cred="$home/.vnc/kasm-credentials"
	local scale_file="$home/.config/Claude/device-scale"
	local unit_dir="$home/.config/systemd/user"
	run_as_user "$user" mkdir -p "$unit_dir" || return 1
	gateway_unit "$gw_dir" "$port" "$kasm_port" "$cred" "$secret" \
		"$gw_dir/www" "$scale_file" \
		| write_file "$unit_dir/cws-gateway.service" || return 1
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		chown "$user:$user" "$unit_dir/cws-gateway.service"
	fi
	user_systemctl "$user" enable --now cws-gateway.service || return 1
	log_info "kiosk gateway ready for $user (127.0.0.1:$port ->" \
		"kasm 127.0.0.1:$kasm_port)"
}

# Remove the gateway for a user (kiosk turned off). $1 = user.
gateway_teardown() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 0
	local unit="$home/.config/systemd/user/cws-gateway.service"
	[[ -f $unit ]] || return 0
	user_systemctl "$user" disable --now cws-gateway.service 2> /dev/null
	rm -f "$unit"
}

# Point a hostname's tunnel ingress at a local port (api mode only; manual
# mode gets a hint). Idempotent. $1 = hostname, $2 = port.
gateway_reroute() {
	local hostname="$1"
	local port="$2"
	[[ -z $hostname ]] && return 0
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: reroute %s -> 127.0.0.1:%s\n' "$hostname" "$port"
		return 0
	fi
	if [[ $(tunnel_conf_get mode 2> /dev/null) == 'api' ]]; then
		tunnel_api_reroute "$hostname" "$port" || return 1
	else
		log_info "manual tunnel: point $hostname -> 127.0.0.1:$port yourself"
	fi
}

# Enable or disable the kiosk gateway for one session AND route its tunnel
# accordingly. Turning off is a no-op unless a gateway was set up (so a
# never-kiosk box never touches the tunnel). The kasm Basic gate stays on;
# the gateway injects it, so 'off' just points the hostname back at kasm.
# $1=user $2=display $3=kasm_port $4=hostname $5=on|off
gateway_route() {
	local user="$1"
	local display="$2"
	local kasm_port="$3"
	local hostname="$4"
	local mode="$5"
	local gport
	gport=$(gateway_port "$display")

	if [[ $mode == on ]]; then
		gateway_setup "$user" "$display" "$kasm_port" || return 1
		gateway_reroute "$hostname" "$gport" || return 1
	else
		local home unit
		home=$(user_home "$user") || return 0
		unit="$home/.config/systemd/user/cws-gateway.service"
		if [[ -f $unit || ${appliance_dry_run:-0} -eq 1 ]]; then
			gateway_reroute "$hostname" "$kasm_port" || return 1
			gateway_teardown "$user"
		fi
	fi
}
