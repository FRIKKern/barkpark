// usage-envelope-diff.test.mjs — the cross-tick envelope detector's controls.
//
// Run:  node --test scripts/usage-envelope-diff.test.mjs
//
// THE FIXTURES ARE THE SYSTEM'S OWN OUTPUT, not a hand-drawn shape. Each file in
// scripts/fixtures/usage-envelope-diff/ is `Jason.encode!(Usage.compose/1)` from
// cloud/lib/barkpark_cloud/usage.ex at origin/main dbf50ace7, compiled from that
// source, with these inputs (telemetry: db_size 52428800, disk 41.5, cpu 12.0,
// mem 55.0, req_per_s -1, p95_ms -1, err_5xx_per_s 0.0; seats 3, pending 1,
// instances %{value: 2, quota: 5}):
//
//   blind-unauthorized            reported_at 10:07:02Z window_s 60  inventory {:error, :unauthorized}
//   blind-unreachable             reported_at 10:07:02Z window_s 60  inventory {:error, :unreachable}
//   reasonless                    reported_at 10:22:03Z window_s 60  inventory :unmetered
//   blind-unauthorized-no-window  reported_at 10:37:01Z window_s -1  inventory {:error, :unauthorized}
//   measured                      reported_at 10:37:01Z window_s 60  inventory {:ok, 2 | 140 | 1}
//
// "inventory" = the datasets / documents / webhooks inputs, the three meters
// `instance_meter/2` shapes. The first test re-reads usage.ex so a fixture that
// drifts from the live meter vocabulary or reason vocabulary reds HERE, before
// any detector assertion can pass on a shape the system never emits.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  diffEnvelopes,
  reasonTransitions,
  walkSamples,
  parseMeasuredAt,
  formatRecord,
} from "./usage-envelope-diff.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..");
const fx = (name) =>
  JSON.parse(fs.readFileSync(path.join(here, "fixtures", "usage-envelope-diff", `${name}.json`), "utf8"));

const BLIND = fx("blind-unauthorized");
const BLIND_UNREACHABLE = fx("blind-unreachable");
const REASONLESS = fx("reasonless");
const BLIND_NO_WINDOW = fx("blind-unauthorized-no-window");
const MEASURED = fx("measured");
const INVENTORY = ["datasets", "documents", "webhooks"];
const ID = "0b9c1d3e-5f7a-4c2b-9e11-2d4f6a8b0c1e";

const row = (measured_at, envelope, barkpark_id = ID) => ({ barkpark_id, measured_at, envelope });
const pairs = (records) => records.filter((r) => r.kind === "pair");
const print = (records) => console.log(records.flatMap(formatRecord).join("\n"));

test("PRECONDITION: fixtures carry the live meter vocabulary and only live reason words", () => {
  const src = fs.readFileSync(path.join(repo, "cloud/lib/barkpark_cloud/usage.ex"), "utf8");
  const reasons = src.match(/@unavailable_reasons ~w\(([^)]*)\)/)[1].split(/\s+/).filter(Boolean);
  const block = src.match(/meters = %\{([\s\S]*?)\n    \}\n/)[1];
  const liveMeters = [...block.matchAll(/^\s{6}([a-z0-9_]+):/gm)].map((m) => m[1]).sort();
  assert.equal(liveMeters.length, 13, `compose/1 meter block parsed to ${liveMeters.join(",")}`);
  for (const [name, env] of Object.entries({ BLIND, BLIND_UNREACHABLE, REASONLESS, BLIND_NO_WINDOW, MEASURED })) {
    assert.deepEqual(Object.keys(env), ["meters"], `${name}: envelope top level`);
    assert.deepEqual(Object.keys(env.meters).sort(), liveMeters, `${name}: meter set`);
    for (const [m, meter] of Object.entries(env.meters))
      if ("unavailable_reason" in meter) assert.ok(reasons.includes(meter.unavailable_reason), `${name}.${m}`);
  }
  // The two sides of the silent-restore shape, exactly as instance_meter/2 emits them.
  for (const m of INVENTORY) {
    assert.equal(BLIND.meters[m].unavailable_reason, "unauthorized");
    assert.equal(BLIND.meters[m].value, "unmetered");
    assert.equal("unavailable_reason" in REASONLESS.meters[m], false);
    assert.equal(REASONLESS.meters[m].value, "unmetered");
  }
});

