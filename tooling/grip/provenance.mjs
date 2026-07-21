#!/usr/bin/env node
// provenance.mjs — grip's answer to the question it asks everything else.
//
//   import { treeProvenance, provenanceLine, emitProvenance } from "./provenance.mjs";
//
// THE INCIDENT THIS EXISTS FOR (charter D78). The lead ran
// `node tooling/grip/ledger.mjs leads ledger` from a worktree and got the OLD,
// pre-`leads` usage string — because the process executed the WORKTREE's stale
// `ledger.mjs`, not `origin/main`'s. A shipped feature read as unshipped, and it
// cost a false negative on this very epic while verifying this very wave. The
// adjudicator was un-adjudicated: grip applies "a local checkout is an L3 claim
// that can run 200 commits stale and lie silently" to every fact it judges and
// to nothing about itself. This module is that doctrine turned inward.
//
// THE FOUR FACTS, AND WHY THESE FOUR. Root, HEAD, whether HEAD differs from
// `origin/main`, and whether the tree is dirty. Those are exactly the four
// whose absence produced the false negative: the root says WHICH tree ran, the
// HEAD/origin comparison says whether that tree could possibly know about the
// feature, and dirty says whether what ran is even a committed state.
//
// IT PERFORMS NO FETCH, AND SAYS SO. `origin/main` in any clone is a mirror of
// the SOURCE's `refs/heads/main` as of the last fetch, and a clone silently
// inherits the source's staleness (charter D75: measured 41 commits and 69
// files apart, both exits 0). So "in sync with origin/main" is a claim about a
// possibly-stale ref, and the line must say "as of last fetch" rather than
// imply a live comparison. Fetching here would be a network write-path in a
// diagnostic banner — an unacceptable cost on every single verb invocation, and
// a side effect in a module whose whole job is to observe.
//
// STDERR, NOT STDOUT — measured, not reasoned (D78). An unconditional stdout
// banner breaks `leads --json` AND `fold`: both `JSON.parse(stdout)`, and both
// fail with `Unexpected token 'g', "[grip-prove"... is not valid JSON`. `fold`
// emits BARE JSON with no flag gating it, so a stdout banner corrupts the
// tool's only always-machine verb. This module therefore never writes to
// stdout; `emitProvenance` defaults to `process.stderr` and callers should not
// override it with stdout.
//
// TOTAL BY CONSTRUCTION. `treeProvenance` never throws, never exits, and never
// returns a half-object. Outside a git repo, in a repo with no commits, in a
// single-ref CI checkout with no `origin/main` (which exits 128 — D75), or on a
// host with no `git` at all, it returns a STATED VERDICT: the unknowable fields
// are `null` and `state` + `reason` say which of those worlds we are in. A
// diagnostic that can crash the tool it is diagnosing is worse than no
// diagnostic, because the crash is attributed to the verb.
//
// DEPENDS ON NOTHING IN grip/. Node builtins only, on purpose: a module that
// reports on the tree must not import the modules whose staleness it is
// reporting on, or a stale tree can break its own staleness warning.

import { spawnSync } from "node:child_process";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * THE TREE THIS CODE CAME FROM — not `process.cwd()`, and the distinction is
 * the incident. The lead's `leads ledger` answered from a stale WORKTREE's
 * `ledger.mjs`; what misled them was which FILE executed, not which directory
 * they were standing in. `process.cwd()` answers the second question, and the
 * two diverge the moment anyone runs `node /path/to/main/tooling/grip/census.mjs`
 * from somewhere else. Grip's data is module-relative too (`census.mjs` resolves
 * its ledger and corpus off `import.meta.url`), so the module's own tree is the
 * tree that determines every answer grip gives. `treeProvenance` still takes any
 * `cwd` — the tests point it at throwaway repos — but the entry-point banner
 * defaults here.
 */
export const MODULE_TREE = dirname(fileURLToPath(import.meta.url));

/** Nothing grip does at startup is worth hanging a verb over. */
const GIT_TIMEOUT_MS = 5_000;

