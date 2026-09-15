#!/usr/bin/env node
//
// advisory-census.mjs — how much of this repo's CI is queue depth?
//
// THE QUESTION THIS EXISTS FOR
// ---------------------------
// One PR push fires ~120 check-runs. Exactly FOUR can block a merge
// (`Cloud gate`, `Console gate`, `Elixir gate`, `PR references an active task`
// — the authority is .github/required-checks.json, READ AT RUN TIME, never
// hardcoded here). The other ~116 are advisory: they cannot stop anything.
// On 2026-09-15 that advisory mass produced a 104-deep Actions queue and a
// production deploy run sat waiting on an unassigned runner.
//
// A check that has never concluded non-success has never caught anything.
// That is the single strongest signal available without reading minds, and it
// is what this tool measures.
//
// WHAT IT MEASURES, AND AT WHICH GRANULARITY — the two are different and the
// difference is the whole honesty of the output
// ---------------------------------------------------------------------------
//   LAYER P (POPULATION, complete for the window, WORKFLOW granularity).
//     For every workflow, the exact number of `pull_request` runs in the
//     window and how many concluded failure / cancelled. These come from
//     /actions/runs `total_count` UNDER A FILTER, which is exact — the
//     UNFILTERED total_count on this endpoint saturates near 40000 and is NOT
//     a count. The layer is complete: it is not a sample. It cannot tell you
//     WHICH JOB inside a workflow failed.
//
//   LAYER H (HEADS, sampled, CHECK-RUN/JOB granularity).
//     For a sample of recent PR head shas, every check-run name on that head
//     with its conclusion and wall-clock duration. This is the layer that
//     knows check-run NAMES, per-PR COST, and which names conclude `skipped`
//     (dispatched-but-no-op) versus actually running. It is a SAMPLE and is
//     labelled as one everywhere it is printed.
//
//   LAYER B (BURST, complete for each workflow's failures, WORKFLOW
//     granularity). THE DISCRIMINATOR between "a check on this diff" and "a
//     census of repo state". A diff-check fails on the PR that broke it: its
//     reds are scattered across time and land on one PR at a time. A repo-state
//     census fails on EVERY OPEN PR AT ONCE the moment the repo drifts, because
//     none of those PRs caused it and none of them can clear it. So for every
//     workflow with failures in the window this layer bucket-sorts the failing
//     runs into 60-minute windows and reports the largest number of DISTINCT
//     PULL REQUESTS reddened in a single bucket, and the share of all failures
//     that landed in multi-PR buckets (`co_fail_share`). A high co-fail share
//     is the signature of a census; a low one is the signature of a diff check.
//     This is a measurement, not the prior it tests — and it does refute part
//     of the prior (see the report).
//
//   LAYER M (MERGED-PAST, sampled, CHECK-RUN granularity). THE ONLY SOUND
//     PROXY FOR "ACTED ON" THIS REPO ADMITS, and it only ever answers in the
//     NEGATIVE. For a sample of PRs MERGED inside the window, read the head
//     sha's complete check-run rollup: any advisory name sitting non-success
//     on a merged head is a red that shipped. Nobody cleared it, nobody
//     re-ran it green, and the merge happened anyway — because it could. This
//     does NOT prove the converse: a name green at merge may have been fixed
//     in response to an earlier red, or may simply never have gone red. So
//     `merged_past` is a floor on ignored reds, never a ceiling on attention.
//     CAVEAT, and it is the same one everywhere in this tool: a re-run after
//     the merge would have overwritten the conclusion, which can only move a
//     row from red to green. The floor is a floor.
//
//   LAYER S (STATIC, complete, from the checked-out workflow files).
//     Trigger shape (`on:` keys), workflow-level `paths:` filters, and
//     `continue-on-error` occurrences. Layer S exists because of a specific
//     lie: a job or step carrying `continue-on-error: true` reports
//     `conclusion: success` while its assertions failed. A workflow can look
//     green for a month with dead assertions. Any name whose workflow carries
//     continue-on-error is flagged CoE and its zero-failure record is NOT
//     evidence of health.
//
// WHAT IT CANNOT MEASURE — stated here so no reader has to infer it
// -----------------------------------------------------------------
//   · "ACTED ON". There is no API for human attention. A red that was ignored
//     and a red that was fixed are the same row. This tool reports RUNS and
//     REDS and refuses to synthesise an engagement number. The nearest honest
//     proxy — did a red on name N precede a commit touching what N guards —
//     needs a committed name->guarded-paths map that does not exist in this
//     repo; --proxy-note prints why rather than printing a fabricated ratio.
//   · HISTORY DESTROYED BY RERUNS. A re-run OVERWRITES a run's conclusion in
//     place. Every failure that anyone re-ran to green in the window is
//     invisible to Layer P. Layer P therefore UNDERCOUNTS failures, in an
//     unknown amount, in one direction only. It never overcounts.
//   · SUPERSEDED HEADS. Layer H samples each PR's CURRENT head. Check-runs on
//     force-pushed-away heads are not reachable from the pulls API.
//
// USAGE
//   node tooling/gates/advisory-census.mjs                    # 30d, 30 heads
//   node tooling/gates/advisory-census.mjs --days 14 --heads 50
//   node tooling/gates/advisory-census.mjs --json out.json    # machine-readable
//   node tooling/gates/advisory-census.mjs --proxy-note       # why (3) is unmeasured
//
// Auth: uses `gh auth token`. Read-only. It writes nothing but its report.

