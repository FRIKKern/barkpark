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

## Wave B decisions (Decide, 2026-07-22 — 14 survey lanes + 8 verify lanes with run proofs; every load-bearing claim below was fired live, not inferred)

- **PDF-D34 — STRUCTURED CAPACITY ON THE EXISTING BEAT (the ONE server change).** `beat_fields/1`
  silently drops any non-string capacity (proven live: map body → 200 `ok:true`, roster stores
  null; JSON-string round-trips byte-identical). Fix: a `put_capacity/2` accepting THREE shapes —
  (a) native map (Phoenix-decoded JSON body, for glue/curl), (b) a JSON string that decodes to a
  map (LOAD-BEARING for the CLI: flags always ride the query string, `commandFlagBelongsInBody`
  hardcodes `cycle.open` only, so `--capacity` stays `type:string` carrying JSON text — zero Go),
  (c) legacy non-empty plain string stored as-is (back-compat, existing rows untouched).
  Validation STRICT: `size_class` ∈ `light|standard|heavy|xl` (a live off-vocab row — `"big"` —
  would silently degrade via route.py's `CLASS.get(...,2)` default; refuse it at the gate);
  `slots_total`/`slots_free` integers ≥ 0, `slots_free ≤ slots_total`; `budget` optional number
  ≥ 0. Invalid map/JSON-map → `{:error, :invalid_capacity}` → 422 arm mirroring
  `:invalid_status`/`:invalid_ttl`. The protective test sends a map and MUST FAIL on pre-fix main
  (the silent-drop is untested today — `fleet_test.exs` only ever sends `"1 task"`). Roster needs
  zero change (`to_row` passes the stored value through — verified).
- **PDF-D35 — NAMING SEAM RULED: the server speaks `size_class`; the glue transforms.** The
  stored field is `size_class` (PDF-D7 charter vocabulary). route.py keeps `max_class` and stays
  PURE and UNTOUCHED — its 9-check selftest is the iteration surface. `helpers/transform.py`
  renames `size_class`→`max_class`, decodes all three capacity shapes, converts ISO8601
  `last_seen`→epoch float (route.py does float math — fed a string it breaks), and passes the
  server `status` field through (PDF-D20: server wins). The transform is a PROVEN code shape:
  dress-rehearsed against synthetic server-shaped rows (mixed batch → heavy-on-big +
  light-on-lean; capacity swap → assignment FLIPS with names constant; cap → all-spend_cap) and
  against the real live roster row (no crash, offline row correctly excluded). The
  worker-protocol paper's `max_size:"M"` vocabulary is DEAD — paper gets a correction line
  (backlog), never the code.
- **PDF-D36 — MEASUREMENT LAW.** `size_class` derives from TOTAL RAM (stable; never fluctuating
  available-RAM). Platform-branched probes, both proven live: Darwin `sysctl -n hw.memsize` /
  `hw.ncpu` (mac: 16.0 GiB, 10 cores); Linux `awk /proc/meminfo MemTotal` / `nproc` (guerrilla:
  3.73 GiB, 2 cores — and macOS has NO `nproc`, a single shared one-liner is impossible).
  Threshold table with EXPLICIT inclusivity — a real, common machine sits exactly on the 16-GiB
  seam: light `RAM < 4`; standard `4 ≤ RAM < 16`; heavy `16 ≤ RAM < 64`; xl `RAM ≥ 64` (GiB).
  `FLEET_MAX_CLASS` env var (house convention; net-new, zero collisions) is the declared CEILING;
  effective = min(observed, declared) computed AT THE EDGE before the beat — route.py never
  learns about ceilings. `slots_free` is the LOOP'S OWN CONTROL-FLOW STATE (1 parked idle, 0 from
  claim to close) — never an OS probe. PINNED INVARIANT: sourcing slots_free from anything but
  live loop state breaks the offline≡busy equivalence (PDF-D40).