/** The prefix every provenance banner carries, so it is greppable and skippable. */
export const PROVENANCE_PREFIX = "[grip-provenance]";

/**
 * Said on every rendered comparison. `origin/main` is only as fresh as the last
 * fetch (D75), and the banner must not imply it just checked. `FETCHED_PHRASE`
 * is the four words that go IN the one-line banner; `FETCHED_NOTE` is the full
 * sentence carried in the object for machine consumers.
 */
export const FETCHED_PHRASE = "as of last fetch";
export const FETCHED_NOTE = `${FETCHED_PHRASE} — grip performs no fetch of its own`;

/** The worlds `treeProvenance` can find itself in. Every one of them is an ANSWER. */
export const PROVENANCE_STATE = Object.freeze({
  MEASURED: "measured",
  NO_ORIGIN_MAIN: "no-origin-main",
  NO_COMMITS: "no-commits",
  NOT_A_REPO: "not-a-repo",
  GIT_UNAVAILABLE: "git-unavailable",
});

/**
 * Run one git command and report the outcome WITHOUT ever throwing.
 * Returns { ok, out, code, reason } — `reason` is populated on failure only.
 */
function git(args, cwd) {
  let r;
  try {
    r = spawnSync("git", args, {
      cwd,
      encoding: "utf8",
      timeout: GIT_TIMEOUT_MS,
      windowsHide: true,
      // Never inherit stdio: a banner must not be able to hang on a pager or
      // prompt for credentials on a verb that was only asked for a SHA.
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch (err) {
    // spawnSync can throw for a cwd that does not exist on some platforms.
    return { ok: false, out: "", code: null, reason: err?.message ?? String(err) };
  }
  if (r.error) {
    const enoent = r.error.code === "ENOENT";
    return {
      ok: false,
      out: "",
      code: null,
      reason: enoent ? "git is not on PATH" : (r.error.message ?? String(r.error)),
      unavailable: enoent,
    };
  }
  if (r.status !== 0) {
    return { ok: false, out: "", code: r.status, reason: (r.stderr || "").trim() || `git ${args[0]} exited ${r.status}` };
  }
  return { ok: true, out: (r.stdout ?? "").trim(), code: 0 };
}

const short = (sha) => (typeof sha === "string" && sha.length >= 8 ? sha.slice(0, 8) : sha ?? null);

/**
 * Which tree is this process answering from?
 *
 * @param {{ cwd?: string }} [opts]
 * @returns {{
 *   cwd: string, state: string, reason: string|null, in_repo: boolean,
 *   root: string|null, head: string|null, head_short: string|null,
 *   origin_main: string|null, origin_main_short: string|null,
 *   differs_from_origin: boolean|null, dirty: boolean|null, dirty_files: number|null,
 *   fetched_note: string,
 * }}
 */
export function treeProvenance({ cwd = process.cwd() } = {}) {
  const base = {
    cwd,
    state: PROVENANCE_STATE.MEASURED,
    reason: null,
    in_repo: false,
    root: null,
    head: null,
    head_short: null,
    origin_main: null,
    origin_main_short: null,
    differs_from_origin: null,
    dirty: null,
    dirty_files: null,
    fetched_note: FETCHED_NOTE,
  };

  // 1. THE ROOT. `--show-toplevel` returns the WORKTREE's own path; the
  // tempting `--git-common-dir` returns the PRIMARY checkout's .git and would
  // name the wrong tree in exactly the situation this module was built for.
  const root = git(["rev-parse", "--show-toplevel"], cwd);
  if (!root.ok) {
    return {
      ...base,
      state: root.unavailable ? PROVENANCE_STATE.GIT_UNAVAILABLE : PROVENANCE_STATE.NOT_A_REPO,
      reason: root.unavailable
        ? "git is not on PATH — grip cannot say which tree it is answering from"
        : `not a git repository (or git refused): ${root.reason}`,
    };
  }

  const out = { ...base, in_repo: true, root: root.out };

  // 2. HEAD. Absent in a repo with no commits — an answer, not an error.
  const head = git(["rev-parse", "HEAD"], cwd);
  if (head.ok) {
    out.head = head.out;
    out.head_short = short(head.out);
  } else {
    out.state = PROVENANCE_STATE.NO_COMMITS;
    out.reason = `HEAD is unresolvable (a repository with no commits?): ${head.reason}`;
  }

  // 3. origin/main. A single-ref CI checkout has none and exits 128 (D75).
  // That is the honest "I cannot compare" state, not a crash.
  const om = git(["rev-parse", "origin/main"], cwd);
  if (om.ok) {
    out.origin_main = om.out;
    out.origin_main_short = short(om.out);
    if (out.head) out.differs_from_origin = out.head !== om.out;
  } else if (out.state === PROVENANCE_STATE.MEASURED) {
    out.state = PROVENANCE_STATE.NO_ORIGIN_MAIN;
    out.reason = "this clone has no origin/main ref, so grip cannot say whether this tree is stale";
  }

  // 4. DIRTY. `-uno` on purpose: untracked files are noise here (build output,
  // scratch), while a modified TRACKED file means the code that just ran is not
  // the code at HEAD — which is the thing worth saying.
  const status = git(["status", "--porcelain", "-uno"], cwd);
  if (status.ok) {
    const lines = status.out ? status.out.split("\n").filter((l) => l.trim() !== "") : [];
    out.dirty = lines.length > 0;
    out.dirty_files = lines.length;
  }

  return out;
}

/**
 * The one-line human banner. Never multi-line: it is the FIRST thing an
 * operator sees before a verb's real output, and it earns exactly one line.
 *
 * @param {ReturnType<typeof treeProvenance>} p
 * @returns {string}
 */
export function provenanceLine(p) {
  if (!p || typeof p !== "object") return `${PROVENANCE_PREFIX} unknown — no provenance was measured`;

  if (!p.in_repo) {
    const what = p.state === PROVENANCE_STATE.GIT_UNAVAILABLE ? "GIT UNAVAILABLE" : "NOT A GIT REPOSITORY";
    return `${PROVENANCE_PREFIX} ${what} at ${p.cwd} — grip cannot say which tree it is answering from`;
  }

  const parts = [`tree ${p.root}`];
  parts.push(p.head_short ? `HEAD ${p.head_short}` : "HEAD unresolvable (no commits)");

  if (p.differs_from_origin === true) {
    parts.push(`DIFFERS from origin/main ${p.origin_main_short} ${FETCHED_PHRASE} — this tree may not contain what main ships`);
  } else if (p.differs_from_origin === false) {
    parts.push(`in sync with origin/main ${FETCHED_PHRASE}`);
  } else {
    parts.push(`cannot compare against origin/main ${FETCHED_PHRASE} — ${p.reason || "no comparison was possible"}`);
  }

  if (p.dirty === true) parts.push(`DIRTY (${p.dirty_files} tracked file${p.dirty_files === 1 ? "" : "s"} modified)`);
  else if (p.dirty === false) parts.push("clean");

  return `${PROVENANCE_PREFIX} ${parts.join(" · ")}`;
}

/**
 * Measure and announce, on STDERR. The single call every grip entry point
 * makes as its first act.
 *
 * Defaults to `MODULE_TREE`, not `process.cwd()` — see the note on that
 * constant: the question is which tree the CODE came from.
 *
 * Returns the measured provenance so a caller that also wants it in machine
 * form (`leads --json` carries it as a `provenance` object) pays for the four
 * git calls exactly once.
 *
 * @param {{ cwd?: string, stream?: { write: (s: string) => unknown } }} [opts]
 */
export function emitProvenance({ cwd = MODULE_TREE, stream = process.stderr } = {}) {
  const p = treeProvenance({ cwd });
  try {
    stream.write(`${provenanceLine(p)}\n`);
  } catch {
    // A closed or broken stderr must never take down the verb. The banner is a
    // courtesy; the verb's answer is the product.
  }
  return p;
}
