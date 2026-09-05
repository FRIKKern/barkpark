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
// COMPOSITION. The canonical starter dirs no longer hold the framework
// boilerplate they used to double-author: those 16 files live once in
// templates/_shared/ and `create-barkpark-app` lays them down UNDER the starter
// tree at scaffold time (see the ownership note in src/scaffold.ts). The mirror
// must be what the scaffolder WRITES, not what the starter dir holds, so this
// script composes the same way — _shared first, the starter tree over it — and
// each mirrored slug stays a complete, self-contained app tree with no _shared
// directory of its own. `_shared` is never mirrored as a slug.
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

// Mirrors SHARED_TEMPLATE_DIR in js/packages/create-barkpark-app/src/constants.ts.
const SHARED = "_shared";

mkdirSync(MIRROR_ROOT, { recursive: true });

for (const slug of TEMPLATES) {
  const src = join(CANONICAL_ROOT, slug);
  const dst = join(MIRROR_ROOT, slug);
  if (!existsSync(src)) {
    console.error(`sync-starter-templates: canonical template missing: ${src}`);
    process.exit(1);
  }
  const shared = join(CANONICAL_ROOT, SHARED);
  if (!existsSync(shared)) {
    console.error(`sync-starter-templates: shared template source missing: ${shared}`);
    process.exit(1);
  }

  rmSync(dst, { recursive: true, force: true });
  // _shared first, then the starter OVER it — the starter always wins, exactly
  // as scaffold() composes. cpSync's default force:true makes the second copy
  // an overwrite rather than an error.
  cpSync(shared, dst, { recursive: true });
  cpSync(src, dst, { recursive: true });
  console.log(`synced ${slug} → cloud/priv/templates/${slug}`);
}

console.log("done — verify with: diff -r cloud/priv/templates/<slug> js/packages/create-barkpark-app/templates/<slug>");
