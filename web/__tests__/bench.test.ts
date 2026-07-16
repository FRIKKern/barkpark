/**
 * bench.tsx `run()` used to await `benchCell(...) -> fetch('/api/find').then(r
 * => r.json())` with no try/catch/finally: `setRunning(false)`/`setProgress(null)`
 * sat AFTER the loop, unreachable on throw. React error boundaries don't catch
 * event-handler rejections, so one failed fetch left the "Run benchmark" button
 * stuck on "Running…" forever with no error and no retry.
 *
 * `runBenchmark` is the extracted, DOM-free control flow the component's click
 * handler now delegates to (see bench.tsx) — driven here with plain spy
 * setters standing in for the real `useState` setters, so this proves the
 * button-re-enable + error-surfacing contract.
 *
 * Node's test runner strips types but cannot parse JSX, so — like
 * sheet-grid-render.test.ts — this transpiles the component with the repo's
 * own TypeScript compiler and rewrites the `@/lib/*` alias to file URLs
 * before importing the real component module.
 *
 * Run: `node --test --test-reporter=spec __tests__/bench.test.ts`.
 */

import { test, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import ts from "typescript";
import type { SearchEngine } from "../lib/find.ts";

/* ── load the component (tsx → mjs, alias → file URLs) ────────────────────── */

const componentsDir = fileURLToPath(new URL("../components/", import.meta.url));
const libUrl = new URL("../lib/", import.meta.url).href;

const source = readFileSync(path.join(componentsDir, "bench.tsx"), "utf8");
const transpiled = ts.transpileModule(source, {
  compilerOptions: {
    jsx: ts.JsxEmit.ReactJSX,
    module: ts.ModuleKind.ESNext,
    target: ts.ScriptTarget.ES2022,
    verbatimModuleSyntax: false,
  },
}).outputText;

// `@/lib/foo` → absolute file:// URL of the .ts source (node strips types).
// `next/link` has no plain-ESM export map in this workspace and is never
// invoked by the pure `runBenchmark` control flow under test, so it is
// swapped for an inert local stub rather than resolved for real.
const rewritten = transpiled
  .replace(
    /(["'])@\/lib\/([^"']+)\1/g,
    (_m, _q, mod: string) => JSON.stringify(`${libUrl}${mod}.ts`),
  )
  .replace(/import\s+Link\s+from\s+["']next\/link["'];?/, "const Link = () => null;");

// The temp module must live inside web/ so `react`/`next/link` resolve.
const tmpPath = path.join(componentsDir, `.bench.test-${process.pid}.mjs`);
writeFileSync(tmpPath, rewritten);
after(() => {
  try {
    unlinkSync(tmpPath);
  } catch {
    /* already gone */
  }
});

const mod = await import(pathToFileURL(tmpPath).href);

interface Cell {
  rt: number;
  upstreamMs: number | null;
  total: number;
}

type Grid = Record<string, Partial<Record<SearchEngine, Cell>>>;

const { runBenchmark } = mod as {
  runBenchmark: (
    fetchCell: (q: string, engine: SearchEngine) => Promise<Cell>,
    setters: {
      setRunning: (v: boolean) => void;
      setProgress: (v: string | null) => void;
      setGrid: (v: Grid) => void;
      setError: (v: string | null) => void;
    },
  ) => Promise<void>;
};

/** A tiny recorder standing in for the four `useState` setters `runBenchmark`
 * takes — no React, no DOM, just the last value each setter was called with. */
function fakeSetters() {
  const state = {
    running: false,
    progress: null as string | null,
    grid: {} as Grid,
    error: null as string | null,
  };
  return {
    state,
    setRunning: (v: boolean) => {
      state.running = v;
    },
    setProgress: (v: string | null) => {
      state.progress = v;
    },
    setGrid: (v: Grid) => {
      state.grid = v;
    },
    setError: (v: string | null) => {
      state.error = v;
    },
  };
}

test("runBenchmark re-enables the button and surfaces an error when /api/find fails (fails before the try/catch/finally fix)", async () => {
  const s = fakeSetters();
  const failingFetchCell = async (): Promise<Cell> => {
    throw new Error("fetch failed");
  };

  await runBenchmark(failingFetchCell, {
    setRunning: s.setRunning,
    setProgress: s.setProgress,
    setGrid: s.setGrid,
    setError: s.setError,
  });

  // The button re-enables: without the finally, `running` stays true forever.
  assert.equal(s.state.running, false, "running must be reset to false after a failed cell");
  // The transient "Running… q · engine" progress label is cleared too.
  assert.equal(s.state.progress, null, "progress must be cleared after a failed cell");
  // An inline error banner has something to show.
  assert.equal(s.state.error, "fetch failed", "error must carry the failure message");
});

test("runBenchmark clears a stale error and re-populates the grid on a subsequent successful run", async () => {
  const s = fakeSetters();
  s.state.error = "previous run failed";

  const okFetchCell = async (): Promise<Cell> => ({ rt: 12, upstreamMs: 4, total: 3 });

  await runBenchmark(okFetchCell, {
    setRunning: s.setRunning,
    setProgress: s.setProgress,
    setGrid: s.setGrid,
    setError: s.setError,
  });

  assert.equal(s.state.running, false, "running settles back to false on success too");
  assert.equal(s.state.progress, null, "progress clears on success too");
  assert.equal(s.state.error, null, "a successful run clears any stale error banner");
  assert.ok(Object.keys(s.state.grid).length > 0, "grid is populated on a successful run");
});

test("runBenchmark surfaces a non-Error throw with a generic message instead of crashing", async () => {
  const s = fakeSetters();
  const failingFetchCell = async (): Promise<Cell> => {
    throw "boom";
  };

  await runBenchmark(failingFetchCell, {
    setRunning: s.setRunning,
    setProgress: s.setProgress,
    setGrid: s.setGrid,
    setError: s.setError,
  });

  assert.equal(s.state.running, false, "running must still be reset on a non-Error throw");
  assert.ok(s.state.error && s.state.error.length > 0, "a non-Error throw still surfaces a banner message");
});
