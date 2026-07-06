#!/usr/bin/env bats
#
# setup.bats
# Unit tests for setup.sh helpers whose stdout is a captured return value.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export APPLIANCE_ETC="$TEST_TMP/etc"
	# Sourcing setup.sh defines its functions without running main()
	# (main is guarded by BASH_SOURCE == $0).
	# shellcheck source=setup.sh
	source "$SCRIPT_DIR/../setup.sh"
	appliance_dry_run=0
	appliance_force=0
}

teardown() {
	[[ -n $TEST_TMP && -d $TEST_TMP ]] && rm -rf "$TEST_TMP"
}

# Regression: ensure_target_user's stdout IS its return value, so any
# progress logging must go to stderr. A log line leaking into stdout
# pollutes $user and breaks every downstream user_home lookup (the
# from-zero live install failed with exactly "no home directory for
# '[appliance] no --user given...cowork'").
@test "ensure_target_user: returns a CLEAN username, no log leakage" {
	id() { return 1; }         # default account does not exist yet
	useradd() { return 0; }    # pretend creation succeeds
	local u
	u=$(APPLIANCE_DEFAULT_USER=cowork ensure_target_user '')
	[[ $u == 'cowork' ]]
	# belt and suspenders: no stray whitespace/newline/log text
	[[ $u != *'appliance'* ]]
	[[ $(printf '%s' "$u" | wc -l) -eq 0 ]]
}

@test "ensure_target_user: passes an existing explicit user through" {
	id() { [[ $1 == 'alice' ]] && return 0; return 1; }
	local u
	u=$(ensure_target_user alice)
	[[ $u == 'alice' ]]
}

@test "ensure_target_user: ignores root as a candidate, mints default" {
	id() { return 1; }
	useradd() { return 0; }
	local u
	u=$(SUDO_USER=root APPLIANCE_DEFAULT_USER=cowork ensure_target_user '')
	[[ $u == 'cowork' ]]
}

@test "colord_polkit_rule: grants the color-manager action group" {
	local rule
	rule=$(colord_polkit_rule)
	[[ $rule == *'org.freedesktop.color-manager.'* ]]
	[[ $rule == *'polkit.Result.YES'* ]]
	[[ $rule == *'polkit.addRule'* ]]
}

@test "install_polkit_rules: writes the rule to polkit's rules.d" {
	# write_file runs in a pipeline subshell, so record via a file.
	write_file() { printf '%s' "$1" > "$TEST_TMP/target"; cat > /dev/null; }
	install_polkit_rules
	[[ "$(cat "$TEST_TMP/target")" == '/etc/polkit-1/rules.d/40-cws-colord.rules' ]]
}

@test "reconfigure_user: regenerates the session config and autostart" {
	profile_kasmvnc_write_config() { echo "wc $1 $2" >> "$TEST_TMP/calls"; }
	install_autostart() { echo "as $1" >> "$TEST_TMP/calls"; }
	reconfigure_user alice 8443 kasmvnc
	grep -qx 'wc alice 8443' "$TEST_TMP/calls"
	grep -qx 'as alice' "$TEST_TMP/calls"
}

@test "run_reconfigure: applies polkit + primary + every member" {
	mkdir -p "$APPLIANCE_ETC"
	printf 'profile=kasmvnc\n' > "$APPLIANCE_ETC/appliance.conf"
	printf 'bob\t2\t8444\t2G\t150\n' > "$APPLIANCE_ETC/members.tsv"
	require_root() { return 0; }
	install_polkit_rules() { echo polkit >> "$TEST_TMP/calls"; }
	reconfigure_user() { echo "ru $1 $2 $3" >> "$TEST_TMP/calls"; }
	run_reconfigure cws
	grep -qx 'polkit' "$TEST_TMP/calls"
	grep -qx 'ru cws 8443 kasmvnc' "$TEST_TMP/calls"
	grep -qx 'ru bob 8444 kasmvnc' "$TEST_TMP/calls"
}

@test "run_reconfigure: forces overwrite so stale config is replaced" {
	mkdir -p "$APPLIANCE_ETC"
	printf 'profile=kasmvnc\n' > "$APPLIANCE_ETC/appliance.conf"
	require_root() { return 0; }
	# write_file keeps existing files unless appliance_force=1; capture it.
	install_polkit_rules() { echo "force=${appliance_force:-0}" >> "$TEST_TMP/calls"; }
	reconfigure_user() { :; }
	run_reconfigure cws
	grep -qx 'force=1' "$TEST_TMP/calls"
}
