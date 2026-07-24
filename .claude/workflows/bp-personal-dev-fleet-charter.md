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

## Wave B round-2 decisions (Decide, 2026-07-23 — the CLOSING round; 11 survey lanes + 6 verify lanes, every load-bearing claim executed, not read)

- **PDF-D46 — CLOSING-ROUND SHAPE (direction A with C folded in, confirmed).** One centerpiece
  build (`pdf-wb-efficiency-proof`, round 1) + two round-2 stamp slices dispatched only after
  the proof MERGES (`pdf-wb-epic-crit2-stamp`, `pdf-bl-presence-honesty-sparse` AC1). All other
  round-2 duties were EXECUTED AT DECIDE with verify-fleet evidence in hand: the guerrilla live
  egress verify (passed, 5 legs), the fresh-binary `--capacity` beat smoke (passed, roster
  round-trips a typed map, probe cleaned), and the round-1 ledger closes (all five slice tasks
  now genuinely done with real merge/live evidence — the same-day false-done pattern repaired,
  not papered over). Zero new verbs, zero server changes, zero code edits to
  dispatch.sh/route.py/transform.py — the proof rides the merged FLEET_ROSTER_JSON /
  FLEET_FILE_ORDER_BIN seams (D42's "add the seam" contingency is MOOT).
- **PDF-D47 — REOPEN/STAMP RECIPE IS THE THIRD PATH (proven end-to-end on
  `pdf-wb-charter-landing`).** `bp task stage <id> open` flips lifecycle done→open but KEEPS the
  closed claim occupying the slot: a fresh claim under a NEW worker id → `not_ready` (exit 6),
  and a direct stamp at the old epoch → `not_in_progress:open` (exit 2) — BOTH predicted paths
  refuted by live probe. The ONLY working path: re-claim under the task's OWN `claim.worker`
  (the original closer, read per task — never a shared lead id), which renews the closed claim,
  bumps the epoch, and enters in_progress; then stamp at the NEW epoch, then close. Batch recipe:
  stage open → `HOLDER=$(bp task get <id> -o json | jq -r .doc.claim.worker)` → claim as HOLDER
  → stamp each unmet criterion (verbatim `--criterion-text`) → close done → re-get and assert
  met==total. Applied 2026-07-23 to capacity-contract, edge-measurement, dispatch-glue, and
  egress-guard: all four now done with full criteria. The false-done memory recipe's
  "stamp directly on the standing worker+epoch" is WRONG post-stage — re-claim is mandatory.
- **PDF-D48 — EGRESS GUARD LIVE-VERIFIED ON GUERRILLA (criterion closed on 5-leg proof).**
  Fresh first-ever `type:listener` beat = ZERO frames on a subscribed
  `/v1/data/listen/production` SSE stream while non-listener anchors forwarded (eventIds
  80679/80681 with the suppressed listener at the 80680 gap); `Last-Event-ID` replay excluded
  listener rows but replayed non-listener docs (type-scoped, non-vacuous); listener DELETE
  silent while a same-window non-listener control fired; roster row present before, gone after.
  HONEST RESIDUAL: the webhook leg rests on merged unit tests (`broadcast_test.exs`), not a live
  webhook endpoint — recorded, not hidden. PREMISE CORRECTION: `/v1/fleet/beat|roster` HTTP
  routes DO exist (Tasks-plugin route table); but the egress guard operates on the underlying
  listener DOC mutations — the doc path (`/v1/data/mutate` createOrReplace/delete) is what the
  5-leg proof exercised.
- **PDF-D49 — SQUASH-MERGE ANCESTRY LESSON (budget-clamp ruling: FIXED, nothing to file).**
  `git merge-base --is-ancestor <branch-commit> origin/main` is the WRONG test after a squash
  merge: commit-hash ancestry ≠ content presence. The review's budget-floor fix (4d2db4885)
  IS on origin/main inside squash commit 89afdd479 (#5686) — file byte-identical between the two
  commits; origin/main's `measure_budget` emits `budget: 0.0` on an overspent ledger while the
  pre-fix parent emits `-0.35` (both executed). The defect class (negative budget → server 422 →
  `|| true` swallows → listener silently vanishes at cap-trip) was real and is CLOSED. Rule
  forward: prove landed-ness by CONTENT (`git show <sha>:<file> | diff`), never by hash ancestry.
- **PDF-D50 — FLEET CLI IS 100% MANIFEST-DRIVEN (beat smoke closed at provenance rigor).**
  `internal/cli/cli.go` has no `fleet` case — beat/roster ride the generic capabilities-manifest
  dispatch, so a pre-round-1 and post-round-1 binary behave identically for `fleet beat
  --capacity`. A fresh origin/main build (6a7ead0a7, provably containing #5685 via merge-base)
  ran the structured-capacity beat against deployed guerrilla: roster round-trips a typed JSON
  map (never a string), the beat write is draft-only (delete result shows ONLY `drafts.<id>` —
  PDF-D17 corroborated live), probe cleaned, roster left clean. The "fresh binary" duty closes
  the PROVENANCE caveat, not server behavior.
- **PDF-D51 — DEPLOYED SCHEMA DRIFT: `listener.status` REJECTS ITS OWN VOCABULARY on guerrilla.**
  Live probe: status=idle/working/blocked/provisioning ALL 422 `{"status":["is invalid"]}` via
  the doc-mutation path, while other select schemas validate fine and the schema CODE on
  origin/main is correct — root-cause hypothesis: a stale registered schema row predating the
  options (Bootstrap is idempotent-on-(name,dataset) and never updates). Symptom CONFIRMED,
  root-cause PLAUSIBLE. Filed `pdf-bl-listener-status-schema-drift` (backlog). Interim law:
  beats against guerrilla OMIT `status` via the doc path (the `/v1/fleet/beat` endpoint path
  sets status server-side and is unaffected — the smoke's beat stored `status:idle` fine).
- **PDF-D52 — BACKLOG DISPOSITIONS (the four Decide-seeded + two net-new).**
  (a) `pdf-bl-worker-protocol-paper-sync` = EXECUTE NOW (round-1 slice; 2-block Paper patch,
  stale `max_size:"M"` + global-120s-TTL confirmed live).
  (b) `pdf-bl-file-order-env-override` = EXECUTE NOW SHRUNK (round-1 slice; ~15-line
  env-fallback diff to file-order.sh only — the dispatch.sh half already merged in #5687; task
  description's "reconcile" note is stale and is corrected on the task).
  (c) `pdf-bl-adapter-rate-card` = STAYS OPEN, annotated: the local half is ANSWERED (one
  `codex exec` invocation emits exactly ONE `turn.completed` with usage summed across tool
  calls; D37 + route.py's CLASS_COST already ARE the rate ruling) — only the remote
  claude-flag-on-a-real-listener-host leg remains.
  (d) `pdf-bl-scratch-orphan-postgres-janitor` = STAYS OPEN (census re-confirmed, 5 foreign
  PPID-1 orphans; multi-hour build, not a closing-round errand).
  (e) NET-NEW filed: `pdf-bl-listener-status-schema-drift` (D51) and
  `pdf-bl-doctor-bp-staleness-regex` (doctor.sh:82's sed pattern can't match a
  `-dirty`-suffixed commit, so the bp-staleness check silently self-skips on every dirty build).
- **PDF-D53 — PRESENCE-HONESTY AC1 CLOSES FROM THE PROOF TRANSCRIPT (round 2, never conflated).**
  AC0 (the D40/D41 ruling implemented as docs) is byte-anchored: the SKILL.md hunks are genuinely
  new in #5686/#5687 and no server code changed (no `quiet` status exists — the optional render
  was correctly never built). AC1's "live roster read" half stays HONESTLY OPEN until the
  efficiency proof runs: the proof MUST capture at least one raw roster GET showing live rows
  (including one `status:offline` row so the dispatch exclusion line prints — dry-run gap), and
  THAT transcript quote closes AC1. transform.py capacity-decode robustness is a DIFFERENT fact
  (already selftest-covered) and never substitutes for the live read.
- **PDF-D54 — PROOF CONTRACT PINS (byte-exact, from the executed dry-run; the builder transcribes,
  never explores).** (1) The dispatch cap-gate ledger is `$FLEET_HOME/orchestrator/spend.jsonl`,
  dialect `cost_usd` — `record_spend` writes a DIFFERENT per-worker file; R0 must ABORT-verify
  path+dialect or every cap rung can fake green. (2) The beat receipt NEVER echoes `capacity` —
  assert round-trip via the roster, never the beat response. (3) The stub filer MUST `exit 0`
  (dispatch.sh's `set -e` while-loop aborts the batch otherwise). (4) Cap comparison is
  `spent >= cap` — a ledger summing exactly the cap trips the freeze. (5) R4 must assert the
  freeze LINE + stub-log 0 bytes (dispatch layer), not merely all-orders-`spend_cap` (the route
  layer alone also produces that). (6) The malformed-ledger ABORT (exit 12) fires even with NO
  cap set — the ledger read is unconditional when the file exists. (7) Roster fixtures include
  one `status:offline` row to capture the PDF-D38 exclusion print (the one dry-run gap).
  (8) Budget the charter's COLD figure — 311.7s boot (D29), never the in-checkout ~25s number.

## Wave C decisions (RECONSTRUCTED at MVP-0 Decide, 2026-07-24 — Wave C's code MERGED (#5930/#5932/#5933/#5973) but its charter content never landed: every cited landing commit (58e019937, 296efabee, a27aeed5e, 1741e7b7e) is a PHANTOM — `git cat-file -t` fails on all four. D55-D75 transcribed verbatim from the wave-c Papers (r1 lines 448-473, r2 lines 349-383); treat any commit hash cited inside those Papers as untrusted until re-verified.)

- **PDF-D55** — Wave C before MVP-0: Screen 2's moments ARE this machinery; MVP-0 substrate audit
  says Screens 0-1 are composition once the data exists.
- **PDF-D56** — D51 corrected: provisioner writes published `listener-<name>`
  `content.status=provisioning` via doc-mutate, exact vocab, `ttl_s`=provisioning budget.
- **PDF-D57** — No token-scope machinery; ledger token minted server-side on the main via a new
  admin-gated mint/revoke pair (`POST|DELETE /v1/fleet/support-tokens`); claim-probe law recorded
  (403 while valid, 401 after revoke).
- **PDF-D58** — ARM out, x86 pinned (cx23 default); size-class from FIRST MEASURED BEAT never SKU;
  create-time placement failure = named CLI failure, writes nothing.
- **PDF-D59** — Support box = warm-image + reduced configure subset, LOCAL health probe (no public
  FQDN — dns/caddy/public-health/tenant-register steps DROPPED); dataset leg ships (merge import
  into localhost:4000 after allow_bundle_import).
- **PDF-D60** — Surface = Go-native `bp cloud support add|remove`; roster IS the progress model;
  Kinsta bar on every terminal state.
- **PDF-D61** — Group = three additive nullable barkparks columns (`fleet_role`,
  `fleet_parent_id` self-FK, `fleet_token_id`) + CP `/v1/fleet/supports` endpoints; guerrilla's
  row ratified as the main.
- **PDF-D62** — Runtime install automatic + fail-open agent CLI; **provider keys never copied** —
  exact SSH one-liner printed for the developer; `barkpark-fleet-listener.service` supervises the
  foreground loop (not a sidecar).
- **PDF-D63** — Remove = mirror with a FOUR-surface verify-gone census (token, box, roster row,
  CP row), non-zero exit on any survivor.
- **PDF-D64** — Local fleet artifacts superseded — discard; 16-GiB host = heavy is correct.
- **PDF-D65** — Riders: adapter remote leg rides the proof; deadlock + doctor regex are round-1
  riders; epic-crit2-stamp + presence-honesty AC1 stay Wave B sweeps; janitor stays filed.
- **PDF-D66** — Proof law: R0 preconditions → R1 clean census → R2 one action →
  online-with-measured-capacity from the LIVE roster → R3 scrub zero with firing control → R4
  stuck-provisioning never lies online → R5 adapter probes → R6 four-surface census delta zero.
- **PDF-D67** — CP wedge is a named prerequisite slice (one-time network recreate + rebuild from
  origin/main). WHY: round 3 and the rewired bind's live leg are dead until 401-not-404.
- **PDF-D68** — Remove ordering: READ CP row FIRST, revoke token FIRST among deletes, CP row LAST;
  no token_id copy on the roster row. WHY: the CP row is the sole token_id holder — the old order
  bakes an unrecoverable orphan-token window.
- **PDF-D69** — Bind rewire: register leg → control plane via requireCloud/CloudClient; mint stays
  on the main; HasCloudToken checked BEFORE the box create. WHY: verified 404-by-construction
  defect; a missing credential must never bill a box.
- **PDF-D70** — Parent auto-resolve matches hostname-of(row.url) vs hostname-of(Config.Server);
  NEVER row.host; refuse-with-candidates on zero/many; `--parent` wins. WHY: host is a raw IP on
  every real row.
- **PDF-D71** — DELETE PAT symmetry: a credential that can bind can unbind. WHY: fail-first-proven
  asymmetry lets a PAT create an orphan it cannot clean.
- **PDF-D72** — Two-host test law: second httptest CP server seeded via SaveConfig(CloudURL),
  which-host assertions. WHY: the single-host harness is why the bind bug passed 9/9 green.
- **PDF-D73** — R4 = row-only short-TTL negctl (~30s ttl, ≥4-min observation), R2 box concurrently
  online; claim scoped to "a withheld listener's row never onlines". WHY: the online gate is
  box-blind — a second box violates the one-box budget and adds zero proof.
- **PDF-D74** — Ledger rulings: crit2-stamp reconcile-closed at Decide; presence-honesty
  stamp-without-evidence REFUSED. WHY: never seal a criterion without evidence.
- **PDF-D75** — Proof reality pins: HCLOUD_TOKEN exported explicitly (Darwin context-blindness),
  R0 asserts existence-not-stock (412 = stock probe), emergency raw hcloud delete-by-label in the
  trap, R5 = free captures + ONE env-var-keyed call. WHY: each pin is a verified false-ABORT or
  leak path.
- **PDF-D76..D82 — VOID.** The wave-c-r3 Paper's decisions section is SEVEN EMPTY BULLETS pointing
  at phantom commit 1741e7b7e; no decision text exists anywhere (papers, git, worktrees — proven
  by per-D grep + `git cat-file` on 8370 commits). The numbering is retired unfilled; the
  substance survives only in the r3 harness itself (`scripts/pdf-support-proof.sh` at stranded
  local commit 6c24833a4, folded into MVP-0's proof per PDF-D90). Lesson: a decision that lives
  only in an unpushed local commit does not exist.

## MVP-0 decisions (Decide, 2026-07-24 — the console journey wave; 16 survey lanes + 10 verify lanes; every load-bearing claim below carries run output from the verify round or a Decide spot-check)

- **PDF-D83 — THE INVERSION IS THE WAVE.** Support provisioning becomes a CP provision job:
  `@kinds` grows ONE word — `provision_support` — executed by the shipped Go provisioner worker.
  Claim shape follows the RESURRECT precedent exactly (its own claim route
  `POST /v1/internal/support-jobs/claim`; REUSES the generic provision-jobs
  succeed/fail/step/console routes). The direction's "kind-filtered claim endpoint" is REJECTED:
  no such pattern exists anywhere (all 4 kinds have dedicated routes — verified in worker.go +
  router.ex). The worker must NOT import package `cli` (laptop-shaped resolveContext/CloudClient);
  it reuses `cloud.CreateSupportServer`/`ConfigureSupportHost`/`SupportRunner` (free — the
  provisioner already imports `internal/cli/cloud`) and REIMPLEMENTS bind/dataset/runtime/online
  in `internal/provisioner/support.go` from claim-payload credentials.
- **PDF-D84 — SUPPORT STEPS FIT THE EXISTING ENUM; the console gets a parallel table.** The
  support job emits ONLY `create → configure → content → verify → ready` (freshen/secure never
  emitted; `@steps` unchanged — validate_step 422s anything else). Console-side, a support job
  must NEVER render through SERVER_STEP_ORDER: its required `secure` row would hang forever
  (verified — only freshen/content are optional). The SPA adds an additive `SUPPORT_STEP_ORDER`
  (5 steps) + kind-aware labels selected where `bp.fleet_role === "support"`; SERVER_STEP_ORDER
  stays byte-identical (3 test sites byte-lock it).
- **PDF-D85 — READ-SIDE KIND FILTER WIDENS; SSE transport untouched.**
  `latest_provision_status_map/1` hard-filters `j.kind == "provision"` (registry.ex:1880) — a
  support job's steps would be silently absent from GET /v1/barkparks. Widen to
  `j.kind in ["provision", "provision_support"]`. The SSE layer needs ZERO change: broadcast is
  a coarse team-wide kind-blind tick and POST /v1/fleet/supports already fires
  `push_event(team, "fleet")` (proven). No new event type (closed vocabulary raises).
- **PDF-D86 — SUPPORTS ARE QUOTA-EXEMPT (deliberate exception to the un-bypassable backstop).**
  The trial ceiling (1) is saturated by the main, so the stranger 403s at add-support
  (router.ex:1887 — proven). Bumping LIMIT_TRIAL is REJECTED: it is role-blind (admits a 2nd
  MAIN), and the env knob is UNREACHABLE in prod anyway (docker-compose passthrough lists no
  LIMIT_* key — a silent no-op, filed as backlog). Instead `register_support_barkpark/2` skips
  `Billing.barkpark_limit_reached?` for `fleet_role:"support"` inserts — a NAMED, documented
  exception: both docstrings ("un-bypassable backstop", "counts ALL instances") are rewritten in
  the same commit, and a NEW test pins the target behavior (subscribed trial team + 1 main at
  ceiling → add-support SUCCEEDS; a 2nd main still 403s). The quota branch of
  register_support_barkpark is untested today — the test is mandatory, not optional. Supersedes
  the count when PDF-D10's per-support billing ships.
- **PDF-D87 — OFFLOAD DATA PLANE = APP-TOKEN-DIRECT (#6007); the catalog proxy is NOT extended.**
  CORS is RESOLVED in app-token-direct's favor: DatasetCors runs endpoint-level and
  `https://barkpark.cloud` is always-allowed on EVERY instance route (live-proven: OPTIONS 204 +
  authed GET with ACAO on guerrilla). A `[read,write,chat]` member token passes the ENTIRE order
  lifecycle: create rides the `write` gate (mutate), claim/next/close/pulse/roster ride
  `:token_root` (any valid bearer — verified plug-by-plug + pinning tests). `task.create` as a
  catalog row is REJECTED: the proxy forwards bodies VERBATIM under the instance's full admin
  token — arbitrary-mutation over-privilege. The browser mints its member token via the shipped
  `POST /v1/barkparks/:id/app-token` and talks straight to the main.
- **PDF-D88 — D62 STANDS; the model key is a VISIBLE NAMED STEP, not a hidden afterthought.**
  A keyless order can NEVER execute: every order is an LLM turn (`agent_exec` → `claude -p` /
  `codex exec`) and the provisioner deliberately never writes provider keys (D62, proven in code
  + systemd unit). The wish's literal clause — "no local HETZNER token" — is fully satisfied; the
  model key is the developer's own BY DESIGN. The add-support UI renders the key hand-off as an
  explicit journey step (the exact SSH one-liner, copy button, "bring your own model key" copy);
  the proof PRE-SEEDS the key on the box as a NAMED rung. Console-managed key custody (CP writes
  the key server-side) = backlog behind an explicit owner sign-off to amend D62.
- **PDF-D89 — ONLINE TRUTH: the job's last step ports the roster poll server-side.** The roster
  lives on the MAIN (beats go box→main directly; the CP is not in the data path). The
  `provision_support` job's `verify` step polls `GET {main}/v1/fleet/roster` (Bearer = the main's
  admin token; roster is `:token_root`) until the listener row reads idle|working|blocked with a
  non-empty capacity map — exactly stepOnline's proven client-side loop, re-hosted. Timeout →
  `fail_job` (terminal, honest — PDF-D10: stuck-provisioning renders honestly and never bills).
  UI "Online" = `status != "offline"` DERIVED — no literal "online" string exists in the vocab.
- **PDF-D90 — R3 HARNESS FOLDED, NOT LANDED-FIRST.** The stranded harness (6c24833a4,
  `scripts/pdf-support-proof.sh`, 1590 lines) rebases clean (0 conflicts) but is UNFIRED (0/8
  criteria) and its charter-custody recipe cites phantom commits — landing it alone closes
  nothing. This wave's proof slice EXTRACTS the file (`git show 6c24833a4:scripts/…`), inherits
  its dialect (PASS/ABORT/FAIL ladder, --plan, negctl, census), and extends it into the
  browser-journey proof. `pdf-wc-support-proof` is annotated superseded-by-fold. External dep,
  hands off: task-2452b8d24005429e + PR #6038 (CP deploy filter misses internal/+cmd/ — the
  provisioner binary does NOT auto-redeploy until it merges) are ACTIVELY held by
  fable-r3-live-fire; the proof's R0 asserts #6038 merged + provisioner redeployed.
- **PDF-D91 — CUSTODY CLOSED BY TRANSCRIPTION AT DECIDE.** D55-D75 transcribed into this file
  from the Papers (this commit); D76-D82 declared void (see above). Rule forward (D49 extended):
  a charter edit is real only when it is on origin/main — commit AND push in the same session.
- **PDF-D92 — MINIMAL GROUP NESTING IS THE FLEET CARD ITSELF.** "Group = two rows and a
  parent_id" renders as support rows nested under their main in the fleet card / instance page
  (barkpark_json already exposes fleet_role + fleet_parent_id — verified router.ex:7723). No
  separate Screen 4 slice; a full group view is backlog. One SPA slice per region under
  OC9/D13/GR merge-train law: fleet-card+add-support = ONE slice; offload = a SECOND slice
  sequenced AFTER it merges (same-file train).
- **PDF-D93 — VERIFIER-CONTRADICTION RULING (spot-checked at Decide).** The
  main-admin-token-scope verifier's claim that `reveal_admin_token`/`admin_token_encrypted`/
  `mint_app_token` "do not exist in-tree" was a MIS-SCOPED GREP — all three exist and are proven
  live (registry.ex:1328/2486/2661; mint_app_token + mint_studio_link both decrypt-and-Bearer to
  the instance). The CP custody chain for the parent main's admin token is REAL and is the
  credential spine of the provision_support claim payload. Its auth SCOPE is green: the admin
  token passes all four main-side calls (export require_admin, mutate require_write,
  support-token mint require_admin, roster token_root) — verified route-by-route with pinning
  tests.

## Roadmap (waves; interleaved with MVP stages per the build plan)

- **Wave A — Presence & roster** (FIRST): `listener` presence record (worker · status · scope ·
  capacity · last_seen · ttl) + heartbeat in listener skill/runner + `bp fleet roster` (+
  console-readable). Proof: kill a listener → OFFLINE exactly at TTL.
- **Wave B — Efficiency loop** (round 1 MERGED #5685-#5690; round 2 CLOSING 2026-07-23):
  measured capacity heartbeats feed route.py live; cap halts dispatch. Decisions PDF-D34..D54;
  proof `pdf-efficiency-proof.sh` (R0-R7 + negctl) is the wave's seal — its merged transcript
  stamps epic criterion 2. Next after seal: MVP-0, then Wave C.
- **Wave C — Cloud add-support, one action** (CODE SHIPPED 2026-07-23: #5930 mint/revoke, #5932
  support add, #5933 group columns/CP endpoints, #5973 remove+census — CLI-driven, local creds;
  decisions D55-D75 reconstructed 2026-07-24, D76-D82 void; r3 live-fire harness folded into
  MVP-0's proof per PDF-D90).
- **MVP-0 — Visual setup + first offload** (IN FLIGHT 2026-07-24: the console journey
  create-main → add-support → offload, CP-provisioned server-side — decisions PDF-D83..D93;
  wave Paper `personal-dev-fleet-wave-mvp0-2026-07-24`).
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
- **2026-07-22 · Wave B round-1 REVIEW (grade A−).** All 5 round-1 slices built green and were
  adversarially re-verified; TWO cross-slice defects — both in the cap-brake path, both invisible
  to each slice's own gate — were found and FIXED in review. (1) `measure_budget` emitted a
  NEGATIVE budget once spend passed the cap; the server's own PDF-D34 contract 422s a negative
  budget and the beat's `|| true` swallowed it — the listener flipped OFFLINE silently at the
  exact moment the cap tripped. Budget now FLOORS at 0 (the protocol's already-documented word;
  0 and negative route identically). Fix on `loop-epic/the-runner-measures-size-class-from-real-1-r`.
  (2) dispatch.sh's cap gate summed a `usd` ledger key that NOTHING writes — PDF-D37's one-row
  format and `record_spend` both spell it `cost_usd` — so every canonical row would have tripped
  the malformed-row ABORT: a permanently stalled brake. Now reads `cost_usd`, skips honest
  `null` rows (matching `measure_budget`), still aborts 12 on a missing key / non-numeric value;
  proven by drill (freeze at $12.25≥$10 with a null row skipped, in-place ledger-zero lifts the
  freeze, garbage AND legacy-`usd` rows abort named). Fix on
  `loop-epic/live-dispatch-glue-roster-transform-rout-2-r`. Re-verified UNCHANGED:
  `pdf-wb-capacity-contract` (24/0; neutering put_capacity's map clause reds exactly 4),
  `pdf-bl-listener-egress-guard` (31/0; stripping forward_event?'s listener clause reds 2),
  `pdf-wb-charter-landing` (byte-identical to 8e6519dd3 at c1d966c08; this REVIEW entry is a
  follow-up commit on its `-r` branch). NOTHING pushed — the LEAD merges the final branches
  (`-r` where fixes exist, originals otherwise), closes the merge-gated criteria, deletes
  `pdf-r2-wave-log` (PDF-D44b), then dispatches round-2 `pdf-wb-efficiency-proof` (its merged
  transcript stamps epic criterion 2 per PDF-D33). Ledger audit: clean — every builder stamped
  mid-claim with evidence, left lifecycle honest, merge-gated criteria open; the round-2 proof
  task sits open/unclaimed as designed. Wave Paper closed as the debrief:
  `personal-dev-fleet-wave-b-2026-07-22`.
- **2026-07-23 · Wave B round-2 DECIDE (close the wave).** 11 survey lanes + 6 verify lanes, all
  executed live: the full dispatch pipeline dry-run passed every fixture variation (R2-R7
  mechanics proven pre-build), the guerrilla egress verify PASSED 5 legs, the reopen/stamp
  recipe was proven end-to-end (the third path — stage → re-claim SAME worker → stamp → close;
  both briefed paths refuted), the budget-clamp defect ruled ALREADY FIXED via squash 89afdd479,
  and the fresh-binary beat smoke closed the provenance caveat. Decisions PDF-D46..D54.
  EXECUTED AT DECIDE: round-1 ledger repaired — `pdf-wb-capacity-contract`,
  `pdf-wb-edge-measurement`, `pdf-wb-dispatch-glue`, `pdf-bl-listener-egress-guard` (live-verify
  + merge evidence), `pdf-wb-charter-landing` (verify probe) all now genuinely done. Wave =
  5 slices: `pdf-wb-efficiency-proof` (r1, fable, the R0-R7 + negctl proof, transcript
  committed) · `pdf-bl-worker-protocol-paper-sync` (r1, opus, 2-block Paper fix) ·
  `pdf-bl-file-order-env-override` (r1, opus, shrunk env-fallback diff) ·
  `pdf-wb-epic-crit2-stamp` (r2 AFTER proof merges, opus, PDF-D33 recipe on epic criterion 2) ·
  `pdf-bl-presence-honesty-sparse` (r2 AFTER proof merges, opus, AC1 from the transcript's live
  roster read per PDF-D53). Net-new backlog: `pdf-bl-listener-status-schema-drift`,
  `pdf-bl-doctor-bp-staleness-regex`. Honestly open: adapter-rate-card (remote leg only),
  scratch-orphan-janitor. Wave Paper: `personal-dev-fleet-wave-b-2026-07-22-r2`.
- **2026-07-23 · Wave B round-2 REVIEW (grade A).** All 3 round-1 slices green and adversarially
  re-verified; ZERO code fixes needed — the review's only commit is this log entry.
  `pdf-wb-efficiency-proof`: the full gate (--plan + full run + --negctl + transcript non-empty)
  was independently re-run cold in the review worktree — 9/9 PASS + negctl 5/5, exit 0; the
  committed transcript is a genuine earlier passing run of the same script (run-ids differ from
  the gate re-runs by design; content matches the asserts line for line, token-scanned clean).
  All D54 pins honored verbatim; dispatch.sh/route.py/transform.py byte-untouched; the charter
  content-copy (D46-D54 + round-2 wave log) is faithful to 7df6c9aeb. Final branch
  `loop-epic/the-proof-that-must-fire-r0-r7-efficienc-0-r` (this entry only).
  `pdf-bl-worker-protocol-paper-sync`: no branch (live Paper patch, rev 4fbf224fce9e9cf2);
  gate re-run CLEAN against the published paper; task correctly closed done (nothing to merge).
  `pdf-bl-file-order-env-override`: final branch
  `loop-epic/file-order-sh-honors-bp-fleet-server-bp--2` UNCHANGED — the 7/4-line diff is
  exactly the briefed shape; gate re-proven (OVERRIDE-HONORED); the `-s`→`-sS` curl change is
  load-bearing for the gate and byte-identical on the happy path. Ledger audit: CLEAN — every
  builder claimed, stamped mid-work with evidence, left lifecycle truthful (proof + env-override
  in_progress with only merge-gated criteria open; paper-sync done); round-2 stamp tasks
  (`pdf-wb-epic-crit2-stamp`, `pdf-bl-presence-honesty-sparse`) sit open/unclaimed as designed.
  LEAD's merge order: (1) merge the proof `-r` branch (carries charter D46-D54 — close its
  criterion 5), (2) merge the env-override branch (skills-only, own gate — close both criteria +
  lifecycle), (3) THEN dispatch `pdf-wb-epic-crit2-stamp` (PDF-D33 recipe, epic criterion 2 from
  the merged transcript) and `pdf-bl-presence-honesty-sparse` (AC1 from the transcript's RAW
  roster GET per PDF-D53). Note for a future wave: the proof's inline-curl filing predates the
  env-override seam — a later simplification could point file-order.sh at scratch via
  BP_FLEET_*, but D42's inline-curl pin stands for this transcript. Wave Paper closed as the
  debrief: `personal-dev-fleet-wave-b-2026-07-22-r2`.
- **2026-07-24 · MVP-0 DECIDE (the console journey — invert the provisioning).** 16 survey lanes
  + 10 verify lanes; three direction corrections absorbed on evidence: (1) "already-shipped
  worker reusing the exact chain" overstated — bind/dataset/runtime/online are laptop-shaped CLI
  code needing a precedented reimplementation in `internal/provisioner/support.go`; (2) "trial
  keeps the journey walkable" was FALSE — the trial ceiling 403s add-support (fixed by the D86
  quota exception, never Stripe); (3) D82 custody was impossible verbatim — every cited landing
  commit is a phantom; D55-D75 transcribed at Decide, D76-D82 void. Also ruled: app-token-direct
  wins the offload data plane (CORS live-proven, catalog task.create = over-privilege, D87);
  keyless order execution is structurally impossible → D62 stands with the model key as a
  visible named step (D88); the r3 harness is folded, not landed-first (D90). Decisions
  PDF-D83..D93. Wave = 5 slices: `pdf-mvp0-cp-support-job` (r1, opus, cloud/** kind + quota
  exception + provision mode + claim json) · `pdf-mvp0-provisioner-support` (r1, fable,
  internal/provisioner support chain re-host, HIGH-FLIP-RISK credential custody) ·
  `pdf-mvp0-fleet-card-spa` (r1, fable, fleet card + add-support flow + SUPPORT_STEP_ORDER,
  one OC9 slice) · `pdf-mvp0-offload-spa` (r2 AFTER fleet-card merges, opus, order file + watch
  via app-token-direct) · `pdf-mvp0-journey-proof` (r2 AFTER all four merge, fable, the
  browser-journey proof-that-must-fire inheriting the folded r3 dialect). Backlog filed
  (published ids, Decide close 2026-07-24): `pdf-bl-console-key-custody` (D62 amendment,
  owner-sign-off gated) · `pdf-bl-support-remove-serverside` · `pdf-bl-catalog-generalization` ·
  `pdf-bl-limit-env-passthrough` · `pdf-bl-nonadmin-task-tests` · `pdf-bl-fleet-group-view`.
  Also at Decide close: `pdf-wc-support-proof` annotated SUPERSEDED-BY-FOLD (per D90 — its
  dialect lives on via `git show 6c24833a4:scripts/pdf-support-proof.sh`, reachable from any
  worktree of this repo); the epic heartbeat reads building; the wave Paper carries the full
  verification digest + decisions + plan. Wave Paper: `personal-dev-fleet-wave-mvp0-2026-07-24`.
- **2026-07-24 · MVP-0 round-1 REVIEW (grade A−).** All 3 round-1 slices built; the two green
  ones adversarially re-verified and fixed in place; the CP slice's gate is CI-bound (no local
  BEAM) and its ledger says so honestly. THE find: the Go↔CP claim envelope MISMATCHED — the CP's
  `support_provision_claim_json` reuses the FLAT `claim_json` dialect (`job_id`/`claim_token`
  top-level) while the Go slice decoded only the PDF-D83 nested pin (`job:{id,claim_token}`);
  strictly decoded, every claim would have failed "missing job.id" and the halves would never
  meet. FIXED Go-side: `claimSupport` now tolerates BOTH dialects (nested first, flat fallback),
  end-to-end test pins the flat drain (`loop-epic/provisioner-worker-executes-provision-su-1-r`,
  fcb309166). SPA fixes (`loop-epic/console-fleet-card-add-support-flow-supp-2-r`, 949e9efdc):
  the add-support name is now fenced in the modal to the provisioner's DNS-label shape (an
  off-shape name would queue, spin, and fail minutes later at `validateSupportSpec`), and the
  presence-slot lookup is attribute-scan (no throwable interpolated selector). SPA↔CP contract
  CROSS-CHECKED GREEN: the CP reads `barkpark_id` (parent_id alias) and answers 202. Re-derived
  independently (HIGH-FLIP-RISK custody): parent admin token is header-only, redaction-registered
  from line zero, claim/mint bodies withheld from errors — holds; note the step-report path
  bypasses console redaction and relies on message discipline (a genuinely independent second
  reviewer is warranted before merge per the flip-risk protocol). TWO CP-side defects for the
  lead, NOT fixable on a green slice: (1) `reap_stale_provision_jobs` is KIND-BLIND at 12 min
  default while the support chain legitimately runs to 30 (verify budget alone is 10) — a healthy
  support job gets re-pended mid-flight; the CP needs a per-kind stale threshold ≥ 30 min for
  `provision_support`. (2) The CP claim map sends the row NAME as `support.name`; the SPA fence
  makes name==slug for new rows, but the CP should send the SLUG for defense in depth. Merge
  order: CP branch (CI green first — its gate never ran) → provisioner `-r` → SPA `-r`; then
  dispatch round-2 `pdf-mvp0-offload-spa` (after the SPA train merges) and
  `pdf-mvp0-journey-proof` (after all four + deploy + #6038; closes epic criterion 1 per D33/D90).
