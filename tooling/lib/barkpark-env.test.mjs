// barkpark-env.test.mjs — the shared 429 backoff.
//
// MEASURED 2026-09-01 17:02Z: under this campaign's own load (18 agent lanes,
// each with a pulse loop and its own queries) the ledger answered `bp task
// ready` with HTTP 429 and `retry_after=1`, and every tooling/ consumer mapped
// that to a terminal fault — a one-second wait rendered as a broken machine.
//
// Every test here injects its fetch AND its sleep, so the suite is hermetic and
// spends no real seconds: the wait ARITHMETIC is asserted off the recorded
// sleeps rather than off a wall clock, which is the only way to test a backoff
// without making the suite slow enough that someone deletes it.
//
//   node --test tooling/lib/barkpark-env.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchBackpressureAware, retryAfterOf, BACKPRESSURE } from './barkpark-env.mjs';

// A minimal Response stand-in: the helper touches only status, ok, headers.get
// and text().
const reply = (status, body = '', headers = {}) => ({
  status,
  ok: status >= 200 && status < 300,
  headers: { get: (k) => headers[k.toLowerCase()] ?? null },
  text: async () => body,
});

const throttle = (retryAfter) => reply(
  429,
  `{"error":{"code":"rate_limited","message":"too many requests","details":{"retry_after":${retryAfter}}}}`,
  { 'retry-after': String(retryAfter) },
);

// Drives the helper over a scripted list of replies, recording every sleep and
// every stderr line instead of performing them.
function harness(script) {
  const slept = [];
  const said = [];
  let calls = 0;
  const run = (init = {}) => fetchBackpressureAware('http://ledger/v1/data/query/production/task', init, {
    fetch: async () => script[Math.min(calls++, script.length - 1)],
    sleep: async (ms) => { slept.push(ms); },
    say: (m) => { said.push(m); },
  });
  return { run, slept, said, calls: () => calls };
}

test('a 429 then a 200 is a SUCCESSFUL read, not a fault', async () => {
  // The measured defect, reproduced: one throttle must not end the read.
  const h = harness([throttle(1), reply(200, '{"result":{"documents":[]}}')]);
  const r = await h.run();

  assert.equal(r.ok, true, 'a throttle that cleared must read as success');
  assert.equal(r.status, 200);
  assert.equal(r.throttled, false, 'the FINAL answer was not a throttle');
  assert.equal(h.calls(), 2, 'the throttled attempt and the one that succeeded');
  assert.deepEqual(h.slept, [1000], "the wait must be the server's 1s, in ms");
});

test('the wait comes from the SERVER, not from our guesswork', async () => {
  for (const [name, res, wantMs] of [
    ['the Retry-After header', throttle(2), 2000],
    ['the envelope details.retry_after when no header', reply(429, '{"error":{"code":"rate_limited","details":{"retry_after":3}}}'), 3000],
    ['our default when the server names nothing', reply(429, '{"error":{"code":"rate_limited"}}'), BACKPRESSURE.DEFAULT_WAIT_S * 1000],
  ]) {
    const h = harness([res, reply(200, '{}')]);
    await h.run();
    assert.deepEqual(h.slept, [wantMs], `${name}: waited ${h.slept}, want ${wantMs}ms`);
  }
});

test('a non-429 is returned on the FIRST answer — a refusal is an answer', async () => {
  // The bound in the other direction. Retrying a 401 or a 404 would only
  // multiply the log: none of them change by being asked again.
  for (const status of [200, 400, 401, 403, 404, 409, 500, 503]) {
    const h = harness([reply(status, '{"error":{"code":"x"}}'), reply(200, '{}')]);
    const r = await h.run();
    assert.equal(r.status, status, `HTTP ${status} must pass straight through`);
    assert.equal(h.calls(), 1, `HTTP ${status} was retried; only a 429 carries its own remedy`);
    assert.deepEqual(h.slept, [], `HTTP ${status} must cost no wait`);
  }
});

test('a permanent throttle gives up at the attempt cap and SAYS it was a throttle', async () => {
  const h = harness([throttle(1)]);
  const r = await h.run();

  assert.equal(h.calls(), BACKPRESSURE.ATTEMPTS, 'every attempt must actually be spent');
  assert.equal(r.status, 429, 'the honest 429 is handed back');
  assert.equal(r.throttled, true, 'and it is flagged as backpressure, so a caller need not re-sniff the status');
  assert.match(r.gaveUp, /attempt cap/, 'the reason must name the bound that ended it');
  assert.equal(h.slept.length, BACKPRESSURE.ATTEMPTS - 1, '4 attempts means 3 waits');
});

test('an hour-long Retry-After is NOT slept out — a big number is a quota, not a blip', async () => {
  // The pulse plugin answers `Retry-After: 3600` on a spent daily cap. Honoring
  // that literally would be indistinguishable from a hung process.
  const h = harness([throttle(3600), reply(200, '{}')]);
  const r = await h.run();

  assert.equal(h.calls(), 1, 'the request must not be repeated after an hour-long ask');
  assert.deepEqual(h.slept, [], 'and above all it must not SLEEP for an hour');
  assert.equal(r.throttled, true);
  assert.match(r.gaveUp, /3600s/, 'the operator must be told the number the server asked for');
});

test('the total wait across one call is bounded', async () => {
  const h = harness([throttle(BACKPRESSURE.MAX_WAIT_S)]);
  const r = await h.run();

  const total = h.slept.reduce((a, b) => a + b, 0) / 1000;
  assert.ok(total <= BACKPRESSURE.MAX_TOTAL_WAIT_S,
    `waited ${total}s in one call, over the ${BACKPRESSURE.MAX_TOTAL_WAIT_S}s budget`);
  assert.equal(r.throttled, true);
});

test('every backoff announces itself, so a slow command is never a mystery', async () => {
  const h = harness([throttle(1), reply(200, '{}')]);
  await h.run();

  assert.equal(h.said.length, 1, 'one line per wait actually taken');
  assert.match(h.said[0], /BACKPRESSURE, not a fault/);
  assert.match(h.said[0], /the server asked for it/,
    'the line must not claim the server asked for a wait we invented');
  assert.match(h.said[0], /attempt 1 of 4/);
});

test('a write is replayed too — a halting plug means the write never happened', async () => {
  // Every 429 this API emits comes from a Plug that halts before the controller
  // (rate_limit.ex and its two siblings), so replaying a refused write cannot
  // duplicate it. `bp task pulse` is a POST and the pulse loops are most of the
  // load that produced the throttle; a pulse lost to a 429 lets a claim lapse.
  const h = harness([throttle(1), reply(200, '{"ok":true}')]);
  const r = await h.run({ method: 'POST', body: '{"worker":"w2"}' });

  assert.equal(r.ok, true);
  assert.equal(h.calls(), 2, 'the POST must be replayed after a throttle that provably ran no handler');
});

test('retryAfterOf reads both spellings and honestly reports absence', async () => {
  assert.equal(retryAfterOf(reply(429, '', { 'retry-after': '7' }), ''), 7);
  assert.equal(retryAfterOf(reply(429, '{"error":{"details":{"retry_after":4}}}'), '{"error":{"details":{"retry_after":4}}}'), 4);
  // Absence must be null, never 0: a 0 would be a busy loop against a limiter.
  assert.equal(retryAfterOf(reply(429, '{}'), '{}'), null);
  assert.equal(retryAfterOf(reply(429, 'not json'), 'not json'), null);
});
