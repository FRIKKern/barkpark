# Barkpark Cloud v4 — render index

All renders exported from the parameterized prototype (`Barkpark Cloud v4.dc.html`), not hand-drawn frames.

## matrix/ — Overview across theme × accent × billing scenario

Order: theme (dark → light) × accent (evergreen → iris → charple) × billing (active → trial → past_due).

| # | theme | accent | billing |
|---|-------|--------|---------|
| 01 | dark | evergreen | active |
| 02 | dark | evergreen | trial |
| 03 | dark | evergreen | past_due |
| 04 | dark | iris | active |
| 05 | dark | iris | trial |
| 06 | dark | iris | past_due |
| 07 | dark | charple | active |
| 08 | dark | charple | trial |
| 09 | dark | charple | past_due |
| 10 | light | evergreen | active |
| 11 | light | evergreen | trial |
| 12 | light | evergreen | past_due |
| 13 | light | iris | active |
| 14 | light | iris | trial |
| 15 | light | iris | past_due |
| 16 | light | charple | active |
| 17 | light | charple | trial |
| 18 | light | charple | past_due |

## screens/ — stress screens + first-tier greenfield (dark · evergreen)

| # | screen |
|---|--------|
| 01 | Fleet at density (compound status pills, axes line, hollow provider marks) |
| 02 | Instance workspace — Overview tab, bp CLI panel open (lifecycle actions + decommission) |
| 03 | Instance workspace — Timeline tab (health-report grouping) |
| 04 | Instance workspace — Usage tab (honest meters, "not measured yet" states) |
| 05 | Onboarding runway (trial scenario, Overview) |
| 06 | 2FA enrollment — QR + secret step |
| 07 | 2FA enrollment — recovery codes (plaintext-once) |
| 08 | Env-var manager — write-only replace-set editor over site detail |
| 09 | Provisioning theater — mid-flight (live step rail + streaming console) |

`overview-light-evergreen.png` (round-3 deliverable) remains the canonical light proof.

## screens2/ — round-5 re-exports + remaining screens (dark · evergreen)

06–08 from screens/ were broken by a prototype bug (three modal-body flags never wired), now fixed at source and re-exported:

| # | screen |
|---|--------|
| fixed 01 | Your account — 2FA enrollment, QR + secret step |
| fixed 02 | Your account — 2FA recovery codes (plaintext-once) |
| fixed 03 | Env-var manager — write-only replace-set editor |
| screen 04 | Sites list |
| screen 05 | Site detail — deploy ladder with failed deploy #40 selected (failure copy + console) + domain checklist |
| screen 06 | Webhooks tab — endpoint list + recent deliveries + replay |
| screen 07 | Operator console — rollout brake, canary wave, warm pool |

Dunning copy corrected to the 3-day backend grace (16 → 19 July).

## matrix/ accent proofs (P2-3)

01–04 accent-proof: ember dark, ember light, fjord dark, fjord light — Overview, active scenario. Closes the roster-blocker: all five identities now have rendered proof in both themes.
