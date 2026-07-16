# Noo-Noo Disk Guardian (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant — **Felix Pristine** — is preserved verbatim at
> `.claude/workflows/bp-felix-pristine-charter.md`. Do NOT read this file for Felix history.
> This slot is now the memory of the **Noo-Noo Disk Guardian** epic.
>
> Epic anchor: bp task **`noo-noo-disk-guardian-epic`** (published, guerrilla).
> Wave Papers: wave 1 **`noo-noo-disk-guardian-wave-2026-07-15`**, wave 2
> **`noo-noo-disk-guardian-wave2-2026-07-15`** (both style=article).
> WORKING REPO for all build slices: **`/Volumes/SATECHI/github/noo-noo`** (github.com/FRIKKern/noo-noo,
> Go daemon `noo-nood` + CLI `noo-noo` + Wails v3 menubar app) — NOT barkpark. Builders branch
> worktrees off noo-noo `main` (wave-2 baseline commit `91eb2b5` = wave 1 fully merged;
> gates re-proven green incl. `-race -count=1` at that exact commit).

## Vision

The user's Mac (228G internal, chronically ~15-25G free) never silently fills again — and when
it fills, noo-noo names the culprit with REAL numbers. The founding incident is the doctrine:
65 leaked Chrome `code_sign_clone` dirs du-reported 129G, deleting 64 freed only ~3G, because
they were APFS copy-on-write clones — **naive du is fiction; every suggestion must cite real
reclaimable bytes**. Noo-noo becomes: (1) a truth-sizer (APFS-clone-aware, sparse-aware) that
every module consults; (2) a data-driven leak-signature registry that spots known leak classes
(Chrome clones first, agent-scratch `/private/tmp` second) with safe, evidence-cited,
liveness-checked fixes; (3) a policy-driven offload module that moves bulky-but-loved assets to
the external SATECHI drive behind UUID-pinned, write-probed guards (native app config where it
exists, move+symlink only where it must); (4) a velocity engine that measures per-asset fill
rate (bytes/day) and schedules cleanup proportional to it; (5) honest "cap or disable" advice
where nothing else works. Safety philosophy is inviolable: diagnose by default, destructive
actions gated, every action audited.

## Decisions

- **D1 — Truth-tiering, not truth-everywhere.** Cheap `st_blocks` sizing is the broad default;
  the `F_LOG2PHYS_EXT` extent-union sizer (physical extents keyed by `(st_dev, devoffset)`,
  hand-marshaled 20-byte `#pragma pack(4)` struct) is a scoped precision instrument for
  clone-signature dirs, offload candidates, and drill-downs. Why: live-proven 74ms on 943 files
  but 6.7s on 197k files (~34µs/file) — correct everywhere, affordable only scoped.
- **D2 — `internal/sizer` is THE size seam.** Public API: `Blocks(path)` (st_blocks walk),
  `UniqueAllocated(paths...)` (extent-union across trees, clone- and sparse-aware),
  `FreedByDelete(volPath, fn)` (statfs Bavail before/after = real freed bytes, ground truth for
  audits). `core.DirSize` (sums logical st_size — worse than du) is retired from decision
  paths. Why: the founding 129G→3G ghost reproduced in a controlled `cp -c` pair — du said
  400M, extent-union correctly said 200M; 50M divergence dropped shared to exactly 150M.
- **D3 — Leak signatures are DATA.** Registry entries `{id, path-glob, staleness-check,
  evidence-spec, risk, workaround}`; new signatures are entries, not code. Signature #1:
  `chrome-code-sign-clone` — glob `/private/var/folders/*/*/X/*.code_sign_clone/code_sign_clone.??????`,
  staleness = **lsof-empty** (mtime PROVEN unsafe: a 6-day-old clone was held open by 7 live
  Chrome processes). Signature #2: `private-tmp-agent-scratch` — aged user-owned scratch under
  `/private/tmp` (claude-501, *-gocache*, worktree scratch; 24G today, PROVEN honest distinct
  data, never OS-cleaned). Why: these are the two live refill classes on this machine.
- **D4 — /private/ carve-out is a PARALLEL predicate, never allowlist widening.** Generic
  `Safety.CanDelete` keeps hard-blocking `/private/` (verified: alwaysBlocked at safety.go:38
  wins over caller allowlists by ordering); leak deletes go through a new signature-scoped
  predicate that requires a registry match AND an lsof-empty recheck at apply time. Why: the
  flagship fix must ship an Apply without weakening the general wall.
