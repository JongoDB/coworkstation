#!/usr/bin/env bats
#
# backup.bats
# Encrypted backup plumbing (lib/backup.sh): setup writes conf+key,
# runs wire the repo/key env into restic, excludes and tags are
# present, ops-log recording, and failure modes.
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
	# shellcheck source=lib/backup.sh
	source "$SCRIPT_DIR/../lib/backup.sh"
	appliance_etc="$APPLIANCE_ETC"
	appliance_dry_run=0
	appliance_force=0
}

teardown() {
	[[ -n $TEST_TMP && -d $TEST_TMP ]] && rm -rf "$TEST_TMP"
}

mock_restic() {
	restic() {
		printf 'RESTIC %s | repo=%s | keyfile=%s\n' "$*" \
			"${RESTIC_REPOSITORY:-}" "${RESTIC_PASSWORD_FILE:-}" \
			>> "$TEST_TMP/restic.log"
	}
	command() {
		if [[ $2 == restic ]]; then return 0; fi
		builtin command "$@"
	}
}

@test "backup_setup: writes conf + 0600 key, inits, warns loudly" {
	mock_restic
	run backup_setup /backup/cws
	[[ $status -eq 0 ]]
	[[ $(grep -c '^repo=/backup/cws$' "$APPLIANCE_ETC/backup.conf") -eq 1 ]]
	[[ $(stat -c %a "$APPLIANCE_ETC/backup.key") == 600 ]]
	[[ -s $APPLIANCE_ETC/backup.key ]]
	grep -q 'RESTIC init | repo=/backup/cws' "$TEST_TMP/restic.log"
	[[ $output == *'COPY'*'SOMEWHERE SAFE'* ]]
}

@test "backup_setup: no repo argument is refused with usage" {
	run backup_setup ''
	[[ $status -ne 0 ]]
	[[ $output == *'usage: cws backup setup REPO'* ]]
}

@test "backup_run: refuses to run before setup" {
	mock_restic
	fleet_users() { printf 'alice\n'; }
	user_home() { printf '%s' "$TEST_TMP/home"; }
	mkdir -p "$TEST_TMP/home"
	run backup_run
	[[ $status -ne 0 ]]
	[[ $output == *'no backup repo configured'* ]]
}

@test "backup_run: snapshots homes with excludes, tag, records" {
	mock_restic
	printf 'repo=/backup/cws\n' > "$APPLIANCE_ETC/backup.conf"
	printf 'k\n' > "$APPLIANCE_ETC/backup.key"
	fleet_users() { printf 'alice\n'; }
	user_home() { printf '%s' "$TEST_TMP/home"; }
	mkdir -p "$TEST_TMP/home"
	run backup_run
	[[ $status -eq 0 ]]
	run cat "$TEST_TMP/restic.log"
	[[ $output == *'backup --exclude */.cache'* ]]
	[[ $output == *'--tag coworkstation'* ]]
	[[ $output == *"$TEST_TMP/home"* ]]
	[[ $output == *'repo=/backup/cws'* ]]
	[[ $output == *"keyfile=$APPLIANCE_ETC/backup.key"* ]]
	grep -q $'backup-run\talice' "$APPLIANCE_ETC/audit.log"
}

@test "backup_run: unknown user warns, empty set errors" {
	mock_restic
	printf 'repo=/backup/cws\n' > "$APPLIANCE_ETC/backup.conf"
	user_home() { return 1; }
	run backup_run ghost
	[[ $status -ne 0 ]]
	[[ $output == *'no such user: ghost'* ]]
	[[ $output == *'no home directories'* ]]
}

@test "cws: backup help reachable through the CLI" {
	run "$SCRIPT_DIR/../cws" backup help
	[[ $status -eq 0 ]]
	[[ $output == *'cws backup setup REPO'* ]]
	[[ $output == *'raw restic'* ]]
}
