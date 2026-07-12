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

# =============================================================================
# kasmvnc_codename mapping + deb URL (item-6 fix: new distros must resolve)
# =============================================================================

@test "kasmvnc_codename: shipped codenames pass through" {
	[[ $(kasmvnc_codename noble) == noble ]]
	[[ $(kasmvnc_codename jammy) == jammy ]]
	[[ $(kasmvnc_codename bookworm) == bookworm ]]
}

@test "kasmvnc_codename: newer distros map to a shipped build" {
	# Debian 13 trixie has no kasmVNC deb -> bookworm (the 404 we hit live)
	[[ $(kasmvnc_codename trixie) == bookworm ]]
	[[ $(kasmvnc_codename sid) == bookworm ]]
	# newer Ubuntu -> noble
	[[ $(kasmvnc_codename plucky) == noble ]]
}

@test "kasmvnc_deb_url: trixie host resolves to the bookworm asset" {
	appliance_distro_codename() { printf 'trixie'; }
	appliance_arch() { printf 'amd64'; }
	local url
	url=$(kasmvnc_deb_url)
	[[ $url == *'kasmvncserver_bookworm_1.3.3_amd64.deb'* ]]
	[[ $url != *trixie* ]]
}

@test "install_packages: a 404 download gives an actionable error" {
	appliance_distro_codename() { printf 'noble'; }
	appliance_arch() { printf 'amd64'; }
	command() { return 1; }          # kasmvncserver not present
	dpkg() { return 1; }
	run_cmd() { return 1; }           # simulate the curl download failing
	run profile_kasmvnc_install_packages
	[[ $status -ne 0 ]]
	[[ $output == *'no .deb at'* ]]
	[[ $output == *'--profile xrdp'* ]]
}

# Stub startxfce4 and dbus-run-session on PATH so we can run the
# generated xstartup and observe which launch path it takes.
_xstartup_stub_bin() {
	local dir="$TEST_TMP/bin"
	mkdir -p "$dir"
	printf '%s\n' '#!/bin/sh' 'echo STARTXFCE4' > "$dir/startxfce4"
	printf '%s\n' '#!/bin/sh' 'echo DBUS-RUN-SESSION' \
		'[ "$1" = "--" ] && shift' 'exec "$@"' > "$dir/dbus-run-session"
	chmod +x "$dir/startxfce4" "$dir/dbus-run-session"
	printf '%s' "$dir"
}

@test "kasmvnc_xstartup: primary session launches xfce directly" {
	local bin
	bin=$(_xstartup_stub_bin)
	kasmvnc_xstartup > "$TEST_TMP/xstartup"
	run env PATH="$bin:$PATH" HOME="$TEST_TMP" DISPLAY=:1 \
		sh "$TEST_TMP/xstartup"
	[[ $status -eq 0 ]]
	[[ $output == *STARTXFCE4* ]]
	# the primary owns the shared user bus; no private bus needed
	[[ $output != *DBUS-RUN-SESSION* ]]
}

@test "kasmvnc_xstartup: extra session isolates its own D-Bus bus" {
	local bin
	bin=$(_xstartup_stub_bin)
	kasmvnc_xstartup > "$TEST_TMP/xstartup"
	# A shared bus is present, as inherited from the systemd user
	# manager — the condition that starves the second xfce4-session.
	run env PATH="$bin:$PATH" HOME="$TEST_TMP" DISPLAY=:50 \
		DBUS_SESSION_BUS_ADDRESS="unix:path=$TEST_TMP/shared-bus" \
		sh "$TEST_TMP/xstartup"
	[[ $status -eq 0 ]]
	# xfce must run under a fresh private bus, before startxfce4
	[[ $output == *DBUS-RUN-SESSION*STARTXFCE4* ]]
}

# =============================================================================
# Kiosk mode: Claude-only appliance UI (matchbox WM + supervised Claude)
# =============================================================================

@test "kasmvnc_mode: defaults to desktop, kiosk only when flagged" {
	appliance_kiosk=0
	[[ $(kasmvnc_mode) == desktop ]]
	unset appliance_kiosk
	[[ $(kasmvnc_mode) == desktop ]]
	appliance_kiosk=1
	[[ $(kasmvnc_mode) == kiosk ]]
}