- **D5 — Offload is per-asset playbooks in three classes.** (a) native-config: pnpm
  (`pnpm config set store-dir /Volumes/SATECHI/.pnpm-store --global` — currently NOT pinned,
  dual-store proven: SATECHI-cwd resolves external, home-cwd grows a second 4.3G internal
  store), colima (`COLIMA_HOME`, hard-gate on `colima stop`), Claude Code
  (`CLAUDE_CONFIG_DIR`, proven in the real binary). (b) relocate move+symlink: LocalWP
  blueprints — digest's delete-class hypothesis **REFUTED**: it is ONE irreplaceable 14.8G
  user Blueprint (Polyflor.zip), docs say deletion is permanent → **NEVER auto-delete**,
  offload-only; Claude `vm_bundles` (10G VM disk). (c) Electron userData: symlink tolerance
  UNVERIFIED on this machine → post-move launch smoke-test gate, no blanket assumption.
  Why: every verdict live-proven this wave; the blueprint refutation alone would have
  destroyed client data.
- **D6 — Volume-guard law: UUID + mount + LIVE write-probe.** Destinations pinned by
  VolumeUUID (`diskutil info -plist`), mount-present checked, and a real write-probe file at
  plan AND apply time. Why: Kompis is mounted with clean-looking plain-text metadata yet
  unwritable — presence ≠ usability; the user's own hand-rolled
  Desktop/Documents/Downloads→SATECHI symlinks are the live unguarded-failure precedent
  (dangling-ENOENT proven by simulation).
