#!/usr/bin/env bats
#
# appliance-member.bats
# Tests for member lifecycle in appliance/member.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export APPLIANCE_ETC="$TEST_TMP/etc"
	export APPLIANCE_CLOUDFLARED_CONF="$TEST_TMP/config.yml"
	export APPLIANCE_SLICE_DIR="$TEST_TMP/systemd"
	mkdir -p "$APPLIANCE_ETC"

	# shellcheck source=member.sh
	source "$SCRIPT_DIR/../member.sh"

	appliance_dry_run=0
	appliance_force=0

	base_config() {
		cat << 'EOF'
tunnel: 0000-1111
credentials-file: /root/.cloudflared/0000-1111.json
ingress:
  - hostname: claude.example.com
    service: http://127.0.0.1:8443
  - service: http_status:404
EOF
	}
}

teardown() {
	if [[ -n $TEST_TMP && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# registry helpers
# =============================================================================

@test "registry_next_display: empty registry starts at 2" {
	local result
	result=$(registry_next_display < /dev/null)
	[[ $result == '2' ]]
}

@test "registry_next_display: skips used displays" {
	local result
	result=$(printf 'a\t2\t8444\t6G\t200%%\nb\t3\t8445\t6G\t200%%\n' \
		| registry_next_display)
	[[ $result == '4' ]]
}

@test "registry_next_display: reuses gaps after removal" {
	local result
	result=$(printf 'a\t2\t8444\t6G\t200%%\nc\t4\t8446\t6G\t200%%\n' \
		| registry_next_display)
	[[ $result == '3' ]]
}

@test "registry_drop: removes only the named row" {
	local out
	out=$(printf 'a\t2\t8444\t6G\t200%%\nb\t3\t8445\t6G\t200%%\n' \
		| registry_drop a)
	[[ $out == "$(printf 'b\t3\t8445\t6G\t200%%')" ]]
}

@test "registry_get: finds a row and fails on absence" {
	printf 'a\t2\t8444\t6G\t200%%\n' > "$TEST_TMP/members.tsv"
	run registry_get a "$TEST_TMP/members.tsv"
	[[ $status -eq 0 ]]
	[[ $output == *'8444'* ]]
	run registry_get ghost "$TEST_TMP/members.tsv"
	[[ $status -ne 0 ]]
}

# =============================================================================
# ingress transforms
# =============================================================================

@test "ingress_add: inserts before the 404 catch-all" {
	local out
	out=$(base_config | ingress_add alice.claude.example.com 8444)
	local expected
	expected=$(cat << 'EOF'
tunnel: 0000-1111
credentials-file: /root/.cloudflared/0000-1111.json
ingress:
  - hostname: claude.example.com
    service: http://127.0.0.1:8443
  - hostname: alice.claude.example.com
    service: http://127.0.0.1:8444
  - service: http_status:404
EOF
	)
	[[ $out == "$expected" ]]
}

@test "ingress_add: is idempotent for an existing hostname" {
	local once twice
	once=$(base_config | ingress_add alice.claude.example.com 8444)
	twice=$(printf '%s\n' "$once" \
		| ingress_add alice.claude.example.com 8444)
	[[ $once == "$twice" ]]
}

@test "ingress_remove: drops exactly the member's two lines" {
	local with without
	with=$(base_config | ingress_add alice.claude.example.com 8444)
	without=$(printf '%s\n' "$with" \
		| ingress_remove alice.claude.example.com)
	[[ $without == "$(base_config)" ]]
}

@test "ingress_remove: leaves other members untouched" {
	local conf out
	conf=$(base_config | ingress_add alice.claude.example.com 8444 \
		| ingress_add bob.claude.example.com 8445)
	out=$(printf '%s\n' "$conf" \
		| ingress_remove alice.claude.example.com)
	[[ $out == *'bob.claude.example.com'* ]]
	[[ $out != *'alice.claude.example.com'* ]]
}

# =============================================================================
# slice quota
# =============================================================================

@test "install_slice_quota: writes override under the user uid" {
	id() { printf '1042'; }
	run_cmd() { :; }
	install_slice_quota alice 4G 150%
	local conf="$APPLIANCE_SLICE_DIR/user-1042.slice.d"
	conf+='/50-claude-appliance.conf'
	[[ -f $conf ]]
	grep -q 'MemoryMax=4G' "$conf"
	grep -q 'CPUQuota=150%' "$conf"
}

# =============================================================================
# cmd_add / cmd_remove (dry-run, stubbed accounts)
# =============================================================================

_stub_account_world() {
	id() {
		if [[ $1 == '-u' ]]; then
			printf '1042'
		fi
		return 0
	}
	getent() {
		printf 'x:x:1042:1042::%s/home:/bin/bash\n' "$TEST_TMP"
	}
	mkdir -p "$TEST_TMP/home"
	chown() { return 0; }
}

@test "cmd_add: dry-run plans account, quota, session, ingress, row" {
	printf 'profile=kasmvnc\nhostname=claude.example.com\n' \
		> "$APPLIANCE_ETC/appliance.conf"
	base_config > "$APPLIANCE_CLOUDFLARED_CONF"
	_stub_account_world
	id() {
		if [[ $1 == '-u' ]]; then printf '1042'; return 0; fi
		return 1  # account does not exist yet
	}
	appliance_dry_run=1
	run cmd_add alice 6G 200%
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: useradd -m -s /bin/bash alice'* ]]
	# The cert + control user are mandatory: without them a member's
	# kasmVNC session never binds (regression guard for the DOA member).
	[[ $output == *'kasmvnc self-signed cert for alice'* ]]
	[[ $output == *'kasmvnc control user for alice'* ]]
	[[ $output == *'alice.claude.example.com'* ]]
	[[ $output == *'http://127.0.0.1:8444'* ]]
	[[ $output == *'DRY-RUN: append alice'* ]]
	[[ ! -f $APPLIANCE_ETC/members.tsv ]]
}

@test "cmd_add: rejects a duplicate member" {
	printf 'alice\t2\t8444\t6G\t200%%\n' > "$APPLIANCE_ETC/members.tsv"
	run cmd_add alice 6G 200%
	[[ $status -ne 0 ]]
	[[ $output == *'already registered'* ]]
}

@test "cmd_remove: dry-run never touches the registry" {
	printf 'alice\t2\t8444\t6G\t200%%\n' > "$APPLIANCE_ETC/members.tsv"
	printf 'profile=kasmvnc\nhostname=claude.example.com\n' \
		> "$APPLIANCE_ETC/appliance.conf"
	base_config | ingress_add alice.claude.example.com 8444 \
		> "$APPLIANCE_CLOUDFLARED_CONF"
	_stub_account_world
	appliance_dry_run=1
	run cmd_remove alice 1
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: userdel alice'* ]]
	[[ $output == *'DRY-RUN: drop alice'* ]]
	grep -q '^alice' "$APPLIANCE_ETC/members.tsv"
	grep -q 'alice.claude.example.com' "$APPLIANCE_CLOUDFLARED_CONF"
}

@test "cmd_remove: refuses a member not in the registry" {
	run cmd_remove ghost 0
	[[ $status -ne 0 ]]
	[[ $output == *'not in the registry'* ]]
}

@test "cmd_remove: --keep-home uses userdel without -r" {
	printf 'alice\t2\t8444\t6G\t200%%\n' > "$APPLIANCE_ETC/members.tsv"
	_stub_account_world
	appliance_dry_run=1
	run cmd_remove alice 1
	[[ $output == *'DRY-RUN: userdel alice'* ]]
	[[ $output != *'userdel -r'* ]]
}

@test "cmd_remove: default removes the home directory" {
	printf 'alice\t2\t8444\t6G\t200%%\n' > "$APPLIANCE_ETC/members.tsv"
	_stub_account_world
	appliance_dry_run=1
	run cmd_remove alice 0
	[[ $output == *'DRY-RUN: userdel -r alice'* ]]
}

# =============================================================================
# CLI validation
# =============================================================================

@test "cli: rejects invalid member names" {
	run bash "$SCRIPT_DIR/../member.sh" add 'Bad Name' \
		--dry-run
	[[ $status -ne 0 ]]
	[[ $output == *'invalid member name'* ]]
}

@test "cli: rejects path-traversal names" {
	run bash "$SCRIPT_DIR/../member.sh" add '../evil' \
		--dry-run
	[[ $status -ne 0 ]]
}

@test "cli: add without a name errors with usage" {
	run bash "$SCRIPT_DIR/../member.sh" add --dry-run
	[[ $status -ne 0 ]]
	[[ $output == *'usage'* ]]
}

@test "cli: list with no registry reports no members" {
	run bash -c 'APPLIANCE_ETC="'"$APPLIANCE_ETC"'" \
		bash "'"$SCRIPT_DIR"'/../member.sh" list'
	[[ $status -eq 0 ]]
	[[ $output == *'no members registered'* ]]
}

@test "cli: list renders registry rows with account state" {
	printf 'alice\t2\t8444\t6G\t200%%\n' > "$APPLIANCE_ETC/members.tsv"
	run bash -c 'APPLIANCE_ETC="'"$APPLIANCE_ETC"'" \
		bash "'"$SCRIPT_DIR"'/../member.sh" list'
	[[ $status -eq 0 ]]
	[[ $output == *'alice'* ]]
	[[ $output == *'MISSING'* ]]
}
