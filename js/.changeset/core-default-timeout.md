---
'@barkpark/core': patch
---

Requests now apply the documented default timeout (30s reads / 60s writes) when none is configured — previously an un-configured client had NO timeout, so a hung server hung the call forever. Also wires the per-call `timeoutMs` override (client config → per-call → default precedence). Set `timeoutMs: 0` to disable.
