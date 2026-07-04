#!/usr/bin/env bash
#===============================================================================
# Coworkstation network installer
#
# Downloads Coworkstation to /opt/coworkstation and runs setup.sh. This is
# the prod entry point — the equivalent of a "download and run" for a
# script-based orchestrator (Coworkstation installs the Claude Desktop
# engine; it is not itself a binary app).
#
# Usage (defaults to the latest release, falls back to main):
#   curl -fsSL https://raw.githubusercontent.com/JongoDB/coworkstation/main/install.sh | sudo bash
#
# Pass setup.sh flags through after `-s --`:
#   curl -fsSL .../install.sh | sudo bash -s -- \
#       --hostname cws.example.com --cf-api-token-file /root/cf-token \
#       --access-allow you@example.com
#
# Override the source ref/dir with env vars:
#   COWORKSTATION_REF=v0.1.0  COWORKSTATION_DIR=/opt/coworkstation
#===============================================================================

set -u

repo='JongoDB/coworkstation'
ref="${COWORKSTATION_REF:-main}"
dir="${COWORKSTATION_DIR:-/opt/coworkstation}"

log() { printf '[coworkstation-install] %s\n' "$*"; }
die() { printf '[coworkstation-install] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	die 'run as root (pipe into: sudo bash)'
fi

for tool in curl tar; do
	command -v "$tool" > /dev/null 2>&1 || die "missing dependency: $tool"
done

# Prefer git when available (keeps the tree updatable); else tarball.
if command -v git > /dev/null 2>&1; then
	if [[ -d $dir/.git ]]; then
		log "updating existing checkout in $dir"
		git -C "$dir" fetch --depth 1 origin "$ref" \
			|| die 'git fetch failed'
		git -C "$dir" checkout -q FETCH_HEAD || die 'git checkout failed'
	else
		log "cloning $repo@$ref into $dir"
		rm -rf "$dir"
		git clone --depth 1 --branch "$ref" \
			"https://github.com/$repo" "$dir" 2> /dev/null \
			|| git clone --depth 1 \
				"https://github.com/$repo" "$dir" \
			|| die 'git clone failed'
	fi
else
	log "downloading $repo@$ref tarball into $dir (git not found)"
	rm -rf "$dir"; mkdir -p "$dir"
	curl -fsSL "https://github.com/$repo/archive/$ref.tar.gz" \
		| tar xz -C "$dir" --strip-components=1 \
		|| die 'tarball download/extract failed'
fi

chmod +x "$dir"/*.sh "$dir"/testbench/*.sh 2> /dev/null || true

log "running setup.sh"
exec "$dir/setup.sh" "$@"
