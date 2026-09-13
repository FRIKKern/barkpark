/**
 * THE MAX_HITS LOCK — the search working-set cap is declared in the canonical
 * modules and nowhere else, every declaration carries the same literal, and
 * both transports actually put that number on the wire.
 *
 * THE DEFECT THESE PIN (task-19107773e2c41c5d). `MAX_HITS = 100` was declared
 * SIX times across three trees with no shared export and no guard:
 *
 *   templates/astro-search-starter/src/components/FinderIsland.tsx:46
 *   templates/astro-search-starter/src/finder/lib/use-live-search.ts:77
 *   templates/search-starter/lib/find-search.ts:60
 *   templates/search-starter/lib/use-live-search.ts:77
 *   web/lib/find-search.ts:62
 *   web/lib/use-live-search.ts:53
 *
 * A shipped correctness fix depends on all six agreeing: web/lib/result-window.ts
 * reasons in prose ABOUT the constant ("the engine caps what it hands back at a
 * WORKING SET (`MAX_HITS`, 100 rows)"), and that reasoning is only true while
 * every transport sends the same limit — find-search.ts sends
 * `limit: String(MAX_HITS)` over HTTP, use-live-search.ts pushes
 * `limit: MAX_HITS` over the WebSocket. Drift either one and the honesty fix
 * starts silently lying on that transport. Nothing watched the pair: the
 * web/lib <-> search-starter fork guard watches CROSS-TREE properties and the
 * astro byte-identity gate watches the astro COPY, so the two files inside one
 * tree were on no guard's axis at all.
 *
 * WHY A SCANNER AND NOT A LIST. The row that first noticed the mirror counted
 * TWO sites. There were six. A sibling list in a filing is what was CHECKED,
 * not what EXISTS — so this file DERIVES the declaration set by walking web/,
 * templates/ and js/ and reports whatever it finds. A seventh declaration
 * nobody told this test about reds it, by name.
 *
 * WHY IT REFUSES ON AN EMPTY READ. A scanner whose walk returns nothing reports
 * "0 stray declarations" and passes — clean-looking and completely blind, which
 * is the exact failure mode this file exists to refuse. `scanMaxHits` therefore
 * throws REFUSING TO MEASURE below three floors: files walked, files mentioning
 * the symbol, and declarations found. The last test below points the scanner at
 * an empty tree and asserts the refusal, so the floors are proven live rather
 * than asserted in a comment.
 *
 * NAMED MUTANTS each test kills:
 *   • re-declare-in-a-transport  → the canonical-sites test reds, naming the file
 *   • bump-one-copy-to-200       → the one-value test reds, printing both values
 *   • http-sends-a-different-cap → the transport-agreement test reds
 *   • blind-the-scanner          → the refusal test reds (the walk stops throwing)
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { MAX_HITS } from "../lib/search-limits.ts";

/** Repo root, four levels of certainty: this file is web/__tests__/<name>. */
const REPO_ROOT = resolve(fileURLToPath(new URL("../../", import.meta.url)));

/** The trees the criterion names. `js/` is scanned even though no declaration
 * lives there today — the point is that one appearing there is CAUGHT. */
const SCAN_ROOTS = ["web", "templates", "js"];

const SOURCE_EXT = /\.(?:ts|tsx|mts|cts|js|jsx|mjs|cjs|astro)$/;
/** Build output and installed artifacts: never authored, and churned by any
 * local `npm install` / `astro build` running alongside the suite. */
const SKIP_DIR =
  /^(?:node_modules|\.git|\.next|\.astro|\.turbo|\.vite|\.cache|\.vercel|\.output|dist|build|out|coverage|vendor)$/;

/**
 * A DECLARATION binds the name to a literal. Deliberately anchored to a whole
 * line so `import { MAX_HITS }` and `limit: String(MAX_HITS)` are MENTIONS, not
 * declarations — the distinction is the whole point of the lock.
 */
const DECL_RE =
  /^\s*(?:export\s+)?(?:const|let|var)\s+MAX_HITS\s*(?::\s*[\w<>[\]| ]+)?\s*=\s*(\d+)\s*;?\s*$/;

/** Floors. MEASURED on this tree 2026-09-12 (scanMaxHits against the real repo):
 * 655 source files walked, 15 files mentioning MAX_HITS, 3 declarations. Set
 * well below those so ordinary churn is not a false red, and far above zero so
 * a blinded walk cannot pass. */
