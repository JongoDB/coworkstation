#!/usr/bin/env bats
#
# appliance-engine.bats
# Tests for engine selection/installation in appliance/lib/engine.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export APPLIANCE_ETC="$TEST_TMP/etc"

	# shellcheck source=lib/common.sh
	source "$SCRIPT_DIR/../lib/common.sh"
	# shellcheck source=lib/engine.sh
	source "$SCRIPT_DIR/../lib/engine.sh"

	appliance_dry_run=0
	appliance_force=0

	write_os_release() {
		printf 'ID=%s\nVERSION_CODENAME=%s\n' "$1" "${2:-stable}" \
			> "$TEST_TMP/os-release"
		APPLIANCE_OS_RELEASE="$TEST_TMP/os-release"
	}
}

teardown() {
	if [[ -n $TEST_TMP && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# select_engine
# =============================================================================

@test "select_engine: --engine official is honored verbatim" {
	select_engine official
	[[ $engine_choice == 'official' ]]
	[[ $engine_reason == *'forced'* ]]
}

@test "select_engine: --engine repo is honored verbatim" {
	select_engine repo
	[[ $engine_choice == 'repo' ]]
}

@test "select_engine: rejects unknown value" {
	run select_engine banana
	[[ $status -ne 0 ]]
	[[ $output == *"unknown engine 'banana'"* ]]
}

@test "select_engine: auto on debian with kvm picks official" {
	write_os_release debian bookworm
	touch "$TEST_TMP/kvm"
	APPLIANCE_DEV_KVM="$TEST_TMP/kvm"
	select_engine auto
	[[ $engine_choice == 'official' ]]
	[[ $engine_reason == *'/dev/kvm present'* ]]
}

@test "select_engine: auto on ubuntu without kvm picks repo+bwrap" {
	write_os_release ubuntu noble
	APPLIANCE_DEV_KVM="$TEST_TMP/no-such-kvm"
	select_engine auto
	[[ $engine_choice == 'repo' ]]
	[[ $engine_reason == *'bwrap'* ]]
}

@test "select_engine: auto on fedora picks repo regardless of kvm" {
	write_os_release fedora
	touch "$TEST_TMP/kvm"
	APPLIANCE_DEV_KVM="$TEST_TMP/kvm"
	select_engine auto
	[[ $engine_choice == 'repo' ]]
	[[ $engine_reason == *'official build unavailable'* ]]
}

# =============================================================================
# install_engine
# =============================================================================

@test "install_engine: records official engine with kvm backend" {
	write_os_release debian bookworm
	touch "$TEST_TMP/kvm"
	APPLIANCE_DEV_KVM="$TEST_TMP/kvm"
	_engine_install_official() { return 0; }
	select_engine auto
	install_engine alice
	[[ -f $APPLIANCE_ETC/engine.conf ]]
	grep -q '^engine=official$' "$APPLIANCE_ETC/engine.conf"
	grep -q '^backend=kvm$' "$APPLIANCE_ETC/engine.conf"
}

@test "install_engine: repo without kvm records bwrap and writes env" {
	write_os_release ubuntu noble
	APPLIANCE_DEV_KVM="$TEST_TMP/no-such-kvm"
	_engine_install_repo() { return 0; }
	user_home() { printf '%s' "$TEST_TMP/home"; }
	run_as_user() { shift; "$@"; }
	mkdir -p "$TEST_TMP/home"
	chown() { return 0; }
	select_engine auto
	install_engine alice
	grep -q '^backend=bwrap$' "$APPLIANCE_ETC/engine.conf"
	local env_file
	env_file="$TEST_TMP/home/.config/environment.d"
	env_file+='/60-claude-appliance.conf'
	[[ -f $env_file ]]
	grep -q '^COWORK_VM_BACKEND=bwrap$' "$env_file"
}

@test "install_engine: engine.conf is refreshed on re-run" {
	write_os_release debian bookworm
	touch "$TEST_TMP/kvm"
	APPLIANCE_DEV_KVM="$TEST_TMP/kvm"
	_engine_install_official() { return 0; }
	_engine_install_repo() { return 0; }
	select_engine auto
	install_engine alice
	grep -q '^engine=official$' "$APPLIANCE_ETC/engine.conf"
	# Second run with a forced repo engine must overwrite the record
	user_home() { printf '%s' "$TEST_TMP/home"; }
	run_as_user() { shift; "$@"; }
	mkdir -p "$TEST_TMP/home"
	chown() { return 0; }
	select_engine repo
	install_engine alice
	grep -q '^engine=repo$' "$APPLIANCE_ETC/engine.conf"
}

@test "install_engine: fails cleanly before select_engine" {
	engine_choice=''
	run install_engine alice
	[[ $status -ne 0 ]]
}

@test "install_engine: propagates installer failure" {
	select_engine official
	_engine_install_official() { return 1; }
	run install_engine alice
	[[ $status -ne 0 ]]
}
