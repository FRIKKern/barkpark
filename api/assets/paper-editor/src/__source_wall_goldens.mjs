// The shared Portable Doc goldens the source-mode wall is measured on, read in one
// place: every block and limit golden (`*.golden.json`) in api/priv/portable_doc/goldens,
// each as a one-block Paper. __source_wall_fixtures.test.mjs and
// canvas/__source_inside_edit_sweep.test.mjs both import this list.

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const GOLDENS = fileURLToPath(new URL("../../../priv/portable_doc/goldens/", import.meta.url));

// [[name, block]], name as "blocks/paragraph", sorted by folder then file.
export function sourceWallGoldens() {
  const out = [];
  for (const dir of ["blocks", "limits"]) {
    for (const file of readdirSync(join(GOLDENS, dir)).filter((name) => name.endsWith(".golden.json")).sort()) {
      const { input } = JSON.parse(readFileSync(join(GOLDENS, dir, file), "utf8"));
      out.push([`${dir}/${file.replace(/\.golden\.json$/, "")}`, { id: "fixture", ...input }]);
    }
  }
  return out;
}
