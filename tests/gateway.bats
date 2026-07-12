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

@test "gateway_unit: wires the env + role/bridge/fleet + node server path" {
	local unit
	unit=$(gateway_unit /opt/coworkstation/gateway 8701 8443 \
		/home/a/.vnc/kasm-credentials /home/a/.config/cws-gateway/secret \
		/opt/coworkstation/gateway/www /home/a/.config/Claude/device-scale \
		admin 8601 /home/a/.config/cws-bridge/token /run/coworkstation/fleet.json)
	[[ $unit == *'CWS_GW_PORT=8701'* ]]
	[[ $unit == *'CWS_GW_UPSTREAM=8443'* ]]
	[[ $unit == *'CWS_GW_CRED=/home/a/.vnc/kasm-credentials'* ]]
	[[ $unit == *'CWS_GW_SECRET=/home/a/.config/cws-gateway/secret'* ]]
	[[ $unit == *'CWS_GW_SCALE_FILE=/home/a/.config/Claude/device-scale'* ]]
	[[ $unit == *'CWS_GW_ROLE=admin'* ]]
	[[ $unit == *'CWS_GW_BRIDGE_PORT=8601'* ]]
	[[ $unit == *'CWS_GW_BRIDGE_TOKEN=/home/a/.config/cws-bridge/token'* ]]
	[[ $unit == *'CWS_GW_FLEET=/run/coworkstation/fleet.json'* ]]
	[[ $unit == *'node /opt/coworkstation/gateway/server.js'* ]]
}

@test "gateway_setup: dry-run plans (with role) and touches nothing" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	appliance_dry_run=1
	run gateway_setup alice 1 8443 admin
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: gateway for alice (port 8701 -> kasm 8443, role admin)'* ]]
	[[ ! -e $TEST_TMP/home/.config/systemd/user/cws-gateway.service ]]
}

@test "fleet collector: units + snapshot JSON" {
	local svc timer
	svc=$(fleet_collector_service /opt/coworkstation)
	[[ $svc == *'Type=oneshot'* ]]
	[[ $svc == *'CWS_FLEET_OUT=/run/coworkstation/fleet.json'* ]]
	[[ $svc == *'/opt/coworkstation/libexec/cws-fleet-snapshot'* ]]
	timer=$(fleet_collector_timer)
	[[ $timer == *'OnUnitActiveSec=20'* ]]
	[[ $timer == *'WantedBy=timers.target'* ]]
	# the snapshot emits valid JSON with the owner as a member
	export APPLIANCE_ETC="$TEST_TMP/etc"; mkdir -p "$APPLIANCE_ETC"
	printf 'owner=alice\n' > "$APPLIANCE_ETC/appliance.conf"
	run env APPLIANCE_ETC="$APPLIANCE_ETC" \
		"$SCRIPT_DIR/../libexec/cws-fleet-snapshot"
	[[ $status -eq 0 ]]
	[[ $output == *'"name":"alice"'* ]]
	[[ $output == *'"members":['* ]]
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
	run gateway_route cws 1 8443 cws.example.com on admin
	[[ $status -eq 0 ]]
	# gateway on port 8701 (display 1) fronting kasm 8443, as admin
	[[ $output == *'gateway for cws (port 8701 -> kasm 8443, role admin)'* ]]
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

@test "action channel: units + tmpfiles wire the spool" {
	local svc path_u tf
	svc=$(action_exec_service /opt/coworkstation)
	[[ $svc == *'Type=oneshot'* ]]
	[[ $svc == *'/opt/coworkstation/libexec/cws-action-exec'* ]]
	path_u=$(action_exec_path)
	[[ $path_u == *'PathExistsGlob=/run/coworkstation/actions/req-*.json'* ]]
	[[ $path_u == *'Unit=cws-action-exec.service'* ]]
	tf=$(action_tmpfiles alice)
	[[ $tf == *'/run/coworkstation/actions 0700 alice alice'* ]]
}

@test "action executor: allowlist maps + validates, writes results" {
	local spool="$TEST_TMP/actions" etc="$TEST_TMP/etc" bin="$TEST_TMP/bin"
	mkdir -p "$spool" "$etc" "$bin"
	printf 'owner=alice\n' > "$etc/appliance.conf"
	printf '#!/bin/sh\necho "CWS $*"\n' > "$bin/cws"; chmod +x "$bin/cws"
	printf '{"id":"a1","action":"session.restart","user":"bob"}' > "$spool/req-a1.json"
	printf '{"id":"a2","action":"session.restart","user":"BAD NAME"}' > "$spool/req-a2.json"
	printf '{"id":"a3","action":"member.add","user":"carol","mem":"6G","cpu":"200%%"}' \
		> "$spool/req-a3.json"
	# argv flag-smuggling attempt via allow (leading dash)
	printf '{"id":"a4","action":"member.add","user":"dave","mem":"6G","cpu":"200%%","allow":"--dry-run"}' \
		> "$spool/req-a4.json"
	run env CWS_ACTION_SPOOL="$spool" CWS_BIN="$bin/cws" APPLIANCE_ETC="$etc" \
		"$SCRIPT_DIR/../libexec/cws-action-exec"
	[[ $status -eq 0 ]]
	# valid action -> mapped cws call, ok
	grep -q '"ok":true' "$spool/result-a1.json"
	grep -q 'sessions restart bob' "$spool/result-a1.json"
	# invalid name -> rejected, not executed
	grep -q '"ok":false' "$spool/result-a2.json"
	grep -q 'invalid user' "$spool/result-a2.json"
	# member.add with valid params -> mapped
	grep -q 'member add carol 6G 200%' "$spool/result-a3.json"
	# flag-smuggling allow -> rejected, cws never invoked with the flag
	grep -q 'invalid params' "$spool/result-a4.json"
	! grep -q 'dry-run' "$spool/result-a4.json"
	# requests consumed
	[[ ! -f $spool/req-a1.json ]]
}

@test "live: gateway login gate + cookie + proxy + websocket gate" {
	if ! command -v node > /dev/null 2>&1; then
		skip 'node not available'
	fi
	run node "$SCRIPT_DIR/helpers/gateway-test.js"
	[[ $status -eq 0 ]]
	[[ $output == *'gateway-test: OK'* ]]
}