import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, existsSync, writeFileSync } from "node:fs";
import path from "node:path";

const REPO = process.env.ADVISORY_CENSUS_REPO || "FRIKKern/barkpark";
const API = "https://api.github.com";

// ---------------------------------------------------------------- args
const argv = process.argv.slice(2);
const argOf = (flag, dflt) => {
  const i = argv.indexOf(flag);
  return i === -1 ? dflt : argv[i + 1];
};
const DAYS = Number(argOf("--days", "30"));
const HEAD_SAMPLE = Number(argOf("--heads", "30"));
const MERGED_SAMPLE = Number(argOf("--merged", "40"));
const JSON_OUT = argOf("--json", null);
const PROXY_NOTE = argv.includes("--proxy-note");
const REPO_ROOT = argOf("--repo-root", process.cwd());

if (PROXY_NOTE) {
  process.stdout.write(PROXY_TEXT());
  process.exit(0);
}

const now = new Date();
const since = new Date(now.getTime() - DAYS * 86400_000);
const SINCE = since.toISOString().slice(0, 10);

// ---------------------------------------------------------------- http
let TOKEN;
try {
  TOKEN = execFileSync("gh", ["auth", "token"], { encoding: "utf8" }).trim();
} catch {
  console.error("advisory-census: `gh auth token` failed — run `gh auth login`.");
  process.exit(2);
}

let CALLS = 0;
async function api(pathname) {
  for (let attempt = 0; attempt < 8; attempt++) {
    CALLS++;
    const res = await fetch(`${API}${pathname}`, {
      headers: {
        authorization: `Bearer ${TOKEN}`,
        accept: "application/vnd.github+json",
        "x-github-api-version": "2022-11-28",
        "user-agent": "barkpark-advisory-census",
      },
    });
    // TWO DIFFERENT LIMITS WEAR THE SAME 403. The PRIMARY limit is the one
    // x-ratelimit-remaining counts down; the SECONDARY ("abuse") limit fires on
    // concurrency and burst with thousands of primary requests still in the
    // bucket, and the first version of this loop mistook it for the primary
    // one, slept toward a reset 14 minutes away, exhausted its attempts and
    // reported CANNOT-READ on a perfectly readable repo. Honour retry-after
    // first, then remaining==0, then plain backoff.
    if (res.status === 403 || res.status === 429) {
      const retryAfter = Number(res.headers.get("retry-after") || 0);
      const remaining = Number(res.headers.get("x-ratelimit-remaining") ?? "1");
      const reset = Number(res.headers.get("x-ratelimit-reset") || 0) * 1000;
      let waitMs;
      if (retryAfter > 0) waitMs = retryAfter * 1000 + 1000;
      else if (remaining === 0) waitMs = Math.max(5000, reset - Date.now() + 2000);
      else waitMs = Math.min(60_000, 5000 * 2 ** attempt); // secondary/burst
      await new Promise((r) => setTimeout(r, waitMs));
      continue;
    }
    if (!res.ok) throw new Error(`${res.status} ${pathname}`);
    return res.json();
  }
  throw new Error(`rate-limited out on ${pathname}`);
}

// Bounded-concurrency map. Sequential `gh api` spawns make an 85-workflow
// census take minutes; this makes it take seconds without tripping abuse
// detection.
async function pmap(items, limit, fn) {
  const out = new Array(items.length);
  let i = 0;
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, async () => {
      while (true) {
        const idx = i++;
        if (idx >= items.length) return;
        out[idx] = await fn(items[idx], idx);
      }
    }),
  );
  return out;
}

// ------------------------------------------------- the truncation refusal
//
// MEASURED, and this is the trap that produced a false finding before this
// tool existed: on a real head the rollup read `total_count=119, received=100`
// and the truncated page showed ZERO non-success while the complete read
// showed TWO. A page that exactly fills per_page is a TRUNCATION WARNING.
// Anything short of `collected === total_count` is CANNOT READ, not a count.
async function checkRunsComplete(sha) {
  const all = [];
  let total = null;
  for (let page = 1; page <= 20; page++) {
    const body = await api(
      `/repos/${REPO}/commits/${sha}/check-runs?per_page=100&page=${page}`,
    );
    if (total === null) total = body.total_count;
    all.push(...body.check_runs);
    if (all.length >= total) break;
    if (body.check_runs.length === 0) break;
  }
  if (all.length !== total) {
    return { sha, ok: false, total, collected: all.length, runs: [] };
  }
  return { sha, ok: true, total, collected: all.length, runs: all };
}

// ---------------------------------------------------------------- layer S
const WF_DIR = path.join(REPO_ROOT, ".github/workflows");

