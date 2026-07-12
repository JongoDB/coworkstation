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

# kasmVNC publishes a per-codename .deb but lags brand-new distro
# releases, so the host codename may have no matching asset (e.g. Debian
# 13 "trixie" 404s). Map the host codename to the newest kasmVNC-built
# codename in the same family; a bookworm/noble build runs fine on the
# next release. An unknown codename is returned as-is so the download's
# own check surfaces a clear error.
kasmvnc_codename() {
	case "$1" in
		# Ubuntu builds kasmVNC ships
		bionic|focal|jammy|noble) printf '%s' "$1" ;;
		# newer Ubuntu -> newest shipped LTS
		oracular|plucky|questing) printf 'noble' ;;
		# Debian builds kasmVNC ships
		buster|bullseye|bookworm) printf '%s' "$1" ;;
		# newer Debian -> newest shipped stable
		trixie|forky|sid) printf 'bookworm' ;;
		*) printf '%s' "$1" ;;
	esac
}

# Compose the release .deb URL for this distro/arch.
kasmvnc_deb_url() {
	local codename arch
	codename=$(kasmvnc_codename "$(appliance_distro_codename)")
	arch=$(appliance_arch)
	if [[ -z $codename ]]; then
		log_err 'cannot determine distro codename for kasmVNC deb'
		return 1
	fi
	printf '%s/v%s/kasmvncserver_%s_%s_%s.deb' \
		"$kasmvnc_release_base" "$kasmvnc_version" \
		"$codename" "$kasmvnc_version" "$arch"
}

# Kiosk mode replaces XFCE with a minimal WM. matchbox-window-manager is
# the single-app kiosk WM (force-fullscreens the top window);
# x11-xserver-utils provides xsetroot for the branded backdrop. A default
# browser is also required: Claude's "Continue with Google" OAuth opens
# the system browser for the handoff (without one it dies with "Failed to
# execute default Web Browser"), and the appliance ships none.
profile_kasmvnc_install_kiosk_deps() {
	if ! command -v matchbox-window-manager > /dev/null 2>&1; then
		# matchbox = kiosk WM; x11-xserver-utils = xsetroot backdrop;
		# xdotool = the supervisor's window detection (no-strand recycle).
		pkg_install matchbox-window-manager x11-xserver-utils xdotool \
			|| return 1
	else
		log_info 'kiosk WM (matchbox) already installed'
	fi
	kasmvnc_install_default_browser
}

# The kiosk desktop-file id of the default browser (Chrome on amd64,
# Chromium elsewhere — Google ships no arm64 Chrome .deb).
kasmvnc_browser_desktop() {
	if [[ $(appliance_arch) == amd64 ]]; then
		printf 'google-chrome.desktop'
	else
		printf 'chromium.desktop'
	fi
}

# Install a default web browser for the OAuth handoff and set it as the
# system fallback. amd64 -> Google Chrome (most reliable for Google
# sign-in); other arches -> Chromium (Google ships no arm64 Chrome deb).
kasmvnc_install_default_browser() {
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: install default browser (%s)\n' \
			"$(kasmvnc_browser_desktop)"
		return 0
	fi
	if [[ $(appliance_arch) != amd64 ]]; then
		if ! command -v chromium-browser > /dev/null 2>&1 \
			&& ! command -v chromium > /dev/null 2>&1; then
			pkg_install chromium-browser || pkg_install chromium \
				|| log_warn 'no browser installed; Google sign-in' \
					'(Continue with Google) will fail on this arch'
		fi
		return 0
	fi
	local bin='/usr/bin/google-chrome-stable'
	if ! command -v google-chrome-stable > /dev/null 2>&1; then
		local key='/usr/share/keyrings/google-chrome.gpg'
		local list='/etc/apt/sources.list.d/google-chrome.list'
		if [[ ! -f $key ]]; then
			curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
				| gpg --dearmor -o "$key" 2> /dev/null || return 1
		fi
		printf 'deb [arch=amd64 signed-by=%s] %s stable main' "$key" \
			'http://dl.google.com/linux/chrome/deb/' \
			| write_file "$list" || return 1
		run_cmd apt-get update || return 1
		pkg_install google-chrome-stable || return 1
	fi
	# System fallback so sensible-browser/x-www-browser resolve too.
	run_cmd update-alternatives --install /usr/bin/x-www-browser \
		x-www-browser "$bin" 200 2> /dev/null || true
	run_cmd update-alternatives --set x-www-browser "$bin" 2> /dev/null || true
}

