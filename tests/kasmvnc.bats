#!/usr/bin/env bats
#
# appliance-kasmvnc.bats
# Tests for the kasmVNC profile (appliance/lib/profiles/kasmvnc.sh)
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	# shellcheck source=lib/common.sh
	source "$SCRIPT_DIR/../lib/common.sh"
	# shellcheck source=lib/profiles/kasmvnc.sh
	source "$SCRIPT_DIR/../lib/profiles/kasmvnc.sh"
	appliance_dry_run=0
	appliance_force=0
}

teardown() {
	[[ -n $TEST_TMP && -d $TEST_TMP ]] && rm -rf "$TEST_TMP"
}

@test "kasmvnc_gen_password: 16 alphanumeric chars" {
	local pw
	pw=$(kasmvnc_gen_password)
	[[ ${#pw} -eq 16 ]]
	[[ $pw =~ ^[A-Za-z0-9]+$ ]]
}

@test "setup_auth: dry-run creates nothing" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	appliance_dry_run=1
	run profile_kasmvnc_setup_auth alice
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: create kasmvnc control user for alice'* ]]
	[[ ! -e $TEST_TMP/home/.kasmpasswd ]]
}

@test "setup_auth: creates control user non-interactively and stores creds" {
	mkdir -p "$TEST_TMP/home/.vnc"
	user_home() { printf '%s' "$TEST_TMP/home"; }
	chown() { return 0; }
	# capture that kasmvncpasswd is fed the password twice on stdin
	runuser() {
		shift 3  # -u alice --
		if [[ $1 == kasmvncpasswd ]]; then
			local in; in=$(cat)
			printf '%s' "$in" > "$TEST_TMP/pw-stdin"
			printf '%s\n' "$*" > "$TEST_TMP/pw-argv"
			return 0
		fi
		"$@"
	}
	run profile_kasmvnc_setup_auth alice
	[[ $status -eq 0 ]]
	# argv: kasmvncpasswd -u alice -w
	grep -q -- '-u alice -w' "$TEST_TMP/pw-argv"
	# stdin had the password twice (two identical non-empty lines)
	local l1 l2
	l1=$(sed -n 1p "$TEST_TMP/pw-stdin"); l2=$(sed -n 2p "$TEST_TMP/pw-stdin")
	[[ -n $l1 && $l1 == "$l2" ]]
	# credentials persisted, mode 600
	[[ -f $TEST_TMP/home/.vnc/kasm-credentials ]]
	grep -q '^username=alice$' "$TEST_TMP/home/.vnc/kasm-credentials"
	grep -q '^password=' "$TEST_TMP/home/.vnc/kasm-credentials"
	[[ $(stat -c '%a' "$TEST_TMP/home/.vnc/kasm-credentials") == 600 ]]
}

@test "setup_auth: idempotent when kasmpasswd already exists" {
	mkdir -p "$TEST_TMP/home"
	printf 'existing' > "$TEST_TMP/home/.kasmpasswd"
	user_home() { printf '%s' "$TEST_TMP/home"; }
	run profile_kasmvnc_setup_auth alice
	[[ $status -eq 0 ]]
	[[ $output == *'already configured'* ]]
}

@test "setup_auth: fails loudly when kasmvncpasswd errors" {
	mkdir -p "$TEST_TMP/home/.vnc"
	user_home() { printf '%s' "$TEST_TMP/home"; }
	runuser() { shift 3; [[ $1 == kasmvncpasswd ]] && { cat >/dev/null; return 1; }; "$@"; }
	run profile_kasmvnc_setup_auth alice
	[[ $status -ne 0 ]]
	[[ $output == *'kasmvncpasswd failed'* ]]
}


@test "kasmvnc_yaml: references the per-user cert paths" {
	local y
	y=$(kasmvnc_yaml 8443 /home/alice)
	[[ $y == *'websocket_port: 8443'* ]]
	[[ $y == *'pem_certificate: /home/alice/.vnc/self.pem'* ]]
	[[ $y == *'pem_key: /home/alice/.vnc/self.key'* ]]
}

@test "setup_cert: dry-run generates nothing" {
	user_home() { printf '%s' "$TEST_TMP/home"; }
	appliance_dry_run=1
	run profile_kasmvnc_setup_cert alice
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: generate kasmvnc self-signed cert'* ]]
	[[ ! -e $TEST_TMP/home/.vnc/self.key ]]
}

@test "setup_cert: generates a user-owned self-signed cert" {
	mkdir -p "$TEST_TMP/home"
	user_home() { printf '%s' "$TEST_TMP/home"; }
	run_as_user() { shift; "$@"; }        # run directly as test user
	runuser() { shift 3; "$@"; }          # drop `-u alice --`, run direct
	run profile_kasmvnc_setup_cert alice
	[[ $status -eq 0 ]]
	[[ -f $TEST_TMP/home/.vnc/self.key ]]
	[[ -f $TEST_TMP/home/.vnc/self.pem ]]
	# valid PEM cert + key
	grep -q 'BEGIN CERTIFICATE' "$TEST_TMP/home/.vnc/self.pem"
	grep -qE 'BEGIN (PRIVATE|RSA PRIVATE) KEY' "$TEST_TMP/home/.vnc/self.key"
	[[ $(stat -c '%a' "$TEST_TMP/home/.vnc/self.key") == 600 ]]
}

@test "setup_cert: idempotent when cert exists" {
	mkdir -p "$TEST_TMP/home/.vnc"
	printf 'x' > "$TEST_TMP/home/.vnc/self.key"
	printf 'x' > "$TEST_TMP/home/.vnc/self.pem"
	user_home() { printf '%s' "$TEST_TMP/home"; }
	run profile_kasmvnc_setup_cert alice
	[[ $status -eq 0 ]]
	[[ $output == *'cert already present'* ]]
}
