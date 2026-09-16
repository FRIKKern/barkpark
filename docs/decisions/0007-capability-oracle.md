<!-- doc-tier: agent | canonical-for: capability-oracle | budget: 1200tok -->
# 0007 — Where a capability answer lives, and how a new key reaches old clients

Status: accepted 2026-09-16 · closes `ssw11-bl-capabilities-version-is-a-placeholder` (charter D112)

## The measurement

Prod, `89.167.28.206`, 2026-09-16:

| Source | Field | Value |
|---|---|---|
| `GET /v1/capabilities` | `server.version` | `0.1.0` |
| `GET /v1/capabilities` | `server.min_cli` | `1.0.0` |
| `GET /status.json` | `version` | `0.2.26.929` |
| `GET /status.json` | `commit` | `ca4534461` |

Two independent defects, confirmed separately:

1. **`server.version` is a placeholder.** It is `Application.spec(:barkpark, :vsn)`
   — the `mix.exs` project version — so it reports `0.1.0` on a box running
   `0.2.26.929`. It has never tracked the release.
2. **`min_cli` was an inert guard.** It is a hardcoded literal in
   `default_server/0`, it was decoded into Go's `manifest.Server.MinCLI`, and it
   was compared at **zero** call sites. `run.go` even documented a "min_cli
   gate" that did not exist — which is exactly how an inert guard reads as a
   working one.

## The decision

**The box does not answer "what release am I".** `/v1/capabilities` answers
*shape* (nouns, verbs, flags, plugins); the running-release oracle is
`GET /status.json` (true version + commit) or the **control plane**, which holds
each instance's self-reported version and `git_commit`. Nothing may branch on
`server.version`. Box-lags-CLI is a supported product state (`pinned_release`,
`autoupdate_paused`, serial rollout), so a client-probed version check would
red correct configurations.

**`min_cli` is advisory, never a refusal.** Every published `bp` release is
tagged `v0.2.x`, strictly below the literal floor `1.0.0`, so a blocking gate
keyed on today's value would refuse **100% of released clients** — the inert
guard's mirror-image failure, and equally invisible. `internal/cli`
`minCLICheck` therefore reports: a named, actionable stderr notice on
`bp capabilities` when this binary is under the floor, silence when it is at or
above, and `UNKNOWN` (never a green) for a `dev` build or a manifest that omits
the key.

**The field cannot simply be deleted.** Go's `manifest.Parse` uses
`DisallowUnknownFields`, so dropping `MinCLI` from the struct would fail every
manifest that still carries it.

## How a new key reaches old clients

The `server` envelope is `additionalProperties:false` and released `bp` binaries
strict-decode the manifest root, so **adding a key to the default envelope is a
whole-CLI parse outage**, not an additive change. A new capability answer must
therefore take one of:

1. **The opt-in query-param pattern** — served only under an explicit flag
   (`?build=1`, `?views=1`), so a client that does not ask never sees the key.
2. **The control plane** — the answer lives outside the box's manifest entirely.

Widening the default envelope is not an option until every strict-decoding
release is out of circulation.
