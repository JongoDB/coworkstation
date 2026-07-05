#!/usr/bin/env bats
#
# clientsync.bats
# Tests for the default device<->box file sync (lib/clientsync.sh).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	# shellcheck source=lib/common.sh
	source "$SCRIPT_DIR/../lib/common.sh"
	# shellcheck source=lib/clientsync.sh
	source "$SCRIPT_DIR/../lib/clientsync.sh"
	appliance_dry_run=0
	appliance_force=0
}

teardown() {
	[[ -n $TEST_TMP && -d $TEST_TMP ]] && rm -rf "$TEST_TMP"
}

_fixture_config() {
	cat << 'XML'
<configuration version="37">
    <folder id="default" label="Default Folder" path="/home/alice/Sync" type="sendreceive">
        <device id="SELF111-AAAAAAA" introducedBy=""></device>
    </folder>
    <gui enabled="true" tls="false">
        <address>127.0.0.1:8384</address>
        <apikey>testkey123</apikey>
    </gui>
    <options>
        <listenAddress>default</listenAddress>
    </options>
</configuration>
XML
}

@test "ports: derived from the member display number" {
	[[ $(clientsync_gui_port 1) == 8384 ]]
	[[ $(clientsync_gui_port 3) == 8386 ]]
	[[ $(clientsync_sync_port 1) == 22000 ]]
	[[ $(clientsync_sync_port 3) == 22002 ]]
}

@test "config transform: folder, gui port, explicit listeners" {
	local out
	out=$(_fixture_config | clientsync_config_xml /home/alice 8386 22002)
	[[ $out == *'path="/home/alice/ClientSync"'* ]]
	[[ $out == *'label="ClientSync"'* ]]
	[[ $out == *'<address>127.0.0.1:8386</address>'* ]]
	[[ $out == *'tcp://0.0.0.0:22002'* ]]
	[[ $out == *'relays.syncthing.net'* ]]
	[[ $out != *'<listenAddress>default</listenAddress>'* ]]
}

@test "folder devices transform: adds and deduplicates" {
	local folder='{"id":"default","devices":[{"deviceID":"SELF"}]}'
	local out
	out=$(clientsync_folder_devices_json 'NEWDEV' <<< "$folder")
	[[ $(jq '.devices | length' <<< "$out") == 2 ]]
	out=$(clientsync_folder_devices_json 'NEWDEV' <<< "$out")
	[[ $(jq '.devices | length' <<< "$out") == 2 ]]
}

@test "setup: dry-run plans without touching anything" {
	appliance_dry_run=1
	run clientsync_setup alice 2
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: clientsync for alice (gui 8385, sync 22001)'* ]]
}

@test "setup: generates, transforms, enables the per-user service" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	mkdir -p "$TEST_TMP/home"
	pkg_install() { return 0; }
	command() {
		if [[ $1 == '-v' && $2 == 'syncthing' ]]; then return 0; fi
		builtin command "$@"
	}
	# `syncthing generate` writes the fixture config
	run_as_user() {
		shift
		if [[ $1 == 'syncthing' ]]; then
			mkdir -p "$TEST_TMP/home/.config/syncthing"
			_fixture_config \
				> "$TEST_TMP/home/.config/syncthing/config.xml"
			return 0
		fi
		"$@"
	}
	chown() { return 0; }
	run_cmd() { printf 'RUN: %s\n' "$*" >> "$TEST_TMP/calls"; }
	clientsync_setup alice 1
	local cfg="$TEST_TMP/home/.config/syncthing/config.xml"
	grep -q 'ClientSync' "$cfg"
	grep -q '127.0.0.1:8384' "$cfg"
	grep -q 'RUN: systemctl enable --now syncthing@alice' \
		"$TEST_TMP/calls"
}

@test "setup: existing config is kept (idempotent)" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	mkdir -p "$TEST_TMP/home/.config/syncthing"
	printf 'SENTINEL' > "$TEST_TMP/home/.config/syncthing/config.xml"
	pkg_install() { return 0; }
	command() {
		if [[ $1 == '-v' && $2 == 'syncthing' ]]; then return 0; fi
		builtin command "$@"
	}
	run_as_user() { shift; "$@"; }
	run_cmd() { :; }
	run clientsync_setup alice 1
	[[ $status -eq 0 ]]
	[[ $output == *'already configured'* ]]
	grep -q 'SENTINEL' "$TEST_TMP/home/.config/syncthing/config.xml"
}

@test "add-device: rejects a malformed device id before any API call" {
	run clientsync_add_device alice 'not-a-device-id'
	[[ $status -ne 0 ]]
	[[ $output == *'does not look like a Syncthing device ID'* ]]
}

@test "api: reads port and key from config.xml" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	mkdir -p "$TEST_TMP/home/.config/syncthing"
	_fixture_config > "$TEST_TMP/home/.config/syncthing/config.xml"
	local out
	out=$(clientsync_api alice)
	[[ $out == '8384 testkey123' ]]
}
