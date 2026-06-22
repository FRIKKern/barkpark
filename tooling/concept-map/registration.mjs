#!/usr/bin/env node
// registration.mjs — the plugin REGISTRATION-SURFACE predicate, shared.
//
// A concept carries the plugin registration surface when its plugin entry file
// (api/lib/barkpark/plugins/<concept>.ex) defines the recurring wiring calls
// (register_schemas / register_routes) — the same discriminator anatomy.mjs uses
// to separate true pluggable features from plain domain libraries. This is the
// ONLY structural difference between a CLEAN-FEATURE (a registered plugin) and a
// CLEAN-NONPLUGIN (a pristine domain lib that is clean by the coupling math but
// is simply not a plugin). Computed live off the tree — nothing is hardcoded.
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const PLUGINS_DIR = join(ROOT, "api/lib/barkpark/plugins");

// The recurring wiring calls a real plugin entry file defines. Mirrors
// anatomy.mjs REGISTRATION_CALLS verbatim so the two passes agree.
export const REGISTRATION_CALLS = ["register_schemas", "register_routes"];

// True when the concept's plugin entry file exists AND defines at least one of
// the registration wiring calls — i.e. it is a registered plugin, not a plain
// domain library. Falls out of the tree; no concept names are baked in.
export function isRegistered(concept) {
  const pf = join(PLUGINS_DIR, concept + ".ex");
  if (!existsSync(pf)) return false;
  const src = readFileSync(pf, "utf8");
  return REGISTRATION_CALLS.some((c) => new RegExp("def\\s+" + c + "\\b").test(src));
}
