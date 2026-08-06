<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-26 | budget: 1400tok -->
# Restart Survey 26 — CCH29 Studio live regression and frozen gates

Assignment `restart-survey-26` re-attested `cloud-console-hardening-wave-29-2026-08-03::studio` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **unchanged lossy adapter; connected geometry, navigation, revision identity, and accessibility blocked in this lane**.

## Direct answer

Published, drafts, and raw machine reads resolve to exact pinned revision `18768b0a14c2eead927181c4a0e37c18`: 431,200 bytes, SHA-256 `2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15`. Direct draft-twin lookup is typed not-found. Canonical flat/scoped routes and invalid-workspace 404 work, while this lane’s canonical Studio request stopped at authentication.

Static replay of the exact current payload through the current Studio canvas converter preserves all 252 IDs and exact order but remains materially lossy: exact text 239/252; paragraph-wrapped nested lists preserve 0/406 words across 11 items; legacy table headers preserve 0/35 because the adapter reads `head` while source uses `header`; 313 inline mark records become zero.

## Frozen-gate ruling

Machine source and block/order accounting pass. Lossless text, nested lists, table headers, and inline semantics remain failures. Callout tone adapter exists statically, but connected accessibility is unproven. Geometry, focus/navigation, connected revision identity, post-auth errors, and LiveView reliability were blocked in this lane and are not proxy-passed by machine JSON or adapter replay.

The inspected mounted revision path derives from content `rev` or zero rather than proving top-level `_rev`; connected capture in Survey 25 independently confirms immutable `_rev` absence. Source/pre-auth routes were stable, but no broader connected reliability pass is claimed. No mutations or test-suite pass occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-26","unit":"cloud-console-hardening-wave-29-2026-08-03::studio","paper_rev":"18768b0a14c2eead927181c4a0e37c18","verdict":"unchanged_failure_with_connected_gates_blocked","source":{"blocks":252,"bytes":431200,"sha256":"2524c05d63ac96c31f31e4c8a54219be64d23e8356ec7acd27978c358509ec15"},"adapter_replay":{"blocks_preserved":"252/252","order_exact":true,"text_exact":"239/252","nested_words_preserved":"0/406","legacy_headers_preserved":"0/35","marks":"313->0"},"connected_studio":"blocked_authentication_in_this_lane","mutations":false,"tests_claimed_passing":false}
```
