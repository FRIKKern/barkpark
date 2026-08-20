# PDS w31 — slice 7 (`task-37befa974015b2f2`) premise + pay-net-dns coupling: re-derivation recipes

Baseline: `origin/main` = `8b2018bc0024bdf771093cadedff8e3e54fc0606`.
NOTE: the primary checkout was diverged (48 ahead / 224 behind) and missing
`internal/cli/hetzner_respost*.go`, so every run below was taken on a read-only
export, NOT on the working tree:

    S=$SCRATCH/om; rm -rf $S; mkdir -p $S; git archive origin/main | tar -x -C $S

macOS: `cc` is aliased to a Claude wrapper — every `go test` needs `CC=/usr/bin/clang`.

## R1 — the row has zero acceptance criteria (the reason it cannot be merge-gated)

    bp task get task-37befa974015b2f2 -o json | python3 -c "import json,sys;c=json.load(sys.stdin)['doc']['content'];print(repr(c.get('lifecycle_status')),repr(c.get('acceptance_criteria')))"
    # -> 'open' None

## R2 — REFUTES the row's premise: a create CAN already refuse

In the export, make one create observe hook disagree, then run the create table:

    # internal/cli/hetzner_lb_cmd.go, inside hzObservePlacementGroupCreated:
    #   if string(pg.Type) == "spread" { return hzResDisagrees("type", string(pg.Type), "MUTATION-PROBE") }
    CC=/usr/bin/clang go test ./internal/cli -run 'TestHetznerLBFamilyCreatesObserveTheResponseNotTheRequest/placement-group' -v

    # -> exited 1, "…the post-condition is UNMET on field \"type\" (id 17)…", stdout EMPTY

Two facts in one run: `hzResObservedResponse` routes `obs.field` to `hzResUnmet`
at `exitGeneric` (so the refusal arm exists), and the refusal DISCARDS
`obs.extra` entirely (`hzResUnmet` prints no payload) — so `hzResDisagrees` is
not a usable channel for a create either way.

## R3 — the advisory arm is feasible, exit-neutral, and does not re-introduce the echo

Turn `hzObserveLBCreated` into a closure over the asked `--algorithm` and add
`extra["divergence"]` when it differs from `lb.Algorithm.Type`; call site becomes
`hzObserveLBCreated(a.val("algorithm"))`.

    CC=/usr/bin/clang go test ./internal/cli -run 'TestHetznerLBFamilyCreatesObserveTheResponseNotTheRequest'
    # -> ok  github.com/FRIKKern/barkpark/internal/cli  0.378s

Receipt (captured by adding a deliberately-failing `want`):

    ✓ create — load-balancer web-lb (id 7)
      algorithm: round_robin
      confirmation_basis: the create response object
      confirmed_present: true
      divergence: algorithm — you asked for least_connections, the server reports round_robin
      ipv4: 192.0.2.7
      load_balancer_type: lb11
      location: nbg1

`unwanted: ["algorithm: least_connections"]` (hetzner_lb_cmd_test.go:596) still
passes — the phrasing must not spell `<field>: <asked>` or the anti-echo pin reds.
The ✓ line itself is unchanged, and the advisory sorts in among the observed keys.

## R4 — the two divergence fixtures already exist; three must stay silent

`hzLBCreateCases()` (hetzner_lb_cmd_test.go:579): load-balancer asks
`least_connections` against a `round_robin` response; floating-ip asks
`--home-location nbg1` against `home_location: fsn1`. primary-ip,
placement-group and certificate-managed carry no divergence.

## R5 — exclusions, each with the false positive it would produce

    grep -n 'func hzLBTypeRef' -A 6 internal/cli/hetzner_lb_cmd.go     # :451 numeric token -> ID, not Name
    grep -n 'want spread' internal/cli/hetzner_lb_cmd.go               # :1777 client rejects every other --type
    grep -n 'type PrimaryIP struct' -A 22 $(go env GOMODCACHE)/github.com/hetznercloud/hcloud-go/v2@v2.44.0/hcloud/primary_ip.go

- primary-ip `--datacenter`: the hook prints `pip.Location.Name`; the fixture
  asks `nbg1-dc3` and the response location is `nbg1` -> guaranteed false
  advisory. `PrimaryIP.Datacenter` is additionally deprecated "after 1 July 2026".
- placement-group `--type`: only `spread` reaches the API — divergence unreachable.
- certificate `--domain`: the managed fixture asks `example.com` and the response
  returns `[example.com www.example.com]` — a legitimate superset.
- load-balancer `--type`: enrollable only on the non-numeric branch.

## R6 — the pay-net-dns fork

    grep -n 'hzResDone(out, "create"' internal/cli/hetzner_{net,dns,storage,backup}_cmd.go
    grep -n 'hzClassCreate:' internal/cli/hetzner_res_census_test.go   # :271 -> {"hzResObservedResponse"}

The census's class binding makes `hzResObservedResponse` the ONLY legal paying
symbol for the five create rows. Three of those five print argv today —
`network:654` `ip_range` (parsed flag, not `netw.IPRange`), `firewall:1104`
`rules` (len of parsed flags), `zone:295` `mode` — and `record:575` is argv in
every key, with `result.RRSet` optional (nil today prints a ✓; after payment it
would refuse via `hzResNotReadable`).
