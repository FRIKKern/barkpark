#!/usr/bin/env node
// re-indexer.mjs — the CONTINUOUS RE-INDEXER (cqv5 phase 5).
//
// Keeps the understanding map CURRENT with ZERO manual runs, so an agent's
// `manifest.mjs verify` always passes — the map is never more than one edit
// behind. It does the cheap, drift-gated half of the chain automatically:
//
//   • manifest      — ALWAYS rebuilt (instant; `git ls-files -s`, no hashing)
//   • blast-radius  — rebuilt ONLY if its content signature drifted (cached on sig)
//   • symbol-graph  — rebuilt ONLY if its per-lang signatures drifted (cached on sig)
//
// It does NOT run the expensive agent research (coverage / intentions / publish) —
// that stays drift-gated and manual via status.mjs. The re-indexer's job is to
// keep the structural map pinned to the live tree, nothing more.
//
// MODES
//   (default)              daemon: fs.watch(recursive) + ~500ms debounce → incremental reindex
//   --once <file>...       git-hook mode: fast, non-blocking incremental reindex, exit 0
//   install-hook           install an OPT-IN, idempotent git post-commit hook
//   status                 is the map current? (delegates to manifest verify) + last reindex
//
// DEPENDENCY-FREE. Robust: a reindex failure is caught + logged, never crashes
// the daemon. Non-disruptive: the hook is post-commit (runs AFTER the commit, so
// it never blocks committing), fast, and opt-in.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, watch, mkdirSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();

// ── the builders the re-indexer drives (the chain's cheap, cacheable half) ──
const MANIFEST = "tooling/map/manifest.mjs";
const BLAST = "tooling/blast-radius/build-index.mjs";
const SYMBOLS = "tooling/symbol-graph/build-symbols.mjs";

// where we record the last reindex (status reads it; daemon writes it)
const STATE = join(HERE, "last-reindex.json");

// ── EXCLUDE — same shape the other tools use (file-importance/build-signals.mjs).
// Plus the re-indexer's own derived outputs and state so a rebuild never re-triggers
// the watcher (the index.json / symbols.json / manifest.json writes would loop).
const EXCLUDE = /(^|\/)(node_modules|_build|deps|dist|\.git|vendor|priv\/static\/assets|tmp)\/|package-lock\.json$|pnpm-lock\.yaml$|\.lock$|go\.sum$|erl_crash\.dump$/;
// derived map artifacts — writing these must NOT count as a source change.
const DERIVED = /(^|\/)(manifest\.json|index\.json|symbols\.json|last-impact\.json|last-reindex\.json|nodes\.json|.*-report\.json|.*-cache\.json)$/;

const C = process.stderr.isTTY
  ? { g: "\x1b[32m", y: "\x1b[33m", r: "\x1b[31m", b: "\x1b[1m", d: "\x1b[2m", x: "\x1b[0m" }
  : { g: "", y: "", r: "", b: "", d: "", x: "" };
const log = (s = "") => process.stderr.write(s + "\n");
const ts = () => new Date().toISOString();

// run a builder script, capturing nothing on stdout, surfacing only failures.
// returns { ok, ms, err? } — NEVER throws (a reindex failure must not crash us).
function runBuilder(rel, args = []) {
  const t0 = Date.now();
  try {
    execFileSync("node", [join(ROOT, rel), ...args], {
      cwd: ROOT,
      stdio: ["ignore", "ignore", "ignore"],
      maxBuffer: 256 * 1024 * 1024,
    });
    return { ok: true, ms: Date.now() - t0 };
  } catch (err) {
    return { ok: false, ms: Date.now() - t0, err: String(err.message || err).split("\n")[0] };
  }
}

// read a JSON file under ROOT, tolerant of missing/corrupt.
function readJson(absPath) {
  try { return JSON.parse(readFileSync(absPath, "utf8")); } catch { return null; }
}