@test "kasmvnc_xstartup: no arg / desktop stays the full XFCE session" {
	[[ $(kasmvnc_xstartup) == *startxfce4* ]]
	[[ $(kasmvnc_xstartup desktop) == *startxfce4* ]]
	# and does NOT drag in the kiosk stack
	[[ $(kasmvnc_xstartup) != *matchbox-window-manager* ]]
}

@test "kasmvnc_xstartup kiosk: WM + supervised launcher, no XFCE" {
	local out
	out=$(kasmvnc_xstartup kiosk)
	[[ $out == *matchbox-window-manager* ]]   # kiosk WM
	[[ $out == *xsetroot* ]]                   # branded backdrop
	[[ $out == *cws-launch* ]]                 # guarded Claude launch
	[[ $out == *'while :'* ]]                  # supervisor loop
	[[ $out != *startxfce4* ]]                 # no desktop
}

# Stub the kiosk runtime deps so we can run the generated xstartup and
# observe the launch path. The supervisor loop is infinite by design, so
# the sleep stub SIGTERMs the loop shell ($PPID) after the first pass —
# the run therefore exits on the signal, and we assert on the captured
# output rather than a zero status.
_kiosk_stub_bin() {
	local dir="$TEST_TMP/kbin"
	mkdir -p "$dir"
	printf '%s\n' '#!/bin/sh' 'echo MATCHBOX' > "$dir/matchbox-window-manager"
	printf '%s\n' '#!/bin/sh' 'echo XSETROOT' > "$dir/xsetroot"
	printf '%s\n' '#!/bin/sh' 'echo CWS-LAUNCH' > "$dir/cws-launch"
	printf '%s\n' '#!/bin/sh' 'kill "$PPID" 2>/dev/null' > "$dir/sleep"
	printf '%s\n' '#!/bin/sh' 'echo DBUS-RUN-SESSION' \
		'[ "$1" = "--" ] && shift' 'exec "$@"' > "$dir/dbus-run-session"
	chmod +x "$dir"/*
	printf '%s' "$dir"
}

@test "kasmvnc_xstartup kiosk: primary supervises Claude on the shared bus" {
	local bin
	bin=$(_kiosk_stub_bin)
	kasmvnc_xstartup kiosk > "$TEST_TMP/xstartup"
	chmod +x "$TEST_TMP/xstartup"
	run env PATH="$bin:$PATH" HOME="$TEST_TMP" DISPLAY=:1 \
		sh "$TEST_TMP/xstartup"
	[[ $output == *CWS-LAUNCH* ]]           # Claude launched via guardian
	[[ $output != *DBUS-RUN-SESSION* ]]     # primary uses the shared bus
	[[ $output != *STARTXFCE4* ]]
}

@test "kasmvnc_xstartup kiosk: extra session re-execs under a private bus" {
	local bin
	bin=$(_kiosk_stub_bin)
	kasmvnc_xstartup kiosk > "$TEST_TMP/xstartup"
	chmod +x "$TEST_TMP/xstartup"
	run env PATH="$bin:$PATH" HOME="$TEST_TMP" DISPLAY=:50 \
		DBUS_SESSION_BUS_ADDRESS="unix:path=$TEST_TMP/shared-bus" \
		sh "$TEST_TMP/xstartup"
	# private bus first, then the supervised Claude launch
	[[ $output == *DBUS-RUN-SESSION*CWS-LAUNCH* ]]
	# extra session redirected its own config home
	[[ -d $TEST_TMP/.config/cws-sessions/50 ]]
}

@test "install_kiosk_deps: installs matchbox, idempotent when present" {
	# not installed -> installs matchbox + xsetroot provider
	command() { return 1; }
	pkg_install() { printf 'PKG %s\n' "$*"; }
	run profile_kasmvnc_install_kiosk_deps
	[[ $status -eq 0 ]]
	[[ $output == *'matchbox-window-manager'* ]]
	[[ $output == *'x11-xserver-utils'* ]]
	# already present -> no install
	command() { return 0; }
	run profile_kasmvnc_install_kiosk_deps
	[[ $status -eq 0 ]]
	[[ $output == *'already installed'* ]]
}
