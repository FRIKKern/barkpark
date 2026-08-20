# Re-derivation recipe — #3 mixed-shape / reserved-name write drop (verify phase, gyldendal-field-report wave 1)

Baseline: origin/main `a07a0baa138d628987706e94a31329379410f23a`.
Mechanism: `Writer.from_envelope/1` (api/lib/barkpark/content/writer.ex:1165) takes its
content-present branch whenever the payload has a MAP under key `content`, and passes
attrs through UNCHANGED. Every other top-level key survives into `attrs` and is then
silently discarded by `Document.changeset`'s `cast/3` whitelist (api/lib/barkpark/content/document.ex:81-93).
No line says "discard". HTTP answer is 200 with a document echoing only the kept fields.

## Read the two sites on main (no checkout needed)

    git show origin/main:api/lib/barkpark/content/writer.ex | sed -n '1163,1195p'
    git show origin/main:api/lib/barkpark/content/document.ex | sed -n '81,95p'

## Live reproduction (test env, real HTTP through the mutate controller)

Write an ExUnit file OUTSIDE the repo (scratchpad) and run it by absolute path —
`mix test <abs path>` compiles it against test/support:

    cd api && mix test /abs/path/wsr_mixed_shape_test.exs

Three payloads, all `POST /v1/data/mutate/test` with a write token:

  A. MIXED  — `{_id,_type,title, content:{body}, acceptance_criteria, priority, tags}`
     => 200; stored content = `%{"body" => "hello"}`; the three siblings are nil.
  B. FLAT   — same minus the `content` map
     => 200; stored content carries acceptance_criteria, priority, tags. Survives.
  C. COLLIDE— pure FLAT Sanity doc whose OWN field is named `content` (a map):
     `{_id,_type,title, content:{nb:"brødtekst"}, slug, publishedAt, authorRef}`
     => 200; stored content = `%{"nb" => "brødtekst"}`; slug/publishedAt/authorRef LOST.

C is the third cause the survey flagged as unreproduced: a caller who never intended
the legacy envelope trips the legacy branch by FIELD NAME alone.

## Orphan-key derivation (proves a 422 or strip-list is implementable)

At the content-present branch the names are in hand:

    out = Writer.from_envelope(attrs)
    orphans = out |> Map.drop(~w(_id _type _rev _draft _publishedId _createdAt _updatedAt
                                 doc_id type dataset rev title status content)) |> Map.keys()
    # => ["acceptance_criteria", "priority", "tags"]

(the `@reserved_in` module attribute at writer.ex:1163 is exactly this list.)

## Op coverage

create / createOrReplace / createIfNotExists / replace all drop identically (200, same
stored content). `mutate_controller.ex:20/27` already opens and drains a `Warnings`
queue, so a non-blocking advisory is deliverable today; the response body carries only
`["results","transactionId"]` — no `warnings` key on the drop.

## Baseline gates (green at survey time)

    cd api && mix test test/barkpark/content/writer_test.exs test/barkpark/content/mutations_test.exs   # 14 tests, 0 failures
    cd api && mix test test/barkpark_web/controllers/mutate_controller_test.exs                          # 46 tests, 0 failures
