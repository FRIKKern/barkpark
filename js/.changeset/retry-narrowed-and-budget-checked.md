---
'@barkpark/core': minor
---

The retry policy is narrowed to the server faults the API calls transient, and
every retry is now budget-checked against the caller's deadline.

BEHAVIOUR CHANGE, and it is a narrowing — some calls that used to be re-issued
automatically now hand back the first error.

Before, `defaultShouldRetry` repeated any `BarkparkAPIError` with a status
`>= 500`, plus every `BarkparkNetworkError` and `BarkparkTimeoutError`, three
times, with no deadline arithmetic anywhere. That was strictly wider than the
`bp` CLI, which speaks to the same API and deliberately retries one thing: a 500
whose envelope code is `internal_error`. The divergence was accidental. It is
chosen now, and it is chosen narrow, because the only measurement anyone has
taken against this API says a wider retry is not a better one.

Now:

- A `>= 500` is retried only when its envelope code is `internal_error`. A 5xx
  the server named — `import_failed`, `export_failed`, `storage_unavailable`,
  `runtime_unavailable`, `runtime_capacity`, `chat_create_failed` — is handed
  straight back, because repeating it papers over the defect that produced it or
  hammers a component that has already said it is out of room. A 5xx with no
  code at all is not evidence of a transient fault and is not retried either.
- A transport fault (`BarkparkNetworkError`, `BarkparkTimeoutError`) is no
  longer retried under the default read policy: conflating a dropped connection
  with a served fault hides a distinct failure mode. It is still retried for an
  idempotent write (`retry: true` on a commit), where one stable
  `Idempotency-Key` shared by every attempt makes the replay provably safe —
  which is what the error taxonomy already documented.
- A 429 is unchanged: always retried, honouring `Retry-After`.
- New `deadlineMs`, on the client config and per call: an overall budget for the
  whole call, retries and backoff sleeps included, as opposed to `timeoutMs`
  which bounds ONE attempt. It is **undefined by default**, so no existing
  consumer's calls get shorter. When set, a retry that cannot finish inside the
  remaining time is not started at all, and the server's own error is thrown
  immediately rather than the deadline being spent on a backoff sleep.

WHAT TO DO. Most callers need no change. If you relied on the SDK silently
re-issuing a dropped connection on a read, either retry it yourself where you
can see the surrounding transaction, or issue it as an idempotent write. If you
call from a place with a real global bound — a serverless route handler, an
`AbortSignal.timeout` — set `deadlineMs` to it and the retry ladder will stop
converting a would-be answer into an abort.
