#!/usr/bin/env bats
#
# gateway.bats
# Kiosk gateway provisioning (lib/gateway.sh) + the live node harness for
# gateway/server.js (branded login, cookie session, proxy, WS gate).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	# shellcheck source=lib/common.sh
	source "$SCRIPT_DIR/../lib/common.sh"
	# shellcheck source=lib/gateway.sh
	source "$SCRIPT_DIR/../lib/gateway.sh"
	appliance_dry_run=0
	appliance_force=0
}

teardown() {
	[[ -n $TEST_TMP && -d $TEST_TMP ]] && rm -rf "$TEST_TMP"
}

@test "gateway_port: derived from display, clear of kasm/bridge ranges" {
	[[ $(gateway_port 1) == 8701 ]]
	[[ $(gateway_port 4) == 8704 ]]
	# above kasmVNC (8443+) and the client bridge (8600+)
	[[ $(gateway_port 1) -gt 8600 ]]
}

@test "gateway_unit: wires the env + node server path" {
	local unit
	unit=$(gateway_unit /opt/coworkstation/gateway 8701 8443 \
		/home/a/.vnc/kasm-credentials /home/a/.config/cws-gateway/secret \
		/opt/coworkstation/gateway/www /home/a/.config/Claude/device-scale)
	[[ $unit == *'CWS_GW_PORT=8701'* ]]
	[[ $unit == *'CWS_GW_UPSTREAM=8443'* ]]
	[[ $unit == *'CWS_GW_CRED=/home/a/.vnc/kasm-credentials'* ]]
	[[ $unit == *'CWS_GW_SECRET=/home/a/.config/cws-gateway/secret'* ]]
	[[ $unit == *'CWS_GW_SCALE_FILE=/home/a/.config/Claude/device-scale'* ]]
	[[ $unit == *'node /opt/coworkstation/gateway/server.js'* ]]
}

@test "gateway_setup: dry-run plans and touches nothing" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	appliance_dry_run=1
	run gateway_setup alice 1 8443
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: gateway for alice (port 8701 -> kasm 8443)'* ]]
	[[ ! -e $TEST_TMP/home/.config/systemd/user/cws-gateway.service ]]
}

@test "gateway_teardown: no-op when no unit is present" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	run gateway_teardown alice
	[[ $status -eq 0 ]]
}

@test "gateway_reroute: dry-run states the target, no API call" {
	appliance_dry_run=1
	run gateway_reroute cws.example.com 8701
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: reroute cws.example.com -> 127.0.0.1:8701'* ]]
}

@test "gateway_reroute: empty hostname is a no-op" {
	run gateway_reroute '' 8701
	[[ $status -eq 0 ]]
	[[ -z $output ]]
}

@test "gateway_route on: sets up the gateway and routes to its port" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	appliance_dry_run=1
	run gateway_route cws 1 8443 cws.example.com on
	[[ $status -eq 0 ]]
	# gateway on port 8701 (display 1) fronting kasm 8443
	[[ $output == *'DRY-RUN: gateway for cws (port 8701 -> kasm 8443)'* ]]
	# and the hostname is pointed at the gateway port
	[[ $output == *'reroute cws.example.com -> 127.0.0.1:8701'* ]]
}

@test "gateway_route off: routes back to kasm when a gateway existed" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	appliance_dry_run=1
	run gateway_route cws 1 8443 cws.example.com off
	[[ $status -eq 0 ]]
	# back to the kasm port
	[[ $output == *'reroute cws.example.com -> 127.0.0.1:8443'* ]]
}

@test "live: gateway login gate + cookie + proxy + websocket gate" {
	if ! command -v node > /dev/null 2>&1; then
		skip 'node not available'
	fi
	run node "$SCRIPT_DIR/helpers/gateway-test.js"
	[[ $status -eq 0 ]]
	[[ $output == *'gateway-test: OK'* ]]
}
