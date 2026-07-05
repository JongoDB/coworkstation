# shellcheck shell=bash
#===============================================================================
# Client sync — the DEFAULT way files reach the box
#
# Every user gets a Syncthing instance and a ~/ClientSync folder out of
# the box: the folder on their phone/tablet/laptop IS a folder on the
# box, end-to-end encrypted in transit, no cloud intermediary. Cowork
# folder mounts and the Code tab consume it like any other directory.
# Client apps: Syncthing (Android/desktop), Möbius Sync (iOS/iPadOS).
#
# Pairing is explicit both ways (loud consent): the operator runs
# `cws client add-device <THEIR-DEVICE-ID>`, and the device's app must
# accept the box + folder in turn. Nothing syncs until both sides say
# yes, and only the picked folder ever syncs — never whole-disk.
#
# Cloud-drive mounts (storage.sh) remain available as the OPTIONAL,
# user-configured alternative.
#
# Sourced by setup.sh, member.sh, and cws.
#===============================================================================

# Per-user ports keyed off the member display number (display 1 is the
# setup.sh user): GUI/API on loopback, sync listener per instance.
clientsync_gui_port() { printf '%s' $((8383 + ${1:-1})); }
clientsync_sync_port() { printf '%s' $((21999 + ${1:-1})); }

clientsync_install_packages() {
	if command -v syncthing > /dev/null 2>&1; then
		return 0
	fi
	pkg_install syncthing
}

# Pure transform: adapt a freshly generated Syncthing config.xml to our
# layout. stdin -> stdout. Args: home gui_port sync_port
# - default folder moves from ~/Sync to ~/ClientSync (label ClientSync)
# - GUI/API stays loopback, on the per-user port
# - sync listener gets an explicit per-user port so multiple users
#   don't fight over 22000, plus the relay fallback so devices connect
#   even when the box's inbound ports are firewalled (relays carry
#   only E2E-encrypted traffic).
clientsync_config_xml() {
	local home="$1"
	local gui="$2"
	local sync="$3"
	sed \
		-e "s|<address>127.0.0.1:8384</address>|<address>127.0.0.1:$gui</address>|" \
		-e "s|path=\"$home/Sync\"|path=\"$home/ClientSync\"|" \
		-e 's|label="Default Folder"|label="ClientSync"|' \
		-e "s|<listenAddress>default</listenAddress>|<listenAddress>tcp://0.0.0.0:$sync</listenAddress><listenAddress>dynamic+https://relays.syncthing.net/endpoint</listenAddress>|"
}

# Provision client sync for a user. $1 = user, $2 = display number.
# Idempotent: an existing config is kept untouched.
clientsync_setup() {
	local user="$1"
	local display="${2:-1}"
	local gui sync
	gui=$(clientsync_gui_port "$display")
	sync=$(clientsync_sync_port "$display")

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: clientsync for %s (gui %s, sync %s)\n' \
			"$user" "$gui" "$sync"
		return 0
	fi

	clientsync_install_packages || return 1

	local home cfg_dir cfg
	home=$(user_home "$user") || return 1
	cfg_dir="$home/.config/syncthing"
	cfg="$cfg_dir/config.xml"

	if [[ -f $cfg ]]; then
		log_info "client sync already configured for $user"
	else
		run_as_user "$user" syncthing generate --home "$cfg_dir" \
			> /dev/null 2>&1 || {
			log_err "syncthing generate failed for $user"
			return 1
		}
		local updated
		updated=$(clientsync_config_xml "$home" "$gui" "$sync" \
			< "$cfg") || return 1
		printf '%s\n' "$updated" > "$cfg" || return 1
		chown "$user:$user" "$cfg"
	fi

	run_as_user "$user" mkdir -p "$home/ClientSync" || return 1
	run_cmd systemctl enable --now "syncthing@$user" || return 1
	log_info "client sync ready for $user (~/ClientSync);" \
		"pair devices with: sudo cws client add-device <THEIR-ID>"
}