function staticLayer() {
  const out = new Map();
  if (!existsSync(WF_DIR)) return out;
  for (const f of readdirSync(WF_DIR).filter((f) => /\.ya?ml$/.test(f))) {
    const p = path.join(WF_DIR, f);
    const src = readFileSync(p, "utf8");
    const lines = src.split("\n");

    // `on:` block = from the `on:`/`"on":` line to the next column-0 key.
    let onStart = -1;
    for (let i = 0; i < lines.length; i++) {
      if (/^(on|"on"|'on'):/.test(lines[i])) { onStart = i; break; }
    }
    let onBlock = "";
    if (onStart >= 0) {
      const buf = [lines[onStart]];
      for (let i = onStart + 1; i < lines.length; i++) {
        if (/^\S/.test(lines[i])) break;
        buf.push(lines[i]);
      }
      onBlock = buf.join("\n");
    }
    const triggers = [];
    for (const t of [
      "pull_request", "pull_request_target", "push", "schedule",
      "workflow_dispatch", "workflow_run", "merge_group", "issue_comment",
      "release", "repository_dispatch",
    ]) {
      if (new RegExp(`^\\s{2,4}${t}:`, "m").test(onBlock)) triggers.push(t);
    }
    // A workflow-level `paths:`/`paths-ignore:` sits INSIDE the on: block.
    const pathsFiltered = /^\s+paths(-ignore)?:/m.test(onBlock);
    // continue-on-error anywhere: job level or step level. Either one can make
    // a failed assertion report `success` upward.
    const coe = (src.match(/continue-on-error:\s*true/g) || []).length;

    out.set(f, {
      file: f,
      triggers,
      pathsFiltered,
      continueOnError: coe,
      onBlockPresent: onStart >= 0,
    });
  }
  return out;
}

