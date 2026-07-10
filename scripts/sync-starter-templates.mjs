#!/usr/bin/env node
// scripts/sync-starter-templates.mjs — ONE source of truth for the starter templates.
//
// HOW THESE STAY IN SYNC
// ----------------------
// The blog-starter and website-starter trees ship from TWO roots:
//   • js/packages/create-barkpark-app/templates/<slug>  ← CANONICAL (the published
//     `create-barkpark-app` artifact; edit templates HERE)
//   • cloud/priv/templates/<slug>                        ← MIRROR (vendored so the
//     Cloud provisioner can place the same files server-side)
// This script mirrors each canonical template dir into cloud/priv/templates by
// deleting the mirror dir and copying the canonical one back byte-for-byte. Only
// the two template dirs are touched — any cloud-only file that lives OUTSIDE
// blog-starter/ and website-starter/ (e.g. a README pointer) is preserved.
//
// Node built-ins only, no deps. Deterministic + idempotent: a second run is a
// no-op. Convergence is proven by `diff -r` showing zero drift between the roots.
//
//   node scripts/sync-starter-templates.mjs           # mirror canonical → cloud
//
// A CI drift gate that FAILS when the mirror lags the canonical lands separately
// (fail-before rule — the gate must be able to go red before this sync exists).
import { cpSync, rmSync, existsSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..");

const CANONICAL_ROOT = join(repoRoot, "js", "packages", "create-barkpark-app", "templates");
const MIRROR_ROOT = join(repoRoot, "cloud", "priv", "templates");

// The template dirs under management. Everything else under MIRROR_ROOT is left
// untouched (delete-and-copy is scoped to these dirs only).
const TEMPLATES = ["blog-starter", "website-starter"];

mkdirSync(MIRROR_ROOT, { recursive: true });

for (const slug of TEMPLATES) {
  const src = join(CANONICAL_ROOT, slug);
  const dst = join(MIRROR_ROOT, slug);
  if (!existsSync(src)) {
    console.error(`sync-starter-templates: canonical template missing: ${src}`);
    process.exit(1);
  }
  rmSync(dst, { recursive: true, force: true });
  cpSync(src, dst, { recursive: true });
  console.log(`synced ${slug} → cloud/priv/templates/${slug}`);
}

console.log("done — verify with: diff -r cloud/priv/templates/<slug> js/packages/create-barkpark-app/templates/<slug>");
