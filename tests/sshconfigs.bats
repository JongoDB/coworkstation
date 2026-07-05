#!/usr/bin/env bats
#
# appliance-sshconfigs.bats
# Tests for the managed-settings generator (appliance/gen-sshconfigs.sh)
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
GEN="$SCRIPT_DIR/../gen-sshconfigs.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export APPLIANCE_ETC="$TEST_TMP/etc"
	mkdir -p "$APPLIANCE_ETC"
}

teardown() {
	if [[ -n $TEST_TMP && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "single shared entry has the required schema fields" {
	run bash "$GEN" --host claude.example.com --ssh-user cowork
	[[ $status -eq 0 ]]
	local id host name
	id=$(jq -r '.sshConfigs[0].id' <<< "$output")
	name=$(jq -r '.sshConfigs[0].name' <<< "$output")
	host=$(jq -r '.sshConfigs[0].sshHost' <<< "$output")
	[[ $id == 'coworkstation' ]]
	[[ -n $name ]]
	[[ $host == 'cowork@claude.example.com' ]]
}

@test "per-member mode emits one entry per registry row" {
	printf 'alice\t2\t8444\t6G\t200%%\nbob\t3\t8445\t6G\t200%%\n' \
		> "$APPLIANCE_ETC/members.tsv"
	run bash "$GEN" --host claude.example.com --per-member
	[[ $status -eq 0 ]]
	local count hosts
	count=$(jq '.sshConfigs | length' <<< "$output")
	hosts=$(jq -r '.sshConfigs[].sshHost' <<< "$output" | tr '\n' ' ')
	[[ $count == '2' ]]
	[[ $hosts == 'alice@claude.example.com bob@claude.example.com ' ]]
}

@test "per-member mode fails without a registry" {
	run bash "$GEN" --host claude.example.com --per-member
	[[ $status -ne 0 ]]
	[[ $output == *'no member registry'* ]]
}

@test "start-dir is included only when set" {
	run bash "$GEN" --host h.example.com --ssh-user u \
		--start-dir '~/projects'
	local dir
	dir=$(jq -r '.sshConfigs[0].startDirectory' <<< "$output")
	[[ $dir == '~/projects' ]]

	run bash "$GEN" --host h.example.com --ssh-user u
	dir=$(jq -r '.sshConfigs[0] | has("startDirectory")' <<< "$output")
	[[ $dir == 'false' ]]
}

@test "allowlist flag adds sshHostAllowlist" {
	run bash "$GEN" --host h.example.com --ssh-user u --allowlist
	local allow
	allow=$(jq -r '.sshHostAllowlist[0]' <<< "$output")
	[[ $allow == 'h.example.com' ]]
}

@test "merge preserves unrelated managed-settings keys" {
	printf '{"permissions":{"deny":["WebFetch"]},"theme":"dark"}\n' \
		> "$TEST_TMP/managed.json"
	run bash "$GEN" --host h.example.com --ssh-user u \
		--merge "$TEST_TMP/managed.json"
	[[ $status -eq 0 ]]
	[[ $(jq -r '.theme' <<< "$output") == 'dark' ]]
	[[ $(jq -r '.permissions.deny[0]' <<< "$output") == 'WebFetch' ]]
	[[ $(jq '.sshConfigs | length' <<< "$output") == '1' ]]
}

@test "output is deterministic across runs" {
	printf 'alice\t2\t8444\t6G\t200%%\n' > "$APPLIANCE_ETC/members.tsv"
	local a b
	a=$(bash "$GEN" --host h.example.com --per-member)
	b=$(bash "$GEN" --host h.example.com --per-member)
	[[ $a == "$b" ]]
}

@test "usage errors are actionable" {
	run bash "$GEN" --ssh-user u
	[[ $status -ne 0 ]]
	[[ $output == *'--host is required'* ]]

	run bash "$GEN" --host h.example.com
	[[ $status -ne 0 ]]
	[[ $output == *'--ssh-user'* ]]
}
