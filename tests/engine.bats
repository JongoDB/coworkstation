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

@test "select_engine: auto on ubuntu without kvm stays OFFICIAL and warns" {
	# The community build is explicit opt-in only: auto must never
	# silently swap in a patched binary to gain the Cowork VM feature.
	write_os_release ubuntu noble
	APPLIANCE_DEV_KVM="$TEST_TMP/no-such-kvm"
	run bash -c '
		source "'"$SCRIPT_DIR"'/../lib/common.sh"
		source "'"$SCRIPT_DIR"'/../lib/engine.sh"
		APPLIANCE_OS_RELEASE="'"$TEST_TMP"'/os-release"
		APPLIANCE_DEV_KVM="'"$TEST_TMP"'/no-such-kvm"
		select_engine auto
		printf "choice=%s\n" "$engine_choice"
	' 2>&1
	[[ $output == *'choice=official'* ]]
	[[ $output == *'KVM'* ]]
	select_engine auto
	[[ $engine_choice == 'official' ]]
	[[ $engine_reason == *'Cowork VM'* ]]
}

@test "select_engine: --engine repo warns about the community build" {
	run select_engine repo
	[[ $status -eq 0 ]]
	[[ $output == *'opting into'* ]]
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
	install_engine
	[[ -f $APPLIANCE_ETC/engine.conf ]]
	grep -q '^engine=official$' "$APPLIANCE_ETC/engine.conf"
	grep -q '^backend=kvm$' "$APPLIANCE_ETC/engine.conf"
}

@test "install_engine: repo without kvm records backend=none (v3: no bwrap)" {
	# Upstream v3 parked the bwrap Cowork backend, so the repo engine is
	# KVM-or-nothing exactly like the official one — and no
	# COWORK_VM_BACKEND env drop-in may be written.
	write_os_release ubuntu noble
	APPLIANCE_DEV_KVM="$TEST_TMP/no-such-kvm"
	_engine_install_repo() { return 0; }
	select_engine repo
	install_engine
	grep -q '^backend=none$' "$APPLIANCE_ETC/engine.conf"
	[[ ! -e $TEST_TMP/home/.config/environment.d/60-coworkstation.conf ]]
}

@test "claude_desktop_binary: prefers official, falls back to unofficial" {
	command() {
		if [[ $1 == '-v' && $2 == 'claude-desktop' ]]; then return 1; fi
		if [[ $1 == '-v' && $2 == 'claude-desktop-unofficial' ]]; then
			return 0
		fi
		builtin command "$@"
	}
	[[ $(claude_desktop_binary) == 'claude-desktop-unofficial' ]]
	command() { return 1; }
	[[ $(claude_desktop_binary) == 'claude-desktop' ]]
}

@test "install_engine: official without kvm records backend=none" {
	write_os_release ubuntu noble
	APPLIANCE_DEV_KVM="$TEST_TMP/no-such-kvm"
	_engine_install_official() { return 0; }
	select_engine auto
	install_engine
	grep -q '^engine=official$' "$APPLIANCE_ETC/engine.conf"
	grep -q '^backend=none$' "$APPLIANCE_ETC/engine.conf"
	# no bwrap env written for the official engine
	[[ ! -e $TEST_TMP/home/.config/environment.d/60-coworkstation.conf ]]
}

@test "install_engine: engine.conf is refreshed on re-run" {
	write_os_release debian bookworm
	touch "$TEST_TMP/kvm"
	APPLIANCE_DEV_KVM="$TEST_TMP/kvm"
	_engine_install_official() { return 0; }
	_engine_install_repo() { return 0; }
	select_engine auto
	install_engine
	grep -q '^engine=official$' "$APPLIANCE_ETC/engine.conf"
	# Second run with a forced repo engine must overwrite the record
	user_home() { printf '%s' "$TEST_TMP/home"; }
	run_as_user() { shift; "$@"; }
	mkdir -p "$TEST_TMP/home"
	chown() { return 0; }
	select_engine repo
	install_engine
	grep -q '^engine=repo$' "$APPLIANCE_ETC/engine.conf"
}

@test "install_engine: fails cleanly before select_engine" {
	engine_choice=''
	run install_engine
	[[ $status -ne 0 ]]
}

@test "install_engine: propagates installer failure" {
	select_engine official
	_engine_install_official() { return 1; }
	run install_engine
	[[ $status -ne 0 ]]
}
