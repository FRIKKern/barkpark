// attach-deadline.mjs — A CLOCK ON THE ONE STRETCH OF overflow-guard THAT HAD NONE.
//
// ── THE DEFECT (task-3eda8d2ebb0b2327) ──────────────────────────────────────
// overflow-guard.mjs bounds every wait it makes EXCEPT the window between
// "DevToolsActivePort is readable" and "the first leg navigates":
//
//   SERVER_CAP    15000ms   the static-server poll          bounded
//   DEVTOOLS_CAP  15000ms   the DevToolsActivePort poll     bounded
//   BRINGUP_ATTEMPTS  3     the launch loop                 bounded
//   RENDER/EVAL caps       every leg                        bounded
//   ─────────────────────  the attach                       NOTHING
//
// In that window sit three unbounded awaits: `fetch(/json/version)` with no
// AbortSignal; `Cdp.connect`, whose promise settles on `open` or on a transport
// `error` AND ON NOTHING ELSE; and every `cdp.send`, whose resolver is parked in
// a pending Map and freed only by a matching reply frame or by the socket's
// `close` handler. A CDP endpoint that ACCEPTS the websocket and then answers
// nothing settles none of the three.
//
// REPRODUCED on origin/main a2deecc1f with a deaf CDP stub (raw-net: answers
// /json/version with a real-shaped payload, completes the RFC6455 handshake,
// writes no frame ever) plus a fake Chrome that publishes a DevToolsActivePort
// pointing at it. The guard printed its three normal bring-up lines through
// `>> chrome  DeafChrome/0.0`, then sat ALIVE at %CPU 0.0 with EMPTY stderr,
// indefinitely — not a crash, not a slow run, an immortal silent process that
// burns the job timeout and reaches the merge button as an anonymous red.
//
// ── WHY A HANG IS WORSE THAN EITHER HONEST OUTCOME ──────────────────────────
// An instrument has three permitted endings: it MEASURED (0), it found a DEFECT
// (1), or it REFUSED (2). A hang is a fourth, and it is the only one that
// publishes no sentence: `scripts/console-refusal-capture.mjs` can quote a
// refusal, and a reviewer can read a defect, but there is nothing to quote from
// a process that never spoke. The whole point of the exit-2 vocabulary is that
// an environment fault says so; an unbounded await silently opts out of it.
//
// ── THE DISCRIMINATION THIS FILE MUST NOT BLUR ──────────────────────────────
// This bounds the ATTACH, never a MEASUREMENT. Everything after the first leg
// navigates keeps its own caps and its own exit codes; a slow PAGE is a finding
// about the page. A timeout here means the DEBUGGER never answered, so NOT ONE
// rule was read and NO CLAIM was made about any stylesheet — the same class
// bringup-retry.mjs reasons about one step earlier, and it is exit 2 for the
// same reason.
//
// ── AND WHY THE BUDGET IS GENEROUS ──────────────────────────────────────────
// The reported symptom is ~10 concurrent guards on one box, so a real attach
// under load is SLOW, not dead. A tight deadline would convert load into a
// refusal, which is a new lie in the other direction. The default is therefore
// far above any healthy attach (a local attach measures in tens of
// milliseconds) and only catches the class that never answers AT ALL.

/** The whole attach window's budget, per step. Overridable so a test rig and a
 *  loaded CI box can both be honest about what they are waiting for. */
export const ATTACH_CAP = Number(process.env.OVERFLOW_GUARD_ATTACH_CAP || 30000);

/**
 * Thrown when a step of the attach outlived its budget.
 *
 * Carries `attachTimeout: true` so a caller routes it onto ITS OWN exit-2 path
 * without sniffing the message — the same contract BringUpRefusal uses, for the
 * same reason: message sniffing is how a refusal quietly becomes a defect.
 */
export class AttachTimeout extends Error {
  constructor(step, ms) {
    super(
      `ATTACH TIMEOUT — "${step}" did not answer within ${ms}ms. The debugger ` +
      `accepted the connection and then said nothing, so NOT ONE rule was read ` +
      `and no claim is made about any stylesheet. Environment, not CSS. ` +
      `(raise OVERFLOW_GUARD_ATTACH_CAP if a loaded box needs longer)`,
    );
    this.name = "AttachTimeout";
    this.attachTimeout = true;
    this.refused = true;
    this.step = step;
    this.ms = ms;
  }
}

/**
 * Race one attach step against a clock.
 *
 * The timer is INJECTED (`setTimer`/`clearTimer`) so the unit suite can drive a
 * never-settling promise past its deadline on a fake clock, in a millisecond,
 * with no browser and no real waiting — which is the only way an arm about a
 * HANG can itself terminate.
 *
 * The timer is ALWAYS cleared on the settled path: an un-cleared Node timer
 * holds the event loop open, so a guard that measured everything correctly
 * would then refuse to exit — trading a hang before the legs for a hang after
 * them.
 *
 * @param {Promise<T>|any} work   the attach step, already started
 * @param {object} o
 * @param {string} o.step         what is being waited on, named in the refusal
 * @param {number} [o.ms]         budget (default ATTACH_CAP)
 * @returns {Promise<T>}
 * @throws {AttachTimeout} when the clock wins
 * @template T
 */
export function withAttachDeadline(work, {
  step,
  ms = ATTACH_CAP,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
} = {}) {
  return new Promise((resolve, reject) => {
    let done = false;
    const handle = setTimer(() => {
      if (done) return;
      done = true;
      reject(new AttachTimeout(step, ms));
    }, ms);
    // `unref` where the host offers it: a pending attach must never be the
    // reason the process stays alive after its own refusal is printed.
    if (handle && typeof handle.unref === "function") handle.unref();
    Promise.resolve(work).then(
      (v) => { if (done) return; done = true; clearTimer(handle); resolve(v); },
      (e) => { if (done) return; done = true; clearTimer(handle); reject(e); },
    );
  });
}