const MIN_FILES_WALKED = 100;
const MIN_MENTION_FILES = 5;
const MIN_DECLARATIONS = 3;

export interface MaxHitsScan {
  filesWalked: number;
  /** repo-relative paths of every file mentioning the symbol at all */
  mentionFiles: string[];
  /** one entry per declaring LINE */
  declarations: { file: string; line: number; value: string }[];
}

function walk(dir: string, out: string[]): void {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    if (e.isDirectory()) {
      if (SKIP_DIR.test(e.name)) continue;
      walk(join(dir, e.name), out);
    } else if (e.isFile() && SOURCE_EXT.test(e.name)) {
      out.push(join(dir, e.name));
    }
  }
}

/**
 * Walk `root`'s SCAN_ROOTS and report every mention and every declaration of
 * MAX_HITS. THROWS rather than returning a clean zero when the walk is too thin
 * to have measured anything.
 */
export function scanMaxHits(root: string = REPO_ROOT): MaxHitsScan {
  const files: string[] = [];
  for (const r of SCAN_ROOTS) walk(join(root, r), files);

  const mentionFiles: string[] = [];
  const declarations: MaxHitsScan["declarations"] = [];
  let unreadable = 0;
  for (const abs of files) {
    let src: string;
    try {
      src = readFileSync(abs, "utf8");
    } catch {
      // A path can vanish between the walk and the read (a build running
      // alongside the suite). Count it; the floors below are what decide
      // whether the scan still measured anything.
      unreadable++;
      continue;
    }
    if (!src.includes("MAX_HITS")) continue;
    const rel = relative(root, abs).split(sep).join("/");
    mentionFiles.push(rel);
    src.split("\n").forEach((line, i) => {
      const m = DECL_RE.exec(line);
      if (m) declarations.push({ file: rel, line: i + 1, value: m[1] });
    });
  }

  if (files.length - unreadable < MIN_FILES_WALKED) {
    throw new Error(
      `REFUSING TO MEASURE: the MAX_HITS scan READ ${files.length - unreadable} of ${files.length} ` +
        `source file(s) under ` +
        `${SCAN_ROOTS.join(", ")} of ${root}, below the floor of ${MIN_FILES_WALKED}. ` +
        `A scan this thin reports "no stray declarations" having read nothing.`,
    );
  }
  if (mentionFiles.length < MIN_MENTION_FILES) {
    throw new Error(
      `REFUSING TO MEASURE: only ${mentionFiles.length} file(s) mention MAX_HITS, below the ` +
        `floor of ${MIN_MENTION_FILES}. The symbol was renamed or the reader is blind.`,
    );
  }
  if (declarations.length < MIN_DECLARATIONS) {
    throw new Error(
      `REFUSING TO MEASURE: found ${declarations.length} declaration(s) of MAX_HITS, below the ` +
        `floor of ${MIN_DECLARATIONS}. The declaration regex no longer matches the shipped form.`,
    );
  }
  return { filesWalked: files.length - unreadable, mentionFiles, declarations };
}

/**
 * THE CANONICAL MODULES — the only files allowed to bind the literal.
 * Three files, ONE declaration: templates/search-starter's copy is the source,
 * the astro copy is byte-identity-enforced against it by
 * scripts/check-astro-finder-drift.sh, and web/'s fork is pinned to both by the
 * same-value test below.
 */
const CANONICAL = [
  "templates/astro-search-starter/src/finder/lib/search-limits.ts",
  "templates/search-starter/lib/search-limits.ts",
  "web/lib/search-limits.ts",
];

/* ── the declaration set ────────────────────────────────────────────────── */

test("MAX_HITS is bound ONLY in the canonical search-limits modules", () => {
  const scan = scanMaxHits();
  const declaring = [...new Set(scan.declarations.map((d) => d.file))].sort();
  const stray = declaring.filter((f) => !CANONICAL.includes(f));
  assert.deepEqual(
    stray,
    [],
    `MAX_HITS is declared outside the canonical module(s). Import it from ` +
      `lib/search-limits instead of re-declaring it here:\n  ${stray.join("\n  ")}`,
  );
  assert.deepEqual(
    declaring,
    CANONICAL,
    "a canonical search-limits module lost its declaration — the import sites now bind nothing",
  );
  // Exactly one binding per canonical file: a second `const MAX_HITS` inside
  // search-limits.ts itself would satisfy the file check above.
  assert.equal(
    scan.declarations.length,
    CANONICAL.length,
    `expected one declaration per canonical module, got: ` +
      scan.declarations.map((d) => `${d.file}:${d.line}`).join(", "),
  );
});