// ── the one incremental reindex. Always manifest; blast + symbols are
// SELF-GATING — the builders cache on their content signature, so invoking them
// when nothing drifted is ~free (they reuse their cache and rewrite identical
// output). We still report which ones actually did work vs reused cache by
// comparing the builder's reported `head`/sig isn't worth it — instead we just
// time each and let the builder's own caching keep unchanged runs cheap.
function reindex(reason) {
  const t0 = Date.now();
  const results = {};

  // 1) manifest — always, instant.
  results.manifest = runBuilder(MANIFEST, ["build"]);

  // 2) blast-radius — self-gated on its elixirSig + go/js scans. Cheap when unchanged.
  results.blast = runBuilder(BLAST);

  // 3) symbol-graph — self-gated per-language on langSig. Cheap when unchanged.
  results.symbols = runBuilder(SYMBOLS);

  const totalMs = Date.now() - t0;
  const parts = [];
  for (const [name, r] of Object.entries(results)) {
    if (r.ok) parts.push(`${C.g}${name} ${r.ms}ms${C.x}`);
    else parts.push(`${C.r}${name} FAILED (${r.err})${C.x}`);
  }
  const anyFail = Object.values(results).some((r) => !r.ok);
  log(`${C.d}${ts()}${C.x} ${C.b}reindex${C.x} (${reason}) — ${parts.join(" · ")} ${C.d}[${totalMs}ms total]${C.x}`);

  // persist state for `status` (best-effort; never fatal).
  try {
    writeFileSync(STATE, JSON.stringify({
      at: ts(), reason, totalMs,
      results: Object.fromEntries(Object.entries(results).map(([k, r]) => [k, { ok: r.ok, ms: r.ms, err: r.err || null }])),
      head: gitHead(),
    }, null, 2) + "\n");
  } catch { /* state write is best-effort */ }

  return { ok: !anyFail, results, totalMs };
}

function gitHead() {
  try { return execFileSync("git", ["rev-parse", "HEAD"], { cwd: ROOT, encoding: "utf8" }).trim(); }
  catch { return ""; }
}

// is this changed path one we care about? (source, not derived/excluded)
function isRelevant(relPath) {
  if (!relPath || relPath.startsWith("..")) return false;
  const p = relPath.split(sep).join("/");
  if (EXCLUDE.test("/" + p)) return false;
  if (DERIVED.test("/" + p)) return false;
  return true;
}

// ════════════════════════════════════════════════════════════ DAEMON ═══════
// fs.watch the repo root recursively. Debounce a burst of change events (~500ms)
// into a single incremental reindex. Robust + auto-reconnecting like cody's watch
// loop — if the recursive watcher dies (rename of a watched dir, FS hiccup) we
// re-establish it after a short backoff.
const DEBOUNCE_MS = 500;
const RECONNECT_MS = 3000;

