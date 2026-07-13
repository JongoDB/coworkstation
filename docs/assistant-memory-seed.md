# Assistant memory seed

Verbatim copies of this assistant's persistent memory notes for the
Coworkstation project, so a new assistant instance (which has no access to
the original session's memory store) can seed its own. See
`docs/HANDOFF.md` for the full engineering brief — these notes are the
distilled "how to work with the owner" and "how to reach the box" facts
that memory would otherwise carry silently.

If your assistant has its own persistent-memory system, save each section
below as its own memory (type noted per section) rather than just reading
it once.

---

## Memory: autonomous-operation

- **type:** feedback
- **description:** User wants fully autonomous execution — deploy, merge,
  validate, build without asking

On the Coworkstation project the user expects full autonomy: deploy fixes
to the live box, merge PRs, continue validation, and implement
improvements/feature requests without being asked to confirm each step.

**Why:** He said explicitly "I shouldn't need to tell you to deploy fixes,
merge PRs, continue validation, implement improvements and feature
requests." He values momentum over check-ins.

**How to apply:** Default to acting. Land bugfixes through to deployment +
verification, not just a pushed branch. Still respect hard safety rules
(never enter Claude account passwords / financial creds; those stay
delegated to the owner). Verify with lint + BATS green before pushing,
same as the existing suite. Prefer the project's own deploy path
(regenerate via setup/install/reconfigure) over hand-patching live files.

---

## Memory: box-access

- **type:** reference
- **description:** How to reach the live Coworkstation box for
  client-side validation

The live Coworkstation appliance is reached over SSH as
**`cws@cws-ssh.fightingsmartcyber.com`** (the local `~/.ssh/config` block
sets only a cloudflared `ProxyCommand`, no `User`, so you must give `cws@`
explicitly — the default local user is rejected). The session user /
control account on the box is `cws`.

kasmVNC serves HTTP Basic auth; passwords via `sudo cws credentials
<user>` (or `sudo cat ~/.vnc/kasm-credentials`). Sessions: primary
`cws.<zone>` (display `:1`), member `<name>-cws.<zone>`, extra device
`<user>-s50-cws.<zone>` (display `:50+`). Bridge PWA URL from `sudo cws
client bridge-link`; box Syncthing device id from `sudo cws client id`.

Client-side validation plan lives in `docs/browser-validation.md`. Run
browser checks by driving a real browser (the claude-in-chrome extension),
not Playwright — Playwright can't carry Basic auth onto the kasm
WebSocket. See the autonomous-operation note above.

**Update (2026-07-12):** the branded gateway now fronts every hostname —
visiting the domain lands on a login page (no more raw Basic-auth dialog),
then a `/home` hub. The kasm Basic-auth path above still exists one layer
down (the gateway injects it upstream); `sudo cws credentials <user>` is
still the source of truth for the password, which is now also the
gateway's login password for that user.

---

## Memory: MEMORY.md index (for reference)

The index this assistant used to track the above two notes:

```
- [Autonomous operation](autonomous-operation.md) — deploy/merge/validate/build without asking; hard safety rules still apply
- [Box access](box-access.md) — SSH as cws@cws-ssh.fightingsmartcyber.com; kasm creds via `cws credentials`; drive real Chrome not Playwright
```