test("every declaration of MAX_HITS carries the same literal", () => {
  const scan = scanMaxHits();
  const values = [...new Set(scan.declarations.map((d) => d.value))];
  assert.equal(
    values.length,
    1,
    `MAX_HITS has DRIFTED — the copies no longer agree:\n  ` +
      scan.declarations.map((d) => `${d.file}:${d.line} = ${d.value}`).join("\n  "),
  );
  assert.equal(
    values[0],
    String(MAX_HITS),
    `the shipped source declares ${values[0]} but web/lib/search-limits.ts exports ${MAX_HITS}`,
  );
});

test("the scan REFUSES on an empty read instead of reporting zero strays", () => {
  const empty = mkdtempSync(join(tmpdir(), "max-hits-lock-"));
  // The walk finds no source files at all -- the shape a retargeted root, a
  // renamed tree or a broken SKIP_DIR produces. The scan must say so, loudly.
  assert.throws(
    () => scanMaxHits(empty),
    /REFUSING TO MEASURE/,
    "a scan that finds nothing must refuse, not pass",
  );
});

/* ── the transports ─────────────────────────────────────────────────────── */

const shipped = (rel: string) => readFileSync(join(REPO_ROOT, rel), "utf8");

/**
 * The expression each transport hands to the server as `limit`, lifted from the
 * SHIPPED source. Returns the evaluated value, so what is asserted is the thing
 * that reaches the request — not that two constants happen to be equal.
 */
function wireLimit(rel: string): unknown {
  const src = shipped(rel);
  const hits = [...src.matchAll(/^\s*limit:\s*(.+?),\s*$/gm)];
  assert.equal(
    hits.length,
    1,
    `${rel}: expected exactly one \`limit:\` on the outbound payload, found ${hits.length}`,
  );
  const expr = hits[0][1];
  assert.ok(
    /^\s*(?:export\s+)?import\s*\{[^}]*\bMAX_HITS\b[^}]*\}\s*from\s*["'][^"']*search-limits["']/m.test(
      src,
    ),
    `${rel} sends \`limit: ${expr}\` but does not import MAX_HITS from lib/search-limits — ` +
      `its MAX_HITS is some other binding`,
  );
  assert.ok(
    !src.split("\n").some((l) => DECL_RE.test(l)),
    `${rel} re-declares MAX_HITS locally; the imported cap is shadowed`,
  );
  return new Function("MAX_HITS", `return (${expr});`)(MAX_HITS);
}

test("the HTTP leg and the WebSocket leg put the SAME limit on the wire", () => {
  const http = wireLimit("web/lib/find-search.ts");
  const ws = wireLimit("web/lib/use-live-search.ts");

  // The HTTP leg rides a URLSearchParams, so it is a string by construction;
  // the channel push carries a JSON number. Same VALUE, different encodings.
  assert.equal(typeof http, "string", "the ?limit= query param must serialise as a string");
  assert.equal(typeof ws, "number", "the channel push must carry limit as a number");
  assert.equal(
    Number(http),
    ws,
    `the transports disagree: HTTP sends limit=${http}, the WebSocket pushes limit=${ws}. ` +
      `web/lib/result-window.ts's WORKING SET reasoning is false on one of them.`,
  );
  assert.equal(Number(http), MAX_HITS);
});

test("the template forks' transports carry the same limit as web/'s", () => {
  const legs: [string, string][] = [
    ["templates/search-starter/lib/find-search.ts", "string"],
    ["templates/search-starter/lib/use-live-search.ts", "number"],
    ["templates/astro-search-starter/src/finder/lib/use-live-search.ts", "number"],
    ["templates/astro-search-starter/src/components/FinderIsland.tsx", "string"],
  ];
  for (const [rel, kind] of legs) {
    const v = wireLimit(rel);
    assert.equal(typeof v, kind, `${rel}: limit encoded as ${typeof v}, expected ${kind}`);
    assert.equal(Number(v), MAX_HITS, `${rel} sends limit=${v}, web/ sends ${MAX_HITS}`);
  }
});