test("criterion 1: an appeared, a disappeared and a changed key are each named distinctly", () => {
  const records = walkSamples([row("2026-09-25T10:22:03.100000", REASONLESS), row("2026-09-25T10:37:01.200000", BLIND_NO_WINDOW)]);
  print(records);
  const [p] = pairs(records);
  assert.equal(p.adjacency, "adjacent");
  const has = (meter, key, change) => p.changes.some((c) => c.meter === meter && c.key === key && c.change === change);
  for (const m of INVENTORY) assert.ok(has(m, "unavailable_reason", "added"), `${m} unavailable_reason added`);
  for (const m of ["req_per_s", "p95_ms"]) assert.ok(has(m, "window_s", "removed"), `${m} window_s removed`);
  for (const m of ["cpu", "ram", "disk", "db_size", "req_per_s", "p95_ms"])
    assert.ok(has(m, "measured_at", "changed"), `${m} measured_at changed`);
  const added = p.changes.find((c) => c.meter === "documents" && c.key === "unavailable_reason");
  assert.deepEqual(added, { meter: "documents", key: "unavailable_reason", change: "added", after: "unauthorized" });
  const removed = p.changes.find((c) => c.meter === "req_per_s" && c.key === "window_s");
  assert.deepEqual(removed, { meter: "req_per_s", key: "window_s", change: "removed", before: 60 });
  // Nothing else: seats / instances / flow meters are identical and must stay silent.
  assert.equal(p.changes.filter((c) => ["seats", "instances", "api_requests", "bandwidth"].includes(c.meter)).length, 0);
});

test("criterion 2: a change confined to unavailable_reason is reported while every value is byte-identical", () => {
  // Precondition — a value-only projection (UsageHistoryPoint{At, Value}) of
  // these two envelopes is IDENTICAL, so the history endpoint sees nothing.
  const project = (env) => JSON.stringify(Object.fromEntries(Object.entries(env.meters).map(([k, m]) => [k, m.value])));
  assert.equal(project(BLIND), project(BLIND_UNREACHABLE));
  const changes = diffEnvelopes(BLIND, BLIND_UNREACHABLE);
  console.log(changes);
  assert.deepEqual(
    changes,
    INVENTORY.map((meter) => ({ meter, key: "unavailable_reason", change: "changed", before: "unauthorized", after: "unreachable" })),
  );
  assert.deepEqual(
    reasonTransitions(BLIND, BLIND_UNREACHABLE, "adjacent").map((t) => [t.meter, t.transition]),
    INVENTORY.map((m) => [m, "reason_changed"]),
  );
});

test("criterion 3a: reason-bearing -> reasonless unmetered across ADJACENT ticks is named silent_restore", () => {
  const records = walkSamples([row("2026-09-25T10:07:02.412000", BLIND), row("2026-09-25T10:22:03.087000", REASONLESS)]);
  print(records);
  const [p] = pairs(records);
  assert.equal(p.adjacency, "adjacent");
  assert.equal(p.missed_ticks, 0);
  assert.deepEqual(
    p.transitions.map((t) => [t.meter, t.transition, t.reason_before, t.reason_after, t.value_after]),
    INVENTORY.map((m) => [m, "silent_restore", "unauthorized", null, "unmetered"]),
  );
  assert.ok(formatRecord(p).some((l) => l.includes("TRANSITION silent_restore meter=documents")));
});

test("criterion 3b: a row with no predecessor is no_predecessor, never a transition", () => {
  const records = walkSamples([row("2026-09-25T10:22:03.087000", REASONLESS)]);
  print(records);
  assert.deepEqual(records, [{ barkpark_id: ID, kind: "no_predecessor", measured_at: "2026-09-25T10:22:03.087000" }]);
  // And a SECOND barkpark's first row is its own no_predecessor, not paired with the first's.
  const two = walkSamples([row("2026-09-25T10:07:02Z", BLIND, "a"), row("2026-09-25T10:22:03Z", REASONLESS, "b")]);
  assert.deepEqual(two.map((r) => [r.barkpark_id, r.kind]), [["a", "no_predecessor"], ["b", "no_predecessor"]]);
});

