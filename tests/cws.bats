#!/usr/bin/env bats
#
# cws.bats
# Tests for the cws CLI (dispatch, menu seam, credentials, version).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
CWS="$SCRIPT_DIR/../cws"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export APPLIANCE_ETC="$TEST_TMP/etc"
	mkdir -p "$APPLIANCE_ETC"
}

teardown() {
	[[ -n $TEST_TMP && -d $TEST_TMP ]] && rm -rf "$TEST_TMP"
}

@test "cws help lists the subcommands" {
	run bash "$CWS" help
	[[ $status -eq 0 ]]
	[[ $output == *'cws setup'* ]]
	[[ $output == *'cws member'* ]]
	[[ $output == *'cws storage'* ]]
	[[ $output == *'cws ssh-config'* ]]
}

@test "cws version prints the current release" {
	run bash "$CWS" version
	[[ $status -eq 0 ]]
	[[ $output =~ ^cws\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "cws rejects an unknown command with the usage" {
	run bash "$CWS" frobnicate
	[[ $status -ne 0 ]]
	[[ $output == *"unknown command 'frobnicate'"* ]]
	[[ $output == *'cws setup'* ]]
}

@test "cws with no args and no TTY prints usage and fails" {
	run bash -c "printf '' | bash '$CWS'"
	[[ $status -ne 0 ]]
	[[ $output == *'cws setup'* ]]
}

@test "cws help lists the kiosk toggle" {
	run bash "$CWS" help
	[[ $status -eq 0 ]]
	[[ $output == *'cws kiosk'* ]]
}

@test "cws kiosk status: off by default, on when the conf flag is set" {
	run bash "$CWS" kiosk status
	[[ $status -eq 0 ]]
	[[ $output == *'kiosk: off'* ]]
	printf 'profile=kasmvnc\nkiosk=1\n' > "$APPLIANCE_ETC/appliance.conf"
	run bash "$CWS" kiosk status
	[[ $status -eq 0 ]]
	[[ $output == *'kiosk: on'* ]]
}

@test "cws kiosk on: refuses without root and names the escalation" {
	[[ $EUID -eq 0 ]] && skip 'root would pass the gate and reconfigure'
	printf 'profile=kasmvnc\n' > "$APPLIANCE_ETC/appliance.conf"
	run bash "$CWS" kiosk on
	[[ $status -ne 0 ]]
	[[ $output == *'must run as root'* ]]
	[[ $output == *'sudo cws kiosk on'* ]]
}

@test "cws kiosk: rejects a bad action" {
	run bash "$CWS" kiosk sideways
	[[ $status -ne 0 ]]
	[[ $output == *'usage: cws kiosk'* ]]
}

@test "cws member list forwards to member.sh" {
	run bash "$CWS" member list
	[[ $status -eq 0 ]]
	[[ $output == *'no members registered'* ]]
}

@test "cws ssh-config forwards flags and emits valid JSON" {
	run bash "$CWS" ssh-config --host cws.example.com --ssh-user alice
	[[ $status -eq 0 ]]
	local host
	host=$(jq -r '.sshConfigs[0].sshHost' <<< "$output")
	[[ $host == 'alice@cws.example.com' ]]
}

@test "cws menu: opens on the TTY seam, quits cleanly, shows status" {
	run bash -c "printf 'q\n' | APPLIANCE_ASSUME_TTY=1 bash '$CWS' 2>&1"
	[[ $status -eq 0 ]]
	[[ $output == *'Coworkstation'* ]]
	[[ $output == *'pair a device'* ]]
	[[ $output == *'optional cloud drive'* ]]
	[[ $output == *'engine: not installed'* ]]
}

@test "cws menu: dispatches member list then quits" {
	run bash -c "printf '5\nq\n' | APPLIANCE_ASSUME_TTY=1 bash '$CWS' 2>&1"
	[[ $status -eq 0 ]]
	[[ $output == *'no members registered'* ]]
}

@test "cws credentials: says how to escalate on an unreadable file" {
	run bash "$CWS" credentials nosuchuser12345
	[[ $status -ne 0 ]]
	[[ $output == *'no such user'* ]]
}
