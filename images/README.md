# Coworkstation images

Flash-and-go bootstrap paths for a Coworkstation box.

## cloud-init (VPS, mini-PC with Ubuntu autoinstall)

[`cloud-init.yaml`](cloud-init.yaml) is standard user-data: replace
`__HOSTNAME__` and `__ADMIN_KEY__`, feed it to your provider
(DigitalOcean/Hetzner user-data field, Ubuntu autoinstall, Proxmox
cloud-init drive). It creates the first member (`cowork`), clones
this repo to `/opt/coworkstation`, and runs `setup.sh`. By
default the credential steps (tunnel login, Access policy, Claude
sign-in) are listed in the box's `/etc/motd` and stay manual — no
secrets in user-data.

For a genuinely one-shot bring-up, SSH in once after boot and run
the zero-touch flow instead (token file + `--access-allow`; see the
[runbook](../../docs/runbook.md#zero-touch-recommended)).

**Do not put the API token in user-data.** Cloud user-data is served
from the instance metadata endpoint (`169.254.169.254`), which **any
local process — including every member's session — can read** for the
life of the instance. The edge-wide Cloudflare token would be exposed
to every user on the box. Fetch it after boot into a `0600` root file
instead.

Engine note: most VPSes have no nested virtualization, so engine
auto-selection lands on this repo's build with the bwrap Cowork
backend. That is the expected configuration, not a degraded one.

## Raspberry Pi 5 (pi-gen)

A dedicated image is Phase 5 follow-up work; until then, on stock
Raspberry Pi OS (Bookworm, arm64):

```bash
sudo apt install git && git clone \
  https://github.com/jongodb/coworkstation
sudo coworkstation/setup.sh \
  --user pi --hostname claude.example.com
```

For a pi-gen stage, the recipe is: base `stage2`, a stage that
installs `git` + clones the repo + runs
`setup.sh --engine auto --profile kasmvnc` with
`APPLIANCE_KASMVNC_VERSION` pinned, and a firstboot script that
prints the manual steps. Sizing and encoder caveats:

- 16 GB Pi 5 recommended; bwrap backend is the practical choice for
  multi-member (KVM guests are RAM-hungry).
- The Pi 5 has **no H.264 hardware encoder** — kasmVNC (JPEG/WebP
  regions) performs well; don't plan on Sunshine/Moonlight there.
- Use an NVMe HAT or USB3 SSD; Cowork sessions are I/O-heavy on
  first VM download/extract.
