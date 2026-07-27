<!-- doc-tier: human | canonical-for: scaffy-duels-caps-fixtures | budget: 1500tok -->

# Capabilities-manifest fixtures (ctx-compression epic)

Frozen before/after pair for the born-brief `bp capabilities` projection
(BRIEF-KEEP-LIST v1, task `ctx-s1-brief-manifest`, charter
`.claude/workflows/bp-ctx-compression-charter.md` decisions 3–9). These are the
duel/token-calibration corpus for `ctx-s5-count-tokens` and the wave-2 paired
duel (`ctx-b1-paired-duel`) — byte sizes here are BYTES, not tokens, until a
`count_tokens` run converts them.

| File | What | Size |
|---|---|---|
| `caps-full-2026-07-24.json`  | full manifest, 142 commands, admin tier | 95,915 B |
| `caps-brief-2026-07-24.json` | BRIEF-KEEP-LIST v1 projection of the same manifest | 26,502 B (3.62x, 27.6%) |

## Regen (recorded commands)

Both captured 2026-07-24 against `https://guerrilla.barkpark.cloud`
(admin-tier token, 142 commands). To regenerate against a live server with a
current `bp` build:

```bash
go build -o bp ./cmd/barkpark
./bp capabilities -o json --full > tooling/scaffy-duels/fixtures/caps-full-<date>.json
./bp capabilities -o json        > tooling/scaffy-duels/fixtures/caps-brief-<date>.json
```

Date-stamp new captures instead of overwriting these — the pair above is the
frozen wave-1 measurement baseline. The full capture is byte-identical to
`docs/cli/fixtures/full-manifest.json` at capture time (same command, same
server); that test fixture DOES get overwritten on regen, this one does not.

The projection itself is `briefManifest` in `internal/cli/capsbrief.go`; its
protective kit (invoke-completeness, legend pin, ≤32% ratio tripwire, hostile
synthetic, `--full` byte-identity) lives in `internal/cli/capsbrief_test.go`.
