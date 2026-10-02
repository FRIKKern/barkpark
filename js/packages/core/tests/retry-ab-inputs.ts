// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// THE HARNESS PARAMETERS OF THE A/B — the LIVE half of the pin.
//
// These used to be module-local consts inside retry-ab.test.ts. They live here
// because two readers need them and the two must read the SAME value: the
// harness that produces a number, and the pin in retry-ab.test.ts that checks
// the recorded number still describes the harness that produced it.
//
// This file is the GUARDED side. Its counterpart, retry-ab.recorded.ts, is a
// hand-written transcript of what these were WHEN THE NUMBERS WERE TAKEN, and
// it deliberately imports nothing from here or from src/retry — a guard whose
// expected value is read out of the thing it guards cannot fire.
//
// Changing anything in this file, or any of the src/retry constants the pin
// also covers, invalidates the recorded measurement. Re-run the harness; do not
// edit the transcript to match.

/** Command pairs per arm. */
export const PAIRS = 40
/** The caller's whole-call budget, mirroring the Go client's 5s http.Client.Timeout. */
export const BUDGET_MS = 5_000
/** Base delay handed to the retry loop by both arms. */
export const BASE_MS = 300
/** Backoff ceiling handed to the retry loop by both arms. */
export const MAX_BACKOFF_MS = 5_000
/** Attempts including the first, for both arms. */
export const MAX_ATTEMPTS = 3

// Arm B's stated distribution. It is an ASSUMPTION, not a measurement (see the
// arm B banner in retry-ab.test.ts) — but the recorded 27/40 vs 32/40 is a
// deterministic function of these three numbers, so moving one silently
// restates the result.
/** Arm B TTFB floor, ms — the guerrilla band recorded 2026-08-23. */
export const TTFB_MIN = 350
/** Arm B TTFB ceiling, ms — the guerrilla band recorded 2026-08-23. */
export const TTFB_MAX = 4_500
/** Arm B fault rate. INVENTED; no fault rate was ever recorded for that box. */
export const FAULT_RATE = 0.45
