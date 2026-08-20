// bringup-retry.test.mjs — the retry helper, proven without a browser.
//
// What this file is FOR: the fix it guards is invisible in a green run (a
// second attempt that succeeds prints two extra lines and nothing else), so the
// only way the mechanics stay honest is a test that asserts them directly —
// that a retry HAPPENS, that it gets a FRESH profile dir, that failed-attempt
// stderr is PRINTED, and above all that N consecutive refusals still REFUSE.
//
// The last one is the fail-closed assertion: if this helper could ever resolve
// without a DevTools port, a required Console gate would go green over a run
// that measured nothing.

import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { Readable } from "node:stream";

import {
  BRINGUP_ATTEMPTS,
  BringUpRefusal,
  bringUpChrome,
  captureStderr,
  formatStderrTail,
} from "./bringup-retry.mjs";

// ── a harness that stands in for the OS ──────────────────────────────────────
// `ports` is the script: one entry per attempt. A number = Chrome came up on
// that port; null = it never wrote DevToolsActivePort; an Error = spawn threw.
function harness(ports, { attempts = BRINGUP_ATTEMPTS, stderrPerAttempt = [] } = {}) {
  const profiles = [];
  const abandoned = [];
  const logged = [];
  let n = 0;

  const run = () =>
    bringUpChrome({
      label: "test-instrument",
      attempts,
      newProfile: () => {
        const p = `/tmp/test-instrument-${profiles.length}`;
        profiles.push(p);
        return p;
      },
      launch: (profile) => {
        const i = n;
        n += 1;
        const outcome = ports[i];
        if (outcome instanceof Error) throw outcome;
        return { child: { pid: 1000 + i, profile }, readStderr: () => stderrPerAttempt[i] || "" };
      },
      awaitDevToolsPort: async ({ child }) => {
        const outcome = ports[child.pid - 1000];
        return typeof outcome === "number" ? outcome : null;
      },
      abandon: async ({ profile, child, attempt }) => {
        abandoned.push({ profile, pid: child && child.pid, attempt });
      },
      log: (s) => logged.push(s),
    });

  return { run, profiles, abandoned, logged, log: () => logged.join("") };
}

test("a first-attempt refusal followed by a success RETURNS success", async () => {
  const h = harness([null, 9222]);
  const r = await h.run();
  assert.equal(r.devPort, 9222);
  assert.equal(r.attempt, 2, "the winning attempt is reported, not hidden");
});

test("N consecutive refusals still REFUSE — the helper can never green an unmeasured run", async () => {
  const h = harness([null, null]);
  await assert.rejects(h.run(), (err) => {
    assert.ok(err instanceof BringUpRefusal);
    assert.equal(err.refused, true, "the class is carried on the object, never sniffed from the message");
    assert.equal(err.attempts, 2);
    assert.match(err.message, /DevToolsActivePort/);
    assert.match(err.message, /bounded bring-up attempts/);
    return true;
  });
});

test("a three-attempt bound refuses after exactly three — the loop is BOUNDED", async () => {
  const h = harness([null, null, null, 9222], { attempts: 3 });
  await assert.rejects(h.run(), (err) => err instanceof BringUpRefusal);
  assert.equal(h.profiles.length, 3, "it stopped at the bound instead of reaching the scripted success");
});

test("every attempt gets a FRESH profile dir — the retry never re-races the first one", async () => {
  const h = harness([null, 9222]);
  await h.run();
  assert.equal(h.profiles.length, 2);
  assert.notEqual(h.profiles[0], h.profiles[1]);
  assert.equal(
    h.abandoned[0].profile,
    h.profiles[0],
    "the failed attempt's profile is handed to abandon() for removal, not leaked",
  );
});

test("a FAILED attempt's chrome stderr is PRINTED — the fix stays auditable", async () => {
  const h = harness([null, 9222], {
    stderrPerAttempt: ["[0807/010302.1:ERROR:socket_posix.cc(99)] bind() failed: Address already in use"],
  });
  await h.run();
  const log = h.log();
  assert.match(log, /attempt 1\/2 REFUSED/);
  assert.match(log, /chrome stderr/);
  assert.match(log, /bind\(\) failed: Address already in use/);
  assert.match(log, /attempt 2\/2 SUCCEEDED after 1 refusal/);
  assert.match(log, /never a claim about the page/);
});

test("silence from chrome is reported as silence, not as an absent section", async () => {
  const h = harness([null, 9222]);
  await h.run();
  assert.match(h.log(), /wrote nothing before it went away/);
});

test("a synchronous spawn throw is a REFUSAL, not a measured defect, and is retried", async () => {
  const enoexec = Object.assign(new Error("spawn ENOEXEC"), { code: "ENOEXEC" });
  const h = harness([enoexec, 9222]);
  const r = await h.run();
  assert.equal(r.attempt, 2);
  assert.match(h.log(), /attempt 1\/2 REFUSED — spawn ENOEXEC/);
});

test("a spawn that throws on EVERY attempt refuses, naming the errno", async () => {
  const enoexec = Object.assign(new Error("spawn ENOEXEC"), { code: "ENOEXEC" });
  const h = harness([enoexec, enoexec]);
  await assert.rejects(h.run(), (err) => {
    assert.ok(err instanceof BringUpRefusal);
    assert.match(err.message, /ENOEXEC/);
    assert.deepEqual(err.reasons, ["spawn ENOEXEC", "spawn ENOEXEC"]);
    return true;
  });
});

test("a first-attempt SUCCESS is silent — no retry noise on the 88% path", async () => {
  const h = harness([9222, 9333]);
  const r = await h.run();
  assert.equal(r.attempt, 1);
  assert.equal(h.log(), "", "nothing is printed when the browser comes up first try");
  assert.equal(h.profiles.length, 1, "exactly one profile dir is allocated on the happy path");
});

test("captureStderr keeps a BOUNDED tail and never drops the fatal last line", async () => {
  const child = new EventEmitter();
  child.stderr = Readable.from(["x".repeat(50), "\nFATAL: no usable sandbox\n"]);
  const read = captureStderr(child, 40);
  await new Promise((r) => child.stderr.on("end", r));
  const tail = read();
  assert.ok(tail.length <= 40, `tail was ${tail.length} bytes, cap is 40`);
  assert.match(tail, /FATAL: no usable sandbox/);
});

test("captureStderr on a child with no pipe returns empty rather than throwing", () => {
  assert.equal(captureStderr({ pid: 1 })(), "");
});

test("formatStderrTail indents every line so the block cannot be mistaken for our own output", () => {
  const out = formatStderrTail("one\ntwo");
  assert.match(out, /last 2 line\(s\)/);
  assert.match(out, /\| one/);
  assert.match(out, /\| two/);
});
