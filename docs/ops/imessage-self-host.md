<!-- doc-tier: human | canonical-for: imessage-self-host-profile | budget: 2600tok -->
# iMessage — the self-hosted operator profile (Connectors)

iMessage is the one first-focus channel that is **not a product**. It is an operator profile: a
thing you can run for **yourself**, on **your own Mac**. It does not — cannot — fit Barkpark
Cloud's multi-tenant model. This runbook says exactly what it costs, exactly what it is not, and
names the parts a script will never do for you.

Charter: `.claude/workflows/bp-connectors-charter.md` (D3 / D44). Code:
`connectors/src/connectors/imessage.ts`.

## The one-paragraph truth

Apple ships **no server API for iMessage**. There is no bot token, no webhook, no OAuth, no
"Add to iMessage" button — none of it exists, at any price. Every iMessage bot on earth is a Mac
somewhere with Messages.app signed into an Apple ID, being automated by unofficial software.
Barkpark can bridge that, and does. What it will not do is dress it up as a Cloud feature.

## Why it can never be a Cloud connector

- **The Apple ID is the identity.** There is no per-tenant credential to isolate — the isolation
  boundary is the *machine*, not a token. Two workspaces on one Mac would share one identity.
  So: **ONE workspace per Mac.** No exceptions, no multiplexing.
- **It is unofficial and breakable.** The relay drives private Apple surfaces. Any macOS or
  Messages update can break it, without notice and without recourse. Treat an outage as normal.
- **It needs a machine you own and keep awake.** A Mac, on, logged in, not asleep, indefinitely.

So the connector is **registered only when `CONNECTORS_PROFILE=self-hosted`**. This is enforced in
code (`registerBuiltinConnectors`), it **fails closed** — unset, blank, `cloud`, or a typo all mean
"not self-hosted" — and `connectors/test/imessage-connector.test.ts` proves it. A Barkpark Cloud
deployment cannot offer iMessage by accident, and no configuration mistake turns it on.

## FORBIDDEN: the vendor's "Spectrum Cloud" mode

The community adapter (`chat-adapter-imessage`) advertises a hosted mode — `projectId` +
`projectSecret`, pointed at **photon.codes**. It is the obvious-looking shortcut to "iMessage in
Cloud." **Do not take it.**

> It does not remove the Mac. It moves the Mac to somebody else — a third party who then holds
> **real Apple credentials** for a real Apple ID.

Barkpark has not made that trust decision, and charter D3 deliberately avoids it. So the refusal
lives in the **code**, not in a footnote: `parseIMessageCredential()` throws
`SpectrumCloudForbiddenError` on any credential carrying `projectId`/`projectSecret`, and the
connector never calls the vendor's `createiMessageAdapter()` factory — that factory falls back to
`process.env.IMESSAGE_PROJECT_ID` / `IMESSAGE_PROJECT_SECRET`, so one stray environment variable in
a deployment could otherwise route a tenant's messages through photon.codes, silently. We construct
the adapter class directly, which reads no environment at all. A test poisons those env vars and
proves the route is dead.

If anyone ever *does* want that trade, it is a **new, explicit trust decision** with a charter
entry — never a config flag someone discovers.

## The irreducible human gates

None of these can be scripted. Budget the hours.

1. **A dedicated Mac.** Any Apple-silicon Mac will do. It must stay powered, awake
   (`caffeinate -dimsu`), and logged in. A laptop that sleeps is a bot that is offline.
2. **An Apple ID as the relay identity.** Signed into Messages.app on that Mac. Use a **dedicated
   Apple ID**, not your personal one: everything it can read, the bridge can read. Two-factor setup
   is a browser + phone flow; there is no API for it.
3. **Full Disk Access.** System Settings → Privacy & Security → Full Disk Access → add the relay
   process (and your terminal, if you launch it from one). Messages history lives in a protected
   SQLite database; without this the relay sees nothing, and fails quietly.
4. **Automation permission** for Messages.app, granted at the first send (a GUI prompt).

## Install

1. Register your Mac as an install row in `chat_bridge.connector_installs`:

   | column | value |
   |---|---|
   | `provider` | `imessage` |
   | `install_key` | a stable name for the Mac, e.g. `mac-mini-closet` |
   | `workspace_id` | the ONE workspace this Mac serves |
   | `credential_ref` | `local`, or the gRPC JSON below |

2. Choose the relay shape:

   - **`local`** — the bridge process runs **on the Mac** and drives Messages.app directly. The
     simplest setup, and the one to start with.
   - **`self-host-grpc`** — the bridge runs elsewhere and talks to an
     `@photon-ai/advanced-imessage` gRPC server **on your Mac**:

     ```json
     {"mode":"self-host-grpc","address":"10.0.0.9:443","phone":"+15550001111","token":"<your relay token>"}
     ```

     Still your Mac, still your Apple ID. Use `"shared"` for `phone` on a single-number Mac.

3. Run the bridge with the profile set — **this is what unlocks the connector**:

   ```bash
   CONNECTORS_PROFILE=self-hosted npm start   # in connectors/
   ```

   Without it, iMessage is simply not registered, and the boot log will not mention it.

## Version pinning

`connectors/package.json` pins `chat-adapter-imessage` to an **exact** version — never a caret.
This vendor has already broken its own transport once (HTTP/Socket.IO → gRPC) in a minor release.
An unpinned bump is an outage. A test asserts the pin.

## What you get, and what you do not

- **You get:** DMs and group messages into a Barkpark Session, replies back out, per-channel thread
  continuity — the same turn loop as every other connector, with no special case in the core.
- **You do not get:** any Cloud story, any multi-tenant story, any uptime promise, or any support
  from Apple. If it breaks after a macOS update, it broke because it was always going to.
