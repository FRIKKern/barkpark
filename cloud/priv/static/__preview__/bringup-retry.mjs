// bringup-retry.mjs — ONE bounded Chrome bring-up, shared by the four browser
// instruments (cssom-parity, overflow-guard, breakpoint-sweep, modal-oracle).
//
// ── WHY THIS EXISTS ────────────────────────────────────────────────────────
// Measured over 85 real console-harness browser-job attempts: 74 success / 11
// failure, 10 of the 11 being "Chrome never wrote DevToolsActivePort" — a
// per-VM, stochastic bring-up refusal. Capacity was refuted four ways (same
// run, same second, same sha: one browser job succeeded while a sibling
// refused; the one all-three-fail run spanned three Azure regions and two
// runner images; a same-instant, same-region, same-image control succeeded).
// Every one of those refusals reached the merge button as a red REQUIRED
// context, and a reviewer's first move on a red CSS gate is to go hunting for
// a CSS bug that was never measured.
//
// ── THE DISCRIMINATION THIS FILE MUST NOT BLUR ─────────────────────────────
// cch-w19-bl-gr115-intermittent-ua-defaults rules: "Do NOT paper over it with
// a retry that hides the race." That ruling governs an exit-1 MEASURED
// intermittency — the instrument PARSED the stylesheet and reported UA
// defaults on one run and clean on the next, so a retry would be discarding a
// real observation about app.css.
//
// This is the other class. An exit-2 BRING-UP REFUSAL is the browser failing
// to exist: NOT ONE rule was parsed, so NO CLAIM WAS MADE about any
// stylesheet, and there is by construction nothing for a retry to hide. The
// two classes are kept apart by exit code, not by prose: anything the browser
// tells us AFTER it is up stays exit 1 and is NEVER retried by this helper —
// this helper's scope ends the instant DevToolsActivePort is readable.
//
// ── TWO NON-OPTIONAL MECHANICS ─────────────────────────────────────────────
// (i)  A FRESH PROFILE DIR PER ATTEMPT. All four instruments mkdtemp'd the
//      profile ONCE, before the bring-up. Retrying into that same directory
//      re-races the same DevToolsActivePort path against a possibly-still-dying
//      Chrome, so `newProfile()` is called INSIDE the loop, per attempt.
// (ii) ATTEMPT STDERR IS CAPTURED AND PRINTED. All four spawned with
//      `stdio: "ignore"`, which throws Chrome's own account of why it died on
//      the floor. A retry that keeps that is a fix nobody can audit: the second
//      attempt succeeds silently, the class vanishes from the ledger, and
//      nobody ever learns the cause. Every failed attempt prints its captured
//      stderr tail, and a succeeding retry says which attempt won.
//
// Deliberately NOT claimed: an efficacy multiplier. Attempt independence on the
// SAME VM is unproven, so this file logs the attempt number and outcome and
// lets the conversion ratio be READ off real runs rather than asserted here.

const DEFAULT_ATTEMPTS = 2;

/** How many bring-up attempts each instrument makes. Bounded on purpose: an
 *  unbounded retry converts a dead runner into a job that burns its timeout
 *  instead of refusing, which is a slower lie, not a smaller one. */
export const BRINGUP_ATTEMPTS = DEFAULT_ATTEMPTS;

/** Bytes of a single attempt's stderr kept for the refusal report. Chrome is
 *  chatty in headless (font config, dbus, GPU); the tail is where the fatal
 *  line lands. */
export const STDERR_TAIL_CAP = 4000;

/** Thrown when every bounded attempt refused. Carries `refused: true` so each
 *  instrument can route it onto ITS OWN exit-2 path (cssom-parity's tagged
 *  bring-up error, overflow-guard's and breakpoint-sweep's `die()`,
 *  modal-oracle's by-hand exit) without message sniffing. */
export class BringUpRefusal extends Error {
  constructor(message, { attempts = 0, reasons = [] } = {}) {
    super(message);
    this.name = "BringUpRefusal";
    this.refused = true;
    this.attempts = attempts;
    this.reasons = reasons;
  }
}

/**
 * Attach a bounded stderr collector to a spawned child.
 *
 * The caller must have spawned with stderr as a PIPE (`stdio: ["ignore",
 * "ignore", "pipe"]`). An unread pipe can fill and block the child, so this
 * always consumes; it just refuses to keep more than STDERR_TAIL_CAP bytes.
 *
 * @returns {() => string} the captured tail, callable at any time.
 */