test("criterion 3c: the same before/after across a MISSING tick is a gap, not silent_restore", () => {
  const records = walkSamples([row("2026-09-25T10:07:02.412000", BLIND), row("2026-09-25T10:52:03.087000", REASONLESS)]);
  print(records);
  const [p] = pairs(records);
  assert.equal(p.adjacency, "gap");
  assert.equal(p.missed_ticks, 2);
  assert.deepEqual(p.transitions.map((t) => t.transition), INVENTORY.map(() => "reason_cleared_across_gap"));
  assert.equal(p.transitions.some((t) => t.transition === "silent_restore"), false);
  assert.ok(formatRecord(p)[0].includes("GAP ~2 missed tick(s)"));
});

test("a reason that clears to a MEASURED value is reason_cleared_to_value, not silent_restore", () => {
  const t = reasonTransitions(BLIND, MEASURED, "adjacent");
  assert.deepEqual(t.map((x) => [x.meter, x.transition, x.value_after]), [
    ["datasets", "reason_cleared_to_value", 2],
    ["documents", "reason_cleared_to_value", 140],
    ["webhooks", "reason_cleared_to_value", 1],
  ]);
  assert.deepEqual(reasonTransitions(REASONLESS, BLIND, "adjacent").map((x) => x.transition), INVENTORY.map(() => "reason_raised"));
});

test("an offset-less measured_at (timestamp without time zone) is UTC, whatever TZ the reader runs in", () => {
  assert.equal(parseMeasuredAt("2026-09-25T10:07:02.412000"), Date.parse("2026-09-25T10:07:02.412Z"));
  assert.equal(parseMeasuredAt("2026-09-25T12:07:02+02:00"), Date.parse("2026-09-25T10:07:02Z"));
  const r = spawnSync(process.execPath, ["--input-type=module", "-e",
    `import {parseMeasuredAt} from ${JSON.stringify(path.join(here, "usage-envelope-diff.mjs"))}; console.log(parseMeasuredAt("2026-09-25T10:07:02"))`],
    { env: { ...process.env, TZ: "Pacific/Kiritimati" }, encoding: "utf8" });
  assert.equal(Number(r.stdout.trim()), Date.parse("2026-09-25T10:07:02Z"));
});

test("CLI: reads JSONL rows in any order and prints the named transition; bad input exits 2", () => {
  const dir = fs.mkdtempSync(path.join(process.env.TMPDIR || "/tmp", "ued-"));
  const file = path.join(dir, "rows.jsonl");
  fs.writeFileSync(file, [row("2026-09-25T10:22:03.087", REASONLESS), row("2026-09-25T10:07:02.412", BLIND)].map((r) => JSON.stringify(r)).join("\n") + "\n");
  const cli = path.join(here, "usage-envelope-diff.mjs");
  const ok = spawnSync(process.execPath, [cli, file], { encoding: "utf8" });
  console.log(ok.stdout);
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stdout, /no_predecessor/);
  assert.match(ok.stdout, /TRANSITION silent_restore meter=webhooks reason "unauthorized" -> ∅ value_after="unmetered"/);
  assert.match(ok.stdout, /removed meter=webhooks key=unavailable_reason "unauthorized"/);
  const js = spawnSync(process.execPath, [cli, "--json", file], { encoding: "utf8" });
  assert.equal(js.status, 0);
  const recs = js.stdout.trim().split("\n").map((l) => JSON.parse(l));
  assert.deepEqual(recs.map((r) => r.kind), ["no_predecessor", "pair"]);
  fs.writeFileSync(file, "{not json\n");
  const bad = spawnSync(process.execPath, [cli, file], { encoding: "utf8" });
  assert.equal(bad.status, 2);
  assert.match(bad.stderr, /line 1: not JSON/);
  fs.rmSync(dir, { recursive: true, force: true });
});
