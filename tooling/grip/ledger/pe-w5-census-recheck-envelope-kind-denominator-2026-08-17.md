# PE wave-5 verify — envelope kind, expandable allowlist, denominator (2026-08-17)

Re-derivation recipes for the three census-recheck design unknowns, proven against
the LIVE fresh guerrilla BEAM and origin/main HEAD.

## (a) Is the 422 `kind` a discrete field or only in the message?

ONLY in strings. The wire envelope has exactly `error.{code,message,hint}` — no
`kind`/`type` field. The struct carries them but the controller drops them.

```bash
# live 422 (any bpml_unprintable paper — this one 422s on an `expandable` block)
curl -s 'https://guerrilla.barkpark.cloud/papers/task-tui-wave-2026-08-17b/source?format=bpml' | python3 -m json.tool
# => {"error":{"code":"bpml_unprintable",
#     "hint":"this paper uses a block shape outside the BPML kernel vocabulary; fetch format=json",
#     "message":"BPML printer: block type \"expandable\" is outside the BPML kernel vocabulary (kind: block)"}}

# code anchor: envelope has NO kind field (3 keys only)
git show origin/main:api/lib/barkpark_web/controllers/bulldocs_source_controller.ex | sed -n '114,124p'
# message format (both shapes) lives in the exception:
git show origin/main:api/lib/barkpark/portable_doc/bpml/unprintable_error.ex | sed -n '58,67p'
```

Consequence for the recheck AC-2 kind-bucketing: it is a **regex-parse**, not a field read.
- KIND (block|inline|mark|head_cell): parse `hint` for `a (\w+) shape` OR `message` for `\(kind: (\w+)\)` — both carry it.
- block TYPE (expandable, valueref, columns, …) for Decide's block-kind-by-tag sub-bucket: `message` ONLY, via `type "(\w+)"` (double-quoted by `inspect`).

## (b) origin/main expandable printer allowlist

NOT on origin/main — the `expandable` printer clause ships in the still-OPEN #11814
(pe-w2-bpml-inline-vocabulary). origin/main's bpml tree has ZERO `expandable`.

```bash
git show origin/main:api/lib/barkpark/portable_doc/bpml/printer.ex | grep -ic expandable   # => 0
git fetch origin refs/pull/11814/head:pr-11814
git show pr-11814:api/lib/barkpark/portable_doc/bpml/printer.ex | grep -n -A3 expandable
# L146-149: defp block(%{"type" => "expandable"} = b, d) ...
#           wrap("expandable", attr_str(b, ["id", "summary"]), children, d)
```

D30's `[id, summary]` allowlist is EXACT — but only exists on the #11814 branch. Quote it from
there (or after merge), never from origin/main.

## (c) Live published-paper denominator

Moving target, drifting UP as papers are minted through the session. NOT a stable 784.

```bash
curl -s 'https://guerrilla.barkpark.cloud/v1/data/query/production/paper?limit=2000&fields=_id' \
  | python3 -c "import json,sys;r=json.load(sys.stdin)['result'];print(r['count'])"
# 776 (census file, morning) -> 788 -> 789 (this verify round). Pin at fetch time.
```

Response is `result.count` / `result.documents` (server caps `limit` at 1000, but count is exact).
