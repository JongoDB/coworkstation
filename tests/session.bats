#!/usr/bin/env bats
#
# session.bats
# Concurrent per-device sessions (lib/session.sh): display/port
# allocation in the :50+ range, the per-session unit, hostname
# routing, dry-run inertness, removal, and the xstartup config-home
# branch that dodges the Claude singleton lock.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export APPLIANCE_ETC="$TEST_TMP/etc"
	mkdir -p "$APPLIANCE_ETC"
	# shellcheck source=lib/common.sh
	source "$SCRIPT_DIR/../lib/common.sh"
	# shellcheck source=lib/fleet.sh
	source "$SCRIPT_DIR/../lib/fleet.sh"
	# shellcheck source=lib/tunnel-api.sh
	source "$SCRIPT_DIR/../lib/tunnel-api.sh"
	# shellcheck source=lib/session.sh
	source "$SCRIPT_DIR/../lib/session.sh"
	appliance_etc="$APPLIANCE_ETC"
	appliance_dry_run=0
	appliance_force=0
}

teardown() {
	[[ -n $TEST_TMP && -d $TEST_TMP ]] && rm -rf "$TEST_TMP"
}

@test "session_next_display: starts at 50, skips used" {
	[[ $(session_next_display) == 50 ]]
	printf 'alice\t50\t8492\talice-s50.x\n' > "$APPLIANCE_ETC/sessions.tsv"
	[[ $(session_next_display) == 51 ]]
}

@test "session_unit: display + websocket port override wired in" {
	local unit
	unit=$(session_unit 50 8492)
	[[ $unit == *'vncserver :50 -websocketPort 8492'* ]]
	[[ $unit == *'vncserver -kill :50'* ]]
	[[ $unit == *'WantedBy=default.target'* ]]
}

@test "session_add: dry-run plans display/port/host, writes nothing" {
	printf 'hostname=cws.example.com\n' > "$APPLIANCE_ETC/appliance.conf"
	id() { return 0; }
	user_home() { printf '%s' "$TEST_TMP/home"; }
	mkdir -p "$TEST_TMP/home/.config/systemd/user"
	: > "$TEST_TMP/home/.config/systemd/user/kasmvnc.service"
	appliance_dry_run=1
	run session_add alice
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: extra session alice :50 port 8492 host alice-s50.cws.example.com'* ]]
	[[ ! -f $APPLIANCE_ETC/sessions.tsv ]]
}

@test "session_add: provisions unit, routes api, registers, records" {
	printf 'hostname=cws.example.com\n' > "$APPLIANCE_ETC/appliance.conf"
	id() { return 0; }
	user_home() { printf '%s' "$TEST_TMP/home"; }
	mkdir -p "$TEST_TMP/home/.config/systemd/user"
	: > "$TEST_TMP/home/.config/systemd/user/kasmvnc.service"
	chown() { return 0; }
	user_systemctl() { printf '%s\n' "$*" >> "$TEST_TMP/sysctl"; }
	tunnel_conf_get() { printf 'api'; }
	tunnel_api_member_add() {
		printf '%s %s %s\n' "$1" "$2" "${3:-}" > "$TEST_TMP/route"
	}
	run session_add alice 'alice@corp.com'
	[[ $status -eq 0 ]]
	local unit="$TEST_TMP/home/.config/systemd/user/kasmvnc-s50.service"
	[[ -f $unit ]]
	grep -q 'websocketPort 8492' "$unit"
	[[ $(cat "$TEST_TMP/route") == 'alice-s50.cws.example.com 8492 alice@corp.com' ]]
	grep -qP '^alice\t50\t8492\talice-s50\.cws\.example\.com$' \
		"$APPLIANCE_ETC/sessions.tsv"
	grep -q $'session-add\talice:50' "$APPLIANCE_ETC/audit.log"
	grep -q 'enable --now kasmvnc-s50.service' "$TEST_TMP/sysctl"
}

@test "session_add: refuses a user without a primary session" {
	id() { return 0; }
	user_home() { printf '%s' "$TEST_TMP/bare"; }
	mkdir -p "$TEST_TMP/bare"
	run session_add alice
	[[ $status -ne 0 ]]
	[[ $output == *'no primary session'* ]]
}

@test "session_remove: stops unit, removes route + row, keeps config" {
	printf 'alice\t50\t8492\talice-s50.cws.example.com\n' \
		> "$APPLIANCE_ETC/sessions.tsv"
	user_home() { printf '%s' "$TEST_TMP/home"; }
	mkdir -p "$TEST_TMP/home/.config/systemd/user"
	: > "$TEST_TMP/home/.config/systemd/user/kasmvnc-s50.service"
	user_systemctl() { printf '%s\n' "$*" >> "$TEST_TMP/sysctl2"; }
	tunnel_conf_get() { printf 'api'; }
	tunnel_api_member_remove() { printf '%s\n' "$1" > "$TEST_TMP/unroute"; }
	run session_remove alice 50
	[[ $status -eq 0 ]]
	[[ ! -f $TEST_TMP/home/.config/systemd/user/kasmvnc-s50.service ]]
	[[ $(cat "$TEST_TMP/unroute") == 'alice-s50.cws.example.com' ]]
	[[ ! -s $APPLIANCE_ETC/sessions.tsv ]]
	[[ $output == *'config home'*'kept'* ]]
	run session_remove alice 99
	[[ $status -ne 0 ]]
}

@test "xstartup: extra displays get their own config home" {
	# shellcheck source=lib/profiles/kasmvnc.sh
	source "$SCRIPT_DIR/../lib/profiles/kasmvnc.sh"
	local x="$TEST_TMP/xstartup"
	kasmvnc_xstartup > "$x"
	chmod +x "$x"
	mkdir -p "$TEST_TMP/bin"
	printf '#!/bin/sh\necho "XDG=${XDG_CONFIG_HOME:-unset}"\n' \
		> "$TEST_TMP/bin/startxfce4"
	chmod +x "$TEST_TMP/bin/startxfce4"
	run env -i HOME="$TEST_TMP" DISPLAY=':52.0' \
		PATH="$TEST_TMP/bin:/usr/bin:/bin" sh "$x"
	[[ $output == "XDG=$TEST_TMP/.config/cws-sessions/52" ]]
	[[ -d $TEST_TMP/.config/cws-sessions/52 ]]
	run env -i HOME="$TEST_TMP" DISPLAY=':2.0' \
		PATH="$TEST_TMP/bin:/usr/bin:/bin" sh "$x"
	[[ $output == 'XDG=unset' ]]
}