- **PDF-D37 — SPEND LEDGER + CAP LAW.** ONE row format, append-only JSONL, one line per CLOSED
  order: `{ts, order_id, agent, cost_usd|null, tokens|null, source, klass}`. Deterministic path
  OUTSIDE per-order scratch churn (`${FLEET_HOME:-$HOME/.barkpark-fleet}/<worker>/spend.jsonl`;
  orchestrator keeps its own under `.../orchestrator/`). NEVER auto-reset — an auto-reset
  silently un-trips the cap; rotation is an explicit operator action. Denomination by provenance:
  **claude** = real dollars (`claude -p --output-format json` top-level `total_cost_usd` —
  live-proven; its native `--max-budget-usd` fires `subtype:error_max_budget_usd` — a third brake
  for free; floor cost measured ~$0.20/invocation in a fat-context harness — re-measure in a lean
  listener before using as a constant); **codex** = tokens ONLY, read from `codex exec --json`
  stdout's `turn.completed.usage` (VERIFIED CORRECTION: the `token_count` event exists only in
  the on-disk `~/.codex/sessions` rollout file, NEVER on exec stdout) — dollars via `CLASS_COST`
  fallback, raw tokens recorded for honesty; **custom** = `CLASS_COST` fallback. Every row
  carries `source` (`claude-cli-json | codex-turn-usage | class-cost-fallback`).
  `FLEET_SPEND_CAP` env var; the glue computes `spend_cap_reached = sum(ledger) ≥ cap` by
  RE-READING the file before EVERY batch (liveness is proven by the R6 zero-the-ledger control).
  Malformed ledger row = loud ABORT — never coerce to 0 (brake disabled) or ∞ (brake stuck). TWO
  independent brakes that cannot double-count (route.py's cap short-circuit runs BEFORE
  per-listener budget bookkeeping — verified code order): fleet cap at dispatch + per-listener
  `budget` fed by the beat. Cap scope is ORCHESTRATOR-LOCAL by honest design (one orchestrator
  per scope — PDF-D8/D9); the ledger file prints in every proof transcript.
- **PDF-D38 — GLUE SHAPE.** NEW `.claude/skills/fleet-orchestrator/helpers/dispatch.sh` +
  `helpers/transform.py`; NEVER a `route.py --live` mode (purity law — "Pure function. No I/O"
  stays literally true). Pipeline: `bp fleet roster -o json` → transform.py → cap gate (ledger
  re-read) → `route.py --route` → `file-order.sh` per assignment (assignee = winner) → one
  printed line PER DECISION with its reason. The glue logs excluded-offline rows BEFORE calling
  route.py: route.py drops offline rows before computing `capable_exists`, so its
  `no_capacity_for_class` honestly cannot distinguish "no such box" from "the sole capable box is
  offline/busy-stale" — the glue print restores honesty, zero route.py change. Cap tripped: one
  loud freeze line, every order printed `spend_cap`, file-order.sh NEVER invoked.
