#!/usr/bin/env bats
#
# appliance-storage.bats
# Tests for remote-backed storage (appliance/storage.sh)
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# shellcheck source=storage.sh
	source "$SCRIPT_DIR/../storage.sh"

	appliance_dry_run=0
	appliance_force=0
}

teardown() {
	if [[ -n $TEST_TMP && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# Provider mapping and validation
# =============================================================================

@test "storage_backend_for: maps friendly names to rclone backends" {
	[[ $(storage_backend_for gdrive) == 'drive' ]]
	[[ $(storage_backend_for onedrive) == 'onedrive' ]]
	[[ $(storage_backend_for dropbox) == 'dropbox' ]]
}

@test "storage_backend_for: rejects unknown providers" {
	run storage_backend_for icloud
	[[ $status -ne 0 ]]
	[[ $output == *'unknown provider'* ]]
}

@test "cmd_add: rejects invalid remote names" {
	id() { return 0; }
	run cmd_add alice 'Bad Name' gdrive '' 10G
	[[ $status -ne 0 ]]
	[[ $output == *'invalid remote name'* ]]
}

@test "cmd_add: rejects a nonexistent user" {
	id() { return 1; }
	run cmd_add ghost drive gdrive '' 10G
	[[ $status -ne 0 ]]
	[[ $output == *'does not exist'* ]]
}

# =============================================================================
# Mount unit
# =============================================================================

@test "storage_unit: bounded cache and safe umask are wired in" {
	local unit
	unit=$(storage_unit drive 5G)
	[[ $unit == *'--vfs-cache-mode full'* ]]
	[[ $unit == *'--vfs-cache-max-size 5G'* ]]
	[[ $unit == *'--umask 077'* ]]
	[[ $unit == *'rclone mount drive: %h/CloudDrives/drive'* ]]
	[[ $unit == *'fusermount -uz %h/CloudDrives/drive'* ]]
}

@test "storage_install_unit: writes the unit under the member home" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	run_as_user() { shift; "$@"; }
	run_cmd() { :; }
	chown() { return 0; }
	id() { printf '1042'; }
	# enabling the unit is exercised by appliance-common's
	# user_systemctl tests; here we only assert the unit is written.
	user_systemctl() { :; }
	mkdir -p "$TEST_TMP/home"
	storage_install_unit alice drive 10G
	local unit
	unit="$TEST_TMP/home/.config/systemd/user/rclone-drive.service"
	[[ -f $unit ]]
	grep -q 'vfs-cache-max-size 10G' "$unit"
}

# =============================================================================
# Token intake
# =============================================================================

@test "storage_read_token: reads from --token-file" {
	printf '{"access_token":"x"}' > "$TEST_TMP/tok"
	local out
	out=$(storage_read_token gdrive "$TEST_TMP/tok")
	[[ $out == '{"access_token":"x"}' ]]
}

@test "storage_read_token: fails without file or terminal" {
	run bash -c '
		source "'"$SCRIPT_DIR"'/../storage.sh"
		printf "" | storage_read_token gdrive ""
	'
	[[ $status -ne 0 ]]
	[[ $output == *'--token-file'* ]]
}

@test "storage_read_token: interactive prompt names the provider cmd" {
	run bash -c '
		source "'"$SCRIPT_DIR"'/../storage.sh"
		printf "{\"t\":1}\n" | APPLIANCE_ASSUME_TTY=1 \
			storage_read_token gdrive "" 2>&1
	'
	[[ $status -eq 0 ]]
	[[ $output == *'rclone authorize "drive"'* ]]
	[[ $output == *'{"t":1}'* ]]
}

# =============================================================================
# Dry-run and CLI
# =============================================================================

@test "cmd_add: dry-run plans config, unit, and enable steps" {
	id() { if [[ $1 == '-u' ]]; then printf '1042'; fi; return 0; }
	user_home() { printf '%s' "$TEST_TMP/home"; }
	command() {
		if [[ $1 == '-v' && $2 == 'rclone' ]]; then return 0; fi
		builtin command "$@"
	}
	mkdir -p "$TEST_TMP/home"
	printf '{"t":1}' > "$TEST_TMP/tok"
	appliance_dry_run=1
	run cmd_add alice drive gdrive "$TEST_TMP/tok" 10G
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: write rclone remote drive (drive)'* ]]
	[[ $output == *'rclone-drive.service'* ]]
	[[ $output == *'cloud storage ready'* ]]
	[[ ! -d $TEST_TMP/home/.config ]]
}

@test "cli: add without required flags errors" {
	run bash "$SCRIPT_DIR/../storage.sh" add --user alice
	[[ $status -ne 0 ]]
	[[ $output == *'--provider'* ]]
}

@test "cli: list without rclone reports nothing configured" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	command() {
		if [[ $1 == '-v' && $2 == 'rclone' ]]; then return 1; fi
		builtin command "$@"
	}
	mkdir -p "$TEST_TMP/home"
	run cmd_list alice
	[[ $status -eq 0 ]]
	[[ $output == *'no storage configured'* ]]
}