# The box's Syncthing device ID for a user (what the client app adds).
clientsync_device_id() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 1
	local cfg_dir="$home/.config/syncthing"
	runuser -u "$user" -- syncthing --home "$cfg_dir" --device-id \
		2> /dev/null \
		|| runuser -u "$user" -- syncthing device-id \
			--home "$cfg_dir" 2> /dev/null
}

# GUI port + API key for a user's instance. Echoes "port apikey".
clientsync_api() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 1
	local cfg="$home/.config/syncthing/config.xml"
	if [[ ! -r $cfg ]]; then
		log_err "cannot read $cfg (run as root, or set up first)"
		return 1
	fi
	local port key
	port=$(grep -oE '<address>127\.0\.0\.1:[0-9]+</address>' "$cfg" \
		| head -1 | grep -oE '[0-9]+' | tail -1)
	key=$(grep -oE '<apikey>[^<]+</apikey>' "$cfg" | head -1 \
		| sed -e 's|<apikey>||' -e 's|</apikey>||')
	if [[ -z $port || -z $key ]]; then
		log_err 'could not read GUI port/apikey from config.xml'
		return 1
	fi
	printf '%s %s' "$port" "$key"
}

# Pure transform: add a device id to a folder-config JSON's device
# list, deduplicated. stdin folder JSON -> stdout. $1 = device id.
clientsync_folder_devices_json() {
	local device_id="$1"
	jq --arg d "$device_id" \
		'.devices = ((.devices + [{deviceID: $d}])
			| unique_by(.deviceID))'
}

# Pair a client device: register it and share ClientSync with it.
# The DEVICE still has to accept the box + folder in its own app —
# consent is explicit on both ends. Args: user device_id [label]
clientsync_add_device() {
	local user="$1"
	local device_id="$2"
	local label="${3:-client-device}"

	if [[ ! $device_id =~ ^[A-Z0-9-]{50,63}$ ]]; then
		log_err "that does not look like a Syncthing device ID" \
			'(7 groups like ABCDEFG-...)'
		return 1
	fi
	local api port key
	api=$(clientsync_api "$user") || return 1
	port="${api%% *}"
	key="${api#* }"
	local base="http://127.0.0.1:$port/rest"

	curl -fsS -X POST "$base/config/devices" -H "X-API-Key: $key" \
		-H 'Content-Type: application/json' \
		--data "$(jq -n --arg d "$device_id" --arg n "$label" \
			'{deviceID: $d, name: $n, autoAcceptFolders: false}')" \
		> /dev/null || {
		log_err 'device registration failed (is syncthing running?)'
		return 1
	}
	local folder updated
	folder=$(curl -fsS "$base/config/folders/default" \
		-H "X-API-Key: $key") || return 1
	updated=$(clientsync_folder_devices_json "$device_id" \
		<<< "$folder") || return 1
	curl -fsS -X PUT "$base/config/folders/default" \
		-H "X-API-Key: $key" -H 'Content-Type: application/json' \
		--data "$updated" > /dev/null || return 1

	log_info "device paired and offered the ClientSync folder."
	log_info '  Finish on the device: accept the new device/folder'
	log_info '  prompt in Syncthing (Android/desktop) or Möbius (iOS).'
}

# One-line health: service state + connected device count.
clientsync_status() {
	local user="$1"
	local state='unknown' connected='-'
	state=$(systemctl is-active "syncthing@$user" 2> /dev/null)
	local api port key
	if api=$(clientsync_api "$user" 2> /dev/null); then
		port="${api%% *}"
		key="${api#* }"
		connected=$(curl -fsS --max-time 5 \
			"http://127.0.0.1:$port/rest/system/connections" \
			-H "X-API-Key: $key" 2> /dev/null \
			| jq '[.connections[]? | select(.connected)] | length' \
			2> /dev/null)
	fi
	printf 'clientsync %s: service=%s connected_devices=%s\n' \
		"$user" "${state:-unknown}" "${connected:--}"
}
