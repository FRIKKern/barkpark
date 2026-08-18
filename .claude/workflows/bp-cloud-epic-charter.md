# create-barkpark-app + codegen correctness epic — charter

Epic task: `create-app-codegen-correctness-audit` (task-e9e8867d672b9acf) · wave Paper: `create-app-codegen-correctness-wave-2026-08-18`

## Vision

The two Node surfaces a user runs on their own machine — `npx create-barkpark-app` and the
`barkpark generate` codegen CLI — must never hang without a diagnostic, never leave a
half-written project that blocks the retry, never emit a package manifest npm rejects, and
never die with an opaque `TypeError` on an edge-case schema. This epic is an
improvement-only, evidence-first correctness ledger over `js/packages/create-barkpark-app/src`
and `js/packages/codegen/src`: every candidate is either a REAL bug carrying the concrete
input that breaks it and a test that reds without the fix, or a SAFE pattern cited by the
guard that makes it safe. The honest per-class count — stated even where it is zero — is the
deliverable, not a fix quota.

## Decisions

- **D1. Verdict-first ledger, not a bug bounty.** The surface is unusually well-hardened
  (dir-emptiness check, name normalisation via `path.basename`, `literal()` C0 escaping,
  `propName()` quoting, zero-option select degradation are all present AND tested). Manufacturing
  fixes on guarded paths is forbidden; a SAFE verdict must cite the guard.
- **D2. The crown is codegen's missing fetch timeout.** `grep -rnE 'AbortSignal|timeout|setTimeout|AbortController' js/packages/codegen/src` returns zero on origin/main; `doFetch(url,{headers})` carries no `signal`. Proven RED against a real local server: headers-stall and body-stall both PENDING at 2500ms.
- **D3. One `AbortSignal.timeout` covers headers AND body — no per-phase deadline.** Measured: ARM C (headers 200, `res.json()` never settles) rejected at 804ms. The sibling `jscc-backlog-stalled-body-timeout` finding does NOT transfer: core's gap is a `clearTimeout` at `transport.ts:439` firing before the body read, a mechanism `AbortSignal.timeout` does not have.
- **D4. Add a `withDeadline` race anyway.** The signal is advisory to an injected `fetchImpl`; ARM A/E stayed PENDING with the signal alone and all five arms rejected with the race. `fetchImpl` is a public documented option, and the race also makes the fix engine-independent across the declared `node>=20` floor. The `!res.ok` best-effort `res.text()` read must be wrapped too — it was still PENDING otherwise.
- **D5. Mirror `core/transport.ts:358` vocabulary: 30s read default, `0` disables.** Two packages should read as one system, and a slow-link user needs an escape hatch.
- **D6. Do NOT claim "hangs indefinitely".** On the `node>=20` floor global fetch is undici with documented header/body defaults; the verifier's probes bounded at 2.5s and never measured a 300s ceiling. The honest claim is "a stalled server stalls `barkpark generate` for minutes with no diagnostic, and forever against any injected `fetchImpl`".
- **D7. Codegen crash guards go in the MAPPER, not in zod.** A `.min(1)` on the schema name changes the error text of both CLI paths and risks the committed drift fixture; a mapper-side guard is local and matches the existing loud, locatable composite error.
- **D8. Widen the existing nameless-composite guard, never add a second error path.** `typeof sub.name` at `generate.ts:174` dereferences before it decides, so `fields:[{name:'a'},null]` re-raises the exact opaque `TypeError: Cannot read properties of null (reading 'name')` that guard was written to eliminate — reachable end-to-end (`node dist/cli.mjs generate --from …` exit 1) because zod's `.passthrough()` never validates a composite's nested `fields`.
- **D9. An empty schema name FAILS LOUD, it is not sanitised.** `pascalCase('')` is `''` and zod's `name: z.string()` has no `.min(1)`, so `schemas:[{name:''}]` emits `export interface  extends …` and dies in prettier at 48:1. Inventing an interface name would silently produce a type nobody asked for.
- **D10. `--watch` is a false success, not a no-op — fix it with a monotonic counter.** The watcher fires and re-hits the network with the STALE dataset, printing `Re-wrote <old path>`. mtime is sub-ms on APFS but 1-second-granularity filesystems would silently miss same-tick saves; a counter is uniform.
- **D11. Scaffold cleanup must record `existedBefore` and lstat the path.** The naive one-line `fs.rm(targetDir,{recursive:true,force:true})` was proven to unlink a user's SYMLINK and leave the 4 partial files inside the real directory, and to delete a pre-existing empty dir the user created. Empty the entries in those cases; remove the path only when this run created it.
- **D12. `ensureTargetEmpty` and the cleanup move into an exported module.** `index.ts` runs `main(process.argv)` at import and exports nothing, so a test of a COPIED guard proves the replica, not the shipped code.
- **D13. Reserved npm names are a REAL error; the 214-char cap is hardening.** `validate-npm-package-name@7.0.2` returns `validForOldPackages:false` for `node_modules` and `favicon.ico`, and `yarn install` exits 1 with `Name is blacklisted` (npm/pnpm/bun exit 0). A 300-char name is only a WARNING everywhere, including publish. Core-module names and `test` are valid — the blacklist is exactly two names.
- **D14. No `validate-npm-package-name` dependency.** Pulling a package in to reject two literals is worse than the bug; the fix is a two-name guard plus a length clamp inside `toPackageName`.
- **D15. Locale determinism FILES, it does not build.** The comparator regimes really do disagree on the committed fixture (2 of 81 name lists), but NO locale reproduces it — five env locales and seven explicit locales all produce the byte-identical committed artifact. The code-unit variant forces a 52-line regen of `web/lib/barkpark.types.ts`, which is OUTSIDE this epic's fence; the fence-safe pinned-`Intl.Collator('en-US')` variant costs zero regen and is the only implementation a future slice may build.
- **D16. The exit-0 install swallow is judgment, not a bug.** The failure is printed twice in yellow with the exact manual command, `didInstall` is threaded into `printNextSteps`, and this matches the create-next-app norm. The git-init swallow is worse (bare `catch {}`, `skipGit` never read, half-initialised `.git` left behind) and is FILED.
- **D17. The wish's "unsanitised path from a project name" premise is REFUTED.** `normalizeProjectName = path.basename(String(raw).trim())`, so `..` is rejected, `/` empties, `../../etc` becomes `etc`. Nothing reaches `path.resolve` carrying traversal.
- **D18. The wish's "copy follows a symlink / crashes on EACCES" premise is SAFE by construction.** The copy source is the package-bundled template tree (`find templates -type l` empty), never user input; EACCES propagates uncaught to exit 1.
- **D19. Builders build first.** A fresh worktree is RED for module-resolution reasons (`dist/cli.mjs` missing; `@barkpark/react` entry unresolved) until `pnpm install` + a build run — a red-first test read against an unbuilt tree is a misread.
- **D20. Fence: `js/packages/create-barkpark-app/src` + `js/packages/codegen/src` + their test trees + one named changeset per slice.** No `templates/` (the sibling web-templates wave owns them), no `web/`, `api/`, `cloud/`, `js/packages/core`, `js/packages/react`. Disjoint from the media (`api/lib/barkpark/media`) and controller+plug (`api/lib/barkpark_web`) waves by tree.

