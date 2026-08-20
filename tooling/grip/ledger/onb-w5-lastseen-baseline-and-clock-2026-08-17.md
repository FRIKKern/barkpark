<!-- doc-tier: cold | canonical-for: onb-w5-lastseen-baseline-and-clock-ledger | budget: 2000tok -->
# LAST-SEEN builder: baseline + clock re-derivation (onboarding wave 5)

Baseline captured on origin/main @ e085a92789 (2026-08-17). All re-derive from repo root.

## Golden harness passes on origin/main BEFORE the slice (baseline)

    git worktree add --detach /tmp/wt-om origin/main
    cd /tmp/wt-om && CC=/usr/bin/clang CGO_ENABLED=1 go test ./internal/cli/ \
      -run 'TestBarkparksFleetTableGolden|TestBarkparksYAMLParity' -count=1 -v
    # => PASS: TestBarkparksFleetTableGolden (0.00s); PASS: TestBarkparksYAMLParity (0.00s)

## The clock idiom (in-repo, injectable package var)

    git show origin/main:internal/cli/cloud_support_cmd.go | sed -n '112,113p'
    # 112 // supportClock stamps the roster row's last_seen. A var so tests pin it.
    # 113 var supportClock = func() time.Time { return time.Now().UTC() }
    # swap: origClock := supportClock; t.Cleanup(func(){ supportClock = origClock });
    #       supportClock = func() time.Time { return fixed }   (scaffolding at test:76/85; NO fixed-time pin exists yet)

## relativeAge empty/unparseable behavior

    git show origin/main:internal/cli/cloud_usage.go | sed -n '374,392p'
    # time.Parse fails (empty/garbage) => return sanitizeCell(stamp)  => "" for empty
    # relativeAge does NOT use supportClock; it calls time.Since(t) directly (wall clock)
    # hzCell("") => "—" (hetzner_cmd.go:415-419); so hzCell(relativeAge("")) => "—" deterministically

## Design pin for Decide
- Option A (fixed-clock golden): requires refactoring relativeAge to read an injectable clock (it is NOT injectable today); then a fixed LastSeenAt stamp yields deterministic "Xh ago".
- Option B (empty-stamp em-dash): golden structs carry no LastSeenAt (already the case) => hzCell(relativeAge("")) => "—", zero clock work, but proves nothing about age formatting.
- LastSeenAt field already exists: cloudclient/client.go:95 `LastSeenAt string json:"last_seen_at"`. cloudBarkparkRow (cloud12_cmd.go:641) does NOT project it => YAMLParity will need last_seen added if the column is added to JSON/YAML too.
