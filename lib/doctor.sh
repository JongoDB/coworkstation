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

appliance_etc="${APPLIANCE_ETC:-/etc/coworkstation}"

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
	if [[ $backend == 'none' ]]; then
		if [[ -e ${APPLIANCE_DEV_KVM:-/dev/kvm} ]]; then
			_apl_warn '/dev/kvm EXISTS but engine.conf says' \
				'backend=none (KVM appeared after install?) —' \
				're-run setup to record backend=kvm'
		else
			_apl_warn 'Cowork VM feature is unavailable (no' \
				'/dev/kvm; official engine keeps the unmodified binary)'
		fi
	fi
}

# Cowork runs its microVM as the SESSION user — /dev/kvm existing
# is not enough; the user must be able to open it (kvm group).
apl_check_kvm_access() {
	local user="$1"
	[[ -e ${APPLIANCE_DEV_KVM:-/dev/kvm} ]] || return 0
	if id -nG "$user" 2> /dev/null | tr ' ' '\n' | grep -qx kvm; then
		_apl_pass "$user is in the kvm group (Cowork VM can start)"
	else
		_apl_fail "$user cannot open /dev/kvm (not in the kvm" \
			'group) — Cowork VM will fail; re-run setup or:' \
			"usermod -aG kvm $user (then restart their session)"
	fi
}

apl_check_engine_installed() {
	if command -v claude-desktop > /dev/null 2>&1; then
		_apl_pass 'claude-desktop on PATH (official)'
	elif command -v claude-desktop-unofficial > /dev/null 2>&1; then
		_apl_pass 'claude-desktop-unofficial on PATH (community v3)'
	else
		_apl_fail 'no Claude Desktop launcher installed'
	fi
}

# --- Network -----------------------------------------------------------

# Scan a `ss -Hltn` listing for session-layer ports bound beyond
# loopback. $1 = the ss output. FAIL, never WARN: a publicly bound
# session port defeats the entire access model.
apl_check_public_binds() {
	local ss_output="$1"
	local bad=0 exposed=0 line laddr port
	while IFS= read -r line; do
		[[ -z $line ]] && continue
		laddr=$(awk '{print $4}' <<< "$line")
		port="${laddr##*:}"
		# Loopback binds are always fine.
		case "$laddr" in
			127.0.0.1:*|'[::1]':*|'[::ffff:127.0.0.1]':*) continue ;;
		esac
		# Anything else is a public listener. Classify by port: a
		# session port publicly bound is a hard FAIL (the whole
		# zero-inbound premise); Syncthing's 22000/21027 are expected
		# for ClientSync and only reachable on a LAN (TLS +
		# device-authenticated), so WARN not FAIL; anything else
		# public is unexpected and flagged.
		case "$port" in
			3389|59[0-9][0-9]|84[4-9][0-9]|85[0-9][0-9])
				_apl_fail "session port bound publicly: $laddr" \
					'— the box is meant to bind sessions to loopback'
				bad=1
				;;
			22000|21027)
				_apl_warn "ClientSync (Syncthing) listens on $laddr" \
					'— fine behind the tunnel (LAN-only, encrypted,' \
					'paired-device auth); no inbound port is forwarded'
				exposed=1
				;;
			*)
				_apl_warn "unexpected public listener: $laddr" \
					'— confirm nothing forwards an inbound port to it'
				exposed=1
				;;
		esac
	done <<< "$ss_output"
	if [[ $bad -eq 0 && $exposed -eq 0 ]]; then
		_apl_pass 'no ports bound beyond loopback'
	elif [[ $bad -eq 0 ]]; then
		_apl_pass 'no SESSION ports bound beyond loopback' \
			'(see public-listener notes above)'
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

# Every tunnel ingress hostname must be gated by a Cloudflare Access
# application — a proxied hostname with no Access app is a PUBLIC
# desktop, and it looks healthy in every other check. In api mode the
# recorded token can verify coverage directly (uses tunnel-api.sh,
# sourced by setup.sh); in manual mode there are no credentials to
# query with, so say so instead of staying silent.
apl_check_access_coverage() {
	local tconf="$appliance_etc/tunnel.conf"
	if [[ ! -f $tconf ]] || ! grep -qE '^mode=api$' "$tconf"; then
		local cfconf="${APPLIANCE_CLOUDFLARED_CONF:-/etc/cloudflared/config.yml}"
		if [[ -f $cfconf ]] && grep -qE '^\s+- hostname:' "$cfconf"; then
			_apl_warn 'cannot verify Access coverage (manual tunnel' \
				'mode) — confirm every ingress hostname has an' \
				'Access policy in the Zero Trust dashboard'
		fi
		return
	fi
	local token_file account tunnel
	token_file=$(tunnel_conf_get token_file) \
		&& account=$(tunnel_conf_get account_id) \
		&& tunnel=$(tunnel_conf_get tunnel_id)
	if [[ -z ${token_file:-} || -z ${account:-} || -z ${tunnel:-} ]]; then
		_apl_warn 'tunnel.conf incomplete; skipping Access coverage'
		return
	fi
	if ! tunnel_api_load_token "$token_file" 2> /dev/null; then
		_apl_warn 'api token unavailable; skipping Access coverage'
		return
	fi
	local hosts apps host
	hosts=$(cf_tunnel_get_ingress "$account" "$tunnel" 2> /dev/null \
		| jq -r '.[].hostname // empty' 2> /dev/null | sort -u)
	apps=$(cf_call GET "/accounts/$account/access/apps" 2> /dev/null \
		| jq -r '.[].domain' 2> /dev/null)
	if [[ -z $hosts ]]; then
		_apl_warn 'no ingress hostnames recorded yet'
		return
	fi
	while IFS= read -r host; do
		[[ -z $host ]] && continue
		if grep -qxF "$host" <<< "$apps"; then
			_apl_pass "Access app gates $host"
		else
			_apl_fail "ingress hostname $host has NO Access app —" \
				'it is PUBLIC behind the tunnel'
		fi
	done <<< "$hosts"
}

