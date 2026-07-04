# shellcheck shell=bash
#===============================================================================
# kasmVNC profile — default session layer
#
# Serves the member's XFCE session as an HTTPS-in-browser desktop on a
# localhost port; cloudflared carries it to the edge. TLS is disabled
# locally on purpose: it terminates at the tunnel, and raw ports never
# leave loopback (the doctor fails loudly if one does).
#
# Sourced by appliance/setup.sh and appliance/member.sh.
#===============================================================================

# First member's websocket port; member.sh allocates upward from here.
appliance_kasm_base_port=8443

kasmvnc_release_base='https://github.com/kasmtech/KasmVNC/releases/download'
kasmvnc_version="${APPLIANCE_KASMVNC_VERSION:-1.3.3}"

# Compose the release .deb URL for this distro/arch.
kasmvnc_deb_url() {
	local codename arch
	codename=$(appliance_distro_codename)
	arch=$(appliance_arch)
	if [[ -z $codename ]]; then
		log_err 'cannot determine distro codename for kasmVNC deb'
		return 1
	fi
	printf '%s/v%s/kasmvncserver_%s_%s_%s.deb' \
		"$kasmvnc_release_base" "$kasmvnc_version" \
		"$codename" "$kasmvnc_version" "$arch"
}

profile_kasmvnc_install_packages() {
	local url tmp_deb
	url=$(kasmvnc_deb_url) || return 1
	tmp_deb="${TMPDIR:-/tmp}/kasmvncserver.deb"

	if command -v kasmvncserver > /dev/null 2>&1 \
		|| dpkg -s kasmvncserver > /dev/null 2>&1; then
		log_info 'kasmvncserver already installed'
	else
		run_cmd curl -fsSLo "$tmp_deb" "$url" || return 1
		pkg_install "$tmp_deb" || return 1
		run_cmd rm -f "$tmp_deb"
	fi
}

# KasmVNC 1.3.x requires a TLS cert+key even when require_ssl is false
# (TLS terminates at the Cloudflare tunnel). Its default points at the
# system snakeoil key /etc/ssl/private/ssl-cert-snakeoil.key, which is
# mode 0640 root:ssl-cert and unreadable by the session user — vncserver
# then exits 1 with "certificate file doesn't exist or isn't a file".
# Give each user their OWN self-signed cert under ~/.vnc so there is no
# dependency on system cert ownership/permissions.
# $1 = user
profile_kasmvnc_setup_cert() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 1
	local key="$home/.vnc/self.key"
	local pem="$home/.vnc/self.pem"

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: generate kasmvnc self-signed cert for %s\n' \
			"$user"
		return 0
	fi
	if [[ -f $key && -f $pem ]]; then
		log_info "kasmVNC cert already present for $user"
		return 0
	fi
	run_as_user "$user" mkdir -p "$home/.vnc" || return 1
	if ! runuser -u "$user" -- openssl req -x509 -nodes \
		-newkey rsa:2048 -days 3650 \
		-keyout "$key" -out "$pem" -subj '/CN=localhost' \
		> /dev/null 2>&1; then
		log_err "failed to generate kasmVNC cert for $user"
		return 1
	fi
	run_as_user "$user" chmod 600 "$key" || return 1
	log_info "kasmVNC self-signed cert generated for $user"
}

# Per-user kasmVNC config: loopback bind, tunnel-terminated TLS.
# $1 = user, $2 = websocket port
profile_kasmvnc_write_config() {
	local user="$1"
	local port="$2"
	local home
	home=$(user_home "$user") || return 1

	run_as_user "$user" mkdir -p "$home/.vnc" || return 1
	kasmvnc_yaml "$port" "$home" \
		| write_file "$home/.vnc/kasmvnc.yaml" || return 1
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		chown "$user:$user" "$home/.vnc/kasmvnc.yaml"
	fi
	kasmvnc_xstartup | write_file "$home/.vnc/xstartup" 755 || return 1
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		chown "$user:$user" "$home/.vnc/xstartup"
	fi
}

kasmvnc_yaml() {
	local port="$1"
	local home="$2"
	cat << EOF
network:
  interface: 127.0.0.1
  websocket_port: ${port}
  ssl:
    require_ssl: false
    pem_certificate: ${home}/.vnc/self.pem
    pem_key: ${home}/.vnc/self.key
EOF
}

kasmvnc_xstartup() {
	cat << 'EOF'
#!/bin/sh
exec startxfce4
EOF
}

# KasmVNC 1.3.x's vncserver prompts interactively on first run for a
# control user ("Create a new user with write access… Provide selection
# number:"). In a headless systemd context stdin is empty, so it loops
# forever on "Invalid choice" and never binds a listener. Pre-create the
# kasm control user non-interactively (writing ~/.kasmpasswd) so the
# prompt is skipped. A random password is generated and stored for the
# member in ~/.vnc/kasm-credentials; the primary gate is Cloudflare
# Access in front of the session.
# $1 = user
profile_kasmvnc_setup_auth() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 1
	local passfile="$home/.kasmpasswd"
	local credfile="$home/.vnc/kasm-credentials"

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: create kasmvnc control user for %s\n' "$user"
		return 0
	fi
	if [[ -f $passfile ]]; then
		log_info "kasmVNC control user already configured for $user"
		return 0
	fi

	local pw
	pw=$(kasmvnc_gen_password)
	# kasmvncpasswd reads the password twice from stdin; -u sets the
	# username, -w grants write (desktop-control) access.
	if ! printf '%s\n%s\n' "$pw" "$pw" \
		| runuser -u "$user" -- kasmvncpasswd -u "$user" -w \
			> /dev/null 2>&1; then
		log_err "kasmvncpasswd failed to create control user $user"
		return 1
	fi
	printf 'username=%s\npassword=%s\n' "$user" "$pw" \
		| write_file "$credfile" 600 || return 1
	chown "$user:$user" "$credfile" 2> /dev/null || true
	log_info "kasmVNC control user '$user' created" \
		"(credentials in $credfile)"
}