# Point a user's xdg defaults at the installed browser so Claude's
# xdg-open handoff (http/https + the OAuth redirect) resolves. Writes
# ~/.config/mimeapps.list; no DISPLAY needed. $1 = user.
kasmvnc_set_default_browser() {
	local user="$1"
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: set default browser for %s\n' "$user"
		return 0
	fi
	local desktop
	desktop=$(kasmvnc_browser_desktop)
	run_as_user "$user" xdg-mime default "$desktop" \
		x-scheme-handler/http x-scheme-handler/https text/html \
		2> /dev/null || true
}

profile_kasmvnc_install_packages() {
	local url tmp_deb
	url=$(kasmvnc_deb_url) || return 1
	tmp_deb="${TMPDIR:-/tmp}/kasmvncserver.deb"

	if command -v kasmvncserver > /dev/null 2>&1 \
		|| dpkg -s kasmvncserver > /dev/null 2>&1; then
		log_info 'kasmvncserver already installed'
	else
		if ! run_cmd curl -fsSLo "$tmp_deb" "$url"; then
			log_err "kasmVNC $kasmvnc_version has no .deb at $url"
			log_err '  (this distro/arch may be newer than kasmVNC' \
				'ships; set APPLIANCE_KASMVNC_VERSION to a release' \
				'that covers your codename, or use --profile xrdp)'
			return 1
		fi
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
	# umask 077 in the child so the private key is never briefly readable
	# between creation and the explicit chmod.
	# shellcheck disable=SC2016  # $1/$2 must expand in the child sh, not here
	if ! runuser -u "$user" -- sh -c \
		'umask 077; openssl req -x509 -nodes -newkey rsa:2048 \
		-days 3650 -keyout "$1" -out "$2" -subj "/CN=localhost" \
		> /dev/null 2>&1' openssl-cert "$key" "$pem"; then
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
	kasmvnc_xstartup "$(kasmvnc_mode)" \
		| write_file "$home/.vnc/xstartup" 755 || return 1
	if [[ ${appliance_dry_run:-0} -ne 1 ]]; then
		chown "$user:$user" "$home/.vnc/xstartup"
	fi
}

