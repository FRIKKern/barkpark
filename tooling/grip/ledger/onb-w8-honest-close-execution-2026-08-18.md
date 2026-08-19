<!-- doc-tier: cold | canonical-for: onb-w8-honest-close-execution | budget: 1400tok -->
# Onboarding composition epic — the honest close, executed (wave 8)

Date: 2026-08-18. Author: wave-8 close builder (`onb-w5-close-by-evidence-dossier`, epic-builder-execute-the-honest-close-of-onboarding-c). Surface: bp task ledger (live guerrilla). Zero product-code diff — this note is the only tracked artifact.

Wave 7 did all the close RESEARCH; its Fable close-execution builder was lost to the Fable cap (capped until Aug 21). This wave re-executed the close on Opus. All prerequisites verified live on origin/main (HEAD 097dfdd75b) before any write.

## The close mechanism (empirically re-proved, STEP 0)

A throwaway disposable task confirmed both arms on live guerrilla before any real close:

- `open -> done` via `/v1/data/mutate` (a raw field patch of `lifecycle_status`) is REFUSED: "cannot be moved to the terminal state done through /v1/data/mutate without a revision precondition". Terminal state is reached only through the close primitive.
- The CLOSE PRIMITIVE (`bp task close <id> <worker> <epoch> done ... --set criteria:=[...] --set criteria_override=...`) at the correct epoch SUCCEEDS and the read-back showed lifecycle=done. The probe was deleted.

The eight merge-gated children were REAPED (`claim.worker=null` but a NONZERO expired epoch — close.ex check_fencing keys on epoch presence, so observed_epoch=0 is fenced off). Each closed on its live-re-read stored epoch with `holder_override` + `criteria_override`. The epic itself was truly `claim:null` (epoch absent) and closed at observed_epoch=0 with no overrides.

## What landed

- Epic `onboarding-composition-epic`: lifecycle=done, 3/3 met, confirmed by server read-back (rev ba40a71337b2cdb42c74bea49cafbaae).
  - C0 (sub-5-min journey): FRESH dated proof 2026-08-18 — `scripts/onboarding-journey-proof.sh` LIVE PASS=7 ABORT=0 FAIL=0 (identity leg 1.29s, promptless localhost:4100), `--negctl` PASS=5. D23 wording carried verbatim.
  - C1 (release-cadence guard): GUARD-EXISTENCE + GREEN — guard added by `f71b1444cb` (+40 lines in `scripts/doctor.sh`); §1b live line `✓ release cadence current (cli-v1.17.0: 184 commit(s) / 3d behind main)`. NOT "zero drift" (§1b is advisory, drift-thresholded, has a skip branch). NEVER cites phantom `1928df610e` (touches only `setup/caddy.go`).
  - C2 (wave-1 slices merged + stamped): all EIGHT `onb-w1-*` children read done on their merge shas.
- Eight merge-gated children closed done on verified-ancestor merge shas: onramp-bom (#12035/15056195cd), fleet-health (#12086/25d7c27d1c), alias-shadow (#12060/71dddfeab7), main-hygiene (#12059/6df716ecea), windows-smoke (#12062/05d777e6cb — guard-existence only), device-receipt (#12088/8908e172ef), release-cache (#12089/5965853980), deploy-sh (#12090/11abdb43ec). isprod already done 5/5 (#12087/db0517c6c0).
- `onb-backlog-cloud-url-fleet-backfill`: idx3 merge-gate flipped (cf07df265f/#12061) → 4/5; idx4 HUMAN GATE stays open; lifecycle stays OPEN.
- `onb-backlog-relativeage-clock-injection`: closed cancelled/wont-do (superseded by Option B in LAST-SEEN #12086).
- `onb-backlog-release-cache-unify`: stays OPEN, enumerated (untouched).
- PR #11987 (wave-4 charter) closed UNMERGED; head 8ef508e2fade219a394fd4a260dcfa349491d6ea recorded as recovery anchor.
- `onboarding-composition-epic-wave-4-log` idx1 ("PR merged") annotated DEAD/evidence-only; met stays false, lifecycle stays done.

## THE HUMAN PACKET (three named items, all met:false — outside this wave)

- **A — gyldendal `BARKPARK_CLOUD_URL` backfill.** Set `BARKPARK_CLOUD_URL=https://barkpark.cloud` in the gyldendal fleet env over SSH and restart, so the cloud/deploy button appears. This IS `onb-backlog-cloud-url-fleet-backfill`'s open idx4 human gate. Blocked on live-fleet SSH execution.
- **B — gyldendal `PHX_HOST` / `PHX_SCHEME` redeploy.** The base_url leaks `http://localhost:4000`; set `PHX_HOST=<fqdn>` + `PHX_SCHEME=https` and redeploy. SEPARATE defect from A (config leak, not a missing button).
- **C — Windows × live-instance cell UNPROVEN.** The windows-smoke rider (#12062) has only self-tested hermetically; it has NOT yet fired on a real `install-cli.ps1` diff on windows-latest, and the Windows × paid-live-instance onboarding leg remains plan-proven only, never run.
