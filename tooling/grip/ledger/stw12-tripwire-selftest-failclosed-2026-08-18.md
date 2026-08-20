# stw12 — three tripwires fail-closed (selftest + exit-code re-derivation)

Wave 12 verifier [v2-arm-tripwires-selftest]. Proves the three search-template tripwire
scripts on origin/main (`a6535504`) are mutation-provably fail-closed BEFORE arming into CI.

## Re-run (from repo root)

```
node scripts/check-vendor-blocks.mjs --selftest ; echo vendor=$?          # -> 16/16 passed, vendor=0
bash scripts/templates-literal-check.sh --selftest ; echo literal=$?      # -> 17 cases PASS, literal=0
node tooling/doc-truth/verify-bp-commands.mjs --selftest ; echo cmds=$?   # -> 25/25 passed, cmds=0
```

Each --selftest is self-mutating: it runs the negative half (a planted violation that MUST red)
alongside the positive half, so exit 0 == "the fabricated-bad input DID red." Examples that carry
the fail-closed contract inside each suite:
- vendor:  "engineVerdict FAILS a floor below what the lock requires" / "probe NAMES unknown-boxed types"
- literal: "re-adding ONE text-zinc-400 to it reds (1 hit, got 1)" / "a planted focus ring is caught"
- cmds:    "MUTATION: without E, `bp login --device` is UNPROVEN" / "unknown head is UNRESOLVED, not skipped"

## verify-bp-commands exit-code table (RUN, not read)

Targets are join(REPO_ROOT, rel) — path.join CONCATENATES, so pass a repo-RELATIVE path
(absolute paths become REPO_ROOT/Volumes/... and 404). Fixtures live in the session scratchpad,
reached via `../../dev-caches/.../scratchpad/`.

| input | verdict | exit |
|---|---|---|
| doc with `bp frobnicate the-widget --nonsense` | UNRESOLVED, "head frobnicate resolves in NO source", VERDICT: FAIL | 1 |
| doc with `bp task ready` | parses | 0 |
| missing target file | sources.ok=false, "target not found" | 2 |
| `--offline` on a non-templates/** target | refused ("accepted only when every target is under templates/**") | 2 |
| no doc args | usage banner | 2 |

Exit law (main(), verify-bp-commands.mjs:361-363): sources.ok false -> 2 ; unresolved>0 -> 1 ; else 0.

## Verdict

All three scripts are fail-closed and mutation-proven on main. Arming them into CI (the D-slice)
is safe against this axis — the contract "red on unproven" holds. Live-catalog / server-touching
criteria are NOT exercised here (offline only) and remain merge-gated for the lead.
