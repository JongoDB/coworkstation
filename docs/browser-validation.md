# Browser validation from a real client

Drive a live Coworkstation box from an actual browser — the parts a
headless/server check can't cover: the rendered desktop, Cowork's VM,
multi-client screen sharing, per-account sign-in, and the bridge PWA.

Run this from a machine with **direct network access** (your laptop),
not a sandboxed agent environment — sandbox egress proxies reset the
WebSocket stream kasmVNC needs, so the canvas never renders there.

## Setup

```bash
npm install -g @anthropic-ai/claude-code        # if not already
claude mcp add playwright -- npx @playwright/mcp@latest
git clone https://github.com/jongodb/coworkstation && cd coworkstation
claude                                           # then paste the kickoff prompt
```

Any browser MCP works; Playwright MCP is the well-supported default.
The session reads this repo's `CLAUDE.md` for full project context.

## Credentials at runtime (never in the prompt)

The kasmVNC password is on the box, not in any doc:

```bash
ssh <your-ssh-host> 'sudo cws credentials cws'   # and: ... bob
```

If you reach the box only through the Proxmox console, read it there.
Access (SSO) may or may not gate the URLs depending on whether you
left the Cloudflare Access apps in place.

## What to validate (the client-only checklist)

1. **Login + desktop render** — open the session URL, pass Access (if
   on), enter kasm creds, confirm the XFCE desktop paints and Claude
   Desktop is running. Screenshot.
2. **Cowork VM** — inside the session, start a Cowork task. Needs
   `/dev/kvm` on the box (`cws doctor` shows `backend: kvm` and a
   kvm-group PASS). This is the highest-value check — the VM path is
   the last thing a server-side test can't exercise. Capture any
   error verbatim.
3. **Multi-client, same desktop** — open the SAME session URL in two
   browsers/devices at once. kasmVNC has no connection cap, so both
   drive one shared desktop (shared cursor). Confirm live mirroring.
4. **Second-device session** — open the `USER-sN.<host>` URL. This is
   a SEPARATE desktop with its own config home, so sign into a second
   Claude account there; confirm it does not disturb the primary.
5. **Different-account member** — open a member's `NAME-<host>` URL
   (`cws credentials NAME`), sign into a third Claude account, confirm
   full isolation from the others.
6. **Bridge PWA** — `sudo cws client bridge-link` prints a tokened
   URL; open it on a tablet. Add-to-Home-Screen; test clipboard
   send/fetch and screen share (then ask Claude in the session to run
   the `client_screenshot` tool and confirm it sees the shared
   screen).
7. **ClientSync** — install Syncthing on the client, add the box's
   device ID (`sudo cws client id`), run `sudo cws client add-device
   <CLIENT-ID>`, accept both ends, and confirm a file syncs into
   `~/ClientSync` where Cowork/Code can use it.

## Reporting

For each step: what you saw, a screenshot, and the exact error text if
it failed. File fixes against `main` the same way the rest of the
suite is maintained (lint + BATS green before push). `cws doctor` is
the fast health gate; expect Access-coverage FAILs only if you
deliberately removed the Access apps for open testing.