# Session UI mode baked into the generated xstartup: 'kiosk' (Claude-only
# appliance — a minimal WM plus a supervised Claude, no XFCE) or
# 'desktop' (the full XFCE session). Driven by appliance_kiosk, which
# setup/reconfigure derive from appliance.conf's kiosk= flag; defaults to
# desktop so an un-flagged box is unchanged.
kasmvnc_mode() {
	if [[ ${appliance_kiosk:-0} -eq 1 ]]; then
		printf 'kiosk'
	else
		printf 'desktop'
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

# $1 = mode (kiosk|desktop); default desktop. The desktop path is the
# original full-XFCE session, kept as the rollback lever; kiosk is the
# Claude-only appliance UI.
kasmvnc_xstartup() {
	if [[ ${1:-desktop} == kiosk ]]; then
		kasmvnc_xstartup_kiosk
	else
		kasmvnc_xstartup_desktop
	fi
}

kasmvnc_xstartup_desktop() {
	cat << 'EOF'
#!/bin/sh
# Extra sessions (displays :50 and up, see lib/session.sh) get their
# own config home so a second Claude Desktop runs beside the first —
# the singleton lock is per config dir — with its own sign-in.
dnum=${DISPLAY#:}
dnum=${dnum%%.*}
if [ "$dnum" -ge 50 ] 2> /dev/null; then
	XDG_CONFIG_HOME="$HOME/.config/cws-sessions/$dnum"
	export XDG_CONFIG_HOME
	mkdir -p "$XDG_CONFIG_HOME"
	# Seed the Claude autostart entry — XDG autostart is read from
	# the (redirected) config home, so without this an extra session
	# opens an empty desktop.
	if [ -f "$HOME/.config/autostart/claude-desktop.desktop" ] \
		&& [ ! -f "$XDG_CONFIG_HOME/autostart/claude-desktop.desktop" ]
	then
		mkdir -p "$XDG_CONFIG_HOME/autostart"
		cp "$HOME/.config/autostart/claude-desktop.desktop" \
			"$XDG_CONFIG_HOME/autostart/"
	fi
	# All sessions of one member share the systemd user D-Bus bus
	# (/run/user/<uid>/bus). xfce4-session's org.xfce.SessionManager is
	# a per-bus singleton, so a second desktop on that shared bus finds
	# the name already owned by the primary and exits at once — the X
	# server keeps running, so the client just sees a black screen.
	# Give each extra session its own private bus so its full desktop
	# (xfce4-session, panel, and Claude) can start beside the primary.
	exec dbus-run-session -- startxfce4
fi
exec startxfce4
EOF
}

# Kiosk session: one fullscreen Claude Desktop, no XFCE. The container is
# the appliance, not a workspace, so instead of a desktop we run a
# minimal window manager that force-fullscreens Claude, plus a supervisor
# that relaunches Claude if it exits — nothing else keeps the session
# alive once XFCE is gone, so without the supervisor a crash would leave
# a black screen.
kasmvnc_xstartup_kiosk() {
	cat << 'EOF'
#!/bin/sh
dnum=${DISPLAY#:}
dnum=${dnum%%.*}
# Extra per-device sessions (displays :50+, see lib/session.sh) get their
# own config home — a second Claude beside the first, its own singleton
# and sign-in — and their own private D-Bus bus, since the shared user
# bus's secret-service proxy and singletons collide (the black-screen
# case PR #1 fixed for the desktop path). Re-exec self once under a fresh
# bus, guarded against recursion, so the kiosk tail below runs identically
# on either the shared bus (primary) or a private bus (extra session).
if [ "${dnum:-0}" -ge 50 ] 2> /dev/null; then
	XDG_CONFIG_HOME="$HOME/.config/cws-sessions/$dnum"
	export XDG_CONFIG_HOME
	mkdir -p "$XDG_CONFIG_HOME"
	if [ -z "$CWS_KIOSK_BUS" ]; then
		CWS_KIOSK_BUS=1
		export CWS_KIOSK_BUS
		exec dbus-run-session -- "$0"
	fi
fi

# Branded backdrop so any letterbox around Claude is brand color, not the
# default desktop gray.
xsetroot -solid '#1c1c1c' 2> /dev/null || true
# Minimal kiosk WM: force-fullscreen the top window, no titlebar/taskbar.
matchbox-window-manager -use_titlebar no &

# Is a Claude window currently on screen? Match by the launched process's
# own windows (_NET_WM_PID), not WM_CLASS — Claude's main content window
# does not carry the app class reliably, but every window it owns reports
# its pid. When Claude hides to tray (its close/minimize) all its windows
# drop out of --onlyvisible, so an empty result means the screen is blank.
claude_up() {
	[ -n "$(xdotool search --pid "$cpid" --onlyvisible 2> /dev/null)" ]
}
# Is Claude's OAuth browser running? It opens Chrome for "Continue with
# Google"; matchbox may unmap Claude beneath it, so don't recycle Claude
# out from under a sign-in just because its window is momentarily hidden.
browser_up() {
	pgrep -x chrome > /dev/null 2>&1 \
		|| pgrep -f 'google-chrome ' > /dev/null 2>&1
}

# Supervisor: never strand the user on the bare backdrop. cws-launch execs
# the guarded Claude; when it EXITS, relaunch. There is no taskbar/tray in
# kiosk, so the in-app close/minimize can instead leave the process alive
# with no window — a blank container. So while Claude runs, if the screen
# goes blank (no Claude window AND no OAuth browser) for a few seconds,
# recycle the instance to bring Claude back. The `seen` guard avoids
# recycling during the initial cold start (before the first window paints).
while :; do
	cws-launch &
	cpid=$!
	seen=0
	misses=0
	while kill -0 "$cpid" 2> /dev/null; do
		if claude_up || browser_up; then
			seen=1
			misses=0
		elif [ "$seen" = 1 ]; then
			misses=$((misses + 1))
			[ "$misses" -ge 3 ] && { kill "$cpid" 2> /dev/null; break; }
		fi
		sleep 1.5
	done
	sleep 1
done
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
Description=kasmVNC session (Coworkstation)
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
	log_info '  2. cloudflared tunnel create coworkstation'
	log_info '  3. set "tunnel:" and "credentials-file:" in'
	log_info '     /etc/cloudflared/config.yml'
	log_info "  4. cloudflared tunnel route dns coworkstation $hostname"
	log_info '  5. cloudflared service install && systemctl start cloudflared'
	log_info '  6. protect the hostname with a Cloudflare Access policy'
}

cloudflared_config() {
	local hostname="$1"
	local port="$2"
	cat << EOF
# Coworkstation tunnel. Set "tunnel" and "credentials-file" after
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
	if [[ ${appliance_kiosk:-0} -eq 1 ]]; then
		profile_kasmvnc_install_kiosk_deps || return 1
		kasmvnc_set_default_browser "$user" || return 1
	fi
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
			"$token_file" "$allow_csv" || return 1
	else
		profile_kasmvnc_setup_tunnel "$hostname" "$port" || return 1
	fi
	# Kiosk: stand up the branded-login gateway and route the hostname
	# through it (the tunnel was just pointed at kasm; move it to the
	# gateway, which injects kasm's Basic auth upstream).
	if [[ ${appliance_kiosk:-0} -eq 1 ]]; then
		gateway_route "$user" 1 "$port" "$hostname" on || return 1
	fi
}
