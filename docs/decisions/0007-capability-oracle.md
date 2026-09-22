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

**`min_cli` is advisory, never a refusal.** This paragraph used to justify that
with: "every published `bp` release is tagged `v0.2.x`, strictly below the
literal floor `1.0.0`, so a blocking gate keyed on today's value would refuse
100% of released clients." **RETRACTED 2026-09-17 — that is false**, and it
conflated two tag series in one repo. `v0.2.x` is the **server** series (the
number `/status.json` reports as `0.2.26.929`); the CLI ships from `cli-v*`
tags and `cli-release.yml` does `VERSION=${TAG#cli-v}`, so a released `bp`
carries `1.21.0`. All **27** published CLI releases run `1.1.0`…`1.21.0`, none
below `1.0.0` — verify with
`git tag -l 'cli-v*' | sed 's/cli-v//' | awk -F. '$1<1' | wc -l` (0). The floor
is **satisfied by every client ever shipped**, which is why the guard has never
fired; it was inert for the opposite of the recorded reason.

It stays advisory on the grounds that survive: a `dev` build carries no release
identity, and a floor never once exercised must not debut as a refusal.
`internal/cli` `minCLICheck` reports: a named, actionable stderr notice on
`bp capabilities` when this binary is under the floor, silence when it is at or
above, and `UNKNOWN` (never a green) for a `dev` build or a manifest that omits
the key. Since 2026-09-17 the same reading also gates the `bp whoami` /
`bp doctor --onboarding` freshness leg (`serverFloorStaleness`), which withholds
`up_to_date: true` whenever the server declares this client under its floor —
the only staleness signal that reaches an already-installed binary with no
checkout.

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
