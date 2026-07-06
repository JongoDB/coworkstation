#!/usr/bin/env bats
#
# launch.bats
# Tests for the cws-launch guardian (config-backup rotation + exec).
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export CWS_BACKUP_ROOT="$TEST_TMP/backups"
	export CWS_CLAUDE_CONFIG="$TEST_TMP/Claude"
	mkdir -p "$CWS_CLAUDE_CONFIG"
	# shellcheck source=libexec/cws-launch
	source "$SCRIPT_DIR/../libexec/cws-launch"
}

teardown() {
	[[ -n $TEST_TMP && -d $TEST_TMP ]] && rm -rf "$TEST_TMP"
}

@test "rotate_backup: first copy, then copy-if-changed only" {
	printf 'v1' > "$CWS_CLAUDE_CONFIG/claude_desktop_config.json"
	rotate_backup "$CWS_CLAUDE_CONFIG/claude_desktop_config.json"
	local dir="$CWS_BACKUP_ROOT/claude_desktop_config.json"
	[[ $(ls -1 "$dir" | wc -l) -eq 1 ]]
	# unchanged -> no new copy
	rotate_backup "$CWS_CLAUDE_CONFIG/claude_desktop_config.json"
	[[ $(ls -1 "$dir" | wc -l) -eq 1 ]]
	# changed -> second copy
	printf 'v2' > "$CWS_CLAUDE_CONFIG/claude_desktop_config.json"
	rotate_backup "$CWS_CLAUDE_CONFIG/claude_desktop_config.json"
	[[ $(ls -1 "$dir" | wc -l) -eq 2 ]]
}

@test "rotate_backup: keeps only the newest 5 changed copies" {
	local f="$CWS_CLAUDE_CONFIG/claude_desktop_config.json"
	local dir="$CWS_BACKUP_ROOT/claude_desktop_config.json"
	local i
	for i in 1 2 3 4 5 6 7; do
		printf 'v%s' "$i" > "$f"
		# distinct timestamps for the rotation ordering
		date() { printf '2026%02dT000000' "$i"; }
		rotate_backup "$f"
		unset -f date
	done
	[[ $(ls -1 "$dir" | wc -l) -eq 5 ]]
	# the wiped-state recovery scenario: newest backup has v7
	grep -q 'v7' "$dir/$(ls -1t "$dir" | head -1)"
}

@test "guard_configs: catches per-account cowork stores by glob" {
	mkdir -p "$CWS_CLAUDE_CONFIG/accounts/abc123"
	printf '{}' > "$CWS_CLAUDE_CONFIG/accounts/abc123/spaces.json"
	printf '{}' > "$CWS_CLAUDE_CONFIG/claude_desktop_config.json"
	guard_configs
	[[ -d $CWS_BACKUP_ROOT/accounts_abc123_spaces.json ]]
	[[ -d $CWS_BACKUP_ROOT/claude_desktop_config.json ]]
}

@test "find_launcher: official first, community fallback, clean error" {
	command() {
		if [[ $1 == '-v' && $2 == 'claude-desktop' ]]; then return 1; fi
		if [[ $1 == '-v' && $2 == 'claude-desktop-unofficial' ]]; then
			return 0
		fi
		builtin command "$@"
	}
	[[ $(find_launcher) == 'claude-desktop-unofficial' ]]
	command() { return 1; }
	run find_launcher
	[[ $status -ne 0 ]]
}

@test "main: guards then execs the launcher with args passed through" {
	printf '{}' > "$CWS_CLAUDE_CONFIG/claude_desktop_config.json"
	find_launcher() { printf '%s' "$TEST_TMP/fake-launcher"; }
	printf '#!/bin/bash\necho "LAUNCHED $*"\n' > "$TEST_TMP/fake-launcher"
	chmod +x "$TEST_TMP/fake-launcher"
	run main --some-flag
	[[ $status -eq 0 ]]
	[[ $output == *'LAUNCHED --some-flag'* ]]
	[[ -d $CWS_BACKUP_ROOT/claude_desktop_config.json ]]
}

@test "claude_config: honors XDG_CONFIG_HOME when CWS_CLAUDE_CONFIG unset" {
	# Extra sessions redirect XDG_CONFIG_HOME; the guardian must guard and
	# heal that config home, not the primary's ~/.config/Claude.
	run env -u CWS_CLAUDE_CONFIG XDG_CONFIG_HOME=/xdg bash -c \
		"source '$SCRIPT_DIR/../libexec/cws-launch'; printf %s \"\$claude_config\""
	[[ $output == '/xdg/Claude' ]]
}

@test "clear_stale_singleton: clears the trio when the socket is dangling" {
	# Post-reboot: /tmp is wiped so the socket target is gone, and the
	# recorded pid may be reused — the reboot-crash blank-window case.
	ln -s "$TEST_TMP/gone/SingletonSocket" "$CWS_CLAUDE_CONFIG/SingletonSocket"
	ln -s 'cws-1774' "$CWS_CLAUDE_CONFIG/SingletonLock"
	ln -s '5740472022340416155' "$CWS_CLAUDE_CONFIG/SingletonCookie"
	clear_stale_singleton
	[[ ! -L $CWS_CLAUDE_CONFIG/SingletonSocket ]]
	[[ ! -L $CWS_CLAUDE_CONFIG/SingletonLock ]]
	[[ ! -L $CWS_CLAUDE_CONFIG/SingletonCookie ]]
}

@test "clear_stale_singleton: leaves a live singleton (socket target exists)" {
	mkdir -p "$TEST_TMP/live"
	: > "$TEST_TMP/live/SingletonSocket"        # target present = live owner
	ln -s "$TEST_TMP/live/SingletonSocket" "$CWS_CLAUDE_CONFIG/SingletonSocket"
	ln -s 'cws-1' "$CWS_CLAUDE_CONFIG/SingletonLock"
	clear_stale_singleton
	[[ -L $CWS_CLAUDE_CONFIG/SingletonSocket ]]
	[[ -L $CWS_CLAUDE_CONFIG/SingletonLock ]]
}

@test "clear_stale_singleton: no-op when no singleton files exist" {
	run clear_stale_singleton
	[[ $status -eq 0 ]]
}
