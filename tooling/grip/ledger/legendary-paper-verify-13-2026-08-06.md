<!-- doc-tier: cold | canonical-for: legendary-paper-verify-13-evidence | budget: 1800tok -->
# Verify 13 — email mobile geometry

Verdict: `partial`: mobile unsafety is proven for all four Papers, while the frozen claim’s fixed-width explanation is refuted. The 600px shell is responsive; uncontained intrinsic-width data tables cause whole-document overflow at 390px and 320px.

| Paper | 390px page overflow / crossing tables | 320px page overflow / crossing tables | 320px widest-table visibility |
| --- | ---: | ---: | ---: |
| Cloud Console wave 29 | 258px / 7 of 11 | 328px / 11 of 11 | ~46% |
| PDS wave 45 | 733px / 9 of 12 | 803px / 12 of 12 | ~26% |
| Cloud Console wave 28 | 501px / 15 of 18 | 571px / 17 of 18 | ~33% |
| PDS wave 44 | 221px / 5 of 5 | 291px / 5 of 5 | ~49% |

- The centered card uses `max-width:600px` and correctly shrinks to 318px content at viewport 390 and 248px at 320. Overflowing descendants enlarge document and card `scrollWidth`; the shell is not fixed-width.
- Every widest table computes to `table-layout:auto`, `overflow-x:visible`, no max width, and normal word breaking. Production emits width-100% tables and 24px horizontal cell padding without a wrapping/containment guard.
- Representative intrinsic tokens range from 242.75px to 386.16px, including ports, long test paths, and environment-variable identifiers. Widest tables measure 575–1,086.97px.
- No hidden/clip truncation was found. Instead the entire page requires horizontal panning; inspected 320px captures cut right-hand columns at the viewport boundary. Clients that clip the message canvas can make them unreachable.
- PDS45 overflows even at 1440px (document scroll width 1,507px). The other three avoid desktop page overflow, although CCH28’s 855px table still escapes its 600px card.
- All deployed routes returned 200 at the exact pins. Local and deployed renderers produced identical geometry in all twelve Paper/viewport cells. Prior survey measurements reproduced exactly; the correction is causal wording, not observed failure.
- The document has no viewport meta tag. Existing byte freezes pin emitted markup but do not test responsive browser geometry; one regression explicitly freezes the uncontained table shape.

Evidence: `/private/tmp/bp-verify13/metrics-live.json`, `metrics-local.json`, and screenshots. Representative 320px screenshot hashes are `f32324…5c92`, `e56610…f902`, `ec28cd…280e`, and `efcd71…6210`. Chromium proves browser geometry, not Gmail, Outlook, Apple Mail, WebKit, zoom, dark mode, or client clipping; those client trials remain post-repair work.

The exact four revisions and deployed/local surfaces were measured at clean commit `243a8da520`. No repository, Paper, task, or server state was mutated.
