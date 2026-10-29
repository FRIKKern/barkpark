<!-- doc-tier: agent | canonical-for: http-api-user-prefs | budget: 450tok -->
# Per-account prefs — `/w/:ws/p/:proj/v1/prefs/:dataset/:key`

A small JSON object per account, workspace, dataset and key. Split out of [api-v1.md](../api-v1.md) §8f; auth markers and the error envelope stay there (§2, §9).

| Method | Body | Effect |
|---|---|---|
| `GET` | — | `{key,dataset,value}`; `value` is `null` when unset |
| `PUT` | `{"value":{…}}` | Replaces the whole object |
| `PATCH` | `{"op","field","item","max"?}` | Edits the list at `value[field]` |
| `DELETE` | — | Removes the key; deleting an absent key is still `200` |

The caller is an account session or a personal access token's owner. A token with no owner gets `403 no_user_identity`. A session cookie needs `x-requested-with` on every method but `GET`. A value is capped at 16 KB.

## List ops

`PATCH` locks the row, applies one op, and answers `{ok,key,dataset,value}` with the whole new object. A missing key or field counts as an empty list, and the other keys in `value` are kept.

- `push_front` moves `item` to the front, removes its other copies, and keeps the first `max` entries (all of them when `max` is absent).
- `add` appends `item` unless it is already there.
- `remove` removes every copy of `item`.

Applying the same op twice gives the same value as applying it once, so a client can replay an op it queued offline. Two clients editing one key at the same time both land.

Errors: `422 bad_request` for an unknown `op`, a missing or empty `field`, a missing or `null` `item`, or a `max` that is not a positive integer. `422 invalid_pref` when `value[field]` is not a list, or the result is over 16 KB; nothing is written.
