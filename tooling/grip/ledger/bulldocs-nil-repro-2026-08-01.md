# bulldocs-nil-repro — re-derivation recipes (PDS wave 33 VERIFY, 2026-08-01)

Row under test: `bp-bulldocs-patch-batch-ops-fail-on-nil` ("bp bulldocs patch fails on
ANY multi-op batch: 'append-block failed on nil'"). The filed row reports code
`malformed_op`; the derived mechanism is `duplicate_id` on a nil block id. Both cannot
come from the same clause. Everything below was RUN, not read.

## R1 — Which clause emits "append-block failed on nil"?

    git show origin/main:api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex | sed -n '641,652p'
    git show origin/main:api/lib/barkpark/portable_doc/patch.ex | sed -n '178,196p'

Only `{:error, {code, target, op_kind}}` builds `"#{op_kind} failed on #{inspect(target)}"`,
with `code: to_string(code)`. `malformed_op` is emitted by two clauses whose messages are
fixed literals ("every op must name a known DocPatchOp" / "op must name a known DocPatchOp").
VERDICT: the row's code is a MISATTRIBUTION — carried over from the reporter's first
attempt (`op: "append"`, which really is `malformed_op`).

## R2 — Pure-engine repro (build-free, no DB, ~5s)

    cd api && CC=/usr/bin/clang MIX_ENV=test mix run --no-start /tmp/nil_probe.exs

with `/tmp/nil_probe.exs` folding `Barkpark.PortableDoc.Patch.apply_patches/2` over
N id-less `append-block` ops on `%{"version"=>1,"blocks"=>[]}`.
n=1 → `{:ok, …}`. n=5 → `{:error, {:duplicate_id, nil, "append-block"}}`.
41 id-bearing ops → `{:ok, …}` with 41 blocks. Same for `insert-after`.

## R3 — Live wire repro (guerrilla), the shape that decides the row

    S=https://guerrilla.barkpark.cloud; T=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    # create a scratch paper (the publish wall needs description >=20 chars + registered tags)
    curl -s -X POST "$S/v1/paperflow/papers" -H "Authorization: Bearer $T" -H 'content-type: application/json' \
      -d '{"slug":"scratch-nilprobe","title":"t","description":"scratch paper for a batch-op nil-collision repro, deleted after","tags":[{"tag":"pds","strength":80,"rationale":"repro"},{"tag":"bp-cli","strength":40,"rationale":"surface under test"}],"blocks":[{"id":"anchor","type":"paragraph","content":[]}]}'
    U="$S/v1/paperflow/papers/scratch-nilprobe/ops"
    post(){ curl -s -w ' <- %{http_code}\n' -X POST "$U" -H "Authorization: Bearer $T" -H 'content-type: application/json' -d "$1"; }
    post "$(python3 -c 'import json;print(json.dumps({"ops":[{"op":"append-block","block":{"type":"paragraph","content":[]}} for _ in range(5)]}))')"
    post "$(python3 -c 'import json;print(json.dumps({"ops":[{"op":"append-block","block":{"id":"pb-%d"%i,"type":"paragraph","content":[]}} for i in range(41)]}))')"
    post '{"ops":[{"op":"move-block","id":"pb-0","after":null}]}'
    # ALWAYS clean up, then post-read the delete:
    bp doc delete paper scratch-nilprobe && bp doc get paper scratch-nilprobe -o json

Observed: 5 id-less → `422 {"code":"duplicate_id","message":"append-block failed on nil","target":null}`.
41 id-bearing → `200 ok:true op_count:41` (NO batch-size ceiling).
`move-block` → `422 malformed_op` in BOTH batch and single shapes (`@op_kinds` at
bulldocs_ingest_controller.ex:78 lists five verbs; patch.ex implements and documents six).

## R4 — What the bp CLI shows a human (the two-surface divergence)

    bp bulldocs patch <slug> --file ops5.json ; echo "EXIT=$?"
    bp bulldocs patch <slug> --file ops5.json -o json

Human output: `bp: append-block failed on nil` + a generic hint. NO code, and the
server's `op` / `target` keys are gone in BOTH shapes including `-o json` (which does
show `code: duplicate_id`). Exit 5 — the verb does NOT false-succeed.
NOTE for the label_spine row: the server DOES send `details` (proven at create time:
`{"field":"description","rule":…,"fix":…}` via curl); it is the CLI envelope that eats it.

## R5 — Side finding, on the epic's own thesis

A one-op ID-LESS batch answers `{"ok":true,"rev":2,"block_ids":[],"op_count":1}` —
`block_ids` is EMPTY even though an id WAS minted and persisted. Mechanism, on
origin/main:

    git show origin/main:api/lib/barkpark/content/papers/block_ops.ex | sed -n '795,808p'  # BATCH fold
    git show origin/main:api/lib/barkpark/content/papers/block_ops.ex | sed -n '582,589p'  # SINGLE-op path

The batch `fold_paper_ops/2` calls `locate_paper_affected(op, next)` on the RAW fold
accumulator, and `ensure_block_ids/1` does not run until :706, AFTER the fold. So
`affected.block_id` is `nil` and the `nil -> ids` clause (:800) SILENTLY DROPS it.
The single-op path (:582) runs `ensure_block_ids` BEFORE locate and reports the id
correctly — the two shapes of the same route disagree. The comment at :1204-1208
("the op-fold runs ensure_block_ids over `new_blocks` before this locate") is true of
the single-op path and FALSE of the batch fold. A green receipt whose only addressable
identifier is empty because it was read one step too early.
Reproduce with R3's `post` on a single id-less op.
