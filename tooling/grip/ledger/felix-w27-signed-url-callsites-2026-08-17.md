# felix-w27 signed-url-callsites — re-derivation recipe

Verifier assignment [signed-url-callsites], wave 27. Two seams, both refuted as Act III slices.

## Seam 1 — SignedUrl.sign/3 ttl reachability

VERDICT: already-good (defensive-only). The `:ttl` opt is NEVER caller/request-derived.

    # Only two non-module references to signed_url; only ONE real .sign/3 call site:
    grep -rn 'SignedUrl\.\|signed_url' api/lib --include='*.ex' | grep -v 'defmodule\|media/storage/signed_url'
    # -> media/storage.ex:44 (defdelegate), delivery/urls.ex:147 (the only sign call)
    git show origin/main:api/lib/barkpark/media/delivery/urls.ex | sed -n '145,152p'
    # -> SignedUrl.sign(path, file.id)   # NO opts keyword => ttl always @default_ttl
    git show origin/main:api/lib/barkpark/media/storage/signed_url.ex | sed -n '9,15p'
    # -> @default_ttl 60*60*24*7 (7d); exp = now + Keyword.get(opts,:ttl,@default_ttl)
    # No caller passes :ttl anywhere in api/lib:
    grep -rn 'ttl' api/lib --include='*.ex' | grep -i sign   # only @default_ttl def + presign_ttl (unrelated S3)

Storage.sign/3 delegate has zero callers passing opts. Request data cannot mint a long-lived URL. A clamp would be pure defensive-hardening with no named failure mode.

## Seam 2 — undo_checkout admin? delegated privilege bit

VERDICT: reachable by any WRITE token (non-admin), but the lock is a soft EDITORIAL coordination lock, not a security/isolation boundary. Low severity; behavior-change risk on tightening. Honest framing: doc-vs-code mismatch, effectively already-good.

    grep -rn 'undo_checkout' api/lib --include='*.ex' --include='*.heex'
    # sole controller: controllers/v1/media_controller.ex:381 (no Studio LiveView caller)
    git show origin/main:api/lib/barkpark_web/controllers/v1/media_controller.ex | sed -n '380,388p;453,457p'
    # endpoint gated by require_write(conn); then admin? <- admin?(conn)
    # admin?(conn) = Auth.has_permission?(token,"admin") OR Auth.has_permission?(token,"write")
    git show origin/main:api/lib/barkpark/media/storage/checkout.ex | sed -n '18,56p'
    # ensure_can_release: holder in [nil,""] -> :ok ; admin? -> :ok ; holder==actor -> :ok ; else forbidden

Key structural fact: because `require_write` precedes the call and `admin?` = write-OR-admin, admin? is ALWAYS true for any caller that reaches undo_checkout. The `holder == actor` discrimination is dead on the API path — every writer can force-release any editor's lock. The docstring "Admin or lock holder only" is unenforced. No non-write path reaches admin?=true (endpoint requires write). Not privilege escalation: releasing only clears checkedOutBy on a mediaAsset; grants no data access.
