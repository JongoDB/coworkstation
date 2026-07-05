#!/usr/bin/env bats
#
# install.bats
# Guard-rail tests for the network installer (non-root-testable paths).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

@test "install: refuses dangerous COWORKSTATION_DIR before anything else" {
	for bad in / /etc /usr /home /var; do
		run env COWORKSTATION_DIR="$bad" \
			bash "$SCRIPT_DIR/../install.sh"
		[[ $status -ne 0 ]]
		[[ $output == *'refusing to install'* ]]
		[[ $output != *'run as root'* ]]
	done
}

@test "install: refuses a relative COWORKSTATION_DIR" {
	run env COWORKSTATION_DIR='relative/path' \
		bash "$SCRIPT_DIR/../install.sh"
	[[ $status -ne 0 ]]
	[[ $output == *'absolute path'* ]]
}

@test "install: requires root once the target dir is sane" {
	if [[ $EUID -eq 0 ]]; then
		skip 'running as root'
	fi
	run env COWORKSTATION_DIR=/opt/cws-test \
		bash "$SCRIPT_DIR/../install.sh"
	[[ $status -ne 0 ]]
	[[ $output == *'run as root'* ]]
}