apl_check_tunnel_service() {
	if ! command -v cloudflared > /dev/null 2>&1; then
		_apl_warn 'cloudflared not installed (overlay profile?)'
		return
	fi
	if systemctl is-active --quiet cws-cloudflared 2> /dev/null \
		|| systemctl is-active --quiet cloudflared 2> /dev/null; then
		_apl_pass 'tunnel connector service active'
	else
		_apl_fail 'cloudflared installed but no connector service' \
			'active (cws-cloudflared / cloudflared)'
	fi
}

# A locally-active connector can be serving the WRONG tunnel (found
# live: a pre-existing SSH-tunnel service owned the unit name and
# every session hostname 530'd). Ask Cloudflare how many live
# connections OUR tunnel actually has — the only check that cannot
# be fooled by unit names.
apl_check_tunnel_connections() {
	local tconf="$appliance_etc/tunnel.conf"
	[[ -f $tconf ]] && grep -qE '^mode=api$' "$tconf" || return 0
	local account tunnel resp conns
	account=$(tunnel_conf_get account_id 2> /dev/null)
	tunnel=$(tunnel_conf_get tunnel_id 2> /dev/null)
	[[ -n $account && -n $tunnel ]] || return 0
	if ! resp=$(cf_call GET \
		"/accounts/$account/cfd_tunnel/$tunnel" 2> /dev/null); then
		_apl_warn 'could not query tunnel connection state'
		return 0
	fi
	conns=$(jq '.connections | length' <<< "$resp" 2> /dev/null)
	if [[ $conns =~ ^[0-9]+$ && $conns -gt 0 ]]; then
		_apl_pass "session tunnel has $conns live connection(s)"
	else
		_apl_fail 'session tunnel has NO live connections —' \
			'hostnames will return 530/1033; is cws-cloudflared' \
			'running with the RIGHT token? re-run setup'
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
	local ss_output
	if [[ $# -ge 2 ]]; then
		ss_output="$2"
	elif command -v ss > /dev/null 2>&1; then
		ss_output=$(ss -Hltn 2> /dev/null)
	else
		# no ss: we cannot distinguish "not listening" from "cannot
		# look" — warn instead of reporting a spurious FAIL.
		_apl_warn 'ss unavailable; cannot verify the session listener'
		return
	fi
	local home
	home=$(getent passwd "$user" | cut -d: -f6)

	if [[ -f $home/.vnc/kasmvnc.yaml ]]; then
		_apl_pass "kasmVNC config present for $user"
		# The port lives in the config; default to the base port.
		local port
		port=$(grep -oE 'websocket_port:[[:space:]]*[0-9]+' \
			"$home/.vnc/kasmvnc.yaml" | grep -oE '[0-9]+' | head -1)
		port="${port:-8443}"
		# Require a LOOPBACK listener specifically: a wildcard bind
		# (0.0.0.0:port) is a public exposure, not a healthy session, so
		# it must not read as green here (apl_check_public_binds fails it).
		if grep -qE "127\.0\.0\.1:$port|\[::1\]:$port" \
			<<< "$ss_output"; then
			_apl_pass "kasmVNC listening on $port"
		else
			_apl_fail "kasmVNC config present but nothing is" \
				"listening on loopback:$port (service failed to start" \
				'or bound publicly?)'
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

	printf '== coworkstation doctor ==\n'
	apl_check_engine_conf "$appliance_etc/engine.conf"
	apl_check_engine_installed
	apl_check_kvm_access "$user"
	apl_check_session_layer "$user"
	apl_check_keyring "$user"
	if command -v ss > /dev/null 2>&1; then
		apl_check_public_binds "$(ss -Hltn 2> /dev/null)"
	else
		_apl_warn 'ss not available; skipping public-bind scan'
	fi
	apl_check_tunnel_config /etc/cloudflared/config.yml
	apl_check_access_coverage
	apl_check_tunnel_service
	apl_check_tunnel_connections
	apl_check_unattended_upgrades

	printf -- '-- %d failure(s)\n' "$_apl_failures"
	[[ $_apl_failures -eq 0 ]]
}
