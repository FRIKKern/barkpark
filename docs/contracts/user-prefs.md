<!-- doc-tier: agent | canonical-for: http-api-user-prefs | budget: 450tok -->
# Per-account prefs — `/w/:ws/p/:proj/v1/prefs/:dataset/:key`

A small JSON object per account, workspace, dataset and key ([api-v1.md](../api-v1.md) §8f; errors per §9).

| Method | Body | Effect |
|---|---|---|
| `GET` | — | `{key,dataset,value}`; `value` is `null` when unset |
| `PUT` | `{"value":{…}}` | Replaces the whole object (max 16 KB) |
| `PATCH` | `{"op","field","item","max"?}` | Edits the list at `value[field]` |
| `DELETE` | — | Removes the key; an absent key is still `200` |

The caller is an account session or a personal access token's owner. A token with no owner gets `403 no_user_identity`. A session cookie needs `x-requested-with` on every method but `GET`.

## List ops

`PATCH` locks the row, applies one op, and answers `{ok,key,dataset,value}` with the whole new object. A missing key or field is an empty list; other keys in `value` are kept.

- `push_front` moves `item` to the front, removes its other copies, and keeps the first `max` entries (all when `max` is absent).
- `add` appends `item` unless it is already there.
- `remove` removes every copy of `item`. On an absent key it writes nothing and answers `value: null`.

Applying an op twice in a row changes nothing, so retrying a lost reply is safe. A replay after other ops applies it again, so `push_front` moves its item back to the front. Two clients editing one key at the same time both land.

Errors: `422 bad_request` for an unknown `op`, a missing or empty `field`, a missing or `null` `item`, or a `max` that is not a positive integer (a digit string counts). `422 invalid_pref` when `value[field]` is not a list, the key or dataset is over 200 characters, or the result is over 16 KB. Nothing is written.
