<!-- doc-tier: cold | canonical-for: pe-w7-slice-binary-scaffold-proof | budget: 1200tok -->

# PE wave 7 — slice-binary-scaffold-proof re-derivation

Verifier proof that `bp paper new`'s starter, built from #11934's branch, clears
the LIVE guerrilla publish wall as-emitted. Feeds pe-bl-cold-agent-run.

## Facts and how to re-derive them

### F1 — build bp from #11934's branch (cgo trap)

Bare `go build` at repo root fails ("no Go files"); main is `./cmd/barkpark`.
The `cc`-alias shadow (MEMORY: cc-alias-shadows-compiler) makes cgo error
`unknown option '-E'` — disable cgo.

    S=$SCRATCH/pr11934; mkdir -p $S
    git archive origin/loop-epic/bp-paper-new-create-on-push-one-door-fro-2 | tar -x -C $S
    cd $S && CGO_ENABLED=0 CC=/usr/bin/clang go build -o bp ./cmd/barkpark
    ./bp version   # -> {"cli_version":"dev"}

### F2 — scaffold emits a BPML starter, local-only

    cd $TMPDIR && $S/bp paper new cold-probe-42
    cat .barkpark/papers/cold-probe-42.bpml
    # <paper> with <meta><description>, two <tag> (scaffold s=60, article-draft s=40,
    # distinct strengths, >=20-char rationales), <h1 id="tpl-title">, one <p>.
    # Also writes .pristine/ + state.json rev-0 anchor. No server call.

### F3 — starter validates valid:true AS-EMITTED (no tag swap needed)

Endpoint wants `{"bpml":"<string>"}`. Both the raw curl and `bp paper push
--check` agree.

    TOK=<guerrilla admin>; jq -n --arg b "$(cat cold-probe-42.bpml)" '{bpml:$b}' > p.json
    curl -s -X POST https://guerrilla.barkpark.cloud/v1/plugins/bulldocs/papers/validate \
      -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d @p.json
    # -> {"valid":true,"violations":[]}   HTTP 200
    $S/bp paper push cold-probe-42 --check   # exit 0, {"valid":true,"violations":[]}

### F4 — scaffold + article-draft ARE live-registered (193 tags)

    $S/bp doc ls tag --all -o json | jq -r '.documents | length, (.[]|select(._id=="scaffold" or ._id=="article-draft")._id)'
    # -> 193 / article-draft / scaffold

### F5 — unknown_tag is a 200 valid:false VIOLATION at validate, NOT a 422

The dry-run validate never 422s. It returns HTTP 200 with valid:false. The 422
lives only on the create/publish wall arm. Both surfaces name code=unknown_tag.

    # swap one <tag tag="zzz-not-a-real-tag-9999" ...>, validate:
    # -> HTTP 200 {"valid":false,"violations":[{"code":"unknown_tag",
    #    "message":"publish references unregistered tag(s): zzz-not-a-real-tag-9999",
    #    "hint":"Every tags[].tag must be a registered tag ...",
    #    "details":{"unknown":[...],"suggestions":{"zzz-...":["research-note"]}}}]}
