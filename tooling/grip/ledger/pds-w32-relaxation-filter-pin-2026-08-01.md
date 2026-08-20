# pds-w32 relaxation-filter pin — re-derivation recipes (wave 32 VERIFY, 2026-08-01)

The `TestPDSLive404LengthsDifferByKind` relaxation that `pds-w31-harvest-only`
criterion 5 ships in the same commit as the eight harvested bodies. Everything
below was measured against `origin/main` bytes plus synthetic corpora, in two
scratch Go packages: `relaxmain` (main's test file VERBATIM, package renamed) and
`relaxmut` (each candidate arm as a pure function with a PREDICTED verdict).

## R1 — Rebuild both harnesses from scratch

    S=$TMPDIR/relaxmut; D=$TMPDIR/relaxmain
    mkdir -p $S && cd $S && python3 gen.py           # 5 corpora (gen.py in this row's sibling scratchpad)
    printf 'module relaxmut\n\ngo 1.22\n' > go.mod
    CC=/usr/bin/clang go test ./... -count=1 -v      # 19/19 predictions hold

    rm -rf $D && mkdir -p $D/testdata
    git show origin/main:internal/cli/hetzner_live_fixtures_test.go \
      | sed 's/^package cli$/package relaxmain/' > $D/hetzner_live_fixtures_test.go
    for f in pds_live_hetzner_fixtures.json pds_live_hetzner_placement_group_200.json \
             pds_live_hetzner_placement_group_404.json pds_live_hetzner_server_404.json; do
      git show origin/main:internal/cli/testdata/$f > $D/testdata/$f; done
    printf 'module relaxmain\n\ngo 1.22\n' > $D/go.mod
    cd $D && CC=/usr/bin/clang go test ./... -count=1 -v   # 4/4 PASS on the real fixtures

## R2 — main's arm reds on an 8-kind uniform-length set (main's own code)

    cp -R $S/testdata $D/testdata && cd $D && CC=/usr/bin/clang go test ./... -count=1 -v

7 collision errors at `hetzner_live_fixtures_test.go:172`; the other three
`TestPDSLive*` arms stay GREEN — nothing else in the file guards uniformity.

## R3 — the filter is the whole criterion

`404-filtered` arm on the uniform corpus: RED (`404 fixtures=8 distinctLengths=1`).
Same predicate UNFILTERED: GREEN (`allFixtures=9 distinctLengths=2`) — the 186-byte
placement-group 200 body supplies the second length forever. On a ONE-404-KIND
corpus the unfiltered arm is still GREEN. It is unfalsifiable, not weak.

## R4 — the greenwashing demo (why criterion 5's wording is not enough)

Criterion 5 says "show the relaxed test still reds on a universal-length fixture
set". If that DEMO corpus is 404-only, the *unfiltered* implementation reds on it
too (`allFixtures=8 distinctLengths=1`) — the demo certifies the vacuous arm. The
demo corpus must be manifest-shaped: the 404s AND the 200.

## R5 — the undocumented coupling (both directions)

The length arm reads `f.Bytes` from the MANIFEST, never the file. Manifest lies
about a body by one byte -> the 404-filtered relaxation goes GREEN on a corpus
that is uniform on disk; manifest claims 91 for the 100-byte placement-group body
-> the length arm reds on a *fabricated* collision. Only
`TestPDSLiveFixturesRecordTheirOwnKindAndLength` (manifest bytes == disk bytes)
makes either verdict mean anything, and no comment in the file says so.

## R6 — message distinctness, strong vs weak; and the envelope arm's blindness

Pairwise-across-kinds catches a duplicated message (RED, `server==volume`);
"self-consistent within a kind" is GREEN on the same corpus and, at one body per
kind, is structurally unfalsifiable. `bytes - len(error.message)` is 75 for every
body measured (main's real 91=75+16 and 100=75+25; the synthetic 98=75+23), so an
"envelope constant" arm is GREEN on a uniform-length set — it guards envelope
drift, never uniformity. That prediction was made, RUN, and REFUTED.

## R7 — the credential scanner vs a machine marker

`[A-Za-z0-9]{32,}` in `TestPDSLiveFixturesCarryNoCredential` fires on a bare
sha256 (64-char run) and does NOT fire on the same digest broken by hyphens every
16 chars. Widening the regex to admit a marker is the wrong repair.