# 16-char alphanumeric password from the kernel CSPRNG.
kasmvnc_gen_password() {
	local raw
	raw=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
	printf '%s' "${raw:0:16}"
}

# systemd user service so the session survives logout and starts at
# boot (paired with loginctl enable-linger).
# $1 = user, $2 = X display number (unique per member on the host)
profile_kasmvnc_write_service() {
	local user="$1"
	local display="${2:-1}"
	local home
	home=$(user_home "$user") || return 1
	local unit_dir="$home/.config/systemd/user"

	run_as_user "$user" mkdir -p "$unit_dir" || return 1
	kasmvnc_unit "$display" \
		| write_file "$unit_dir/kasmvnc.service" || return 1
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		chown "$user:$user" "$unit_dir/kasmvnc.service"
	fi
	# enable --now so the session starts during setup (not just at the
	# next boot), via the headless-safe user-manager helper.
	user_systemctl "$user" enable --now kasmvnc.service
}

kasmvnc_unit() {
	local display="${1:-1}"
	cat << EOF
[Unit]
Description=kasmVNC session (Claude appliance)
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/vncserver :${display} -select-de manual
ExecStop=/usr/bin/vncserver -kill :${display}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

# cloudflared package from Cloudflare's apt repo (shared by the
# manual and api tunnel modes).
profile_kasmvnc_install_cloudflared() {
	local keyring='/usr/share/keyrings/cloudflare-main.gpg'
	local list='/etc/apt/sources.list.d/cloudflared.list'

	if command -v cloudflared > /dev/null 2>&1; then
		return 0
	fi
	if [[ ! -f $keyring ]]; then
		if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
			printf 'DRY-RUN: install cloudflare apt key -> %s\n' \
				"$keyring"
		else
			curl -fsSL \
				https://pkg.cloudflare.com/cloudflare-main.gpg \
				-o "$keyring" || return 1
		fi
	fi
	printf 'deb [signed-by=%s] %s %s main' "$keyring" \
		'https://pkg.cloudflare.com/cloudflared' \
		"$(appliance_distro_codename)" | write_file "$list" \
		|| return 1
	run_cmd apt-get update || return 1
	pkg_install cloudflared
}

# Manual tunnel mode: config skeleton the operator finishes after the
# interactive `cloudflared tunnel login`.
# $1 = public hostname, $2 = local websocket port
profile_kasmvnc_setup_tunnel() {
	local hostname="$1"
	local port="$2"

	profile_kasmvnc_install_cloudflared || return 1

	cloudflared_config "$hostname" "$port" \
		| write_file /etc/cloudflared/config.yml || return 1

	log_info 'cloudflared installed. Finish the tunnel interactively:'
	log_info '  1. cloudflared tunnel login'
	log_info '  2. cloudflared tunnel create claude-appliance'
	log_info '  3. set "tunnel:" and "credentials-file:" in'
	log_info '     /etc/cloudflared/config.yml'
	log_info "  4. cloudflared tunnel route dns claude-appliance $hostname"
	log_info '  5. cloudflared service install && systemctl start cloudflared'
	log_info '  6. protect the hostname with a Cloudflare Access policy'
}

cloudflared_config() {
	local hostname="$1"
	local port="$2"
	cat << EOF
# Claude appliance tunnel. Set "tunnel" and "credentials-file" after
# running: cloudflared tunnel login && cloudflared tunnel create ...
# tunnel: <TUNNEL-UUID>
# credentials-file: /root/.cloudflared/<TUNNEL-UUID>.json

ingress:
  - hostname: ${hostname}
    service: http://127.0.0.1:${port}
  - service: http_status:404
EOF
}

# Full profile: packages, per-user config, service, tunnel.
# $1 = user, $2 = public hostname,
# $3 = tunnel mode: manual (default) | api,
# $4 = token file (api mode), $5 = Access allow csv (api mode)
profile_kasmvnc_apply() {
	local user="$1"
	local hostname="$2"
	local tunnel_mode="${3:-manual}"
	local token_file="${4:-}"
	local allow_csv="${5:-}"
	local port="$appliance_kasm_base_port"

	profile_kasmvnc_install_packages || return 1
	profile_kasmvnc_setup_cert "$user" || return 1
	profile_kasmvnc_write_config "$user" "$port" || return 1
	profile_kasmvnc_setup_auth "$user" || return 1
	profile_kasmvnc_write_service "$user" || return 1
	if [[ -z $hostname ]]; then
		log_warn 'no --hostname given: skipping cloudflared setup'
		return 0
	fi
	if [[ $tunnel_mode == 'api' ]]; then
		profile_kasmvnc_install_cloudflared || return 1
		tunnel_api_provision "$hostname" "$port" \
			"$token_file" "$allow_csv"
	else
		profile_kasmvnc_setup_tunnel "$hostname" "$port"
	fi
}
