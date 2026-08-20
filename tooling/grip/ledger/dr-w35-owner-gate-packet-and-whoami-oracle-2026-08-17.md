# dr-w35: the owner's exit-reading gate packet, and the `bp whoami` presence-only oracle (2026-08-17)

Wave-35 verifier assignment `owner-gate-packet-and-whoami-oracle`. No value is stored
here: every number below is quoted beside the command that re-takes it.

## (a) `bp whoami`'s `cloud.logged_in` is token-PRESENCE only — producer named

`internal/cli/builtins.go:183-192` (origin/main, same line numbers). The whole
derivation is:

```go
cloudLoggedIn := false
if cfg, _ := LoadConfig(); cfg != nil && cfg.HasCloudToken() { cloudLoggedIn = true; ... }
```

`HasCloudToken` (`internal/cli/config.go:141-144`) is `ResolveCloudToken() != ""`.
No control-plane call. The human line at `builtins.go:268-271` prints
`cloud:     logged in to <url> (team <id>)`.

The ASYMMETRY is the defect: in the same function, the CONTENT server's
`reachable` IS probed (`builtins.go:153-164`, `loadManifest`), so whoami measures
one plane and merely reads a file for the other, then reports both in the same
vocabulary.

`internal/cli/builtins_test.go:370-400` PINS `logged_in == true` from a config
holding the literal token `sess-secret-must-not-leak` against
`unreachableWhoamiServer(t)` — a stamped pin that structurally cannot detect an
invalid session.

Blast radius of the same predicate as a PRECONDITION: 27 non-test call sites
(`grep -rn 'HasCloudToken()' internal/ | grep -v _test | wc -l`).

### Re-derivation

```sh
grep -rn 'logged_in' internal/ cmd/ | grep -v _test
git show origin/main:internal/cli/config.go | sed -n '136,144p'
git show origin/main:internal/cli/builtins.go | sed -n '180,195p;260,277p'
CC=/usr/bin/clang go test ./internal/cli/ -run TestWhoami -v      # 5/5 PASS today
bp whoami -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["cloud"])'
bp cloud deployments --days 22                                     # 401 unauthorized
```

`CC=/usr/bin/clang` is required — a bare `go test` dies at `runtime/cgo` with
`error: unknown option '-E'` because `cc` is a Claude wrapper on this host.

## (b) The post-login sequence, exact

The human gate is NARROWER than "the owner runs `bp login`": device-link splits
into non-interactive steps, so the ONLY act that needs a human is approving one
URL in a browser. Proved live while the stored session 401s:

```sh
bp login --device-start -o json
# {"device_code":"…","expires_in":600,"interval":5,"user_code":"R36W-Q8CZ",
#  "verification_uri":"https://barkpark.cloud/activate",
#  "verification_uri_complete":"https://barkpark.cloud/activate?code=R36W-Q8CZ"}
```

`expires_in` is 600s and a reading costs 39-57s, so approval and run fit one code.
An approved `--device-poll` PERSISTS the session itself
(`internal/cli/login_device.go:222-247` → `devicePollStep`, which "already
persisted the session"), so nothing else is owed after approval.

```sh
resp=$(bp login --device-start -o json)             # owner opens verification_uri_complete
code=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["device_code"])' <<<"$resp")
until bp login --device-poll "$code" -o json; do sleep 5; done
bash scripts/deploy-reliability-exit-run.sh          # exit 0 = quotable reading
bp cloud deployments --days 22                       # the owed 500 retest
```

The password path (`--email/--password`, `BARKPARK_PASSWORD`) is the headless
alternative per `bp login --help`.

## (c) What the runner prints, and what can move in a week

`scripts/deploy-reliability-exit-run.sh` defaults are FIXED instants
(`:116-117`): `FROM=2026-07-01T00:00:00Z`, `TO=2026-08-09T00:00:00Z`. `--days` is
refused outright (`:202`). The rendered reading (`:397-425`, epilogue `:484-505`)
emits, in order: `window [from .. to]`, `as_of`, `population`, `live_rate`,
`never_covered`, `split`, `beside it (too_young/pending/unreadable)`,
`failure_rate REFUSED — <reason>`, `completeness`, then `producer`, `cost`,
`what this is`, and the verdict line `READING (exit 0) — quotable.`

`as_of` is NOT a clock: `cloud/lib/barkpark_cloud/deploy_ledger.ex:1330` says
"`as_of` is the window's `to`, PINNED, never `utc_now()`". Therefore a
default-window re-run on 2026-08-17 prints `as_of 2026-08-09T00:00:00Z` again.

CONSEQUENCE for the sibling artefact: at the default window, population,
`live_rate`, `too_young` and `pending` are frozen by construction — the ONLY digit
that can move is `never_covered` (and its environment split), because the covering
query is bounded on the LEFT only (`deploy_ledger.ex:432` `@coverage_basis`: "a
later live build minted AFTER the window's `to` still counts"). A week of rebuilds
can only make `never_covered` FALL from 5. Any "the week moved" story that needs
population to move requires an explicitly moved `--to`, which shifts the maturity
fence too — a different question, quoted with its own window line.

## Today's refusal, verbatim (for the packet's "correct refusal" section)

```
$ bash scripts/deploy-reliability-exit-run.sh ; echo RC=$?
deploy-reliability-exit-run: calling the census over [2026-07-01T00:00:00Z .. 2026-08-09T00:00:00Z] — observed cost band 39-57s, client cap 90s applied absolutely with no retry.

deploy-reliability-exit-run: INFRA FAULT (exit 2) — no reading was taken.
  the producer exited 3 after 0s (client cap is 90s, applied absolutely, no retry).
  the route named its own refusal: unauthorized|could not read the deploy census for your team for 2026-07-01T00:00:00Z → 2026-08-09T00:00:00Z (39 days) — the control plane did not recognise this session (401 unauthorized). Nothing was read: this is NOT a population with zero failures. Run `bp login` and try again.
RC=2
```

RC must be captured directly. `… | tail` eats it and prints `EXIT=0` for this
exit-2 run — the standing pipe-swallows-rc trap.

## The 500 claim is UNTOUCHED by today's evidence

Charter `:11691` says `--days 22` "still returns HTTP **500** server-side". Today
`bp cloud deployments --days 22` returned a route-worded `unauthorized` body. A
401 short-circuits before any census query runs, so it is NOT evidence about the
500 in either direction. The retest is owed post-login and unrun.

## Producer pedigree today (the compensating win)

```sh
bp --version   # {"build_date":"2026-08-17T06:29:45Z","cli_version":"dev","commit":"e7379a38b3"}
git merge-base --is-ancestor e7379a38b3 origin/main && echo VOUCHED
```

Ancestor, so the runner's pre-flight refusals 3/4/5/6 did not fire — it reached
the census and failed only on the plane. D581's divergence story is stale.
