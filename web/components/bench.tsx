"use client";

import { useState } from "react";
import Link from "next/link";
import type { FindResponse, SearchEngine } from "@/lib/find";

/* A small fixed query set exercised across both engines × cache modes. */
const QUERIES = ["headless", "cli", "publish", "plugin", "deploy", "barkpark"];
const ENGINES: SearchEngine[] = ["postgres", "indx"];
const NO_STORE_RUNS = 4; // repeatable cold-engine samples
const CACHED_RUNS = 5; // 1 warm-up (cold miss) + 4 warm hits

interface Cell {
  noStore: number; // median client round-trip, cache off
  cachedCold: number; // first cache=on call (miss)
  cachedWarm: number; // median of warm cache=on calls
  upstreamWarm: number; // upstream fetch ms on a warm hit (≈0 = Data Cache)
  total: number;
}

const median = (xs: number[]) =>
  xs.length ? [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)] : 0;

async function timeCall(
  q: string,
  engine: SearchEngine,
  cache: boolean,
): Promise<{ rt: number; upstreamMs: number | null; total: number }> {
  const params = new URLSearchParams({ q, engine });
  if (cache) params.set("cache", "on");
  const t0 = performance.now();
  const r = await fetch(`/api/find?${params.toString()}`);
  const d: FindResponse = await r.json();
  return { rt: Math.round(performance.now() - t0), upstreamMs: d.upstreamMs, total: d.total };
}

async function benchCell(q: string, engine: SearchEngine): Promise<Cell> {
  const noStore: number[] = [];
  for (let i = 0; i < NO_STORE_RUNS; i++) noStore.push((await timeCall(q, engine, false)).rt);

  let cachedCold = 0;
  const warm: number[] = [];
  let upstreamWarm = 0;
  let total = 0;
  for (let i = 0; i < CACHED_RUNS; i++) {
    const c = await timeCall(q, engine, true);
    total = c.total;
    if (i === 0) cachedCold = c.rt;
    else {
      warm.push(c.rt);
      upstreamWarm = c.upstreamMs ?? upstreamWarm;
    }
  }
  return { noStore: median(noStore), cachedCold, cachedWarm: median(warm), upstreamWarm, total };
}

type Grid = Record<string, Partial<Record<SearchEngine, Cell>>>;

export function Bench() {
  const [grid, setGrid] = useState<Grid>({});
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<string | null>(null);

  async function run() {
    setRunning(true);
    setGrid({});
    const next: Grid = {};
    for (const q of QUERIES) {
      next[q] = {};
      for (const engine of ENGINES) {
        setProgress(`${q} · ${engine}`);
        next[q][engine] = await benchCell(q, engine);
        setGrid({ ...next, [q]: { ...next[q] } });
      }
    }
    setProgress(null);
    setRunning(false);
  }

  // Aggregate medians per engine across all queries.
  const agg = (engine: SearchEngine, pick: (c: Cell) => number) => {
    const xs = QUERIES.map((q) => grid[q]?.[engine])
      .filter((c): c is Cell => !!c)
      .map(pick);
    return xs.length ? median(xs) : null;
  };

  const ms = (n: number | null | undefined) =>
    typeof n === "number" ? `${n}ms` : "—";

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-4xl flex-col gap-8 px-6 py-12">
      <header className="flex flex-col gap-3 border-b border-zinc-200 pb-6 dark:border-zinc-800">
        <Link
          href="/"
          className="text-sm text-zinc-500 transition-colors hover:text-zinc-900 dark:hover:text-zinc-200"
        >
          ← Find
        </Link>
        <h1 className="text-4xl font-semibold tracking-tight">Engine benchmark</h1>
        <p className="text-zinc-500 dark:text-zinc-400">
          Client round-trip latency across{" "}
          <span className="text-zinc-700 dark:text-zinc-300">{QUERIES.length} queries</span>{" "}
          × <span className="font-mono">postgres</span> /{" "}
          <span className="font-mono">indx</span> × cache off/on. Cached-warm is
          served from the Next Data Cache (no API round-trip).
        </p>
        <button
          onClick={run}
          disabled={running}
          className="w-fit rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-zinc-50 transition-colors hover:bg-zinc-700 disabled:opacity-50 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
        >
          {running ? `Running… ${progress ?? ""}` : "Run benchmark"}
        </button>
      </header>

      <div className="overflow-x-auto">
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr className="border-b border-zinc-300 text-left dark:border-zinc-700">
              <th className="px-3 py-2 font-medium">query</th>
              <th className="px-3 py-2 font-medium">engine</th>
              <th className="px-3 py-2 text-right font-medium">no-store</th>
              <th className="px-3 py-2 text-right font-medium">cached cold</th>
              <th className="px-3 py-2 text-right font-medium">cached warm</th>
              <th className="px-3 py-2 text-right font-medium">hits</th>
            </tr>
          </thead>
          <tbody>
            {QUERIES.map((q) =>
              ENGINES.map((engine) => {
                const c = grid[q]?.[engine];
                return (
                  <tr
                    key={`${q}:${engine}`}
                    className="border-b border-zinc-200 dark:border-zinc-800"
                  >
                    <td className="px-3 py-2 font-mono text-zinc-600 dark:text-zinc-300">
                      {engine === "postgres" ? q : ""}
                    </td>
                    <td className="px-3 py-2 font-mono text-zinc-500">{engine}</td>
                    <td className="px-3 py-2 text-right font-mono">{ms(c?.noStore)}</td>
                    <td className="px-3 py-2 text-right font-mono">{ms(c?.cachedCold)}</td>
                    <td className="px-3 py-2 text-right font-mono text-emerald-600 dark:text-emerald-400">
                      {ms(c?.cachedWarm)}
                    </td>
                    <td className="px-3 py-2 text-right font-mono text-zinc-400">
                      {c ? c.total : "—"}
                    </td>
                  </tr>
                );
              }),
            )}
          </tbody>
          <tfoot>
            {ENGINES.map((engine) => (
              <tr key={engine} className="border-t-2 border-zinc-300 dark:border-zinc-700">
                <td className="px-3 py-2 font-medium">median</td>
                <td className="px-3 py-2 font-mono text-zinc-500">{engine}</td>
                <td className="px-3 py-2 text-right font-mono font-medium">
                  {ms(agg(engine, (c) => c.noStore))}
                </td>
                <td className="px-3 py-2 text-right font-mono font-medium">
                  {ms(agg(engine, (c) => c.cachedCold))}
                </td>
                <td className="px-3 py-2 text-right font-mono font-medium text-emerald-600 dark:text-emerald-400">
                  {ms(agg(engine, (c) => c.cachedWarm))}
                </td>
                <td className="px-3 py-2" />
              </tr>
            ))}
          </tfoot>
        </table>
      </div>

      <p className="text-xs leading-relaxed text-zinc-400">
        no-store = always-fresh (engine + network every call, median of{" "}
        {NO_STORE_RUNS}). cached cold = first cache=on call (Data Cache miss).
        cached warm = served from cache (median of {CACHED_RUNS - 1}). Numbers are
        client-perceived round-trip; the finder shows per-query engine compute +
        upstream + round-trip live.
      </p>
    </main>
  );
}
