# Media visibility→cache-policy map — independent second review + seeded-private L1 (2026-08-08)

Discharges het-w1-s2-media-visibility-cache criteria 5–6 (D2/D13 human gate, post-merge).
Reviewed: PR #10835 as merged (sha e1b60622e), re-derived from origin/main bytes by an
independent reviewer session; seeded-private L1 run by the lead against guerrilla.

## VERDICT: AGREE — the implemented map matches charter D12 exactly, both quoted strings byte-for-byte. No behavioral divergence.

| visibility (Access.visibility) | cache-control | etag | 304 handling |
|---|---|---|---|
| "public" | public, max-age=86400, must-revalidate | strong "<size>-<mtime36>" | reached; INM short-circuits to 304 |
| "token" | no-store | none | returns BEFORE any 304 code |
| "private" | no-store | none | returns before |
| unknown string | no-store | none | returns before (fail closed) |
| nil mediaAsset doc | public policy | strong | reached (visibility(nil) == "public") |

Anchors: public clause urls.ex:80; fail-closed catch-all urls.ex:97; constants urls.ex:16/:22
literal-equal to D12. Call sites media_controller.ex:99/:142. Arity-2 delegate removed with no
surviving caller — nothing reaches the old visibility-blind policy. 302-to-blob branch untouched
(private, max-age=0, must-revalidate at media_controller.ex:201). /media is not in static_paths —
the controller is the only route to the bytes.

Pins verified non-tautological: urls_test.exs:113 literal policy string; full-list equality across
all five classes (:133-174); conditional-inertness on non-public arms (:175-207, conn.state !=
:sent even on a matching validator); integration pins media_delivery_test.exs:106/:142. No
residual media max-age=31536000 pin on main.

## Live L1 (guerrilla, post-deploy of e1b60622e)

- Public arm: `/media/files/2026/08/synthetic-take-9fdd8fd1.mp4` → 200,
  `cache-control: public, max-age=86400, must-revalidate`, `etag: "3511485-TDO7KRU"`; INM
  conformance live: exact → 304, weak form → 304, list → 304, `*` → 304, garbage → 200.
- **Seeded-private repro (the D12-specified proof, run + reverted by the lead):** patched the
  seeded asset `asset-22050157-…` to `bp_visibility=private` + published → anonymous curl →
  **403** with `cache-control: max-age=0, private, must-revalidate` (deny; no cacheable body);
  reverted to public + published → 200 with the exact public-arm string. Pre-fix this request
  observed `public, max-age=31536000, immutable` — the repro now FAILS, which is the proof.

## Reviewer's non-behavioral notes (follow-up filed)

1. urls.ex:71-72 moduledoc lists nil in the no-store bucket while D12's nil (a nil DOCUMENT) gets
   the public default — two different nils, code correct on both, prose reads contradictory; the
   `String.t() | nil` @spec widening reinforces the confusion (visibility/1 never returns nil).
2. Charter D4 quotes the redirect branch as "private, max-age=0" — the real string carries
   must-revalidate; charter text is a paraphrase, not quotable.
3. INM-across-multiple-header-lines is implemented but unpinned (all five conformance tests send
   a single header line) — D11-scope pin gap.

## Reviewer's sharpest observation

The fail-closed strength is in the ORDERING, not the header: returning before the 304 block means
a client holding a stale validator for bytes it has since lost access to cannot learn "unchanged"
— the revalidation answer would itself be the disclosure. Dropping only the ETag would not close
that channel.
