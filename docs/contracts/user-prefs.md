<!-- doc-tier: agent | canonical-for: http-api-user-prefs | budget: 450tok -->
# Per-account prefs — `/w/:ws/p/:proj/v1/prefs/:dataset/:key`

A small JSON object per account, workspace, dataset and key ([api-v1.md](../api-v1.md) §8f; errors per §9).

| Method | Body | Effect |
|---|---|---|
| `GET` | — | `{key,dataset,value}`; `value` is `null` when unset |
| `PUT` | `{"value":{…}}` | Replaces the whole object (max 16 KB) |
| `PATCH` | `{"op","field","item","max"?}` | Edits `value[field]` |
| `DELETE` | — | Removes the key; an absent key is still `200` |

The caller is an account session or a personal token's owner; an ownerless token gets `403 no_user_identity`. A session cookie needs `x-requested-with` on every method but `GET`.

## Ops

`PATCH` locks the row, applies one op, and answers like `GET`, with the whole new object. Other keys stay.

- `set` puts `item` (any JSON but `null`) at top-level `field`.
- `push_front` moves `item` to the front, removes its other copies, and keeps the first `max` (all when absent).
- `add` appends `item` unless it is already there.
- `remove` removes every copy of `item`. On an absent key it writes nothing and answers `value: null`; the other ops create it. A missing list field is empty.

An op applied twice in a row changes nothing, so a retry is safe. A replay after other ops applies it again. Two ops at once both land, as does one waiting on a `DELETE`; two read-then-`PUT`s can lose one.

Errors: `422 bad_request` for an unknown `op`, a missing or empty `field`, a missing or `null` `item`, or a `max` that is not a positive integer (a digit string counts). `422 invalid_pref` when a list op's `value[field]` is not a list, the key or dataset passes 200 characters, the result 16 KB, or any holds U+0000. Nothing is written.
