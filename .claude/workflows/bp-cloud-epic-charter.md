# Noo-Noo Disk Guardian (epic-cycle charter slot)

> NOTE ON THIS PATH: this filename is the rotating epic-cycle charter SLOT and has carried
> earlier epics. The prior occupant — **Felix Pristine** — is preserved verbatim at
> `.claude/workflows/bp-felix-pristine-charter.md`. Do NOT read this file for Felix history.
> This slot is now the memory of the **Noo-Noo Disk Guardian** epic.
>
> Epic anchor: bp task **`noo-noo-disk-guardian-epic`** (published, guerrilla).
> Wave Paper: **`noo-noo-disk-guardian-wave-2026-07-15`** (style=article).
> WORKING REPO for all build slices: **`/Volumes/SATECHI/github/noo-noo`** (github.com/FRIKKern/noo-noo,
> Go daemon `noo-nood` + CLI `noo-noo` + Wails v3 menubar app) — NOT barkpark. Builders branch
> worktrees off noo-noo `main` (baseline commit `b6b9644`, gates green incl. `-race`).

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
  plan AND apply time. Why: Kompis is mounted with clean-looking metadata yet read-only from
  real APFS corruption (fsck-proven) — presence ≠ usability; the user's own hand-rolled
  Desktop/Documents/Downloads→SATECHI symlinks are the live unguarded-failure precedent
  (dangling-ENOENT proven by simulation).
- **D7 — Kompis is EXCLUDED as an offload target.** Corrupt (fsck: "found to be corrupt and
  needs to be repaired"), read-only, 17.5G of user data at risk — surfaced to the user as its
  own backlog task (repair needs backup + consent). Why: guard evidence, not a target.
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

Wave 2+ (filed as published backlog children of the epic task):
- Daemon leak alerts + notification naming the leak + menubar suggestions submenu wiring
  (`nn-bl-daemon-leak-alerts`).
- Wails webview surfaces: real-vs-du display, offload plan preview (`nn-bl-wails-ui`).
- Auto-relocate behind autoclean-style multi-gate (`nn-bl-auto-relocate-gates`).
- Auto-clean toggle persistence — save callback → TOML write-back (`nn-bl-toggle-persist`).
- Volume health check + surface Kompis corruption to the user (`nn-bl-volume-health`).
- Home-symlink guard remediation for Desktop/Documents/Downloads (`nn-bl-home-symlink-guard`).
- Action-path unification: modules/heuristics/autoclean 3-way split (`nn-bl-action-unify`).
- Store time-series retention/pruning (`nn-bl-store-retention`).
- Snapshot-awareness diagnostic signal (`nn-bl-snapshot-signal`).
- Disable-functionality suggestion class: colima disk cap, Chrome relaunch hygiene
  (`nn-bl-disable-class`).

## Wave log
