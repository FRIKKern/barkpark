# Personal Dev Fleet — Epic Charter

> **This file is the PDF epic's charter** — its own file, deliberately NOT the rotating
> epic-cycle charter slot (`bp-cloud-gui-remake-charter.md` and `bp-pds-charter.md` belong to
> OTHER epics; never write PDF decisions there). Every PDF wave reads and amends this file.
>
> Epic anchor: bp task **`personal-dev-fleet-epic`** (published, guerrilla).
> Papers: `/papers/personal-dev-fleet-strategy` (capstone, READ FIRST) · `-mvp` · `-worker-protocol`
> · `-field-guide` · `-build-plan` · `-gui-plan`.
> Proven base (all live 2026-07-21): skills `fleet-listener`/`fleet-orchestrator` + `helpers/`
> (order filer, capacity router 8/8) + `tooling/fleet/` (provider-neutral runner + protocol) —
> MERGED PR #5178. Claude AND Codex each completed the full contract on the real ledger.

## Vision — the simple core (user-ratified 2026-07-22)

Dev servers **listen and interact with an orchestrator** through the simplest possible protocol:
**four verbs — claim, pulse, stamp, close — over assignee-routed bp tasks.** Extendable on three
axes: more listeners (one command joins), more AI kinds (one adapter line), new work types (an
order is just a task — zero protocol change). **Personal**: the main is the developer's HOME BASE
— Studio, Chat, their ledger, their data **synced from MANY datasets** via the shipped PDS
scrubbed pull. The fleet is helpers attached to your home, invisible until you need hands.

**The simplicity law (governs every wave):** any feature that adds a fifth verb, a second bus, or
a new concept the four-verb core does not need is designed wrong. Elaboration yes; complication no.

## Decisions (session-ratified, condensed; the waves amend from here)

- **PDF-D1 — Hub-and-spoke.** The main is your dev server (full Barkpark + Chat); supports are
  subordinate runners that exist to serve it. Supports need NO Barkpark of their own.
- **PDF-D2 — The ledger is the bus.** Orders = ordinary tasks routed by `assignee`; the claim CAS
  is the fleet mutex; scope (workspace/project/dataset) is intrinsic via `bp use`.
- **PDF-D3 — A fence is a lease.** `bp task claim --resources` refuses overlap 409 server-side;
  `bp task frontier` is the shipped allocator. KNOWN BUG `task-fence-lifecycle-three-defects`:
  close does NOT free resources, release refuses on done → **per-order-unique fence strings**
  until fixed (fixing it is Wave D).
- **PDF-D4 — Work happens IN-TURN.** A listener never backgrounds work and ends its turn
  (observed live: produces nothing). Hard rule in the skills and runner.
- **PDF-D5 — Provider-neutral by construction.** Two spines: bp CLI + `bp mcp serve` (8 task
  tools). The ONLY vendor surface is the one-line exec adapter (claude | codex | custom). Proven.
- **PDF-D6 — Presence is a heartbeat; stale = offline, fail-closed.** Declared capacity is a
  CEILING; dispatch on min(declared, observed). Wave A builds the native record + roster.
- **PDF-D7 — Route by size, best-fit.** Weight classes light/standard/heavy/xl; cheapest
  sufficient box; same-fence never co-locates; over-budget refused; **spend cap = ambition zero**
  (the fleet brake). Router proven 8/8 (`helpers/route.py`).
- **PDF-D8 — The two dials.** Autonomy full|tiered|manual (FULL default ⇒ gate hardening is the
  safety case; fence map doubles as trust map in tiered). Work-source backlog|wish|auto — auto
  REFUSES until tokens-to-merged-value is measured.
- **PDF-D9 — The machine is the isolation boundary.** Worktrees isolate code, not performance.
  Heavy work moves to its own support; the coordination plane (ledger) is the only shared thing.
- **PDF-D10 — Commerce spine: buy the main ($29 PDS), add supplements per support, by size class.**
  Billing (and "Online") start on FIRST HEARTBEAT only — stuck-provisioning never bills. Tokens
  BYO or metered behind the user's own hard cap; never bundled unbounded. Billing human gate is
  the named external dependency.
