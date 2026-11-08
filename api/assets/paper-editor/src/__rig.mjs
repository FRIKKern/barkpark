// __rig.mjs — the exit rule every rig shares, here and in
// api/assets/paper-editor-host-tests/: green means it measured.
//
//   skip(what)          prints `SKIP  <what>` and returns 0, or, under
//                       BP_REQUIRE_CHROME=1 (CI, where a browser is installed
//                       on purpose), prints a FAIL line and returns 1. Use it as
//                       an exit code (`process.exit(skip(…))`) or add it to the
//                       failure count.
//   exitRig(p, f)       exits 1 on any failure, and on ZERO passes: a rig that
//                       ran no case is broken, not clean.
//   tally({ verbose })  the one PASS/FAIL counter rigs share: check(name, fn),
//                       checkAsync(name, fn), record(name, ok, detail). PASS
//                       lines print only when verbose; FAIL lines always.
//   rigRuleBreaks(f, s) what a rig source `s` (file name `f`) does against the
//                       rule. __rig.test.mjs applies it to the rigs in src/ and
//                       paper-editor-host-tests/__rig_rule.test.mjs to the rigs
//                       that moved there.
//
// Locally, with no browser, a SKIP still exits 0: `npm test` and the render
// scripts stay runnable on a machine that has none.

export const CHROME_REQUIRED = process.env.BP_REQUIRE_CHROME === "1";

export function skip(what) {
  console.log(`SKIP  ${what}`);
  if (!CHROME_REQUIRED) return 0;
  console.log("FAIL  BP_REQUIRE_CHROME=1, and a skipped rig is not a passing rig");
  return 1;
}

export function exitRig(passes, failures) {
  if (passes === 0) {
    console.log("FAIL  0 PASS: the rig ran no case, which is not a pass");
    process.exit(1);
  }
  process.exit(failures === 0 ? 0 : 1);
}

export function tally({ verbose = true } = {}) {
  const t = {
    passes: 0,
    failures: 0,
    record(name, ok, detail) {
      if (ok) {
        t.passes += 1;
        if (verbose) console.log(`PASS  ${name}`);
      } else {
        t.failures += 1;
        console.log(`FAIL  ${name}${detail === undefined ? "" : `\n      ${detail}`}`);
      }
      return ok;
    },
    check(name, fn) {
      try { fn(); } catch (e) { return t.record(name, false, e.message); }
      return t.record(name, true);
    },
    async checkAsync(name, fn) {
      try { await fn(); } catch (e) { return t.record(name, false, e.message); }
      return t.record(name, true);
    },
  };
  return t;
}

export function rigRuleBreaks(f, src) {
  return [
    ...(/from "[./\w-]*\/__rig\.mjs"/.test(src) ? [] : [`${f}: does not import __rig.mjs`]),
    ...(/\bexitRig\(/.test(src) ? [] : [`${f}: does not exit through exitRig()`]),
    ...(/process\.exit\((?!skip\()/.test(src) ? [`${f}: calls process.exit outside skip()`] : []),
    ...(/process\.exitCode/.test(src) ? [`${f}: sets process.exitCode`] : []),
    ...(/\blet passes\b|\bpasses\s*(\+\+|\+=)/.test(src) ? [`${f}: counts its own passes instead of tally()`] : []),
    ...(/console\.log\([`"']SKIP/.test(src) ? [`${f}: prints SKIP by hand instead of skip()`] : []),
  ];
}
