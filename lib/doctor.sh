# shellcheck shell=bash
#===============================================================================
# appliance-doctor — readiness checks for the appliance surface
#
# Extends the claude-desktop --doctor philosophy (scripts/doctor.sh):
# PASS/WARN/FAIL lines, distro hints, and no false-green on
# empty/unreadable probes (#692). Check functions that parse system
# state take that state as arguments so BATS can feed fixtures; the
# run_appliance_doctor entry point gathers the live inputs.
#===============================================================================

appliance_etc="${APPLIANCE_ETC:-/etc/claude-appliance}"

_apl_failures=0

_apl_pass() { printf 'PASS  %s\n' "$*"; }
_apl_warn() { printf 'WARN  %s\n' "$*"; }
_apl_fail() {
	printf 'FAIL  %s\n' "$*"
	_apl_failures=$((_apl_failures + 1))
}

# --- Engine ------------------------------------------------------------

# $1 = path to engine.conf
apl_check_engine_conf() {
	local conf="$1"
	if [[ ! -f $conf ]]; then
		_apl_fail "engine.conf missing ($conf) — run setup.sh"
		return
	fi
	local engine backend
	engine=$(grep -E '^engine=' "$conf" | head -1 | cut -d= -f2)
	backend=$(grep -E '^backend=' "$conf" | head -1 | cut -d= -f2)
	case "$engine" in
		official|repo) _apl_pass "engine: $engine (backend: $backend)" ;;
		*) _apl_fail "engine.conf has invalid engine '$engine'" ;;
	esac
	if [[ $backend == 'kvm' && ! -e ${APPLIANCE_DEV_KVM:-/dev/kvm} ]]; then
		_apl_fail 'engine.conf says kvm but /dev/kvm is absent'
	fi
}

apl_check_engine_installed() {
	if command -v claude-desktop > /dev/null 2>&1; then
		_apl_pass 'claude-desktop on PATH'
	else
		_apl_fail 'claude-desktop not installed'
	fi
}

# --- Network -----------------------------------------------------------

# Scan a `ss -Hltn` listing for session-layer ports bound beyond
# loopback. $1 = the ss output. FAIL, never WARN: a publicly bound
# session port defeats the entire access model.
apl_check_public_binds() {
	local ss_output="$1"
	local bad=0 line laddr port
	while IFS= read -r line; do
		[[ -z $line ]] && continue
		laddr=$(awk '{print $4}' <<< "$line")
		port="${laddr##*:}"
		case "$port" in
			3389|590[0-9]|844[0-9]) ;;
			*) continue ;;
		esac
		case "$laddr" in
			127.0.0.1:*|'[::1]':*) ;;
			*)
				_apl_fail "session port bound publicly: $laddr"
				bad=1
				;;
		esac
	done <<< "$ss_output"
	if [[ $bad -eq 0 ]]; then
		_apl_pass 'no session ports bound beyond loopback'
	fi
}

# $1 = path to cloudflared config.yml (may not exist on overlay profile)
apl_check_tunnel_config() {
	local conf="$1"
	# api mode: ingress lives in Cloudflare's remote config, not a
	# local file — check the recorded shape instead.
	if [[ -f $appliance_etc/tunnel.conf ]] \
		&& grep -qE '^mode=api$' "$appliance_etc/tunnel.conf"; then
		if grep -qE '^tunnel_id=.+' "$appliance_etc/tunnel.conf"; then
			_apl_pass 'tunnel: remotely managed (api mode)'
		else
			_apl_fail 'tunnel.conf says api mode but has no tunnel_id'
		fi
		return
	fi
	if [[ ! -f $conf ]]; then
		_apl_warn "no cloudflared config at $conf (overlay profile?)"
		return
	fi
	if grep -qE '^tunnel:' "$conf"; then
		_apl_pass 'cloudflared config has a tunnel id'
	else
		_apl_fail 'cloudflared config.yml still has no tunnel id set'
	fi
	if grep -qE '^\s+- hostname:' "$conf"; then
		_apl_pass 'cloudflared ingress has hostnames'
	else
		_apl_fail 'cloudflared ingress is empty'
	fi
}

