# onb-alias-prune-and-rebuild-points — re-derivation recipes (2026-08-17)

Verifier assignment [alias-prune-and-rebuild-points], onboarding-composition wave.
All commands run from repo root. Go tests need `CC=/usr/bin/clang CGO_ENABLED=1`
(the `cc` alias shadows the compiler → `error: unknown option '-E'` on cgo).

## (a) No alias-removal path exists — additive-only, proven

The ONLY writer of `ServerEntry.Aliases` is `mergeAliases` (config.go:404), called
solely from `RememberServer` (config.go:468). It dedups+appends; it never drops.
`bp use` → `runUse` (servers_cmd.go:23) → `SetActiveServer` (config.go:843) sets
flat fields only, never touches KnownServers/Aliases. No `remove`/`forget`/`rm`
verb exists. The only entry-loss is the tail trim to `maxKnownServers`=20
(config.go:478) which drops whole ENTRIES, never aliases within a kept entry.

    grep -n "\.Aliases\b" internal/cli/*.go | grep -v _test        # every read/write
    grep -n "KnownServers =\|\.Aliases =" internal/cli/config.go    # the two write sites
    sed -n '843,858p' internal/cli/config.go                        # SetActiveServer = flat only

## (b) Machine-hint baseline + slice-1 (auth-hidden) integration points

    CC=/usr/bin/clang CGO_ENABLED=1 go test ./internal/cli/ -run 'Usage|Hint|Noun|Suggest' -v 2>&1 | tail -5
    CC=/usr/bin/clang CGO_ENABLED=1 go test ./internal/cli/ -run 'Fleet|Barkparks' -v 2>&1 | tail -3

Both GREEN (ok, 0.968s / 0.714s). Slice-1 must keep these green.

cli.go three "unknown command" sites all route through `usageErrHintf` +
`nounHint`/`verbHint` + `usageSuggestNouns`/`usageSuggestVerb`:
  - :530  help <verb> unknown   → nounHint(tree,verb)  + usageSuggestNouns
  - :539  bare unknown noun     → nounHint(tree,noun)  + usageSuggestNouns
  - :606  unknown noun (2-tok)  → nounHint(tree,noun)  + usageSuggestNouns
Feed set: nounHint→nearestNoun→tree.NounNames() (usage.go:355) and
usageSuggestNouns→tree.NounNames() (usage.go:277). An auth-hidden branch filters
that noun set. Tests that MUST stay green: TestExecuteUnknownNounStillSuggests,
TestExecuteBareNounHelpShowsVerbList, TestExecuteRealNounFreeTextInfersSoleVerb,
TestExecuteRealNounMultiVerbNamesTheNoun, TestNearestNoun, TestUsageErrHintfEnvelope.

## (c) Fleet-table render seam + LAST-SEEN + JSON last_seen_at

Seam: `renderCloudBarkparksTable` (cloud12_cmd.go:678). Headers cloud12_cmd.go:679
= NAME PROVIDER URL STATUS MODE HEALTH AGENT (7 cols). Row cells :689-692.
Golden: internal/cli/testdata/barkparks_fleet_table.golden (7 cols, no LAST-SEEN)
consumed by TestBarkparksFleetTableGolden (cloud12_cmd_test.go:997, assertGolden).
Adding a LAST-SEEN column MUST regen this golden.

`Barkpark.LastSeenAt` (`json:"last_seen_at"`) ALREADY decodes (client.go:94).
BUT `-o json` does NOT export it: cloudBarkparkRow (cloud12_cmd.go:642) omits
last_seen_at from its map. So slice 3 does NOT narrow — it must add the field to
BOTH renderCloudBarkparksTable (+golden) AND cloudBarkparkRow (+TestBarkparksYAMLParity
at cloud12_cmd_test.go:1078). Struct-decoded, surfaced nowhere today.

    sed -n '678,703p' internal/cli/cloud12_cmd.go     # table seam
    sed -n '642,663p' internal/cli/cloud12_cmd.go     # JSON row (no last_seen_at)
    grep -n "LastSeenAt" internal/cloudclient/client.go