- **PDF-D11 — GUI: store + cockpit in one journey**, extending the Cloud console + Studio under
  the GUI-remake token system. "Group" in code, Fleet in marketing. Data before pixels: no fleet
  screen ships beyond prototype before Wave A's roster. The 7-state catalogue (empty, provisioning,
  working, blocked, offline, cap-hit, conflict) is designed before layouts.
- **PDF-D12 — HERD IS DEMOTED to optional-later.** The herd is a chat-session surface; listeners
  are not chat sessions. Canonical roster = the Fleet Card + `bp fleet roster`. Do not retrofit.
- **PDF-D13 — Twin doctrine inherited.** Paid buys convenience, never capability; a free local
  fleet stays possible. Founder-first at FLAGSHIP grade; pilot lane (manual provisioning, BYO
  keys) before billing; never works-for-me quality.
- **PDF-D14 — Every wave ships behind a proof that must fire** (kill-a-listener → OFFLINE at TTL;
  heartbeat-driven Online; cap freeze = dispatch halt; etc. — see the build plan §proofs). A green
  a broken build could produce counts for nothing.
- **PDF-D15 — Task-authoring facts:** priority 0..4; `brief` is a blocks map; dedup wall needs
  distinct titles/tags (+`distinct_from`); publish via `bp doc publish task <id>`; pr-task-gate
  needs a `Task: <id>` trailer + a CLAIMED (or engine-closed) task.

## Wave A decisions (Decide, 2026-07-22 — verified on a live instance + runtime Go probes)

- **PDF-D16 — LEDGER-NATIVE RECORD RATIFIED.** A listener is a document of type `listener` —
  NEVER type `"task"` (the literal `type == "task"` filter is what structurally excludes listener
  rows from the GitHub outbox, `/v1/tasks/events`, and `/v1/tasks/prime`; registering listeners as
  task-typed silently reopens all three at once — explicit acceptance criterion on every wave).
  Registered through the tasks plugin's `register_schemas` seam (`schema.ex` list edit) +
  `plugin.json` `nouns` += `"fleet"` for provenance. Both rival directions stay enrichments only:
  derived presence (claim-join cross-check) and connection presence (`feed: connected`) are
  backlog, never the record of truth.
- **PDF-D17 — THE BEAT IS A ZERO-ROW WRITE.** Live-measured (scratch instance, 2026-07-22): a
  plain content write mints 1 revision + 1 audit + 1 mutation_event; the Tasks.Pulse idiom mints
  0/0/1. The fleet beat goes one further: **zero mutation_events per beat** — the roster reads
  `last_seen` off the document itself; no consumer needs to observe beats as events (the one
  reason to keep the event row does not exist here). One atomic `Repo.update_all`, `last_seen`
  server-stamped (`DateTime.utc_now()` inside the write — clients assert TTL as DATA, never
  "now"), advisory-lock family `"listener:" <> doc_id` (own family, not `"task:"`), gated on
  worker identity (Tasks.Pulse's `check_holder` would always refuse a listener — sibling module,
  not a call). Registration = first beat: `POST /v1/fleet/beat` upserts — absent doc created via
  the plain Content path (rare; 1 revision is fine), present doc lean-updated. No PubSub
  broadcast: the roster is a poll-read. NOTE: the doc's `rev` integer still bumps per beat; "no
  revision" means no revision ROW.
- **PDF-D18 — SYNC-PUSH EXCLUSION IS STRUCTURAL, NOT CONVENTIONAL.** `Sync.Outbox.fetch/3` has NO
  type filter (verified — only `source != "sync"`), and any event whose mutation is not literally
  `"task."`-prefixed falls to `push_doc` = full createOrReplace to every push-enabled remote. The
  wish's own "sync to many datasets" goal makes this the live config. Fix: `type != "listener"`
  exclusion in `Sync.Outbox.fetch/3` (mirroring the source echo-guard), with its own test, in its
  OWN PR (guard+fix decoupling law) — even zero-row beats leave registration events to guard.
