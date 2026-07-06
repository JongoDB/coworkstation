#!/usr/bin/env bats
#
# clientbridge.bats
# Browser-bridge provisioning (lib/clientbridge.sh), the ingress path
# transform, the cws-client laptop helper, and the live node harness.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export APPLIANCE_ETC="$TEST_TMP/etc"
	mkdir -p "$APPLIANCE_ETC"
	# shellcheck source=lib/common.sh
	source "$SCRIPT_DIR/../lib/common.sh"
	# shellcheck source=lib/tunnel-api.sh
	source "$SCRIPT_DIR/../lib/tunnel-api.sh"
	# shellcheck source=lib/clientbridge.sh
	source "$SCRIPT_DIR/../lib/clientbridge.sh"
	appliance_dry_run=0
	appliance_force=0
}

teardown() {
	[[ -n $TEST_TMP && -d $TEST_TMP ]] && rm -rf "$TEST_TMP"
}

@test "ports: derived from the member display, clear of doctor ranges" {
	[[ $(clientbridge_port 1) == 8600 ]]
	[[ $(clientbridge_port 4) == 8603 ]]
}

@test "ingress_json_add_path: path rule lands BEFORE the plain rule" {
	local base out
	base='[{"hostname":"cws.example.com","service":"http://127.0.0.1:8443"},{"service":"http_status:404"}]'
	out=$(ingress_json_add_path cws.example.com '^/bridge(/.*)?$' 8600 \
		<<< "$base")
	[[ $(jq -r '.[0].path' <<< "$out") == '^/bridge(/.*)?$' ]]
	[[ $(jq -r '.[0].service' <<< "$out") == 'http://127.0.0.1:8600' ]]
	[[ $(jq -r '.[1].hostname' <<< "$out") == 'cws.example.com' ]]
	[[ $(jq -r '.[1] | has("path")' <<< "$out") == 'false' ]]
	[[ $(jq -r '.[-1].service' <<< "$out") == 'http_status:404' ]]
}

@test "ingress_json_add: plain rule coexists with a path rule (bob 404 bug)" {
	local base out
	# the member-add order: bridge path rule exists FIRST
	base='[{"hostname":"bob-cws.example.com","path":"^/bridge(/.*)?$","service":"http://127.0.0.1:8601"},{"service":"http_status:404"}]'
	out=$(ingress_json_add bob-cws.example.com 8444 <<< "$base")
	# path rule untouched
	[[ $(jq -r '.[0].service' <<< "$out") == 'http://127.0.0.1:8601' ]]
	[[ $(jq -r '.[0].path' <<< "$out") == '^/bridge(/.*)?$' ]]
	# plain rule ADDED (not merged into the path rule)
	[[ $(jq -r '.[1].hostname' <<< "$out") == 'bob-cws.example.com' ]]
	[[ $(jq -r '.[1] | has("path")' <<< "$out") == 'false' ]]
	[[ $(jq -r '.[1].service' <<< "$out") == 'http://127.0.0.1:8444' ]]
	[[ $(jq -r '.[-1].service' <<< "$out") == 'http_status:404' ]]
	# and it stays idempotent
	[[ $(ingress_json_add bob-cws.example.com 8444 <<< "$out") == "$out" ]]
}

@test "ingress_json_add_path: idempotent, reconciles a moved port" {
	local base once twice moved
	base='[{"hostname":"cws.example.com","service":"http://127.0.0.1:8443"},{"service":"http_status:404"}]'
	once=$(ingress_json_add_path cws.example.com '^/bridge(/.*)?$' 8600 \
		<<< "$base")
	twice=$(ingress_json_add_path cws.example.com '^/bridge(/.*)?$' 8600 \
		<<< "$once")
	[[ $once == "$twice" ]]
	moved=$(ingress_json_add_path cws.example.com '^/bridge(/.*)?$' 8601 \
		<<< "$once")
	[[ $(jq -r '.[0].service' <<< "$moved") == 'http://127.0.0.1:8601' ]]
	[[ $(jq 'length' <<< "$moved") == $(jq 'length' <<< "$once") ]]
}

@test "clientbridge_unit: env port + display + node server wired in" {
	local unit
	unit=$(clientbridge_unit /opt/coworkstation/bridge 8601 2)
	[[ $unit == *'CWS_BRIDGE_PORT=8601'* ]]
	[[ $unit == *'CWS_BRIDGE_DISPLAY=:2'* ]]
	[[ $unit == *'node /opt/coworkstation/bridge/server.js'* ]]
	[[ $unit == *'WantedBy=default.target'* ]]
	unit=$(clientbridge_unit /opt/b 8600)
	[[ $unit == *'CWS_BRIDGE_DISPLAY=:1'* ]]
}

@test "clientbridge_mcp_snippet: merges without clobbering other keys" {
	local merged
	merged=$(jq -s '.[0] * .[1]' \
		<(printf '{"mcpServers":{"mine":{"command":"x"}},"other":1}') \
		<(clientbridge_mcp_snippet /opt/b))
	[[ $(jq -r '.mcpServers.mine.command' <<< "$merged") == 'x' ]]
	[[ $(jq -r '.mcpServers."client-screen".command' <<< "$merged") == 'node' ]]
	[[ $(jq -r '.other' <<< "$merged") == '1' ]]
}

@test "clientbridge_setup: dry-run plans and touches nothing" {
	appliance_dry_run=1
	run clientbridge_setup alice 2 cws.example.com
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: clientbridge for alice (port 8601, host cws.example.com)'* ]]
}

@test "clientbridge_link: prints the tokened URL" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	mkdir -p "$TEST_TMP/home/.config/cws-bridge"
	printf 'TOK123' > "$TEST_TMP/home/.config/cws-bridge/token"
	run clientbridge_link alice cws.example.com
	[[ $status -eq 0 ]]
	[[ $output == 'https://cws.example.com/bridge/?t=TOK123' ]]
}

@test "cws-client: ssh argv gains the Access ProxyCommand only on --access" {
	# shellcheck source=client/cws-client
	source "$SCRIPT_DIR/../client/cws-client"
	build_ssh_cmd user@cws.example.com 0
	[[ ${ssh_cmd[*]} != *ProxyCommand* ]]
	build_ssh_cmd user@cws.example.com 1
	[[ ${ssh_cmd[*]} == *'cloudflared access ssh --hostname cws.example.com'* ]]
}

@test "cws-client: mount refuses a missing dir; umount needs a target" {
	source "$SCRIPT_DIR/../client/cws-client"
	run main mount /no/such/dir user@host
	[[ $status -ne 0 ]]
	[[ $output == *'no such directory'* ]]
	run main umount
	[[ $status -ne 0 ]]
}

@test "live: bridge server + client-screen MCP end-to-end" {
	if ! command -v node > /dev/null 2>&1; then
		skip 'node not available'
	fi
	run node "$SCRIPT_DIR/helpers/bridge-test.js"
	[[ $status -eq 0 ]]
	[[ $output == *'all assertions passed'* ]]
}