- **PDF-D39 — EGRESS LEAK: SLICE-NOW, OWN PR (PDF-D31 superseded on evidence).** The leak FIRED
  empirically on guerrilla: a generic workspace SSE subscriber received the full listener
  registration doc (worker, capacity, status — eventId 70357) and both delete events; only
  zero-row update beats are silent (PDF-D17 held). A live external Go-http-client reconnects to
  that exact endpoint at the same workspace scope (~15-20 min cadence). Severity framing:
  INTRA-workspace presence disclosure to non-fleet consumers — not cross-tenant (topic is
  workspace-scoped). This wave opens api/** anyway, so D31's only deferral argument dissolves.
  Fix = `type:"listener"` excluded at all three sites — `maybe_dispatch_webhook` head-guard,
  `forward_event?` type clause, `replay_since` both where-clauses — mirroring the shipped Outbox
  idiom, protective tests mutation-proven (guard removed → test fails), its OWN PR (guard+fix
  decoupling law). Replay caveat: the already-logged registration events (eventId 70357 + two
  deletes) stay in mutation_events history; the replay filter is what retroactively muzzles them.
- **PDF-D40 — OFFLINE ≡ BUSY (proven dispatch-equivalence; ZERO Wave B code).** A busy worker
  has `slots_free=0` by construction, so route.py refuses it via two redundant guards
  (online-but-slots-0 filter, offline drop); fresh-busy vs stale-busy changes only the REASON
  STRING, never the dispatch decision — proven by truth-table runs (sole capable box: refused
  both ways; another capable box present: identical placement both ways). Mid-order staleness
  (the bash runner reads offline from claim+30s for any order >30s — the COMMON case, not an
  edge) is fail-closed CORRECT; no mid-turn heartbeat exists or is needed (PDF-D22 ban holds).
  One honest doc line lands in the listener skill + a runner comment. Do NOT conflate with
  PDF-D41 — opposite cases (busy wants refusal; parked-idle wants reachability).
- **PDF-D41 — PRESENCE-HONESTY RULED: docs, not code (closes `pdf-bl-presence-honesty-sparse`).**
  route.py's offline-exclusion STAYS for auto-routing (load-bearing for this wave's proof). A
  DIRECTLY-NAMED assignee bypasses the router entirely: `file-order.sh` has and needs NO presence
  check (verified — zero status/roster reads); the order sits on the ledger until the parked
  listener's persistent SSE Monitor wakes it. Amendments: orchestrator SKILL.md §0/§6 gain the
  named-assignee carve-out ("never dispatch to OFFLINE" applies to the AUTO-router picking among
  candidates, not to naming a known parked listener); listener SKILL.md honesty note gains
  "offline does not remove you from the ledger or block orders addressed to you by name."
  Quiet-vs-dead roster render (ttl_s≥900 heuristic, client-side) = OPTIONAL polish, never a
  requirement. No fifth verb, no stored state (PDF-D23 holds).
- **PDF-D42 — PROOF LAW (`scripts/pdf-efficiency-proof.sh`).** Inherits the kill-listener
  substrate verbatim (fresh origin/main worktree, short `BARKPARK_HOME`, pinned
  `PDS_SCRATCH_POINTER`, PGID kill under `set -m`, `--plan`/`--negctl`, PASS/ABORT/FAIL ladder —
  PDF-D28/D29). Rungs: **R0** precondition — roster 200 + a structured capacity beat round-trips
  on scratch (post-fix assert; the fail-on-main anchor lives in the server slice's protective
  test); **R1** two stub curl-loop listeners beat genuinely different measured profiles; **R2**
  mixed batch → heavy-on-big + light-on-lean asserted from the LIVE roster through
  dispatch.sh/transform/route.py; **R3** SWAP control — capacities exchanged, worker names
  constant → assignment must FLIP (proves content-keyed routing, not identity); **R4** cap
  tripped → freeze fires: one loud line, every order `spend_cap`, ZERO orders filed; **R5**
  untripped control — fresh ledger under cap → dispatch must PROCEED; **R6** ledger-ZEROED
  live-read control — zero the file in place, NO process restart → freeze must NOT fire (catches
  a cached `spend_cap_reached`); **R7** malformed ledger row → named ABORT, never PASS/FAIL.
  Filing legs use INLINE curls with DRAFT-ONLY filing (createOrReplace → query
  `perspective=raw` → delete): `file-order.sh` hardcodes prod via `bp whoami` and must NEVER be
  pointed at scratch unmodified, and a fresh scratch has ZERO registered tags so the publish wall
  422s (`label_spine` then `unknown_tag` — proven live). "Zero tasks filed" = raw row-count
  delta 0.
- **PDF-D43 — LOCAL ELIXIR GATE IS REAL (OOM lore scoped away).** Definitively proven:
  `cd api && CC=clang mix test test/barkpark/tasks/fleet_test.exs` passes 17/17 in a fresh
  origin/main worktree — 5m46s cold (one-time first-compile; deps.get + 805-file app), ~7s warm,
  peak RSS ~455 MB on a 16 GB host. The historical OOM is `mix phx.server`/release boot — a
  DIFFERENT code path; targeted `mix test <file>` never hits it. `CC=clang` is LOAD-BEARING
  (`cc` is shell-aliased to a Claude wrapper; argon2's NIF build shells out to `cc`). Build
  rhythm: ONE worktree per slice, iterate warm — never fresh-worktree-per-commit. Version note:
  local Elixir 1.19.5 vs CI 1.18.1 (format-sensitive surfaces only).
- **PDF-D44 — WAVE A RESIDUE RULINGS.** (a) `pdf-wa-tenant-scope-global-read`: CLOSED superseded
  — its purpose (guard green on main) landed via merged #5630; AC2's "#5647 MERGED" was literally
  unsatisfiable (#5647 CLOSED-not-merged, correctly — its content was redundant);
  `tenant-scope-check.sh` PASSES on fresh origin/main (48 baselined, exit 0). Do NOT re-fix. (b)
  `pdf-r2-wave-log` branch (c14c85252, 18-line r2 REVIEW log, no PR ever opened): content FOLDED
  into this charter's wave log verbatim; the charter-landing slice deletes the branch after its
  PR merges. (c) `pdf-bl-checkout-steward` stays open with REAL remaining work: the
  `worktree-fleet-provider-neutral` DIRECTORY still exists on disk (clean; `git worktree remove`
  + branch prune remain). (d) Stray guerrilla probe listener rows: already deleted (roster
  `documents:[]` verified); delete recipe = dataset-in-path `/v1/data/mutate/production` — the
  workspace-path query-param form 404s.
- **PDF-D45 — BUILDER SUBSTRATE (this wave).** The primary checkout is POISON: ~167 behind, 88
  dirty foreign files, 4 of 6 local fleet-tooling files are stale pre-r2 copies, `fleet.ex`
  absent from local HEAD entirely. Every builder worktrees from freshly-fetched `origin/main`,
  edits skills ONLY in the worktree (r2 law re-affirmed), anchors line numbers to origin/main.
  The charter reaches origin/main via the charter-landing slice: COPY THE FILE from the Decide
  commit (`git show <sha>:<path> > <path>`), never cherry-pick — local main is diverged and
  content-copy is conflict-proof.

## Roadmap (waves; interleaved with MVP stages per the build plan)

- **Wave A — Presence & roster** (FIRST): `listener` presence record (worker · status · scope ·
  capacity · last_seen · ttl) + heartbeat in listener skill/runner + `bp fleet roster` (+
  console-readable). Proof: kill a listener → OFFLINE exactly at TTL.
- **Wave B — Efficiency loop** (IN FLIGHT 2026-07-22): measured capacity heartbeats feed
  route.py live; cap halts dispatch. Decisions PDF-D34..D45; proof `pdf-efficiency-proof.sh`.
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
- **2026-07-22 · Wave A round-2 REVIEW (grade A−).** All 3 slices landed green and were
  adversarially re-verified. `pdf-wa-runner-skills-native-presence`: final branch
  `loop-epic/runner-and-both-fleet-skills-speak-nativ-0-r` (one review fix — the listener skill
  now says `working` at claim / `idle` at close, matching the runner and the orchestrator's
  pill); route.py 9th check re-proven load-bearing by mutation. `pdf-wa-kill-listener-proof`:
  branch `loop-epic/kill-a-listener-executable-proof-corpse--1` UNCHANGED — the full gate was
  independently re-run in the review worktree (7/7 PASS, first offline at 11.30s against
  boundary 11; negctl 7/7, exit 0); its transcript is the epic's criterion-0 evidence (LEAD
  stamps per PDF-D33 after merge). `pdf-wa-charter-recovery-pr`: PR #5638 open, docs-only,
  gate green; its CI reds are MAIN-INHERITED, proven — `tenant-scope-check.sh` exits 1 on
  origin/main itself because round 1's `Tasks.Fleet` in-lock by-PK re-read lacked a
  `# global-read:` justification. Review FIXED that at the root: PR #5647
  (`pdf-r2-tenant-scope-global-read`, task `pdf-wa-tenant-scope-global-read`) — one comment,
  zero behavior change, guard PASS locally; merge it after the Elixir Test gate. [Post-hoc note,
  Wave B Decide: #5638/#5649/#5650 all MERGED; #5647 went CLOSED-redundant — #5630 landed the
  identical fix first; see PDF-D44.] Next: Wave B efficiency loop + the seeded backlog.
- **2026-07-22 · Wave B DECIDE (the efficiency loop).** 14 survey lanes + 8 verify lanes (all
  claims fired live: silent-drop reproduced on scratch, JSON-string capacity byte-identical
  round-trip, transform+router dress rehearsal incl. swap-flip and cap-freeze, SSE egress leak
  FIRED and cleaned up, offline≡busy truth-tabled, local Elixir gate 17/17, codex stdout shape
  corrected). Decisions PDF-D34..D45. Wave = 6 slices: `pdf-wb-capacity-contract` (r1, opus,
  api/** server seam) · `pdf-wb-edge-measurement` (r1, opus, runner+listener skill) ·
  `pdf-wb-dispatch-glue` (r1, fable, dispatch.sh+transform.py+orchestrator skill) ·
  `pdf-bl-listener-egress-guard` (r1, opus, PROMOTED slice-now per PDF-D39, own PR) ·
  `pdf-wb-charter-landing` (r1, opus, this file → origin/main + r2 branch cleanup) ·
  `pdf-wb-efficiency-proof` (r2 AFTER capacity-contract + dispatch-glue merge, fable, the
  proof-that-must-fire R0-R7). Residue executed at Decide: `pdf-wa-tenant-scope-global-read`
  closed superseded-by-#5630; `pdf-bl-presence-honesty-sparse` ruled by PDF-D41 (charter
  criterion stamped; implementation rides the glue slice). Wave Paper:
  `personal-dev-fleet-wave-b-2026-07-22`.