- **PDF-D19 — FLAT MOUNT; GLOBAL-PER-DATASET READ.** `/v1/fleet/*` rides `plugin_routes(scope:
  :token_root)` exactly like `/v1/tasks/*`. Verified correction to PDF-D2's framing: the flat
  family resolves scope via `AssignDefaultScope` (seeded Default workspace), NOT
  `DeriveWorkspaceFromToken` — write and read cannot diverge on workspace by construction. The
  roster read copies `Tasks.Board.snapshot`: `WHERE type = 'listener' AND dataset = ^dataset`,
  **no workspace clause** (the workspace-filtered index shape fail-closes to empty on a nil
  workspace — the global shape makes that bug impossible). `dataset` param defaults
  `"production"`. The console reads the SAME flat HTTP endpoint; a socket-scoped
  (`LiveScope`/`scope_opts(socket)`) fleet read is FORBIDDEN — it would resolve a different
  workspace source and read empty, invisibly.
- **PDF-D20 — ONE STALENESS FORMULA, SERVER-SIDE.** Three drifted copies of "is this stale" math
  already exist across two languages (chat_live/board_live age math, Go taskboard leaseTTL,
  route.py `_online`). The roster's status is computed at read time in ONE module,
  `Barkpark.Tasks.Fleet` — `offline` iff `now - last_seen > ttl_s`, else the stored self-declared
  status — stamped `@canonical capability:fleet-presence-staleness`. Every client (bp table,
  console JSON, route.py dispatch) renders the server's `status` field; route.py keeps `_online`
  only as a fallback for rows lacking a computed status. "working on task-X" = read-time join
  `claim.worker || assignee` (board_live.ex:1013 precedent), never stored on the listener.
  Moduledoc must self-disambiguate: this is the repo's 4th "fleet" and 4th "pulse" concept —
  name the other three, Tasks.Pulse-style.
- **PDF-D21 — ZERO-GO SHIP; DOCUMENTS ENVELOPE.** Runtime-proven: a `{"documents": [rows]}`
  roster payload renders a real multi-column table on every already-installed bp binary; a
  bespoke `{"roster": […]}` key degrades to one crammed KV cell (and breaks `extractListRows`
  pagination). The roster response rides the `documents` key. `cli_commands` mints noun `fleet`,
  verbs `roster` (GET, `writes:false`, `default_output:"table"`) and `beat` (POST,
  `writes:true`) — manifest-driven, live on any installed binary at next fetch, no cli-v*
  release. WORKER-first column order = cosmetic Go backlog (pickColumns leads with `status`
  today), explicitly NOT this wave.
- **PDF-D22 — TTL FIXTURES (self-declared per row stays law; these are defaults, not caps).**
  Server default when unspecified: `ttl_s: 120`. Bash runner: beats every loop tick (~6s),
  declares `ttl_s: 30`. Resident skill: beats only at turn boundaries (start/claim/close — an
  idle SSE-parked session cannot beat), honestly declares `ttl_s: 900`. Detached beat sidecars
  stay BANNED (PDS-D243: `nohup &` is killpg-fragile and dies ambiguously; a setsid-detached
  process outlives the corpse and lies ONLINE forever) — the beat lives inside the single
  foreground loop and shares fate with the worker.
- **PDF-D23 — ROW-STATUS VOCAB.** Self-declared per row: `idle | working | blocked`
  (`provisioning` reserved for cloud-provisioned rows, Wave C). `offline` is computed-only,
  never stored. Empty / cap-hit / conflict are fleet-level view states, never row states.
- **PDF-D24 — THE PROOF IS THE WAVE.** `scripts/pdf-kill-listener-proof.sh` on
  `pds-scratch-target.sh` (release boot dodges the mix-phx OOM; ~14s warm, teardown asserted
  clean). Two stub listeners (`FLEET_AGENT=custom`, zero-token agent), kill one: survivor stays
  ONLINE **and is RETURNED by the roster** (catches the empty-read scope bug the ONLINE assert
  alone would miss); corpse flips OFFLINE at its TTL and NOT before (assert online at TTL-margin,
  offline after). Negative control (`--negctl`): the harness keeps beating the "corpse" and
  asserts its own OFFLINE check FAILS — the check must be able to fail. Harness drives the flat
  routes with the scratch bearer token (verified: bp task verbs 403 on a bare-token scratch
  server; flat `/v1/*` routes authorize from the bearer). Its run transcript is the epic's
  criterion-0 evidence.
