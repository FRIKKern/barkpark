# TUI disposition strip: ALIVE, not dead code (PDS wave 27, verifier `tui-strip-alive`)

Verdict: the TUI's adjudication strip renders. The chain is unbroken from the wire to the frame,
and a mutation kills the test. The "zero dispositions live" measurement came from `bp task ready
-o json`, which the CLI resolves to `view=brief` — a 9-key allowlist that drops `content` whole.
The TUI never sends `view=`.

## Re-derivation recipes

Wire — prime default is FULL and carries `content.disposition`; brief drops it:

    TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    for V in "" "&view=brief" "&view=full"; do
      curl -s -H "Authorization: Bearer $TOK" "https://guerrilla.barkpark.cloud/v1/tasks/prime?limit=25$V" \
      | python3 -c "import json,sys;d=json.load(sys.stdin);r=d['ready'];print(len(r), sum(1 for x in r if (x.get('content') or {}).get('disposition')), sorted(r[0].keys()))"
    done
    # ""->25 1 (26 keys incl. content) | brief->25 0 (9 keys, no content) | full->25 1

The corpus fetch the TUI actually uses (`/v1/tasks?limit=1000`, no view) carries it on 120/200 rows:

    curl -s -H "Authorization: Bearer $TOK" 'https://guerrilla.barkpark.cloud/v1/tasks?limit=200' \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print(sum(1 for r in d['docs'] if (r.get('content') or {}).get('disposition')),'/',len(d['docs']))"

Source chain (all `git show origin/main:` — the primary checkout is 131 commits behind and does
NOT contain the strip at all, so a local `go test` is vacuous here):

    git rev-list --count HEAD..origin/main                       # 131
    grep -n Disposition internal/taskboard/frames.go             # ABSENT locally
    git show origin/main:internal/taskboard/frames.go | grep -n Disposition   # :32-34

    program.go:232  fetch: FetchSnapshotFull
    detail_data.go:39-44  FetchSnapshotFull -> getJSON("/v1/tasks?limit=1000")   # no view param
    fetch.go:434,451-453  toDetail: strField(contentMap(w.Content), "disposition"|…|"reopen_trigger")
    detail_render.go:200,204  emitStrip(dispositionLabel(...), d.DispositionReason, …) / "reopens when"
    program.go:1548 / compose.go:302,870  RenderTaskDetail(m.details[Ref], …)
    git grep -n "view=" origin/main -- internal/taskboard/       # NO MATCHES

## Mutation proof (a test that survives deletion is not a test)

    S=<scratch>; rm -rf $S/main && mkdir -p $S/main && git archive origin/main | tar -x -C $S/main
    cd $S/main && CC=clang go test -run TestDetailDisposition -v ./internal/taskboard/   # 3/3 PASS
    # delete the line detail_render.go:200 (b.emitStrip(dispositionLabel(...)...))
    CC=clang go test -run TestDetailDisposition ./internal/taskboard/                    # FAIL

## Two caveats Decide should carry

1. `emitStrip` returns early on an empty reason (detail_render.go:662-666), and
   `TestDetailDispositionStripEmptyReason` PINS that a disposition with no reason renders
   NOTHING — not even a label. A row staged `closed` with a blank note is invisible in the TUI
   by contract.
2. The MCP bridge forces `view=brief` on BOTH the list and prime reads
   (`internal/cli/mcp_tasks.go` :150, :561), so an MCP agent's ready queue is disposition-blind
   even though the TUI's is not. `task_show` is the documented full escape hatch.
