#!/usr/bin/env bats
#
# appliance-common.bats
# Tests for shared helpers in appliance/lib/common.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# shellcheck source=lib/common.sh
	source "$SCRIPT_DIR/../lib/common.sh"

	appliance_dry_run=0
	appliance_force=0
}

teardown() {
	if [[ -n $TEST_TMP && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# run_cmd
# =============================================================================

@test "run_cmd: executes the command when not dry-run" {
	run_cmd touch "$TEST_TMP/created"
	[[ -f $TEST_TMP/created ]]
}

@test "run_cmd: prints instead of executing under dry-run" {
	appliance_dry_run=1
	run run_cmd touch "$TEST_TMP/created"
	[[ $status -eq 0 ]]
	[[ $output == "DRY-RUN: touch $TEST_TMP/created" ]]
	[[ ! -f $TEST_TMP/created ]]
}

@test "run_cmd: propagates the command's exit status" {
	run run_cmd false
	[[ $status -ne 0 ]]
}

# =============================================================================
# write_file
# =============================================================================

@test "write_file: creates file with parent dirs and content" {
	printf 'hello' | write_file "$TEST_TMP/a/b/conf"
	[[ -f $TEST_TMP/a/b/conf ]]
	[[ $(cat "$TEST_TMP/a/b/conf") == 'hello' ]]
}

@test "write_file: keeps existing file without --force" {
	printf 'original' > "$TEST_TMP/conf"
	printf 'new' | write_file "$TEST_TMP/conf"
	[[ $(cat "$TEST_TMP/conf") == 'original' ]]
}

@test "write_file: overwrites with --force" {
	printf 'original' > "$TEST_TMP/conf"
	appliance_force=1
	printf 'new' | write_file "$TEST_TMP/conf"
	[[ $(cat "$TEST_TMP/conf") == 'new' ]]
}

@test "write_file: dry-run touches nothing and prints target" {
	appliance_dry_run=1
	run bash -c '
		source "'"$SCRIPT_DIR"'/../lib/common.sh"
		appliance_dry_run=1
		printf "data" | write_file "'"$TEST_TMP"'/conf"
	'
	[[ $status -eq 0 ]]
	[[ $output == *"DRY-RUN: write $TEST_TMP/conf"* ]]
	[[ ! -f $TEST_TMP/conf ]]
}

@test "write_file: applies the requested mode" {
	printf 'x' | write_file "$TEST_TMP/script" 755
	local mode
	mode=$(stat -c '%a' "$TEST_TMP/script")
	[[ $mode == '755' ]]
}

# =============================================================================
# distro / arch detection
# =============================================================================

@test "appliance_distro_id: reads ID from os-release fixture" {
	printf 'ID=debian\nVERSION_CODENAME=bookworm\n' \
		> "$TEST_TMP/os-release"
	APPLIANCE_OS_RELEASE="$TEST_TMP/os-release"
	local result
	result=$(appliance_distro_id)
	[[ $result == 'debian' ]]
}

@test "appliance_distro_id: strips quotes" {
	printf 'ID="ubuntu"\n' > "$TEST_TMP/os-release"
	APPLIANCE_OS_RELEASE="$TEST_TMP/os-release"
	local result
	result=$(appliance_distro_id)
	[[ $result == 'ubuntu' ]]
}

@test "appliance_distro_id: unknown when file missing" {
	APPLIANCE_OS_RELEASE="$TEST_TMP/missing"
	local result
	result=$(appliance_distro_id)
	[[ $result == 'unknown' ]]
}

@test "appliance_distro_codename: reads VERSION_CODENAME" {
	printf 'ID=debian\nVERSION_CODENAME=bookworm\n' \
		> "$TEST_TMP/os-release"
	APPLIANCE_OS_RELEASE="$TEST_TMP/os-release"
	local result
	result=$(appliance_distro_codename)
	[[ $result == 'bookworm' ]]
}

@test "appliance_arch: maps uname to debian arch without dpkg" {
	command() {
		if [[ $1 == '-v' && $2 == 'dpkg' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	uname() { printf 'aarch64'; }
	local result
	result=$(appliance_arch)
	[[ $result == 'arm64' ]]
}

# =============================================================================
# resolve_target_user
# =============================================================================

@test "resolve_target_user: explicit user wins" {
	id() { return 0; }
	local result
	result=$(SUDO_USER=other resolve_target_user alice)
	[[ $result == 'alice' ]]
}

@test "resolve_target_user: falls back to SUDO_USER" {
	id() { return 0; }
	local result
	result=$(SUDO_USER=bob resolve_target_user '')
	[[ $result == 'bob' ]]
}

@test "resolve_target_user: rejects root" {
	id() { return 0; }
	run resolve_target_user root
	[[ $status -ne 0 ]]
	[[ $output == *'--user NAME'* ]]
}

@test "resolve_target_user: rejects nonexistent user" {
	id() { return 1; }
	run resolve_target_user ghost
	[[ $status -ne 0 ]]
	[[ $output == *'does not exist'* ]]
}

# =============================================================================
# user_home
# =============================================================================

@test "user_home: reads home from passwd db" {
	getent() { printf 'alice:x:1000:1000::/home/alice:/bin/bash\n'; }
	local result
	result=$(user_home alice)
	[[ $result == '/home/alice' ]]
}

@test "user_home: fails when user has no passwd entry" {
	getent() { return 2; }
	run user_home ghost
	[[ $status -ne 0 ]]
}

# =============================================================================
# user_systemctl (headless-safe systemctl --user)
# =============================================================================

@test "user_systemctl: dry-run prints plan, touches nothing" {
	appliance_dry_run=1
	id() { printf '1042'; }
	run user_systemctl alice enable --now kasmvnc.service
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: user_systemctl alice'* ]]
	[[ $output == *'enable --now kasmvnc.service'* ]]
}

@test "user_systemctl: enables linger, starts manager, sets bus env" {
	id() { printf '1042'; }
	export APPLIANCE_RUNTIME_DIR="$TEST_TMP/run1042"
	mkdir -p "$APPLIANCE_RUNTIME_DIR"
	# no bus yet; "starting" the manager creates it
	loginctl() { printf 'loginctl %s\n' "$*" >> "$TEST_TMP/calls"; }
	systemctl() {
		printf 'systemctl %s\n' "$*" >> "$TEST_TMP/calls"
		# emulate the manager creating its bus socket (a real unix
		# socket, since the code correctly checks with -S)
		python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
			"$APPLIANCE_RUNTIME_DIR/bus"
	}
	runuser() {
		# capture the env passed to the --user invocation
		shift 3  # -u alice --
		printf 'RUNUSER: %s\n' "$*" >> "$TEST_TMP/calls"
	}
	run user_systemctl alice enable --now kasmvnc.service
	[[ $status -eq 0 ]]
	grep -q 'loginctl enable-linger alice' "$TEST_TMP/calls"
	grep -q 'systemctl start user@1042.service' "$TEST_TMP/calls"
	grep -q 'DBUS_SESSION_BUS_ADDRESS=unix:path=.*/bus' "$TEST_TMP/calls"
	grep -q 'systemctl --user enable --now kasmvnc.service' \
		"$TEST_TMP/calls"
}

@test "user_systemctl: fails cleanly if the bus never appears" {
	id() { printf '1042'; }
	export APPLIANCE_RUNTIME_DIR="$TEST_TMP/run-nobus"
	loginctl() { :; }
	systemctl() { :; }   # never creates the bus
	# make the wait fast — override sleep
	sleep() { :; }
	run user_systemctl alice enable --now kasmvnc.service
	[[ $status -ne 0 ]]
	[[ $output == *'bus never appeared'* ]]
}