- **PDF-D25 — CHECKOUT STEWARDSHIP (hard law for this wave's builders).** Local main is 8
  ahead/136 behind origin/main and its `api/lib/barkpark/plugins/tasks.ex` is 59 lines STALE
  (predates #5178). Builders worktree from **freshly-fetched `origin/main`**, never from local
  HEAD. The `worktree-fleet-provider-neutral` branch is DEAD/superseded (never merged; its bp
  task is closed) — do not resurrect. The full steward sequence (preserve the 8 stray charter
  commits → reset local main → PR this charter to origin/main) is a filed backlog task; until it
  lands, wave tasks carry the full build context so the charter's absence from origin/main blocks
  nobody.
- **Amendment map (in-wave, PDF-D12 enforcement):** fleet-listener SKILL.md L31-34 ("until that
  ships…") → flat native-beat instruction; fleet-orchestrator SKILL.md §0 L19-20 collapses to
  "Read it with `bp fleet roster`" and §6 L99-115 is rewritten around the shipped mechanism with
  the "Native home: Herd report_state" sentence DELETED (it contradicts PDF-D12); L59's
  `--resources` order-claim text untouched (different concept). fleet-run.sh gains a start beat
  (after the "listener online" line) and an idle beat inside the `while true` body (before
  `sleep 6`) — never backgrounded. The epic task brief's charter pointer is real only after the
  steward PR lands this file on origin/main.

## Wave A round-2 decisions (Decide, 2026-07-22 — round 1 MERGED #5626/#5627, LIVE on guerrilla; 5 verify lanes with run proofs)

- **PDF-D26 — CLI DIALECT PROVEN LIVE; GO CONTINGENCY CANCELLED.** Zero-Go is fact, not plan:
  no `case "fleet"` exists in cli.go; dispatch is fully manifest-generic; `documents` was already
  the first `listEnvelopeKeys` entry. Live-proven on the installed binary against deployed
  guerrilla: bare `bp fleet roster` renders a REAL TABLE in an interactive tty (two agreeing
  mechanisms: applyGlobals tty-default + manifest `default_output: table`); piped output is
  compact JSON — every "roster prints JSON" sighting was a non-tty probe, not a defect. Wish
  item (1) closes on this verification evidence; NO build slice, NO cli release. Dialect facts
  every client must respect: `worker` is a REQUIRED POSITIONAL (`bp fleet beat <worker>` —
  `--worker` exits 2 "unknown flag", and under `|| true` would beat into the void silently
  forever); beat-declarable status vocab is `idle | working | blocked` ONLY (`online` 422s —
  online/offline are server-derived); the CLI flag is `--ttl`, stored/read back as `ttl_s`.
  Scripted/CI transcript captures run non-tty: use `-o table` explicitly + `BP_COLOR=none`.
- **PDF-D27 — r2∥r3 RUN PARALLEL (one build round).** The r3 brief's "AFTER runner-skills
  MERGES" clause was stale serial-filing language, not a real coupling: the harness stubs its own
  curl-loop listeners against the flat routes, never sources fleet-run.sh or the skills; file
  sets are fully disjoint (tooling/+skills vs scripts/). Confirmed by two independent lanes.
- **PDF-D28 — PROOF TIMING LAW.** The true offline boundary is `elapsed >= ttl_s + 1`
  (`DateTime.diff/3` floors to whole seconds — the +1 is baked in, don't fight it). The harness
  anchors on the SERVER-ECHOED `last_seen` from the last successful beat response (byte-identical
  to what the roster later reports — proven), NEVER on the kill instant. Poll-and-bracket, not
  fixed-offset snapshots: every poll with elapsed < ttl_s must read non-offline; the first poll
  with elapsed >= ttl_s+1 must read offline and stay, with a hard ceiling (ttl_s+5) so a
  never-flips corpse is a timed-out FAIL. KILL IDIOM (probed 2/2 vs 0/2): bare `kill $PID` leaks
  a straggler beat — the in-flight curl child survives and lands ~50ms AFTER the kill. The
  harness MUST `set -m` before backgrounding each listener (non-interactive bash does NOT give
  jobs their own process group by default), assert each listener's PGID is distinct from its
  neighbor's and the harness's own, then `kill -- -PGID`. `--negctl` beats the corpse at the SAME
  cadence as the real loop.
- **PDF-D29 — SCRATCH SUBSTRATE LAW (proven end-to-end).** The harness runs from a FRESH
  origin/main worktree — the primary checkout genuinely lacks the fleet routes (grep: zero hits),
  so an in-place boot 404s by construction. `BARKPARK_HOME` MUST be a short root
  (`mktemp -d /tmp/pdf.XXXX`) — the script's 85-byte TRAP-3 cap refuses any nested-scratchpad
  path (measured 126 bytes → instant exit 1). `PDS_SCRATCH_POINTER` MUST be pinned per-run —
  the default `/tmp/pds-scratch-target.last` is one global file any concurrent scratch boot
  silently repoints. A named PRECONDITION rung asserts `GET /v1/fleet/roster` answers 200 (with
  the `documents` envelope) on the scratch target BEFORE any TTL assert — a 404 must never read
  as a timing failure. Budgets: COLD boot from a bare worktree measured 311.7s (budget 15 min);
  warm re-boot ~13s. Teardown asserts ports released + zero orphan postgres, and was proven clean.
- **PDF-D30 — STEWARD: PARTIAL ONLY, NO RESET.** This wave executes ONLY the safe half — the PDF
  charter commits cherry-picked/copied into an origin/main worktree and PR'd (precedent #5572,
  rehearsed live: f887822c6 applies clean). NO `git reset` in the primary checkout: three live
  wounds are ACTIVE (staged truth-grip fork with its own task; claimed in-progress herd-s4
  apiclient work in internal/apiclient/{fleet,listen,chat}.go; real-time taskboard TaskPurpose
  edits). Also deferred: 4 of the 9 ahead commits carry grip-ledger pollution, and 3 sibling
  charters DIVERGE from what #5572 already shipped — those need line-level reconciliation, not a
  blind PR. The rest of pdf-bl-checkout-steward stays filed backlog.
- **PDF-D31 — LISTENER EGRESS LEAK = BACKLOG, NOT THIS WAVE.** The feared per-beat fan-out is
  REFUTED: heartbeats are raw `Repo.update_all`, zero broadcast (PDF-D17 held); only the ONE-SHOT
  registration rides the content spine to webhooks + SSE. Live severity low: zero active webhooks
  exist on guerrilla, and the disabled site hooks (events publish/unpublish/delete) structurally
  cannot match a draft-create registration. Real residue: the unfiltered `/v1/data/listen` SSE
  leg (+ its Last-Event-ID replay path) forwards one listener doc per registration. Fix is known
  and small (~10 lines: head-guard in `maybe_dispatch_webhook`, `forward_event?` clause, replay
  filter — mirroring the Outbox idiom) — filed as `pdf-bl-listener-egress-guard`; importing an
  api/** Elixir-gate wait into the proof wave buys nothing.
- **PDF-D32 — 900s SKILL TTL STANDS; HONESTY IS DOCUMENTED, NOT INFLATED.** A parked resident
  skill CANNOT beat between turns (no code runs), so 900s is the honest mechanical ceiling — but
  in sparse personal use, gaps between a listener's own orders routinely exceed 15 min, so an
  alive-but-idle session reading `offline` is the design's steady state, not an error. The skills
  must SAY this plainly ("offline = no beat within TTL; for a parked session it means 'quiet',
  not 'dead'"). No fifth verb, no timer sidecar (PDF-D22 ban holds). Whether the roster should
  distinguish quiet-parked from dead is filed as `pdf-bl-presence-honesty-sparse` — a Wave B
  question.
- **PDF-D33 — CRITERION-0 STAMP RECIPE (rehearsed live, epoch semantics proven).** After the r3
  transcript merges, the LEAD (never a builder): `bp task claim personal-dev-fleet-epic <lead>`
  → record epoch E → `bp task stamp … --criterion 0 --met --evidence "<transcript pointer +
  decisive lines>" --criterion-text "$(cat crit0.txt)"` (byte-exact from the stored doc, via
  file, never retyped) → `bp task release … E`. Stamp is EPOCH-INERT (claim block byte-identical
  after stamp — proven); the same claim-time epoch threads stamp AND release unless a pulse
  intervenes. No raw patch, no publish call. NOTE: `bp doc delete` can exit 4 on success —
  verify deletes by re-GET, never by exit code.
- **Amendment-map corrections (r2 builder must absorb):** THREE deferral clauses, not two — the
  literal greps miss the third: fleet-listener SKILL.md L31-34 "until that ships",
  fleet-orchestrator SKILL.md L19-20 "until it ships", AND fleet-orchestrator SKILL.md L113-115
  "Until then…" (same deferred-until-shipped semantics, different words). `report_state` sentence
  at orchestrator L112 deleted per PDF-D12. All beat examples use the POSITIONAL dialect
  (PDF-D26). route.py `_online` gains the server-status preference (PDF-D20) PLUS a 9th selftest
  check proving a row with `status:"offline"` and a FRESH `last_seen` still reads offline (server
  field wins) — without it the new branch is untested. The local skill dirs are untracked-but-
  byte-identical to origin/main: edit ONLY in the worktree; the untracked local copies are inert.

## Roadmap (waves; interleaved with MVP stages per the build plan)

- **Wave A — Presence & roster** (FIRST): `listener` presence record (worker · status · scope ·
  capacity · last_seen · ttl) + heartbeat in listener skill/runner + `bp fleet roster` (+
  console-readable). Proof: kill a listener → OFFLINE exactly at TTL.
- **Wave B — Efficiency loop**: measured capacity heartbeats feed route.py live; cap halts dispatch.
- **MVP-0 — Visual setup + first offload** (console journey; Screens 0-2 of the GUI plan).
- **Wave C — Cloud add-support, one action** (provision + bind + scrubbed pull + listener).
- **Wave D — Durability**: fence-lifecycle fix; lease-lapse recovery; runner robustness.
- **Wave E — Orchestrator at scale**: dials live; gate hardening for full-auto.
- **Wave F — The seal**: one unattended mixed-agent, mixed-size real run; epic closes on it.

## Wave log

- **2026-07-22 · Wave A DECIDE (presence & roster).** 15 survey lanes + 5 verify lanes confirmed
  the ledger-native record; decisions PDF-D16..D25 ratified (zero-row beat, sync-push guard, flat
  mount + global-per-dataset read, one server-side staleness formula, zero-Go documents-envelope
  ship, TTL fixtures 30/900/120, kill-a-listener proof harness, checkout stewardship). Wave =
  4 slices: `pdf-wa-server-presence` (r1, fable) · `pdf-wa-sync-outbox-guard` (r1, opus) ·
  `pdf-wa-runner-skills-native-presence` (r2, opus, after server) · `pdf-wa-kill-listener-proof`
  (r3, opus, after server+runner). Wave Paper: `personal-dev-fleet-wave-2026-07-22`.
- **2026-07-22 · Wave A round-2 DECIDE (close the wave).** Round 1 MERGED (#5626/#5627) and
  LIVE-proven on guerrilla (roster 200 documents-envelope, zero-row beat, offline-past-TTL with
  no write). Decisions PDF-D26..D33: CLI dialect proven live (wish item 1 closes on evidence, no
  Go), r2∥r3 parallel, timing law (anchor on server-echoed last_seen, ttl_s+1 boundary,
  process-group kill with set -m), scratch substrate law (fresh origin/main worktree + short
  BARKPARK_HOME + pinned pointer + precondition rung), steward partial-only NO reset, egress
  leak to backlog, 900s TTL stands with honesty documented, criterion-0 stamp recipe. Wave =
  3 slices, ALL round 1: `pdf-wa-runner-skills-native-presence` (opus) ·
  `pdf-wa-kill-listener-proof` (fable, the epic's criterion-0 proof) ·
  `pdf-wa-charter-recovery-pr` (opus, steward safe half). Backlog filed:
  `pdf-bl-listener-egress-guard`, `pdf-bl-presence-honesty-sparse`. Wave Paper:
  `personal-dev-fleet-wave-2026-07-22-r2`.