export function captureStderr(child, cap = STDERR_TAIL_CAP) {
  let tail = "";
  if (!child || !child.stderr) return () => tail;
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => {
    tail += chunk;
    if (tail.length > cap) tail = tail.slice(tail.length - cap);
  });
  child.stderr.on("error", () => { /* the pipe dying is not a measurement */ });
  return () => tail;
}

/** One tidy block of an attempt's captured stderr, or an honest statement that
 *  there was none — silence is itself a finding (a Chrome that never execed
 *  writes nothing). */
export function formatStderrTail(tail, { indent = "   " } = {}) {
  const text = (tail || "").replace(/\s+$/, "");
  if (!text) return `${indent}chrome stderr: (empty — the process wrote nothing before it went away)\n`;
  const lines = text.split("\n");
  return `${indent}chrome stderr (last ${lines.length} line(s)):\n` +
    lines.map((l) => `${indent}  | ${l}\n`).join("");
}

/**
 * Bring headless Chrome up, retrying a BOUNDED number of times, each attempt in
 * a FRESH profile directory, printing every failed attempt's captured stderr.
 *
 * Every OS interaction is injected so the retry logic itself is unit-testable
 * without a browser — see bringup-retry.test.mjs.
 *
 * @param {object} o
 * @param {string}   o.label              instrument name, for the log lines
 * @param {number}  [o.attempts]          bound (default BRINGUP_ATTEMPTS)
 * @param {() => string} o.newProfile     MUST allocate a FRESH dir each call
 * @param {(profile: string) => ({ child: any, readStderr?: () => string } | Promise<...>)} o.launch
 * @param {(ctx: {profile: string, child: any}) => Promise<number|null>} o.awaitDevToolsPort
 *        resolves the DevTools port, or null/0 when it never appeared
 * @param {(ctx: {profile: string, child: any, attempt: number}) => Promise<void>} o.abandon
 *        reap the child and remove the profile dir of a FAILED attempt
 * @param {(s: string) => void} [o.log]
 * @returns {Promise<{devPort: number, profile: string, child: any, attempt: number}>}
 * @throws {BringUpRefusal} when every attempt refused
 */
export async function bringUpChrome({
  label,
  attempts = DEFAULT_ATTEMPTS,
  newProfile,
  launch,
  awaitDevToolsPort,
  abandon,
  log = (s) => process.stderr.write(s),
}) {
  const reasons = [];

  for (let attempt = 1; attempt <= attempts; attempt++) {
    const profile = newProfile();
    let child = null;
    let readStderr = () => "";
    let reason = null;

    try {
      const started = await launch(profile);
      child = started && started.child ? started.child : null;
      if (started && typeof started.readStderr === "function") readStderr = started.readStderr;
      const devPort = await awaitDevToolsPort({ profile, child });
      if (devPort) {
        if (attempt > 1) {
          const refusedSoFar = attempt - 1;
          log(
            `>> bring-up   ${label}: attempt ${attempt}/${attempts} SUCCEEDED after ` +
              `${refusedSoFar} refusal${refusedSoFar === 1 ? "" : "s"} — each refusal's chrome stderr is printed above.\n` +
              `>> bring-up   This run's measurement comes from attempt ${attempt}. The refusal${refusedSoFar === 1 ? " was an ENVIRONMENT event" : "s were ENVIRONMENT events"}, never a claim about the page.\n`,
          );
        }
        return { devPort, profile, child, attempt };
      }
      reason = "Chrome never wrote DevToolsActivePort — it did not start";
    } catch (err) {
      // A synchronous or async spawn fault (ENOEXEC on an arch-mismatched
      // binary, EACCES from a mount option, ETXTBSY mid-download) is still a
      // bring-up refusal: the browser was never executed, so nothing was
      // measured. It is retried like any other, and named in the final report.
      reason = err && err.message ? err.message : String(err);
    }

    reasons.push(reason);
    log(
      `\n!! bring-up   ${label}: attempt ${attempt}/${attempts} REFUSED — ${reason}\n` +
        `   profile: ${profile}\n` +
        formatStderrTail(readStderr()),
    );
    await abandon({ profile, child, attempt });
  }

  const last = reasons[reasons.length - 1] || "Chrome never came up";
  throw new BringUpRefusal(
    `${last} (${attempts} bounded bring-up attempt${attempts === 1 ? "" : "s"}, each in a fresh profile — every one refused)`,
    { attempts, reasons },
  );
}
