// exit-vocabulary.mjs — THE ONE PLACE THE REFUSE/DEFECT RULE LIVES.
//
// ── WHY THIS FILE EXISTS AT ALL ──────────────────────────────────────────────
// The rule below was already written down, correctly, in overflow-guard.mjs:
//
//     "AUDITED (exit 2): the probe itself threw, so NOTHING was measured — an
//      incomplete run must never be reported as a measured overflow."
//
// It was written at the site where it was learned, and nowhere else. So it did
// not travel. A 2026-08-24 sweep of every instrument under __preview__ found the
// rule stated in one file's comment, obeyed by six of nine files, and BROKEN by
// two — one of which (cssom-parity.mjs) QUOTES the reasoning in its own catch
// block three lines below the two throws that violate it:
//
//     "A ReferenceError escaping this block is a missing global — an environment
//      fact, never a CSS fact ... this keeps a FUTURE missing global from being
//      reported to a reviewer as a stylesheet defect."
//
// The pattern was not "nobody knows the rule". It was "the rule lives where it
// was learned". A convention carried in a comment travels by whoever happened to
// read that file; a convention carried in a function signature travels by import.
// That is the whole reason this is a module and not a paragraph.
//
// ── THE RULE ─────────────────────────────────────────────────────────────────
// An instrument has exactly three things it can say, and they are not a severity
// ladder — they are three different CLAIMS:
//
//   exit 0  MEASURED, CLEAN     I measured the subject and it is sound.
//   exit 1  MEASURED, DEFECTIVE I measured the subject and found the defect I
//                               name. A human should go look at the subject.
//   exit 2  DID NOT MEASURE     I refused. I am making NO claim about the
//                               subject in EITHER direction. A refusal is not a
//                               clean bill and it is not an accusation.
//
// The failure this file exists to prevent is exit 2 leaking out as exit 1: an
// environment fault, a missing fixture, a readiness timeout or a crash wearing
// the clothes of a measured defect. That is strictly worse than a crash, because
// the reader is not merely blocked — the reader is MISDIRECTED, sent to hunt for
// a defect in a subject that was never read. Measured cost, 2026-08-24: a parse
// timeout in cssom-parity.mjs is announced to the reviewer as "a REAL CSS defect
// in cloud/priv/static/app.css — rules the browser dropped or rewrote. See the
// diff above." There is no diff above. Nothing was parsed.
//
// The inverse leak — a real defect reported as a refusal — is also wrong, and is
// why `defect()` exists as its own verb rather than as "not a refusal".
//
// ── WHY THE EXIT IS DRAINED AND NOT JUST CALLED ──────────────────────────────
// seal-predicate.mjs is the one instrument in this tree that got this right on
// purpose, and it says why: on a PIPE — which is what CI always gives you —
// stdout is ASYNCHRONOUS, so `process.stderr.write(refusal); process.exit(2)`
// can terminate the process with the refusal still sitting in the buffer. The
// instrument then refuses SILENTLY and the reader sees a bare exit code with no
// cause. Every exit here drains first, so a shared helper cannot propagate that
// bug to its consumers along with the rule it is meant to carry.

export const EXIT_OK = 0;
export const EXIT_DEFECT = 1;
export const EXIT_REFUSED = 2;

// THE TAG. `Symbol.for` rather than `Symbol()` so a refusal raised in one module
// is still recognised as one after crossing a module boundary — the registry is
// process-wide, a bare Symbol is not, and a tag that silently stopped matching
// would fail OPEN into "defect", which is the exact direction this file forbids.
export const REFUSED = Symbol.for("barkpark.preview.refused-to-measure");

// Raise this when the instrument could not measure. It is an ordinary Error, so
// every existing `catch` and stack trace keeps working; the tag is what `settle`
// and `isRefusal` sort on.
export function refusalError(message, { cause } = {}) {
  const err = new Error(message);
  err[REFUSED] = true;
  if (cause !== undefined) err.cause = cause;
  return err;
}

// A ReferenceError is ALWAYS a refusal and never a subject defect: it means this
// runtime is missing a global the instrument needs (the measured case: no
// `WebSocket` on Node 20), so the instrument never ran, so it measured nothing.
// This is the one implicit rule, and it lives here rather than being re-derived
// in each file that needs it.
export function isRefusal(err) {
  return Boolean(err && (err[REFUSED] === true || err instanceof ReferenceError));
}

// How long to wait for a backpressured stream before exiting anyway. A truncated
// refusal is bad; an instrument that HANGS forever holding a CI runner is worse,
// and it fails in a shape nobody recognises as this bug.
export const DRAIN_CAP_MS = 2000;

