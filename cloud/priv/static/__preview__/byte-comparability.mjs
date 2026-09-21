// byte-comparability.mjs — which preview scenarios a PNG-diff gate may compare
// byte for byte, and which it must not.
//
// WHY (task-a0258bec59b256d7, criterion 1)
// ────────────────────────────────────────────────────────────────────────────
// A quarter of the committed scenarios paint CLOCK-DEPENDENT content — relative
// timestamps ("3m ago"), countdowns, trial runways, in-flight deploy ages. Two
// runs of the SAME tree produce different bytes for them, so any future gate
// that diffs matrix PNGs would red on the clock and be called flaky within a
// day. That knowledge existed only as a sentence in an evidence packet; this
// file is where the harness itself holds it, so the exclusion happens by
// construction instead of by someone remembering.
//
// DERIVED BY A CONTROL, NEVER TYPED
// ────────────────────────────────────────────────────────────────────────────
// The list below is the output of two INDEPENDENT SERIAL runs of shoot.sh over
// the whole matrix, diffed cell by cell. Serial, not sharded: parallel shards
// add their own instability (measured by the 2026-09-20 re-review: 37 unstable
// under parallel sharding against 35 serial), and a list that cannot tell the
// clock from the scheduler is not a list about the clock.
//
// The comment beside each row is the CELLS that moved, which is the part a
// re-derivation can disagree with. 29 of the 35 moved in all four cells; the
// six that moved at 1440 only (notif-member, shell-site, the three
// site-binding-* and sites-on-instance) are the ones whose clock text is
// dropped at the tablet width — exactly the rows a ONE-CELL control classifies
// by luck. The 2026-09-20 re-review sampled a single cell (ember/light/1440)
// and landed on the same count of 35; this control read all four, so the
// agreement is two instruments, not one repeated.
//
// TO RE-DERIVE (about 11 minutes on an M-series laptop, ~0.85s per shot):
//
//   CHROME=<chrome-headless-shell> PORT=4473 OUT=/tmp/runA ./shoot.sh
//   CHROME=<chrome-headless-shell> PORT=4474 OUT=/tmp/runB ./shoot.sh
//   # then: any cell whose sha256 differs between runA and runB is unstable;
//   # a scenario is unstable if ANY of its cells is.
//
// WHAT THIS FILE IS NOT: it is not a defect list. An unstable scenario is
// perfectly reviewable by eye and by every non-byte assertion in this harness.
// It is a statement about ONE comparison operator.

import { SCENARIOS } from "./scenarios.mjs";

// The scenarios two identical runs disagree about. Sorted; the suite beside
// this file reds on a row naming a scenario that no longer exists.
export const CLOCK_UNSTABLE = [
  "activity-identity-change",                // dark/1440,dark/768,light/1440,light/768
  "billing-cancelling",                      // dark/1440,dark/768,light/1440,light/768
  "billing-forever",                         // dark/1440,dark/768,light/1440,light/768
  "billing-me-recovers",                     // dark/1440,dark/768,light/1440,light/768
  "billing-me-unreadable",                   // dark/1440,dark/768,light/1440,light/768
  "billing-member",                          // dark/1440,dark/768,light/1440,light/768
  "billing-past-due",                        // dark/1440,dark/768,light/1440,light/768
  "billing-portal-return",                   // dark/1440,dark/768,light/1440,light/768
  "billing-support-plus",                    // dark/1440,dark/768,light/1440,light/768
  "deploy-detail-cruel",                     // dark/1440,dark/768,light/1440,light/768
  "env-editor",                              // dark/1440,dark/768,light/1440,light/768
  "failed",                                  // dark/1440,dark/768,light/1440,light/768
  "instance-failed-member",                  // dark/1440,dark/768,light/1440,light/768
  "notif-member",                            // dark/1440,light/1440
  "promote-failure",                         // dark/1440,dark/768,light/1440,light/768
  "promote-in-flight",                       // dark/1440,dark/768,light/1440,light/768
  "promote-migrated",                        // dark/1440,dark/768,light/1440,light/768
  "promote-retry",                           // dark/1440,dark/768,light/1440,light/768
  "provisioning",                            // dark/1440,dark/768,light/1440,light/768
  "rollback",                                // dark/1440,dark/768,light/1440,light/768
  "shell-site",                              // dark/1440,light/1440
  "site-binding-bound",                      // dark/1440,light/1440
  "site-binding-mismatch",                   // dark/1440,light/1440
  "site-binding-unknown",                    // dark/1440,light/1440
  "site-deploy-rail-failed",                 // dark/1440,dark/768,light/1440,light/768
  "site-deploy-rail-failed-classified",      // dark/1440,dark/768,light/1440,light/768
  "site-deploy-rail-live",                   // dark/1440,dark/768,light/1440,light/768
  "site-member",                             // dark/1440,dark/768,light/1440,light/768
  "site-states",                             // dark/1440,dark/768,light/1440,light/768
  "sites-on-instance",                       // dark/1440,light/1440
  "theater-failed",                          // dark/1440,dark/768,light/1440,light/768
  "theater-failed-member",                   // dark/1440,dark/768,light/1440,light/768
  "theater-midflight",                       // dark/1440,dark/768,light/1440,light/768
  "webhooks-autodisabled",                   // dark/1440,dark/768,light/1440,light/768
  "webhooks-panel",                          // dark/1440,dark/768,light/1440,light/768
]

// The provenance of the list above, machine-readable so the suite can assert it
// is complete enough to repeat.
export const DERIVATION = Object.freeze({
  date: "2026-09-21",
  base: "35888f22f7c5d2d355f428d13116c780cfd1fcd5",
  command:
    "CHROME=<chrome-headless-shell> OUT=<dir> ./shoot.sh  (twice, SERIAL, full matrix; sha256 per cell, diffed)",
  chrome: "chromium_headless_shell-1217 (chrome-headless-shell-mac-arm64)",
  runs: 2,
  cells: 552, // 138 scenarios x {light,dark} x {1440,768}
  unstableCells: 128,
});

const UNSTABLE = new Set(CLOCK_UNSTABLE);

// Comparable unless a control PROVED otherwise. The polarity is deliberate: a
// scenario added after this register was derived is compared, and shows up as a
// gate failure someone must classify, rather than being silently skipped by a
// default that quietly stops looking as the suite grows.
export function isByteComparable(name) {
  return !UNSTABLE.has(String(name));
}

// The population a PNG-diff gate may legitimately assert over, derived from
// scenarios.mjs on every call rather than stored.
export function byteComparableScenarios() {
  return Object.keys(SCENARIOS).filter(isByteComparable).sort();
}