apl_check_tunnel_service() {
	if ! command -v cloudflared > /dev/null 2>&1; then
		_apl_warn 'cloudflared not installed (overlay profile?)'
		return
	fi
	if systemctl is-active --quiet cloudflared 2> /dev/null; then
		_apl_pass 'cloudflared service active'
	else
		_apl_fail 'cloudflared installed but service not active'
	fi
}

# --- Session layer -----------------------------------------------------

# $1 = user, $2 = optional `ss -Hltn` listing (for tests). A config
# file is necessary but NOT sufficient — the session only works if the
# server is actually listening, so a present config with no listener is
# a FAIL, not a PASS (the cloud-init headless-bus bug shipped exactly
# that false-green).
apl_check_session_layer() {
	local user="$1"
	local ss_output="${2-$(command -v ss > /dev/null 2>&1 \
		&& ss -Hltn 2> /dev/null)}"
	local home
	home=$(getent passwd "$user" | cut -d: -f6)

	if [[ -f $home/.vnc/kasmvnc.yaml ]]; then
		_apl_pass "kasmVNC config present for $user"
		# The port lives in the config; default to the base port.
		local port
		port=$(grep -oE 'websocket_port:[[:space:]]*[0-9]+' \
			"$home/.vnc/kasmvnc.yaml" | grep -oE '[0-9]+' | head -1)
		port="${port:-8443}"
		if grep -qE "127\.0\.0\.1:$port|\[::1\]:$port|\*:$port" \
			<<< "$ss_output"; then
			_apl_pass "kasmVNC listening on $port"
		else
			_apl_fail "kasmVNC config present but nothing is" \
				"listening on $port (service failed to start?)"
		fi
	elif [[ -f /etc/xrdp/xrdp.ini ]]; then
		_apl_pass 'xrdp profile detected'
	else
		_apl_fail "no session layer configured for $user"
	fi
}

# $1 = user. On a freshly-provisioned appliance the keyring only
# populates at the member's FIRST Claude sign-in (a documented
# post-provision step), so an absent-or-empty keyring is a WARN, not a
# FAIL — provisioning succeeded, the member just hasn't signed in yet.
# (The #692 empty-store-is-a-false-green concern is about the app's own
# --doctor on a used install, handled separately in scripts/doctor.sh.)
apl_check_keyring() {
	local user="$1"
	local home
	home=$(getent passwd "$user" | cut -d: -f6)
	local ring_dir="$home/.local/share/keyrings"
	if [[ ! -d $ring_dir ]]; then
		_apl_warn "no keyring for $user yet (created at first sign-in)"
		return
	fi
	if find "$ring_dir" -name '*.keyring' -size +0c 2> /dev/null \
		| grep -q .; then
		_apl_pass "keyring present and non-empty for $user"
	else
		_apl_warn "keyring not yet populated for $user" \
			"(completes at the member's first Claude sign-in)"
	fi
}

# --- Updates -----------------------------------------------------------

apl_check_unattended_upgrades() {
	if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] \
		&& grep -q 'Unattended-Upgrade "1"' \
			/etc/apt/apt.conf.d/20auto-upgrades; then
		_apl_pass 'unattended-upgrades enabled'
	else
		_apl_warn 'unattended-upgrades not enabled — updates are manual'
	fi
}

# --- Entry point -------------------------------------------------------

# $1 = target user
run_appliance_doctor() {
	local user="$1"
	_apl_failures=0

	printf '== Claude appliance doctor ==\n'
	apl_check_engine_conf "$appliance_etc/engine.conf"
	apl_check_engine_installed
	apl_check_session_layer "$user"
	apl_check_keyring "$user"
	if command -v ss > /dev/null 2>&1; then
		apl_check_public_binds "$(ss -Hltn 2> /dev/null)"
	else
		_apl_warn 'ss not available; skipping public-bind scan'
	fi
	apl_check_tunnel_config /etc/cloudflared/config.yml
	apl_check_tunnel_service
	apl_check_unattended_upgrades

	printf -- '-- %d failure(s)\n' "$_apl_failures"
	[[ $_apl_failures -eq 0 ]]
}