// Flush before exiting. `write` returns false only when the buffer is full, and
// only then is there anything to wait for.
//
// THIS USES THE STREAM'S OWN `once`, NOT `events.once`, AND THE DIFFERENCE IS A
// BUG THIS MODULE'S OWN TEST CAUGHT. The first version wrapped `events.once` in
// `try { … } catch {}` — meaning to tolerate a stream closing mid-flush. But
// `events.once` throws synchronously on anything that is not an EventEmitter or
// EventTarget, and the catch swallowed that too, falling straight through to the
// exit. The helper written to stop truncated refusals would have shipped
// truncating them, silently, on exactly the streams a caller might inject. So
// the wait is now explicit: resolve on `drain`, on `error`, on `close`, or on a
// bounded timer, and never on a swallowed exception.
async function writeDrained(stream, text) {
  if (!text) return;
  if (stream.write(text)) return;
  if (typeof stream.once !== "function") return; // nothing to wait on
  await new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve();
    };
    // `unref` where available so a pending drain timer can never be the only
    // thing keeping the process alive.
    const timer = setTimeout(finish, DRAIN_CAP_MS);
    if (typeof timer.unref === "function") timer.unref();
    stream.once("drain", finish);
    stream.once("error", finish);
    stream.once("close", finish);
  });
}

/**
 * Build an instrument's exit vocabulary.
 *
 * `instrument` names the banner ("OVERFLOW GUARD", "GUARD", "PROOF"). `teardown`
 * is awaited before every exit, so a browser or server is never left running by
 * a refusal — the case that made overflow-guard.mjs write its rule down.
 *
 * `subject` is what the instrument measures ("cloud/priv/static/app.css"), and
 * it appears in the refusal so the reader is told, BY NAME, what was not judged.
 * A refusal that does not say what it declined to measure is half a refusal.
 */
// @canonical capability:instrument-exit-vocabulary aka:refuse,refusal,exit 2,exit code,refused to measure,environment fault,measured defect,die,teardown
export function createExitVocabulary({
  instrument,
  subject = "the subject",
  teardown = async () => {},
  stdout = process.stdout,
  stderr = process.stderr,
  exit = (code) => process.exit(code),
} = {}) {
  if (!instrument) throw new Error("createExitVocabulary needs an `instrument` name for its banner");

  const finish = async (code, text, stream) => {
    await teardown();
    await writeDrained(stream, text);
    return exit(code);
  };

  return {
    REFUSED,
    refusalError,
    isRefusal,

    // NO CLAIM IS BEING MADE. The wording is fixed here rather than per-caller so
    // that every refusal in this tree is greppable and reads the same way to a
    // human who has seen one of them before.
    refuse: (reason) =>
      finish(
        EXIT_REFUSED,
        `\n!! ${instrument} (exit 2): REFUSED TO MEASURE — ${reason}\n` +
          `   NO claim is being made about ${subject}, in either direction: a refusal is the\n` +
          `   absence of a measurement, not a clean bill and not an accusation.\n`,
        stderr,
      ),

    // A MEASURED DEFECT. Reserved for "I read the subject and it is wrong".
    defect: (reason) =>
      finish(EXIT_DEFECT, `\n!! ${instrument} (exit 1): MEASURED DEFECT — ${reason}\n`, stderr),

    pass: (reason) => finish(EXIT_OK, `${instrument} PASS — ${reason}\n`, stdout),

    // THE ONE-CALL CATCH. This is the line that makes the rule travel: a
    // harness's `catch (err)` becomes `await vocab.settle(err)`, and the
    // classification stops being a judgement call at every throw site.
    //
    // UNTAGGED THROWS SORT AS REFUSALS, DELIBERATELY. An unexpected throw means
    // the instrument stopped early, so it did not finish measuring — reporting
    // that as a defect is the precise error this module exists to prevent. A
    // real defect must be raised through `defect()`, which is a decision rather
    // than a default. Fail toward "I did not measure", never toward an accusation.
    settle: async (err) => {
      const detail = (err && err.message) || String(err);
      return isRefusal(err)
        ? finish(
            EXIT_REFUSED,
            `\n!! ${instrument} (exit 2): REFUSED TO MEASURE — ${detail}\n` +
              `   NO claim is being made about ${subject}, in either direction.\n`,
            stderr,
          )
        : finish(
            EXIT_REFUSED,
            `\n!! ${instrument} (exit 2): REFUSED TO MEASURE — the instrument threw before it ` +
              `finished: ${detail}\n` +
              `   An unexpected throw means the run stopped early, so it measured NOTHING. NO claim\n` +
              `   is being made about ${subject} — this is NOT a defect finding.\n`,
            stderr,
          );
    },
  };
}
