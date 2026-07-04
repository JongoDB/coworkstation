#!/usr/bin/env bats
#
# appliance-doctor.bats
# Tests for readiness checks in appliance/lib/doctor.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export APPLIANCE_ETC="$TEST_TMP/etc"

	# shellcheck source=lib/common.sh
	source "$SCRIPT_DIR/../lib/common.sh"
	# shellcheck source=lib/doctor.sh
	source "$SCRIPT_DIR/../lib/doctor.sh"

	_apl_failures=0
}

teardown() {
	if [[ -n $TEST_TMP && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# apl_check_public_binds
# =============================================================================

@test "public_binds: loopback-only session ports pass" {
	local ss='LISTEN 0 128 127.0.0.1:8443 0.0.0.0:*
LISTEN 0 128 127.0.0.1:3389 0.0.0.0:*'
	run apl_check_public_binds "$ss"
	[[ $output == *'PASS'* ]]
	[[ $output != *'FAIL'* ]]
}

@test "public_binds: wildcard-bound kasm port fails" {
	local ss='LISTEN 0 128 0.0.0.0:8443 0.0.0.0:*'
	apl_check_public_binds "$ss"
	[[ $_apl_failures -eq 1 ]]
}

@test "public_binds: wildcard-bound rdp port fails" {
	local ss='LISTEN 0 128 *:3389 *:*'
	apl_check_public_binds "$ss"
	[[ $_apl_failures -eq 1 ]]
}

@test "public_binds: vnc display range is scanned" {
	local ss='LISTEN 0 128 192.168.1.5:5901 0.0.0.0:*'
	apl_check_public_binds "$ss"
	[[ $_apl_failures -eq 1 ]]
}

@test "public_binds: unrelated public ports are ignored" {
	local ss='LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
LISTEN 0 511 0.0.0.0:80 0.0.0.0:*'
	apl_check_public_binds "$ss"
	[[ $_apl_failures -eq 0 ]]
}

@test "public_binds: ipv6 loopback is accepted" {
	local ss='LISTEN 0 128 [::1]:8443 [::]:*'
	apl_check_public_binds "$ss"
	[[ $_apl_failures -eq 0 ]]
}

# =============================================================================
# apl_check_engine_conf
# =============================================================================

@test "engine_conf: missing file fails with setup hint" {
	run apl_check_engine_conf "$TEST_TMP/absent.conf"
	[[ $output == *'FAIL'* ]]
	[[ $output == *'run setup.sh'* ]]
}

@test "engine_conf: valid official conf passes" {
	mkdir -p "$APPLIANCE_ETC"
	printf 'engine=official\nreason=test\nbackend=kvm\n' \
		> "$APPLIANCE_ETC/engine.conf"
	touch "$TEST_TMP/kvm"
	APPLIANCE_DEV_KVM="$TEST_TMP/kvm"
	apl_check_engine_conf "$APPLIANCE_ETC/engine.conf"
	[[ $_apl_failures -eq 0 ]]
}

@test "engine_conf: invalid engine value fails" {
	mkdir -p "$APPLIANCE_ETC"
	printf 'engine=banana\nbackend=kvm\n' \
		> "$APPLIANCE_ETC/engine.conf"
	touch "$TEST_TMP/kvm"
	APPLIANCE_DEV_KVM="$TEST_TMP/kvm"
	apl_check_engine_conf "$APPLIANCE_ETC/engine.conf"
	[[ $_apl_failures -ge 1 ]]
}

@test "engine_conf: kvm backend without /dev/kvm fails" {
	mkdir -p "$APPLIANCE_ETC"
	printf 'engine=official\nbackend=kvm\n' \
		> "$APPLIANCE_ETC/engine.conf"
	APPLIANCE_DEV_KVM="$TEST_TMP/no-such-kvm"
	apl_check_engine_conf "$APPLIANCE_ETC/engine.conf"
	[[ $_apl_failures -eq 1 ]]
}

# =============================================================================
# apl_check_tunnel_config
# =============================================================================

@test "tunnel_config: missing file is a warn, not a fail" {
	run apl_check_tunnel_config "$TEST_TMP/absent.yml"
	[[ $output == *'WARN'* ]]
	[[ $output != *'FAIL'* ]]
}

@test "tunnel_config: skeleton without tunnel id fails" {
	cat > "$TEST_TMP/config.yml" << 'EOF'
# tunnel: <TUNNEL-UUID>
ingress:
  - hostname: claude.example.com
    service: http://127.0.0.1:8443
  - service: http_status:404
EOF
	apl_check_tunnel_config "$TEST_TMP/config.yml"
	[[ $_apl_failures -eq 1 ]]
}

@test "tunnel_config: completed config passes" {
	cat > "$TEST_TMP/config.yml" << 'EOF'
tunnel: 0000-1111
credentials-file: /root/.cloudflared/0000-1111.json
ingress:
  - hostname: claude.example.com
    service: http://127.0.0.1:8443
  - service: http_status:404
EOF
	apl_check_tunnel_config "$TEST_TMP/config.yml"
	[[ $_apl_failures -eq 0 ]]
}

@test "tunnel_config: config with no ingress hostnames fails" {
	printf 'tunnel: 0000-1111\ningress:\n  - service: http_status:404\n' \
		> "$TEST_TMP/config.yml"
	apl_check_tunnel_config "$TEST_TMP/config.yml"
	[[ $_apl_failures -eq 1 ]]
}

# =============================================================================
# apl_check_keyring (the non-empty rule from #692)
# =============================================================================

@test "keyring: absent dir is a warn (first login creates it)" {
	getent() {
		printf 'alice:x:1000:1000::%s:/bin/bash\n' "$TEST_TMP/home"
	}
	mkdir -p "$TEST_TMP/home"
	run apl_check_keyring alice
	[[ $output == *'WARN'* ]]
	[[ $output != *'FAIL'* ]]
}

@test "keyring: empty keyring pre-sign-in is a WARN, not a fail" {
	getent() {
		printf 'alice:x:1000:1000::%s:/bin/bash\n' "$TEST_TMP/home"
	}
	mkdir -p "$TEST_TMP/home/.local/share/keyrings"
	touch "$TEST_TMP/home/.local/share/keyrings/login.keyring"
	run apl_check_keyring alice
	[[ $output == *'WARN'* ]]
	apl_check_keyring alice
	[[ $_apl_failures -eq 0 ]]
}

@test "keyring: non-empty keyring passes" {
	getent() {
		printf 'alice:x:1000:1000::%s:/bin/bash\n' "$TEST_TMP/home"
	}
	mkdir -p "$TEST_TMP/home/.local/share/keyrings"
	printf 'data' \
		> "$TEST_TMP/home/.local/share/keyrings/login.keyring"
	apl_check_keyring alice
	[[ $_apl_failures -eq 0 ]]
}

# =============================================================================
# run_appliance_doctor exit status
# =============================================================================

@test "doctor: exit status reflects failures" {
	apl_check_engine_conf() { _apl_fail 'forced'; }
	apl_check_engine_installed() { :; }
	apl_check_session_layer() { :; }
	apl_check_keyring() { :; }
	apl_check_public_binds() { :; }
	apl_check_tunnel_config() { :; }
	apl_check_access_coverage() { :; }
	apl_check_tunnel_service() { :; }
	apl_check_unattended_upgrades() { :; }
	command() {
		if [[ $1 == '-v' && $2 == 'ss' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	run run_appliance_doctor alice
	[[ $status -ne 0 ]]
	[[ $output == *'1 failure(s)'* ]]
}

@test "doctor: all-green run exits zero" {
	apl_check_engine_conf() { _apl_pass 'ok'; }
	apl_check_engine_installed() { :; }
	apl_check_session_layer() { :; }
	apl_check_keyring() { :; }
	apl_check_public_binds() { :; }
	apl_check_tunnel_config() { :; }
	apl_check_access_coverage() { :; }
	apl_check_tunnel_service() { :; }
	apl_check_unattended_upgrades() { :; }
	command() {
		if [[ $1 == '-v' && $2 == 'ss' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	run run_appliance_doctor alice
	[[ $status -eq 0 ]]
}

# =============================================================================
# apl_check_session_layer: config present must also mean a live listener
# =============================================================================

@test "session_layer: kasmvnc config + listener = two passes" {
	getent() {
		printf 'alice:x:1042:1042::%s:/bin/bash\n' "$TEST_TMP/home"
	}
	mkdir -p "$TEST_TMP/home/.vnc"
	printf 'network:\n  websocket_port: 8443\n' \
		> "$TEST_TMP/home/.vnc/kasmvnc.yaml"
	local ss='LISTEN 0 128 127.0.0.1:8443 0.0.0.0:*'
	apl_check_session_layer alice "$ss"
	[[ $_apl_failures -eq 0 ]]
}

@test "session_layer: config present but NO listener is a FAIL (#false-green)" {
	getent() {
		printf 'alice:x:1042:1042::%s:/bin/bash\n' "$TEST_TMP/home"
	}
	mkdir -p "$TEST_TMP/home/.vnc"
	printf 'network:\n  websocket_port: 8443\n' \
		> "$TEST_TMP/home/.vnc/kasmvnc.yaml"
	local ss='LISTEN 0 128 127.0.0.1:22 0.0.0.0:*'
	run apl_check_session_layer alice "$ss"
	[[ $output == *'nothing is'* ]]
	apl_check_session_layer alice "$ss"
	[[ $_apl_failures -eq 1 ]]
}

@test "session_layer: no config at all is a FAIL" {
	getent() {
		printf 'alice:x:1042:1042::%s:/bin/bash\n' "$TEST_TMP/home"
	}
	mkdir -p "$TEST_TMP/home"
	apl_check_session_layer alice ''
	[[ $_apl_failures -eq 1 ]]
}

# =============================================================================
# apl_check_engine_conf: backend=none (official engine, no KVM)
# =============================================================================

@test "engine_conf: official with backend=none is a WARN, not a FAIL" {
	mkdir -p "$APPLIANCE_ETC"
	printf 'engine=official\nreason=test\nbackend=none\n' \
		> "$APPLIANCE_ETC/engine.conf"
	run apl_check_engine_conf "$APPLIANCE_ETC/engine.conf"
	[[ $output == *'WARN'* ]]
	[[ $output == *'Cowork VM'* ]]
	apl_check_engine_conf "$APPLIANCE_ETC/engine.conf"
	[[ $_apl_failures -eq 0 ]]
}

# =============================================================================
# apl_check_access_coverage
# =============================================================================

@test "access_coverage: api mode, gated hostname passes" {
	mkdir -p "$APPLIANCE_ETC"
	printf 'mode=api\ntunnel_id=tun-1\naccount_id=acct-1\ntoken_file=%s\n' \
		"$TEST_TMP/tok" > "$APPLIANCE_ETC/tunnel.conf"
	tunnel_conf_get() {
		case "$1" in
			token_file) printf '%s' "$TEST_TMP/tok" ;;
			account_id) printf 'acct-1' ;;
			tunnel_id)  printf 'tun-1' ;;
		esac
	}
	tunnel_api_load_token() { :; }
	cf_tunnel_get_ingress() {
		printf '[{"hostname":"cws.example.com","service":"http://127.0.0.1:8443"},{"service":"http_status:404"}]'
	}
	cf_call() {
		printf '[{"domain":"cws.example.com","id":"app-1"}]'
	}
	run apl_check_access_coverage
	[[ $output == *'PASS'* ]]
	[[ $output == *'cws.example.com'* ]]
	apl_check_access_coverage
	[[ $_apl_failures -eq 0 ]]
}

@test "access_coverage: api mode, UNGATED hostname is a FAIL" {
	mkdir -p "$APPLIANCE_ETC"
	printf 'mode=api\n' > "$APPLIANCE_ETC/tunnel.conf"
	tunnel_conf_get() {
		case "$1" in
			token_file) printf '%s' "$TEST_TMP/tok" ;;
			account_id) printf 'acct-1' ;;
			tunnel_id)  printf 'tun-1' ;;
		esac
	}
	tunnel_api_load_token() { :; }
	cf_tunnel_get_ingress() {
		printf '[{"hostname":"alice.cws.example.com","service":"http://127.0.0.1:8444"}]'
	}
	cf_call() { printf '[{"domain":"cws.example.com"}]'; }
	run apl_check_access_coverage
	[[ $output == *'FAIL'* ]]
	[[ $output == *'PUBLIC'* ]]
	apl_check_access_coverage
	[[ $_apl_failures -eq 1 ]]
}

@test "access_coverage: manual mode with hostnames warns, never silent" {
	local cfconf="$TEST_TMP/config.yml"
	printf 'tunnel: t\ningress:\n  - hostname: cws.example.com\n    service: http://127.0.0.1:8443\n' \
		> "$cfconf"
	APPLIANCE_CLOUDFLARED_CONF="$cfconf"
	run apl_check_access_coverage
	[[ $output == *'WARN'* ]]
	[[ $output == *'Access'* ]]
}
