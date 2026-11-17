<!-- doc-tier: agent | canonical-for: http-api-user-prefs | budget: 450tok -->
# Per-account prefs — `/w/:ws/p/:proj/v1/prefs/:dataset/:key`

A small JSON object per account, workspace, dataset and key ([api-v1.md](../api-v1.md) §8f; errors per §9).

| Method | Body | Effect |
|---|---|---|
| `GET` | — | `{key,dataset,value}` and `ETag`; unset: `value: null`, no tag |
| `PUT` | `{"value":{…}}` | Replaces the object (max 16 KB); `If-Match`: only a value it names (`*`: any); `If-None-Match: *`: only if unset; else `412` |
| `PATCH` | `{"op","field","item","max"?}` | Edits `value[field]` |
| `DELETE` | — | Removes the key (absent: still `200`) |

The caller is an account session or a personal token's owner (an ownerless token: `403 no_user_identity`). A session cookie needs `x-requested-with` except on `GET`.

## Ops

`PATCH` applies one op under a row lock and answers like `GET`; other keys stay.

- `set` puts `item` (any JSON but `null`) at top-level `field`.
- `push_front` moves `item` to the front, once, and keeps the first `max` (default all).
- `add` appends `item` unless it is there.
- `remove` drops every copy of `item`; on an absent key it writes nothing (`value: null`), the other ops create it. A missing list field is empty.

An op repeated at once changes nothing (a safe retry); after other ops it applies again. Concurrent ops all land, as does one waiting on a `DELETE`; a plain `PUT` can undo them.

Errors write nothing: `422 bad_request` for an unknown `op`, a missing or empty `field`, a missing or `null` `item`, a `max` not a positive integer (digit strings count), `If-None-Match` not `*`, or both headers. `422 invalid_pref` when a list op's `value[field]` is not a list, key or dataset passes 200 characters, the result 16 KB, or any holds U+0000.