## Roadmap

### Wave 1 (this wave) — the five proven REAL findings, all round 1, all Opus

| # | Slice | Task | Surface | Size |
|---|---|---|---|---|
| 1 | Bound every codegen fetch: signal + `withDeadline`, 30s default, `0` disables | `cca-w1-codegen-fetch-timeout` | `codegen/src/fetch-schema.ts` | medium |
| 2 | Fail loud on a null composite sub-field and on an empty schema name | `cca-w1-codegen-mapper-guards` | `codegen/src/generate.ts` | small |
| 3 | `--watch` reloads the config (monotonic cache-bust) | `cca-w1-codegen-watch-reload` | `codegen/src/cli.ts` | small |
| 4 | Partial scaffold no longer poisons the retry (HIGH-FLIP) | `cca-w1-scaffold-cleanup` | `create-barkpark-app/src/index.ts` + new `target-dir.ts` | medium |
| 5 | `toPackageName` rejects the two npm-blacklisted names, clamps at 214 | `cca-w1-package-name-guard` | `create-barkpark-app/src/scaffold.ts` | small |

### Filed for later waves (backlog, not this wave)

`.ts` config advertised with no loader (broken on the Node 20 floor) · pinned-collator determinism
(D15) · `prettier.resolveConfig(process.cwd())` making output cwd-dependent · git-init silent
failure + half-initialised `.git` · `applyHostedDemo` stranding a complete tree · CLI/env plumbing
for `timeoutMs` · install-failure exit code · duplicate schema names / `_type` / `_id` emitting
invalid-but-loud TS · interactive validator checking the raw name instead of the normalised one.

## Wave log

_(empty — the lead appends one line per merged wave)_
