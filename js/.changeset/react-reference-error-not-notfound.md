---
'@barkpark/react': patch
---

`BarkparkReference`: a failed fetch is no longer reported as a missing document.

**Supersedes the pending `react-reference-unwrap-response` changeset on this
point.** That entry promises the derived `client={bp}` fetcher "returns
`notFound` on non-ok responses" — it does not, as of this change, and shipping
both statements unamended would release a contradiction. Everything else in that
changeset (envelope unwrapping, the `fetchRaw` type correction) still stands;
only the non-ok clause is replaced by what follows.

Previously every non-2xx collapsed into the same `null` as a genuine 404, and
`notFound` defaults to `null`, so a 401, 403, 429 or 5xx rendered an empty
fragment: no error, no fallback, no log. The two derived-fetcher branches are
now repaired separately, because they fail differently:

- the `client.doc(type, id)` branch swallows **only** `BarkparkNotFoundError`
  (matched on `err.code`, not `instanceof`, per the core error taxonomy) and
  rethrows everything else untouched;
- the `client.fetchRaw` branch maps **only** `res.status === 404` to `null` and
  otherwise throws a typed `BarkparkReferenceFetchError` carrying `code`,
  `status` and `url` — no core error object exists on that path. A JSON-decode
  failure now surfaces as an error too, instead of being swallowed.

Two new props land the failure: `errorFallback` (rendered instead of the
document when the fetch fails; `notFound` is never used for a failure) and
`onError(err, id)`. With neither supplied the component logs a `console.error`
receipt rather than blanking silently. The error is deliberately **not**
rethrown for a consumer error boundary: measured on React 19, neither a rejected
promise passed to `use()` nor a throw in the render resumed after it reaches a
boundary — the subtree never settles, which is worse than the blank it replaces.

The client entry's gzip budget in `.size-limit.json` is re-baselined from
22.5 KB to 22.75 KB: the discrimination measures 22.7 KB (was 22.48 KB).
The percentage is not the argument — there is no 2% bar in this repo, only the
absolute cap in `.size-limit.json`. It is stated rather than absorbed silently
— the previous cap left only ~20 B of slack, so no amount of trimming fits an
error path under it.

404 and 200 behaviour is unchanged. `@barkpark/react@1.0.0-preview.1` as
published on npm does not contain the collapse, so this corrects unreleased
behaviour and owes no deprecation cycle.