- **D7 — Kompis is EXCLUDED as an offload target — and it is HARDWARE write-locked, not
  fsck-repairable (CORRECTED wave 2).** Live proof: `diskutil info -plist` reports
  WritableMedia=false / Writable=false / WritableVolume=false and a live `touch` fails
  "Read-only file system" — the media itself refuses writes. fsck_apfs -n's "found to be
  corrupt and needs to be repaired" is a simulate-mode artifact, unverifiable/unrepairable on
  write-locked media; `diskutil verifyVolume`'s trailing "a repair action has been taken" is
  boilerplate (post-run state unchanged, proven). repairVolume/First Aid CANNOT succeed here —
  the correct playbook is rescue-copy-first (EXECUTED 2026-07-15: 16G rsync'd to SATECHI), then
  hardware diagnosis (SD lock switch / controller RO fault / dying firmware lock). The earlier
  D7/nn-bl-volume-health "corruption + backup-then-repair" framing was the WRONG branch of the
  dichotomy and would have shipped the exact harmful suggestion the volume-health module exists
  to prevent. Why: the discriminator is the WritableMedia plist key — media-RO
  (WritableMedia=false → rescue-copy only, never repair) vs fs-corruption-RO
  (WritableMedia=true, WritableVolume=false → backup-then-repair with consent).
- **D8 — Velocity = light the existing pipeline, no new engine.** Add a `cache_roots` config
  field + thread `scan.Roots{Caches:…}` at the two call sites (main.go:280, tick.go:55);
  time-normalize the heuristic to bytes/day; cadence self-gates inside heuristics riding the
  single-consumer `trig` channel — NO new timer goroutine. Why: a probe test proved one config
  field lights scan→cache_size_history→CacheVelocity end-to-end; the single-consumer channel
  IS the scan-storm guard.
- **D9 — The 0005 audit migration is NOT a blocker; the READ path is the gap.** Verified pivot
  both surveyors missed: `cmd/noo-nood/main.go:366` inlines the DDL at daemon boot, and Apply
  fail-safes (audit pre-row before delete). Real work: fold DDL into schema.sql, implement
  `Record/Update/AutoCleanStatsSince` on `*store.Store`, wire `stats != nil`. Why: the trail is
  write-only today (Status always reports 0), and velocity/leak history build on reading it.
- **D10 — Snapshot ghost CLOSED.** No Time Machine destination, zero snapshots on the Data
  volume — "deleting doesn't free" = clone du-fiction + continuous refill (/private/tmp 24G is
  honest distinct data). Snapshot awareness demoted to a cheap backlog diagnostic. Why:
  disconfirmed by direct enumeration on this machine.
- **D11 — Ride existing seams; defer unification.** Offload = new Op `"relocate"` +
  `Destination` field on `modules.Action`; leak/velocity daemon surfacing rides
  `heuristics.Suggestion`. The verified 3-path split (modules.Action / heuristics.Suggestion /
  autoclean.Action) is real debt but NOT this wave. Why: no single choke point exists;
  unifying first would stall every user-visible win.
- **D12 — Wave gate is the race gate.** `CC=/usr/bin/clang go test -race ./... &&
  CC=/usr/bin/clang go vet ./...` in the noo-noo repo. Why: Makefile's real gate is `-race`;
  plain `go test` would let daemon-concurrency races slip. Baseline green at b6b9644 (~38s).
- **D13 — Sequenced merges within the wave.** sizer → leaks → offload (compile-time dependency
  on `internal/sizer`; shared `internal/cli/report_cmd.go` all-modules slice), and
  audit-ledger → velocity (shared `cmd/noo-nood/main.go` + `tick.go` regions). Why: file-truth
  collisions and import dependencies make parallel merging a conflict factory.
- **D14 — Menubar one-click UX deferred to wave 2.** The suggestions submenu is
  built-but-disconnected (nil passed; "Task 57" never done) and the Wails frontend needs
  wails3+npm toolchain outside the Go gate (proven: no go:embed, no frontend/dist). Why: it's
  its own surface; the CLI ships the capability this wave.

### Wave-2 decisions (all evidence-anchored — verifier proofs in the wave-2 Paper)

- **D15 — RunTick/collectSuggestions is THE daemon insertion point.** `tick.go` `init()`
  rebinds `runTickFn`→`RunTick`; `main.go:275 runScan` is dead legacy kept alive by one test —
  NEVER wire features there (a branch there fires on zero real triggers). TriggerManual/IPC
  trigger-scan is dead too (DaemonService.sched nil). The `actions` table is ORPHANED (its only
  writer, Clean.Execute, has zero production callers) — new persisted state gets NEW tables,
  never `actions`.
- **D16 — Schema-evolution law.** New tables = `CREATE TABLE IF NOT EXISTS` appended to
  schema.sql — zero ceremony, proven against a copy of the LIVE daemon store (282 rows
  preserved, new table writable). NEVER a bare `ALTER TABLE` in schema.sql: migrate() re-execs
  the full file on every Open, so a non-idempotent statement errors on the SECOND daemon start
  and bricks the store. Columns on existing tables are effectively frozen this wave.
- **D17 — SizeBytes is a first-class field on heuristics.Suggestion.** Proven zero-ripple
  additive (all packages green with only the field added). Size survives the store round-trip
  via the evidence_json carry (`size_bytes` in Evidence — no new column, per D16);
  ipc.suggestionFromStored parses it back into the field (also closes the proven string-type
  hole where round-tripped suggestions read size=0). Leak sizes source from
  sizer.UniqueAllocated per D2. Rides D11 (no 3-path unification).
- **D18 — Posture reads are CLI-fresh, not IPC.** Proven: no IPC method exposes a single disk
  number; pressure samples never leave the watcher goroutine; VolGuard is only called in the
  offload gate. `status`/`trends` do statfs + diskutil in-process (sizer's statfs pattern). No
  new IPC methods this wave. The ~5-min pressure cadence is the DESIGNED cooldown operating on
  a machine living at the memory threshold — an honest posture SIGNAL to report, not a bug to
  fix. All forecasting MUST day-bucket (pressure samples dominate the daily tick ~2 orders).
- **D19 — Playbooks template on `{dest_root}`, rendered at read time.** The 3 hardcoded
  `/Volumes/SATECHI` NativeCommand literals become `{dest_root}` templates substituted from
  `m.cfg.DestRoot` where evidence is built (unconfigured → placeholder + existing verdict
  copy). Sub-asset entries are FLAT SIBLING rows (exact-path matching already nests fine);
  what's new is the GATE: a path-scoped gate kind calling an injected `leaks.LsofProbe`
  (import proven cycle-free) instead of pgrep-by-name.
- **D20 — Process signatures are a SIBLING module, never a leaks-registry extension.** Proven:
  leaks machinery is structurally path-shaped (globs/lstat/RemoveAll/CanDeleteLeakTarget — all
  meaningless for a PID). New `internal/procsig` registry-as-data module, new Op `"terminate"`,
  own safety predicate (own-uid only, registry match only, never pid≤1). Composition with the
  clone sweep is by sequencing: kill orphan → clone dirs go lsof-empty → existing signature
  sweeps them.
- **D21 — colima truth.** The disk that fills and kills dockerd is the DATADISK
  (`/var/lib/docker`, `--disk`), NOT `--root-disk` — corrects nn-bl-disable-class's "rootDisk"
  framing. Grow = `colima stop && colima start --disk N`, growth is automatic (resize2fs
  provision runs every boot; proven live 5G→8G on a disposable profile). Generic lima detection
  MUST special-case `LIMA_HOME=$COLIMA_HOME/_lima` — bare `limactl list` sees NO colima VMs
  (proven). Suggest grow only after proving the datadisk's HOST volume has headroom (statfs on
  resolved $COLIMA_HOME).
- **D22 — CLI verb-first flag law.** Every subcommand strips the verb BEFORE flag.Parse
  (autoclean_cmd.go:58 is the reference); five commands (caches/dev/leaks/offload/startup)
  share the proven silent-no-op trap (`caches clean -y` printed 6.5GB then prompted anyway).
  Protective tests exercise the NATURAL verb-then-flags order; e2e_test.go's flags-before-verb
  ordering (the mask) gets a natural-order companion.
- **D23 — b6 reframed and BACKLOGGED.** Offload Apply never uses mv and never loses data
  (discard-on-failure is tested intent); the 13G incident was a manual mv OUTSIDE the tool.
  Resumability is a new capability: chunked-ditto per top-level child (macOS rsync is openrsync
  with NO --acls — wholesale swap would regress ditto's ACL guarantee). Filed as
  `nn-bl-resumable-copy`; the wave slot goes to b4 (deferred-relocation queue).
- **D24 — Deferred relocation queue = new two-phase table.** Modeled on auto_clean_events
  (queued → applied/cancelled/blocked), never the orphaned `actions` table, never the
  append-only JSONL audit (structurally cannot carry state). Daily-trigger-only auto-apply
  behind an autoclean-style multi-gate cascade (master switch default OFF + risk-ack +
  stop-gate re-pass + volguard re-pass + audit before/after); pressure triggers NEVER apply.
- **D25 — Scan roots resolve symlinks.** filepath.WalkDir does not descend a symlinked root
  (proven: ~/Documents/GitHub→SATECHI visits exactly 1 entry, repo_idleness = 0 rows forever,
  100% silent). EvalSymlinks every scan root before walking; symlinked home-relocation is a
  common pattern on exactly the machines noo-noo targets.
- **D26 — Wails stays backlog (a4).** Toolchain PROVEN green (build/vet/race/app-package all
  pass) but frontend/dist is never embedded (no Assets field → blank Settings window) — embed
  is the prerequisite sub-task on `nn-bl-wails-ui`. Wave 2 is CLI-first per the wish's
  "literally see" being satisfiable in the terminal.

## Roadmap

Wave 1 (this wave — 5 slices, integration-ordered):
1. **nn-w1-sizer-truth** (large, fable) — `internal/sizer`: Blocks / UniqueAllocated
   (F_LOG2PHYS_EXT extent-union, (st_dev,devoffset)-keyed) / FreedByDelete (statfs delta).
   Foundation for everything.
2. **nn-w1-audit-ledger** (medium, opus) — auto_clean_events into schema.sql; Store methods;
   stats wired non-nil; inline DDL + orphan 0005 removed. (Parallel with 1 — disjoint files.)
3. **nn-w1-leaks-registry** (large, fable) — `internal/leaks` data-driven registry + scanner +
   CLI; Chrome code_sign_clone signature (lsof staleness) + /private/tmp agent-scratch;
   /private/ parallel safety predicate + protective fail-before test. AFTER sizer merges.
4. **nn-w1-offload-module** (large, fable) — `internal/modules/offload` + Op "relocate" +
   Destination; `internal/core/volguard.go` (UUID/mount/write-probe); per-asset playbooks
   (native-config as evidence-cited suggestions; move+symlink Apply for relocate-class);
   unguarded home-symlink standing-risk detection. AFTER sizer + leaks merge.
5. **nn-w1-velocity-live** (medium, opus) — cache_roots config + thread both call sites;
   bytes/day rate; pressure config dead-wiring fix (runPressureWatcher reads cfg.Pressure).
   AFTER audit-ledger merges.

Wave 2 (8 slices, integration-ordered; the dispatch frontier sequences file collisions —
slices with disjoint files fly in parallel, colliding ones merge in numbered order):
1. **nn-w2-posture-data** (large, opus, p0) — disk_space_history table + core volume inventory
   (WritableMedia discriminator per D7) + statfs total/free primitive + ListSuggestionsSince +
   symlink-root scan fix (D25). Foundation for status/trends.
2. **nn-w2-status-trends** (large, fable, p0) — `noo-noo status` (machine posture, one honest
   statement) + `noo-noo trends` (day-bucketed sparklines, linear forecast, recurrence with
   permanent-remediation copy). AFTER posture-data merges.
3. **nn-w2-cli-flag-trust** (medium, opus, p1) — D22 verb-first fix across 5 commands +
   natural-order protective tests + ShipIt glob cache targets (b9).
4. **nn-w2-playbook-generalize** (medium, opus, p1) — D19: {dest_root} templating + path-gated
   sub-asset sibling entries (b1+b5).
5. **nn-w2-daemon-leak-alerts** (large, fable, p1) — b10 per D15/D17: leaks on tick+pressure,
   leak-named notification with the one fixing command, menubar suggestions wired. Absorbs
   `nn-bl-daemon-leak-alerts`.
6. **nn-w2-orphan-processes** (medium, fable, p1) — b3 per D20: internal/procsig sibling
   module, orphaned headless-browser signatures, Op "terminate".
7. **nn-w2-vm-disk** (medium, opus, p2) — b2 per D21: colima/lima inner-disk fullness detector
   + guarded grow suggestion; status section. AFTER status-trends merges.
8. **nn-w2-relocation-queue** (large, fable, p2) — b4 per D24: two-phase pending-relocation
   queue + `offload pending`/`run-pending` + gated daily-tick re-check. Absorbs
   `nn-bl-auto-relocate-gates`. LAST to merge (touches files of slices 3,4,5).

Backlog (published children of the epic task):
- Resumable multi-GB copy: chunked-ditto resume, D23 (`nn-bl-resumable-copy`, NEW wave 2).
- Dead IPC surface cleanup: ReportFull dead code, Clean.Execute unreachable, TriggerScan
  nil-sched panic (`nn-bl-ipc-dead-surface`, NEW wave 2).
- MemRatio accuracy: vmstat formula excludes speculative/purgeable/compressed pages — biases
  pressure high (`nn-bl-memratio-accuracy`, NEW wave 2).
- Wails webview surfaces (`nn-bl-wails-ui`) — toolchain proven green; go:embed of
  frontend/dist is the prerequisite (D26).
- Auto-clean toggle persistence — save callback → TOML write-back (`nn-bl-toggle-persist`).
- Home-symlink guard remediation for Desktop/Documents/Downloads (`nn-bl-home-symlink-guard`).
- Action-path unification: modules/heuristics/autoclean 3-way split (`nn-bl-action-unify`).
- Store time-series retention/pruning (`nn-bl-store-retention`).
- Snapshot-awareness diagnostic signal (`nn-bl-snapshot-signal`).
- Disable-functionality suggestion class remainder (`nn-bl-disable-class`) — colima portion
  CORRECTED per D21 and absorbed by nn-w2-vm-disk; Chrome workaround surfacing absorbed by
  nn-w2-status-trends recurrence; actions-runner cruft remains.
- ABSORBED into wave-2 slices (superseded, do not build standalone): `nn-bl-daemon-leak-alerts`
  → nn-w2-daemon-leak-alerts; `nn-bl-volume-health` → nn-w2-posture-data + nn-w2-status-trends
  (with D7's corrected diagnosis); `nn-bl-auto-relocate-gates` → nn-w2-relocation-queue.

## Wave log

### Wave 1 — 2026-07-15 (founding wave) — grade A-

**Landed (built + review-hardened; lead merges in this order, all plain merges):**
1. `nn-w1-sizer-truth` → `loop-epic/internal-sizer-apfs-truth-sizing-st-bloc-0` (ac77b84, unchanged
   by review). internal/sizer: Blocks / UniqueAllocated (F_LOG2PHYS_EXT, byte-exact 20-byte pack(4)
   pin) / FreedByDelete. Live discovery beyond the brief: APFS holes do NOT errno — the fcntl
   SUCCEEDS with devoffset=-1 spanning the hole; handled + tested.
2. `nn-w1-audit-ledger` → `loop-epic/auto-clean-audit-trail-readable-auto-cle-1-r` (f0f55fe).
   auto_clean_events single-sourced into schema.sql v2; store owns the row types (aliases dodge the
   import cycle); Status-always-zero bug fixed with a real end-to-end store regression test.
   Review fix: one stale interface doc.
3. `nn-w1-leaks-registry` → `loop-epic/internal-leaks-data-driven-leak-signatur-2-r` (0e93232,
   stacked on sizer). Data-driven registry (Chrome code_sign_clone lsof-only; /private/tmp scratch
   aged+lsof), fail-safe probe, apply-time TOCTOU re-check, generic CanDelete wall untouched.
   Review fixes: categorical leak wall CASE-FOLDED (APFS is case-insensitive — `/library/*` reached
   real /Library past the case-sensitive check), /private/etc/ added to the wall, `leaks` listed in
   CLI usage; all pinned in safety_probe_test.go.
4. `nn-w1-offload-module` → `loop-epic/internal-modules-offload-playbook-driven-3-r` (6365f5a;
   contains sizer + leaks-r merges so the train is conflict-free). Volguard (UUID + live
   write-probe), playbooks-as-data, copy→verify→swap→symlink→verify→drop-bak with restore,
   NeverDelete structural. Review fix: the SizeFns seam now DEFAULTS to sizer.UniqueAllocated —
   the clone-blind st_blocks fallback would have made "really reclaimable" a du-fiction in the
   epic's own newest module.

Integration proof: all four merged onto b6b9644 in order = zero conflicts, `go test -race` + vet
green. Live host smoke (diagnose-only): leaks names the surviving Chrome clone LIVE with lsof
proof + du-fiction delta; offload scan reports pnpm 4.3G/colima 13G/.claude 8.3G/blueprints
14.8G/vm_bundles 10G with exact native commands + flags the unguarded Desktop/Documents/Downloads
symlinks.

**Stalled:** `nn-w1-velocity-live` — 0 commits, honestly held in_progress. Its brief required
branching after two siblings were ON MAIN, impossible mid-wave. Correct worker behavior; a
dispatch-design flaw (merge-dependent slices belong to the NEXT wave by construction).

**Ledger:** cleanest audited to date — zero fixes; all built slices in_progress with only
merge-gate criteria open, every met criterion evidence-stamped, velocity's stall stamped with
misses + handoff.

**Next wave takes:** (1) lead merge train + close the five merge-gate criteria; (2) re-dispatch
velocity-live immediately after; (3) make offload REAL for the user — pin SATECHI
(UUID 0DBD1B63-0377-450B-A340-7E72D0925EBC) in [offload], run the 3 native-config relocations
(~25G) + 2 guarded relocates (~25G) — this is the wish's actual space relief; (4)
nn-bl-daemon-leak-alerts; then nn-bl-home-symlink-guard / nn-bl-volume-health (Kompis data risk).
[Wave-1 postscript: merge train COMPLETE — all five w1 tasks closed done, main at 91eb2b5,
v0.5.0 installed as launchd daemon io.noo-noo.d on the reference machine.]

### Wave 2 — 2026-07-15/16 — IN FLIGHT (Decide complete, builders dispatched)

Mandate: two pillars — (A) visibility & foresight (`status`/`trends`, recurrence, machine
posture) and (B) generalize every 2026-07-15 manual smart into machine-agnostic product
(b1-b10). 16 surveyors + 8 deep verifiers ran; all load-bearing claims proven with run output
(see the wave-2 Paper `noo-noo-disk-guardian-wave2-2026-07-15` for the proof lines). Decisions
D15-D26 above are this wave's law. 8 slices filed (see Roadmap); 3 new backlog children filed
(resumable-copy, ipc-dead-surface, memratio-accuracy); 3 nn-bl children absorbed/superseded;
nn-bl-volume-health's wrong "backup-then-repair" text corrected per D7. Baseline 91eb2b5
re-proven green (`-race -count=1` + vet). Review closes this entry with the debrief.
