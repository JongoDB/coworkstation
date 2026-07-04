#!/usr/bin/env bats
#
# appliance-mcp.bats
# Protocol and end-to-end tests for the test-bench MCP servers
# (testbench/desktop-control-mcp.js, vm-bench-mcp.js)
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
DESKTOP_SRV="$SCRIPT_DIR/../testbench/desktop-control-mcp.js"
VM_SRV="$SCRIPT_DIR/../testbench/vm-bench-mcp.js"
CLIENT="$SCRIPT_DIR/helpers/mcp-client.js"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	init_req() {
		printf '%s\n' \
			'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"bats","version":"0"}}}' \
			'{"jsonrpc":"2.0","method":"notifications/initialized"}'
	}
}

teardown() {
	if [[ -n $TEST_TMP && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# desktop-control: protocol
# =============================================================================

@test "desktop-control: initialize returns serverInfo and tools cap" {
	init_req > "$TEST_TMP/req.jsonl"
	run node "$CLIENT" "$DESKTOP_SRV" "$TEST_TMP/req.jsonl"
	[[ $status -eq 0 ]]
	local info
	info=$(head -1 <<< "$output" \
		| jq -r '.result.serverInfo.name')
	[[ $info == 'appliance-desktop-control' ]]
}

@test "desktop-control: tools/list exposes the full toolset" {
	{
		init_req
		printf '{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n'
	} > "$TEST_TMP/req.jsonl"
	run node "$CLIENT" "$DESKTOP_SRV" "$TEST_TMP/req.jsonl"
	[[ $status -eq 0 ]]
	local names
	names=$(tail -1 <<< "$output" \
		| jq -r '.result.tools[].name' | sort | tr '\n' ' ')
	[[ $names == 'ax_tree click display_start display_stop key launch screenshot type ' ]]
}

@test "desktop-control: unknown tool returns -32602" {
	{
		init_req
		printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}\n'
	} > "$TEST_TMP/req.jsonl"
	run node "$CLIENT" "$DESKTOP_SRV" "$TEST_TMP/req.jsonl"
	local code
	code=$(tail -1 <<< "$output" | jq -r '.error.code')
	[[ $code == '-32602' ]]
}

@test "desktop-control: tools refuse to run without a test display" {
	{
		init_req
		printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}\n'
	} > "$TEST_TMP/req.jsonl"
	run node "$CLIENT" "$DESKTOP_SRV" "$TEST_TMP/req.jsonl"
	local line
	line=$(tail -1 <<< "$output")
	[[ $(jq -r '.result.isError' <<< "$line") == 'true' ]]
	[[ $(jq -r '.result.content[0].text' <<< "$line") == \
		*'display_start'* ]]
}

@test "desktop-control: launch validates argv types" {
	{
		init_req
		printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"display_start","arguments":{"width":320,"height":240}}}\n'
		printf '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"launch","arguments":{"command":"xlogo","args":"not-an-array"}}}\n'
		printf '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"display_stop","arguments":{}}}\n'
	} > "$TEST_TMP/req.jsonl"
	run node "$CLIENT" "$DESKTOP_SRV" "$TEST_TMP/req.jsonl"
	[[ $status -eq 0 ]]
	local line
	line=$(sed -n '3p' <<< "$output")
	[[ $(jq -r '.result.isError' <<< "$line") == 'true' ]]
	[[ $(jq -r '.result.content[0].text' <<< "$line") == \
		*'array of strings'* ]]
}

# =============================================================================
# desktop-control: live end-to-end on a nested Xvfb display
# =============================================================================

@test "desktop-control: e2e launch, screenshot, input, clean teardown" {
	if ! command -v Xvfb > /dev/null 2>&1 \
		|| ! command -v xdotool > /dev/null 2>&1 \
		|| ! command -v import > /dev/null 2>&1 \
		|| ! command -v xlogo > /dev/null 2>&1; then
		skip 'needs Xvfb, xdotool, imagemagick, x11-apps'
	fi
	{
		init_req
		printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"display_start","arguments":{"width":640,"height":480}}}\n'
		printf '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"launch","arguments":{"command":"xlogo","args":["-geometry","200x200+10+10"]}}}\n'
		printf '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}\n'
		printf '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"click","arguments":{"x":50,"y":50}}}\n'
		printf '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"key","arguments":{"keys":"Return"}}}\n'
		printf '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"display_stop","arguments":{}}}\n'
	} > "$TEST_TMP/req.jsonl"
	run node "$CLIENT" "$DESKTOP_SRV" "$TEST_TMP/req.jsonl"
	[[ $status -eq 0 ]]

	# display_start names the display it created
	local disp
	disp=$(sed -n '2p' <<< "$output" \
		| jq -r '.result.content[0].text' \
		| grep -oE ':[0-9]+')
	[[ -n $disp ]]

	# every step succeeded
	local i line
	for i in 2 3 4 5 6 7; do
		line=$(sed -n "${i}p" <<< "$output")
		[[ $(jq -r '.result.isError // false' <<< "$line") == 'false' ]]
	done

	# screenshot is a real PNG
	local magic
	magic=$(sed -n '4p' <<< "$output" \
		| jq -r '.result.content[0].data' \
		| base64 -d | head -c 4 | od -An -tx1 | tr -d ' \n')
	[[ $magic == '89504e47' ]]

	# teardown left no orphan Xvfb on our display
	run pgrep -f "Xvfb $disp "
	[[ $status -ne 0 ]]
}

# =============================================================================
# vm-bench: protocol + QMP wire
# =============================================================================

@test "vm-bench: tools/list marks every tool experimental" {
	{
		init_req
		printf '{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n'
	} > "$TEST_TMP/req.jsonl"
	run node "$CLIENT" "$VM_SRV" "$TEST_TMP/req.jsonl"
	[[ $status -eq 0 ]]
	local total experimental
	total=$(tail -1 <<< "$output" | jq '.result.tools | length')
	experimental=$(tail -1 <<< "$output" \
		| jq '[.result.tools[]
			| select(.description | startswith("[experimental]"))]
			| length')
	[[ $total == '5' ]]
	[[ $experimental == '5' ]]
}

@test "vm-bench: vm_start rejects a missing image path" {
	{
		init_req
		printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"vm_start","arguments":{"image":"/no/such/image.qcow2"}}}\n'
	} > "$TEST_TMP/req.jsonl"
	run node "$CLIENT" "$VM_SRV" "$TEST_TMP/req.jsonl"
	local line
	line=$(tail -1 <<< "$output")
	[[ $(jq -r '.result.isError' <<< "$line") == 'true' ]]
	[[ $(jq -r '.result.content[0].text' <<< "$line") == \
		*'existing disk image'* ]]
}

@test "vm-bench: QMP client survives greeting, events, and errors" {
	run node "$SCRIPT_DIR/helpers/qmp-mock-test.js" \
		"$SCRIPT_DIR/../testbench/vm-bench-mcp.js"
	[[ $status -eq 0 ]]
	[[ $output == *'QMP-MOCK-OK'* ]]
}
