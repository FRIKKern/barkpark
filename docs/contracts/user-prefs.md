<!-- doc-tier: agent | canonical-for: http-api-user-prefs | budget: 450tok -->
# Per-account prefs — `/w/:ws/p/:proj/v1/prefs/:dataset/:key`

A small JSON object per account, workspace, dataset and key ([api-v1.md](../api-v1.md) §8f; errors per §9).

| Method | Body | Effect |
|---|---|---|
| `GET` | — | `{key,dataset,value}`, `ETag`; `value` is `null` (no tag) when unset |
| `PUT` | `{"value":{…}}` | Replaces the whole object (max 16 KB); with `If-Match`, only a value it names (`*`: any), else `412` |
| `PATCH` | `{"op","field","item","max"?}` | Edits `value[field]` |
| `DELETE` | — | Removes the key; an absent key is still `200` |

The caller is an account session or a personal token's owner; an ownerless token gets `403 no_user_identity`. A session cookie needs `x-requested-with` on every method but `GET`.

## Ops

`PATCH` applies one op under a row lock and answers like `GET`; other keys stay.

- `set` puts `item` (any JSON but `null`) at top-level `field`.
- `push_front` moves `item` to the front, once, and keeps the first `max` (all when absent).
- `add` appends `item` unless it is there.
- `remove` drops every copy of `item`; on an absent key it writes nothing (`value: null`), the other ops create it. A missing list field is empty.

Twice in a row an op changes nothing (a safe retry); replayed after other ops it applies again. Concurrent ops all land, as does one waiting on a `DELETE`; a `PUT` without `If-Match` can undo them.

Errors, writing nothing: `422 bad_request` for an unknown `op`, a missing or empty `field`, a missing or `null` `item`, or a `max` not a positive integer (digit strings count). `422 invalid_pref` when a list op's `value[field]` is not a list, the key or dataset passes 200 characters, the result 16 KB, or any holds U+0000.