function daemon() {
  log(`${C.b}[re-indexer]${C.x} continuous reindex on ${C.d}${ROOT}${C.x} — manifest always · blast+symbols drift-gated`);
  log(`${C.d}  watching (recursive), ${DEBOUNCE_MS}ms debounce. Ctrl-C to stop.${C.x}`);

  // initial pin so the map is current the moment the daemon comes up.
  reindex("startup");

  let timer = null;
  let pending = new Set();
  const schedule = (relPath) => {
    if (relPath) pending.add(relPath);
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      const n = pending.size;
      const sample = [...pending].slice(0, 3).map((p) => p.split("/").pop()).join(", ");
      pending = new Set();
      timer = null;
      reindex(n ? `${n} change(s): ${sample}${n > 3 ? "…" : ""}` : "fs event");
    }, DEBOUNCE_MS);
  };

  let watcher = null;
  const connect = () => {
    try {
      watcher = watch(ROOT, { recursive: true }, (_event, filename) => {
        if (!filename) { schedule(null); return; } // unknown file → reindex anyway
        const relPath = String(filename).split(sep).join("/");
        if (!isRelevant(relPath)) return;
        schedule(relPath);
      });
      watcher.on("error", (err) => {
        log(`${C.y}  watcher error: ${err.message}; reconnecting in ${RECONNECT_MS}ms${C.x}`);
        try { watcher.close(); } catch {}
        setTimeout(connect, RECONNECT_MS);
      });
      log(`${C.d}  connected → fs.watch(${relative(ROOT, ROOT) || "."}, recursive)${C.x}`);
    } catch (err) {
      log(`${C.y}  watch failed: ${err.message}; retry in ${RECONNECT_MS}ms${C.x}`);
      setTimeout(connect, RECONNECT_MS);
    }
  };
  connect();

  // keep the process alive; clean shutdown on signals.
  const shutdown = () => {
    log(`\n${C.d}[re-indexer] stopping.${C.x}`);
    try { if (watcher) watcher.close(); } catch {}
    if (timer) clearTimeout(timer);
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

// ═══════════════════════════════════════════════════════════════ --once ═════
// git-hook / one-shot mode. Reindex the slices the given files affect. Today
// every relevant source change funnels into the same cheap, drift-gated chain,
// so we run the full incremental reindex (manifest + drift-gated blast/symbols).
// Fast, non-blocking, ALWAYS exit 0 — a hook must never fail the surrounding op.
function once(files) {
  const relevant = files.filter((f) => isRelevant(f.split(sep).join("/")));
  if (files.length && !relevant.length) {
    log(`${C.d}[re-indexer --once] no relevant files among ${files.length} change(s) — manifest only${C.x}`);
  }
  const reason = relevant.length
    ? `--once ${relevant.length} file(s): ${relevant.slice(0, 3).map((f) => f.split("/").pop()).join(", ")}${relevant.length > 3 ? "…" : ""}`
    : "--once (no file list)";
  try {
    reindex(reason);
  } catch (err) {
    log(`${C.r}[re-indexer --once] reindex error (non-fatal): ${String(err.message || err).split("\n")[0]}${C.x}`);
  }
  process.exit(0); // hook contract: never block.
}

// ════════════════════════════════════════════════════════════ status ═══════
// Is the map current? Delegate the verdict to manifest.mjs verify (its job is
// exactly "does the pinned map match the live tree"). Add when we last reindexed.
function status() {
  let verdict = null;
  try {
    const out = execFileSync("node", [join(ROOT, MANIFEST), "verify", "--json"], {
      cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024,
    });
    verdict = JSON.parse(out);
  } catch (err) {
    // manifest verify exits 1 when STALE — execFileSync throws but still gives stdout.
    if (err.stdout) { try { verdict = JSON.parse(err.stdout); } catch {} }
    if (!verdict) verdict = { ok: false, reason: "verify-failed", message: String(err.message || err).split("\n")[0] };
  }

  const last = readJson(STATE);
  log(`${C.b}re-indexer status${C.x}`);
  if (verdict.ok) {
    log(`  map: ${C.g}CURRENT${C.x} — HEAD ${(verdict.headNow || "").slice(0, 8)} matches manifest (pinned ${verdict.pinnedAt || "?"})`);
  } else if (verdict.reason === "no-manifest") {
    log(`  map: ${C.y}NO MANIFEST${C.x} — run a reindex (re-indexer.mjs --once, or start the daemon)`);
  } else {
    const c = verdict.counts || {};
    log(`  map: ${C.r}STALE${C.x} — ${c.stale || 0} changed · ${c.added || 0} added · ${c.deleted || 0} deleted · ${c.dirty || 0} dirty`);
    log(`       ${C.d}→ a reindex (or any save while the daemon runs) re-pins it${C.x}`);
  }
  if (last) {
    const ok = last.results && Object.values(last.results).every((r) => r.ok);
    log(`  last reindex: ${last.at} (${last.reason}) — ${ok ? C.g + "ok" : C.r + "had failures"}${C.x} ${C.d}[${last.totalMs}ms]${C.x}`);
  } else {
    log(`  last reindex: ${C.d}(never recorded — daemon not yet run, or --once not yet invoked)${C.x}`);
  }
  process.exit(verdict.ok ? 0 : 1);
}

// ═════════════════════════════════════════════════════════ install-hook ════
// Install an OPT-IN, idempotent git post-commit hook into .githooks/post-commit.
// post-commit runs AFTER the commit lands, so it NEVER blocks committing. The
// hook collects the just-committed files and feeds them to `--once`, re-pinning
// the map every commit. We bracket our block in clear sentinel markers and skip
// re-insertion if the block is already present (idempotent). We respect any
// existing hook content — append, never clobber.
const SENTINEL_BEGIN = "# >>> barkpark re-indexer (cqv5 phase 5) >>>";
const SENTINEL_END = "# <<< barkpark re-indexer (cqv5 phase 5) <<<";

function hookBlock() {
  // Use a path relative to the repo root so the hook is checkout-portable.
  const relScript = relative(ROOT, join(HERE, "re-indexer.mjs")).split(sep).join("/");
  return [
    SENTINEL_BEGIN,
    "# Auto-re-pin the understanding map after every commit (opt-in, non-blocking).",
    "# Runs AFTER the commit, so it can never block or slow down committing.",
    "# Idempotent: bounded by the sentinels above/below — re-running install-hook",
    "# will NOT duplicate this block. Remove the block to disable.",
    "if command -v node >/dev/null 2>&1; then",
    "  # files changed in the commit just made (HEAD vs its first parent; root commit ok).",
    "  _ri_files=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null)",
    "  if [ -n \"$_ri_files\" ]; then",
    `    node "$(git rev-parse --show-toplevel)/${relScript}" --once $_ri_files >/dev/null 2>&1 || true`,
    "  fi",
    "fi",
    SENTINEL_END,
  ].join("\n");
}

function installHook(opts = {}) {
  const dryRun = opts.dryRun;
  const hooksDir = join(ROOT, ".githooks");
  const hookPath = join(hooksDir, "post-commit");
  const block = hookBlock();

  let existing = existsSync(hookPath) ? readFileSync(hookPath, "utf8") : "";
  let action;
  let next;

  if (existing.includes(SENTINEL_BEGIN) && existing.includes(SENTINEL_END)) {
    // idempotent: replace the existing block in place (keeps it fresh if the
    // script path changed) but do not duplicate.
    const re = new RegExp(escapeRe(SENTINEL_BEGIN) + "[\\s\\S]*?" + escapeRe(SENTINEL_END));
    next = existing.replace(re, block);
    action = next === existing ? "already-present (no change)" : "refreshed existing block";
  } else if (existing.trim()) {
    // respect existing hook — append our block after it.
    next = existing.replace(/\n*$/, "\n") + "\n" + block + "\n";
    action = "appended to existing post-commit hook";
  } else {
    // fresh hook.
    next = "#!/bin/bash\n# Post-commit hook.\n\n" + block + "\n";
    action = "created new post-commit hook";
  }

  if (dryRun) {
    log(`${C.b}[install-hook --dry-run]${C.x} would ${action} at ${C.d}${relative(ROOT, hookPath)}${C.x}`);
    log(`${C.d}── hook content (post-commit) ──────────────────────────────${C.x}`);
    process.stdout.write(next.endsWith("\n") ? next : next + "\n");
    log(`${C.d}────────────────────────────────────────────────────────────${C.x}`);
    return { action, hookPath, content: next, dryRun: true };
  }

  if (!existsSync(hooksDir)) mkdirSync(hooksDir, { recursive: true });
  writeFileSync(hookPath, next);
  try { execFileSync("chmod", ["+x", hookPath]); } catch {}
  log(`${C.g}✓${C.x} ${action} → ${C.b}${relative(ROOT, hookPath)}${C.x}`);

  // tell the user how to enable .githooks if it isn't the active hooksPath.
  let active = "";
  try { active = execFileSync("git", ["config", "core.hooksPath"], { cwd: ROOT, encoding: "utf8" }).trim(); } catch {}
  if (active === ".githooks") {
    log(`  ${C.d}core.hooksPath is already .githooks — the hook is live.${C.x}`);
  } else {
    log(`  ${C.y}To enable:${C.x} git config core.hooksPath .githooks   ${C.d}(current: ${active || "(unset — default .git/hooks)"})${C.x}`);
  }
  return { action, hookPath, content: next };
}

function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

// ───────────────────────────────────────────────────────────────── CLI ──────
const [cmd, ...rest] = process.argv.slice(2);

if (cmd === "--once") {
  once(rest.filter((a) => !a.startsWith("--")));
} else if (cmd === "install-hook") {
  installHook({ dryRun: rest.includes("--dry-run") });
} else if (cmd === "status") {
  status();
} else if (cmd === undefined || cmd === "--watch" || cmd === "watch" || cmd === "daemon") {
  daemon();
} else {
  log("usage: re-indexer.mjs                     # daemon (default): watch + debounce + incremental reindex");
  log("       re-indexer.mjs --once <file>...    # git-hook mode: fast reindex, exit 0");
  log("       re-indexer.mjs install-hook [--dry-run]   # install opt-in post-commit hook");
  log("       re-indexer.mjs status              # is the map current? + last reindex");
  process.exit(2);
}