// ------------------------------------------------- LOAD-BEARING derivation
//
// THE ERROR THIS PREVENTS. Most of the check-runs on a head are ADVISORY BY
// NAME and LOAD-BEARING BY TOPOLOGY: `Test (Elixir 1.18.1 / OTP 27.0)` cannot
// block a merge itself, but `Elixir gate` — which CAN — is an `if: always()`
// job that DECIDES over `needs.mix-test.result`. Remove the leaf and the
// required aggregator goes red or vacuous. Any census that recommends moving
// jobs off the PR trigger MUST compute this set first, or its very first
// recommendation is to break the merge gate.
//
// Derivation: find the job whose `name:` renders a required context, then walk
// its `needs:` transitively and collect every reachable job's `name:`. Parsed
// from the two-space job key indentation this repo uses throughout; a job whose
// name cannot be resolved is reported UNRESOLVED and is treated as
// load-bearing, because the safe failure direction is to protect it.
function loadBearing(requiredSet) {
  const bearing = new Set();
  const unresolved = [];
  if (!existsSync(WF_DIR)) return { bearing, unresolved };
  for (const f of readdirSync(WF_DIR).filter((f) => /\.ya?ml$/.test(f))) {
    const lines = readFileSync(path.join(WF_DIR, f), "utf8").split("\n");
    // jobs: key -> {name, needs:[keys]}
    const jobs = new Map();
    let cur = null;
    let inJobs = false;
    for (const line of lines) {
      if (/^jobs:/.test(line)) { inJobs = true; continue; }
      if (!inJobs) continue;
      if (/^\S/.test(line)) { inJobs = false; continue; }
      const jm = /^  ([A-Za-z0-9_-]+):\s*$/.exec(line);
      if (jm) { cur = jm[1]; jobs.set(cur, { key: cur, name: null, needs: [] }); continue; }
      if (!cur) continue;
      const nm = /^    name:\s*(.+?)\s*$/.exec(line);
      if (nm) {
        jobs.get(cur).name = nm[1].replace(/^["']|["']$/g, "");
        continue;
      }
      const nd = /^    needs:\s*(.+?)\s*$/.exec(line);
      if (nd) {
        jobs.get(cur).needs = nd[1]
          .replace(/^\[|\]$/g, "")
          .split(",").map((x) => x.trim().replace(/^["']|["']$/g, ""))
          .filter(Boolean);
      }
    }
    for (const j of jobs.values()) {
      if (!j.name || !requiredSet.has(j.name)) continue;
      // BFS over needs
      const seen = new Set([j.key]);
      const queue = [...j.needs];
      while (queue.length) {
        const k = queue.shift();
        if (seen.has(k)) continue;
        seen.add(k);
        const dep = jobs.get(k);
        if (!dep) { unresolved.push(`${f}:${k}`); continue; }
        if (dep.name) bearing.add(dep.name);
        else unresolved.push(`${f}:${k} (no name:)`);
        queue.push(...dep.needs);
      }
    }
  }
  return { bearing, unresolved };
}

// ---------------------------------------------------------------- required
//
// The required set is READ, never hardcoded. A tool that carries its own copy
// of the blocking four will keep proposing to delete one the day the set moves.
function requiredContexts() {
  const p = path.join(REPO_ROOT, ".github/required-checks.json");
  if (!existsSync(p)) return { set: new Set(), source: "ABSENT" };
  const j = JSON.parse(readFileSync(p, "utf8"));
  const checks = j?.protection?.required_status_checks?.checks || [];
  return { set: new Set(checks.map((c) => c.context)), source: p };
}

// ---------------------------------------------------------------- main
function PROXY_TEXT() {
  return `
WHY "DID A FAILURE EVER PRECEDE A FIX" IS NOT REPORTED AS A NUMBER
=================================================================
Measuring "acted on" soundly needs, for each check-run name N, the set of repo
paths N guards — so that a red on N can be joined against the next commit on
that branch and asked "did it touch what N guards?".

That map does not exist in this repo as a committed artifact. Deriving it would
mean reading each workflow's script invocations and each script's scan sites,
which is a DIFFERENT tool (tooling/gate-map/gate-map.mjs answers the inverse
question for a handful of instruments, not for all ~120 names).

Two further defects would remain even with the map:
  · A re-run OVERWRITES the earlier conclusion. A red that was fixed is the
    row most likely to have been re-run to green, so the very population the
    proxy wants to count is the population the API destroys first.
  · A commit touching a guarded path after a red is not evidence the red caused
    it. In a fleet where several agents push to the same branch it is barely
    evidence of correlation.

So this census reports the two quantities it can measure honestly — HOW OFTEN
EACH NAME RAN, and HOW OFTEN IT CONCLUDED NON-SUCCESS — and states plainly that
it measured runs and reds, not human attention. A name with zero reds has
demonstrably never caught anything; that conclusion needs no proxy. A name with
reds MAY have been acted on, and this tool does not claim to know.
`;
}

(async () => {
  const stat = staticLayer();
  const req = requiredContexts();
  const lb = loadBearing(req.set);

  // ---- Layer P ------------------------------------------------------
  const wfPages = [];
  for (let page = 1; page <= 10; page++) {
    const b = await api(`/repos/${REPO}/actions/workflows?per_page=100&page=${page}`);
    wfPages.push(...b.workflows);
    if (wfPages.length >= b.total_count) break;
  }
  // THE ENDPOINT MATTERS. `/actions/runs?workflow_id=N` SILENTLY IGNORES the
  // parameter and returns the REPO-WIDE total — the first cut of this tool
  // printed the same 83828/5102/14530 triple against all 85 workflows and the
  // only thing that caught it was the uniformity. Per-workflow scoping lives
  // in the PATH: /actions/workflows/{id}/runs. The control below refuses a
  // uniform result rather than printing it.
  const q = (id, extra = "") =>
    `/repos/${REPO}/actions/workflows/${id}/runs?event=pull_request&created=%3E%3D${SINCE}&per_page=1${extra}`;

  const pop = await pmap(wfPages, 3, async (w) => {
    const [tot, fail, canc] = await Promise.all([
      api(q(w.id)),
      api(q(w.id, "&status=failure")),
      api(q(w.id, "&status=cancelled")),
    ]);
    const file = path.basename(w.path);
    return {
      id: w.id,
      workflow: w.name,
      file,
      state: w.state,
      runs: tot.total_count,
      failures: fail.total_count,
      cancelled: canc.total_count,
      ...(stat.get(file) || { triggers: [], pathsFiltered: null, continueOnError: null }),
    };
  });

  // ---- CONTROL: a uniform verdict is the signature of a broken instrument.
  // If every workflow reports the same run count, the scoping parameter was
  // dropped and the numbers are the repo-wide total wearing 85 different names.
  const distinctRunCounts = new Set(pop.map((p) => p.runs));
  if (pop.length > 3 && distinctRunCounts.size === 1) {
    console.error(
      `advisory-census REFUSES: all ${pop.length} workflows report runs=${[...distinctRunCounts][0]}. ` +
      `That is a repo-wide total, not a per-workflow count — the scoping parameter was ignored.`,
    );
    process.exit(3);
  }
  const repoWide = await api(
    `/repos/${REPO}/actions/runs?event=pull_request&created=%3E%3D${SINCE}&per_page=1`,
  );
  const popSum = pop.reduce((a, p) => a + p.runs, 0);

  // ---- Layer B ------------------------------------------------------
  // Failure runs are enumerated in full for every workflow that has any. The
  // /actions/runs listing paginates to at most 1000 items, so a workflow with
  // more failures than that is marked `burst_truncated` and its ratio is
  // reported as a LOWER BOUND rather than silently computed from a prefix.
  const BURST_CAP = 1000;
  await pmap(pop.filter((p) => p.failures > 0), 3, async (p) => {
    const runs = [];
    const pages = Math.min(10, Math.ceil(p.failures / 100));
    for (let page = 1; page <= pages; page++) {
      const b = await api(
        `/repos/${REPO}/actions/workflows/${p.id}/runs?event=pull_request&created=%3E%3D${SINCE}&status=failure&per_page=100&page=${page}`,
      );
      runs.push(...b.workflow_runs);
      if (b.workflow_runs.length < 100) break;
    }
    p.burst_truncated = p.failures > BURST_CAP || runs.length < p.failures;
    p.burst_read = runs.length;

    const buckets = new Map();
    for (const r of runs) {
      const bucket = r.created_at.slice(0, 13); // YYYY-MM-DDTHH
      const pr = (r.pull_requests && r.pull_requests[0]?.number) || r.head_branch || r.head_sha;
      if (!buckets.has(bucket)) buckets.set(bucket, new Set());
      buckets.get(bucket).add(String(pr));
    }
    let maxPRs = 0, inMulti = 0;
    for (const [, set] of buckets) {
      maxPRs = Math.max(maxPRs, set.size);
      if (set.size > 1) inMulti += set.size;
    }
    const distinctPRs = new Set();
    for (const [, set] of buckets) for (const x of set) distinctPRs.add(x);
    p.burst_max_prs_per_hour = maxPRs;
    p.burst_distinct_prs = distinctPRs.size;
    p.burst_co_fail_share = distinctPRs.size
      ? Number((inMulti / distinctPRs.size).toFixed(2))
      : 0;
  });

  // ---- Layer H ------------------------------------------------------
  const prs = [];
  for (let page = 1; page <= 10 && prs.length < HEAD_SAMPLE * 3; page++) {
    const b = await api(
      `/repos/${REPO}/pulls?state=all&sort=updated&direction=desc&per_page=100&page=${page}`,
    );
    if (!b.length) break;
    prs.push(...b);
  }
  const inWindow = prs.filter((p) => new Date(p.updated_at) >= since);
  const heads = [];
  const seen = new Set();
  for (const p of inWindow) {
    if (seen.has(p.head.sha)) continue;
    seen.add(p.head.sha);
    heads.push({ number: p.number, sha: p.head.sha, updated_at: p.updated_at });
    if (heads.length >= HEAD_SAMPLE) break;
  }

  const rollups = await pmap(heads, 3, (h) => checkRunsComplete(h.sha));
  const goodHeads = rollups.filter((r) => r.ok);
  const truncated = rollups.filter((r) => !r.ok);

  // ---- Layer M ------------------------------------------------------
  const mergedPRs = inWindow
    .filter((p) => p.merged_at && new Date(p.merged_at) >= since)
    .slice(0, MERGED_SAMPLE);
  const mergedRollups = (await pmap(mergedPRs, 3, (p) => checkRunsComplete(p.head.sha)))
    .map((r, i) => ({ ...r, number: mergedPRs[i].number }));
  const mergedOk = mergedRollups.filter((r) => r.ok && r.total > 0);
  const mergedPast = new Map(); // name -> {prs:Set, conclusions:{}}
  for (const r of mergedOk) {
    for (const cr of r.runs) {
      const c = cr.conclusion;
      if (["success", "skipped", "neutral", "cancelled", null].includes(c)) continue;
      if (!mergedPast.has(cr.name)) mergedPast.set(cr.name, { prs: new Set(), byConclusion: {} });
      const e = mergedPast.get(cr.name);
      e.prs.add(r.number);
      e.byConclusion[c] = (e.byConclusion[c] || 0) + 1;
    }
  }

  // name -> stats
  const names = new Map();
  for (const r of goodHeads) {
    for (const cr of r.runs) {
      const n = cr.name;
      if (!names.has(n))
        names.set(n, {
          name: n, occurrences: 0, headSet: new Set(), byConclusion: {},
          durSec: 0, durN: 0, runIds: new Set(),
        });
      const e = names.get(n);
      e.occurrences++;
      e.headSet.add(r.sha);
      const c = cr.conclusion || cr.status || "unknown";
      e.byConclusion[c] = (e.byConclusion[c] || 0) + 1;
      if (cr.started_at && cr.completed_at) {
        e.durSec += (new Date(cr.completed_at) - new Date(cr.started_at)) / 1000;
        e.durN++;
      }
      const m = /\/actions\/runs\/(\d+)\//.exec(cr.details_url || "");
      if (m) e.runIds.add(m[1]);
    }
  }

  // run_id -> workflow file, so a check-run NAME can be attributed to the
  // workflow whose Layer-P failure record governs it.
  const allRunIds = new Set();
  for (const e of names.values()) for (const id of e.runIds) allRunIds.add(id);
  const runInfo = new Map();
  await pmap([...allRunIds], 3, async (id) => {
    try {
      const b = await api(`/repos/${REPO}/actions/runs/${id}`);
      runInfo.set(id, { file: path.basename(b.path || ""), workflow: b.name });
    } catch { /* deleted run; leaves the name UNATTRIBUTED, never dropped */ }
  });

  const popByFile = new Map(pop.map((p) => [p.file, p]));

  const rows = [...names.values()].map((e) => {
    // AMBIGUOUS NAMES ARE REAL AND THEY MIS-BIND. `Report main-push failure to
    // a human` is the job name in elixir.yml AND cloud.yml AND
    // console-harness.yml. Taking files[0] silently attributes one workflow's
    // failure record to three different checks. A name that resolves to more
    // than one workflow is marked ambiguous, gets the WORST-CASE (max failure)
    // workflow's record so no recommendation is made on an optimistic read,
    // and is FORCED to keep-on-PR — an ambiguous name is not something this
    // census is entitled to move.
    const files = [...new Set([...e.runIds].map((id) => runInfo.get(id)?.file).filter(Boolean))];
    const ambiguous = files.length > 1;
    const candidates = files.map((f) => popByFile.get(f)).filter(Boolean);
    const p = candidates.length
      ? candidates.reduce((a, b) => (b.failures > a.failures ? b : a))
      : null;
    const file = ambiguous ? files.join("+") : (files[0] || null);
    // `cancelled` is split OUT of failures on purpose: in this repo a cancel is
    // overwhelmingly a concurrency-group supersede (a newer push killed an
    // older run), which says nothing about the check's assertions. Folding it
    // into "non-success" would manufacture evidence that a check catches things.
    const skipped = e.byConclusion.skipped || 0;
    const cancelled = e.byConclusion.cancelled || 0;
    const failed = Object.entries(e.byConclusion)
      .filter(([c]) => !["success", "skipped", "neutral", "cancelled"].includes(c))
      .reduce((a, n) => a + n[1], 0);
    return {
      name: e.name,
      required: req.set.has(e.name),
      workflowFile: file,
      ambiguousWorkflow: ambiguous,
      occurrences: e.occurrences,
      headsSeen: e.headSet.size,
      sampleSkipped: skipped,
      sampleCancelled: cancelled,
      sampleRan: e.occurrences - skipped,
      sampleNonSuccess: failed,
      avgSec: e.durN ? Math.round(e.durSec / e.durN) : null,
      popRuns: p?.runs ?? null,
      popFailures: p?.failures ?? null,
      popCancelled: p?.cancelled ?? null,
      mergedPastReds: mergedPast.get(e.name)?.prs.size ?? 0,
      burstMaxPRsPerHour: p?.burst_max_prs_per_hour ?? null,
      burstCoFailShare: p?.burst_co_fail_share ?? null,
      burstTruncated: p?.burst_truncated ?? null,
      triggers: p?.triggers ?? null,
      pathsFiltered: p?.pathsFiltered ?? null,
      continueOnError: p?.continueOnError ?? null,
    };
  });
  // ---- CLASSIFICATION -----------------------------------------------
  // Mechanical, from the measured fields. Every verdict carries the field
  // values that produced it, so a reader can disagree with the RULE without
  // having to re-derive the DATA.
  // A MATRIX JOB'S RENDERED NAME IS NOT ITS `name:`. GitHub substitutes
  // `${{ matrix.* }}` and, when the name carries no placeholder at all,
  // APPENDS the matrix values in parentheses: the yaml says
  // `Test (Elixir ${{ matrix.elixir }} / OTP ${{ matrix.otp }})` and the check
  // run says `Test (Elixir 1.18.4 / OTP 27.0)`; the yaml says
  // `Cloud reader-corpus census` and the check run says
  // `Cloud reader-corpus census (27.0, 1.18.1)`. A set-membership test on the
  // literal `name:` therefore reports the ENTIRE Elixir test matrix — the
  // required Elixir gate's own upstream — as not load-bearing. Match through
  // the rendering: placeholders become wildcards, and a trailing
  // ` (<matrix values>)` is allowed on any template.
  const lbMatchers = [...lb.bearing].map((n) => {
    const esc = n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const withHoles = esc.replace(/\\\$\\\{\\\{.*?\\\}\\\}/g, ".+?");
    return new RegExp(`^${withHoles}(?: \\([^()]*\\))?$`);
  });
  const isLoadBearing = (name) =>
    lb.bearing.has(name) || lbMatchers.some((re) => re.test(name));

  for (const r of rows) {
    r.loadBearing = isLoadBearing(r.name);
    if (r.required) { r.verdict = "REQUIRED"; r.why = "in .github/required-checks.json"; continue; }
    if (r.loadBearing) {
      r.verdict = "keep-on-PR";
      r.why = "LOAD-BEARING: transitive `needs` of a required aggregator — removing it reds or vacuums the gate";
      continue;
    }
    if (r.ambiguousWorkflow) {
      r.verdict = "keep-on-PR";
      r.why = `AMBIGUOUS: this job name renders from ${r.workflowFile} — its failure record cannot be attributed to one workflow, so this census does not move it`;
      continue;
    }
    if (r.popRuns === 0) { r.verdict = "keep-on-PR"; r.why = "no pull_request runs in window; nothing to move"; continue; }
    // AN UNINTERPOLATED `${{ ... }}` IN A RENDERED CHECK-RUN NAME IS NOT A
    // CHECK. It is what GitHub publishes when a matrix expands to ZERO entries
    // — `Plugin ${{ matrix.entry.plugin }} (Node ${{ matrix.entry.node }})` is
    // the plugin-node matrix reporting that no plugin qualified, and the
    // .github/required-checks.json README records the same shape for the Elixir
    // matrix. It is a SIBLING of the real job, not a separate one, and deleting
    // "it" means deleting the matrix. Never classify one as removable.
    if (/\$\{\{/.test(r.name)) {
      r.verdict = "keep-on-PR";
      r.why = "UNINTERPOLATED MATRIX TEMPLATE: this name is what an EMPTY matrix publishes, not a job of its own — it has no independent existence to move or delete";
      continue;
    }
    const everSkippedOnly = r.sampleRan === 0 && r.sampleSkipped > 0;
    if (r.popFailures === 0 && everSkippedOnly) {
      // `delete` is reserved for a name with nowhere else to go. If the
      // workflow already has a schedule arm, the honest verdict is to move it
      // there, not to destroy the check.
      const hasSchedule = (r.triggers || []).includes("schedule");
      r.verdict = hasSchedule ? "move-to-schedule" : "delete";
      r.why = `0 failures in ${r.popRuns} runs AND conclusion=skipped on all ${r.headsSeen} sampled heads — renders a row, runs nothing, has never caught anything` +
        (hasSchedule ? "; its workflow already has a schedule arm, so it has somewhere to go" : "; its workflow has no schedule arm");
      continue;
    }
    const coeNote = (r.continueOnError || 0) > 0
      ? ` — AND its workflow carries continue-on-error, so a zero here is STRUCTURAL, not evidence of health`
      : "";
    if (r.popFailures === 0) {
      r.verdict = r.popRuns >= 1000 ? "move-to-schedule" : "move-to-push";
      r.why = `0 failures in ${r.popRuns} pull_request runs over the window${coeNote}`;
      continue;
    }
    const rate = r.popFailures / r.popRuns;
    if (rate < 0.002) {
      r.verdict = "move-to-push";
      r.why = `${r.popFailures} failures in ${r.popRuns} runs (${(rate * 100).toFixed(3)}%) — under 1 red per 500 PR runs${coeNote}`;
      continue;
    }
    // CENSUS SHAPE, and the guard that keeps this rule honest. An unfiltered
    // workflow with a schedule arm LOOKS like a repo-state census. But a check
    // that reds on a tenth of all PRs is producing signal at a rate no schedule
    // can replace, whatever its shape. The rate ceiling comes FIRST.
    const RED_CEILING = 0.10;
    if (r.pathsFiltered === false && (r.triggers || []).includes("schedule") && rate < RED_CEILING) {
      r.verdict = "move-to-schedule";
      r.why = `no workflow-level paths: filter (runs on EVERY PR regardless of diff), a schedule arm already exists, and it reds on only ${(rate * 100).toFixed(1)}% of runs — census shape`;
      continue;
    }
    r.verdict = "keep-on-PR";
    r.why = r.pathsFiltered === false
      ? `${r.popFailures} failures in ${r.popRuns} runs (${(rate * 100).toFixed(2)}%) — reds too often to move, but it has NO workflow-level paths: filter, so it runs on every PR regardless of diff. The fix here is a paths filter, not a trigger move.`
      : `${r.popFailures} failures in ${r.popRuns} runs (${(rate * 100).toFixed(2)}%) — it reds, and it is diff-scoped`;
  }

  rows.sort((a, b) => (b.occurrences - a.occurrences) || a.name.localeCompare(b.name));

  const advisory = rows.filter((r) => !r.required);
  const neverFailed = advisory.filter((r) => r.popFailures === 0);
  const neverFailedEverRan = neverFailed.filter((r) => r.sampleRan > 0);
  const neverRan = advisory.filter((r) => r.sampleRan === 0);
  const coeTainted = advisory.filter((r) => (r.continueOnError || 0) > 0);

  const verdictCounts = {};
  for (const r of rows) verdictCounts[r.verdict] = (verdictCounts[r.verdict] || 0) + 1;
  // A head with ZERO check-runs is a PR whose CI has not started yet. Leaving
  // it in the denominator pulls the "check-runs per head" mean down and makes
  // the projected saving look smaller than it is. It is EXCLUDED from cost
  // means and REPORTED separately — never silently dropped.
  const costHeads = goodHeads.filter((r) => r.total > 0);
  const H = costHeads.length || 1;
  const movable = rows.filter((r) => r.verdict === "move-to-push" || r.verdict === "move-to-schedule" || r.verdict === "delete");
  const projected = {
    check_runs_removed_per_head: Number((movable.reduce((a, r) => a + r.occurrences, 0) / H).toFixed(1)),
    of_which_actually_executed: Number((movable.reduce((a, r) => a + r.sampleRan, 0) / H).toFixed(1)),
    runner_seconds_removed_per_head: Math.round(movable.reduce((a, r) => a + (r.avgSec || 0) * r.sampleRan, 0) / H),
    mean_check_runs_per_head_today: Number((costHeads.reduce((a, r) => a + r.total, 0) / H).toFixed(1)),
    mean_EXECUTED_check_runs_per_head_today: Number((rows.reduce((a, r) => a + r.sampleRan, 0) / H).toFixed(1)),
    mean_SKIPPED_check_runs_per_head_today: Number((rows.reduce((a, r) => a + r.sampleSkipped, 0) / H).toFixed(1)),
    mean_runner_seconds_per_head_today: Math.round(rows.reduce((a, r) => a + (r.avgSec || 0) * r.sampleRan, 0) / H),
    median_check_runs_per_head_today: (() => {
      const v = costHeads.map((r) => r.total).sort((a, b) => a - b);
      return v.length ? v[Math.floor(v.length / 2)] : 0;
    })(),
    cost_heads_used: costHeads.length,
    heads_with_zero_check_runs: goodHeads.length - costHeads.length,
  };

  const report = {
    generated_at: now.toISOString(),
    repo: REPO,
    window: { days: DAYS, since: SINCE, until: now.toISOString().slice(0, 10) },
    required_set: { source: req.source, contexts: [...req.set] },
    merged_sample: {
      merged_prs_read: mergedOk.length,
      merged_prs_requested: MERGED_SAMPLE,
      advisory_names_red_at_merge: [...mergedPast.entries()]
        .filter(([n]) => !req.set.has(n))
        .map(([n, v]) => ({ name: n, merged_prs_with_this_red: v.prs.size, conclusions: v.byConclusion }))
        .sort((a, b) => b.merged_prs_with_this_red - a.merged_prs_with_this_red),
      required_names_red_at_merge: [...mergedPast.entries()].filter(([n]) => req.set.has(n)).map(([n, v]) => ({ name: n, prs: v.prs.size })),
    },
    head_sample: {
      requested: HEAD_SAMPLE,
      read_completely: goodHeads.length,
      truncated_refused: truncated.map((t) => ({ sha: t.sha, total: t.total, collected: t.collected })),
      check_runs_per_head: goodHeads.map((r) => r.total),
    },
    api_calls: CALLS,
    controls: {
      distinct_workflow_run_counts: distinctRunCounts.size,
      repo_wide_pr_runs_in_window: repoWide.total_count,
      sum_of_per_workflow_runs: popSum,
      // popSum <= repoWide is the sanity band; equality is not expected because
      // runs from workflows deleted mid-window are counted repo-wide but have
      // no surviving workflow row.
      sum_within_repo_total: popSum <= repoWide.total_count,
    },
    headline: {
      distinct_names: rows.length,
      advisory_names: advisory.length,
      advisory_never_failed_in_window: neverFailed.length,
      advisory_never_failed_and_did_run: neverFailedEverRan.length,
      advisory_never_ran_on_any_sampled_head: neverRan.length,
      advisory_continue_on_error_tainted: coeTainted.length,
      advisory_load_bearing: rows.filter((r) => r.loadBearing).length,
    },
    load_bearing_unresolved_jobs: lb.unresolved,
    verdicts: verdictCounts,
    projected_reduction: projected,
    workflows_population: pop.sort((a, b) => b.runs - a.runs),
    names: rows,
  };

  if (JSON_OUT) writeFileSync(JSON_OUT, JSON.stringify(report, null, 2));

  // ---- human output -------------------------------------------------
  const L = console.log;
  L(`advisory-census — ${REPO}`);
  L(`window: last ${DAYS}d (created>=${SINCE}) · generated ${report.generated_at}`);
  L(`required set (read from ${req.source}): ${[...req.set].join(" | ") || "(none)"}`);
  L(`head sample: ${goodHeads.length}/${heads.length} read to completion` +
    (truncated.length ? ` · ${truncated.length} REFUSED AS TRUNCATED` : "") +
    ` · check-runs per head: ${Math.min(...report.head_sample.check_runs_per_head)}–${Math.max(...report.head_sample.check_runs_per_head)}`);
  L(`api calls: ${CALLS}`);
  L(`controls: ${distinctRunCounts.size} distinct per-workflow run counts (uniform => refused) · ` +
    `sum(per-workflow)=${popSum} vs repo-wide PR runs=${repoWide.total_count} · ` +
    `within band: ${popSum <= repoWide.total_count}`);
  L("");
  L(`HEADLINE`);
  L(`  distinct check-run names on sampled heads : ${rows.length}`);
  L(`  advisory (cannot block a merge)           : ${advisory.length}`);
  L(`  advisory with ZERO failing runs in window : ${neverFailed.length}   <- never caught anything`);
  L(`     ...of which DID run (not merely skipped) : ${neverFailedEverRan.length}`);
  L(`  advisory that never RAN (skipped on every sampled head) : ${neverRan.length}`);
  L(`  advisory whose workflow carries continue-on-error       : ${coeTainted.length}   <- green is not evidence`);
  L(`  advisory that is LOAD-BEARING (needs of a required gate) : ${rows.filter((r) => r.loadBearing).length}   <- cannot be moved`);
  L("");
  const mergedAdvisory = report.merged_sample.advisory_names_red_at_merge;
  const mergedRedTotal = mergedAdvisory.reduce((a, x) => a + x.merged_prs_with_this_red, 0);
  L(`MERGED-PAST (the only sound "acted on" proxy — and it only answers NO)`);
  L(`  merged PRs read to completion            : ${mergedOk.length}`);
  L(`  distinct advisory names RED AT MERGE     : ${mergedAdvisory.length}`);
  L(`  advisory red-at-merge instances          : ${mergedRedTotal}   <- reds that shipped, uncleared`);
  for (const x of mergedAdvisory.slice(0, 15)) L(`    ${String(x.merged_prs_with_this_red).padStart(3)}  ${x.name}`);
  L("");
  L(`VERDICTS`);
  for (const [k, v] of Object.entries(verdictCounts).sort((a, b) => b[1] - a[1])) L(`  ${k.padEnd(18)}: ${v}`);
  L("");
  L(`PROJECTED REDUCTION if every move-*/delete recommendation were taken`);
  L(`  heads used for cost (non-empty)         : ${projected.cost_heads_used}  (${projected.heads_with_zero_check_runs} sampled heads had ZERO check-runs — CI not yet started; excluded)`);
  L(`  mean / median check-runs per head today : ${projected.mean_check_runs_per_head_today} / ${projected.median_check_runs_per_head_today}`);
  L(`     of which EXECUTED / SKIPPED          : ${projected.mean_EXECUTED_check_runs_per_head_today} / ${projected.mean_SKIPPED_check_runs_per_head_today}   (a skipped check-run costs no runner and no queue slot)`);
  L(`  runner-seconds per head today           : ${projected.mean_runner_seconds_per_head_today}`);
  L(`  check-runs removed per head             : ${projected.check_runs_removed_per_head}`);
  L(`  ...of which actually EXECUTED (not skipped) : ${projected.of_which_actually_executed}`);
  L(`  runner-seconds removed per head         : ${projected.runner_seconds_removed_per_head}`);
  if (lb.unresolved.length) L(`  NOTE: ${lb.unresolved.length} needs-targets unresolved (treated as load-bearing): ${lb.unresolved.slice(0, 8).join(", ")}`);
  L("");
  L(`NAMES  (pop* = complete for the window at WORKFLOW granularity; sample* = ${goodHeads.length} heads)`);
  L(["REQ", "occ", "heads", "ran", "skip", "canc", "FAIL", "avgS", "popRuns", "popFail", "popCanc", "coFail", "maxPR/h", "CoE", "triggers", "wf", "LB", "verdict", "name"].join("\t"));
  for (const r of rows) {
    L([
      r.required ? "REQ" : "-",
      r.occurrences, r.headsSeen, r.sampleRan, r.sampleSkipped, r.sampleCancelled, r.sampleNonSuccess,
      r.avgSec ?? "-", r.popRuns ?? "-", r.popFailures ?? "-", r.popCancelled ?? "-",
      r.burstCoFailShare ?? "-", r.burstMaxPRsPerHour ?? "-",
      r.continueOnError ?? "-",
      (r.triggers || []).join(",") || "-",
      r.workflowFile || "UNATTRIBUTED",
      r.loadBearing ? "LB" : "-",
      r.verdict,
      r.name,
    ].join("\t"));
  }
  L("");
  L(PROXY_TEXT());
})().catch((e) => {
  console.error("advisory-census FAILED:", e.message);
  process.exit(1);
});
