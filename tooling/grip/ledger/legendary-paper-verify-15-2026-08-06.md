<!-- doc-tier: cold | canonical-for: legendary-paper-verify-15-evidence | budget: 1700tok -->
# Verify 15 — multipart delivery and immutable provenance

Verdict: `proven` for the frozen negative claim. Barkpark has no complete Paper-delivery path producing multipart HTML/plain text with immutable Paper revision provenance. The exposed “email” surface is a deterministic HTTP HTML preview, not a mail sender.

The full Paper path is:

```text
BulldocsEmailController.show
  → current published Paper by slug
  → reader_source / task resolution / Render.render_document
  → BulldocsEmailHTML.finalize
  → content-type text/html → send_resp
```

The finalizer inserts the title and absolutizes links only. It does not create a Swoosh email, plain body, MIME envelope, provenance header, sender, unsubscribe header, or provider delivery.

| Paper | Pinned `_rev` | HTML bytes | Stable SHA-256 |
| --- | --- | ---: | --- |
| Cloud Console wave 29 | `18768b0a14c2eead927181c4a0e37c18` | 121,072 | `dc57c4…e331` |
| Cloud Console wave 28 | `49c1534d9fb76d0d9adc7b97f25ec471` | 170,149 | `cfe862…a621` |
| PDS wave 45 | `b992fd8aaa028b0dab30a8da76f077fd` | 119,290 | `3e29bd…a900` |
| PDS wave 44 | `8bbd5d874a1b697f1e4e437c473f8e52` | 98,335 | `c46f46…7645` |

- Flat and scoped deployed routes return identical bytes and only `text/html; charset=utf-8`. Three immediate repetitions reproduced every hash.
- No body contains its slug or exact pinned `_rev`; no response includes ETag or `x-barkpark-paper-revision` for these Papers.
- Repository-wide Swoosh census finds only `GrantNotifier` and `UserNotifier`. Both are unrelated text-only auth/grant messages; neither accepts Paper identity/HTML nor calls `html_body`.
- SMTP is configured only when `SMTP_HOST` exists, but no Paper path reaches `Barkpark.Mailer`.
- No Paper multipart alternative, RFC 5322 message, `From`, `Subject`, `Message-ID`, `List-Unsubscribe`, sender identity, receipt, DKIM result, or provider message identifier exists.
- Immediate projection determinism is proven, but revision determinism is not: task widgets and workspace theme resolve live, so a fixed Paper source revision can yield different future bytes.

An out-of-repository service could theoretically fetch the preview and send it, but no integration, delivered MIME source, provider receipt, or mailbox artifact was available. Actual Gmail/Outlook/Apple Mail delivery therefore remains unproven, not evidence of a complete Barkpark path.

Static route→renderer→finalizer→mailer/provider tracing and fresh deployed evidence covered all four exact pins at clean commit `243a8da520`. Mix tests were unavailable because the read-only worktree has no test dependencies/build; no dependency install, send, file edit, Paper mutation, or server mutation occurred.
