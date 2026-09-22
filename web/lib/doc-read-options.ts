import type { ResolveSpec } from "@barkpark/core";

/**
 * Per-type read options for the ONE canonical document fetch
 * (`./get-document.ts`). Deliberately its own module, and deliberately PURE:
 * `get-document.ts` imports `server-only` and `next/cache`, so the decision
 * that actually changes the request line would otherwise only be testable by
 * reading its source — and a grep is not a live probe. Here a test can run it.
 *
 * WHAT IT DECIDES (task-d54c8a595e68ad5d). `?resolve=tasks` is an OPT-IN server
 * seam: it swaps every PortableDoc task block that carries a `query` for a live
 * snapshot of the matching rows. Without it those blocks arrive with no rows,
 * and `@barkpark/react`'s task-board — which reads `snapshot` and never fetches
 * — renders `bp-tasks--empty` forever. Measured on the production dataset
 * before this shipped: 19 of 39 task blocks across 21 papers were query-only,
 * so every one of them was a permanently empty box on this site.
 *
 * SCOPED TO `paper` ON PURPOSE. Task blocks live in PortableDoc content, and
 * `paper` is the only type this site reads that carries them. Sending the param
 * on every type would make the server run a resolver pass over documents that
 * can never contain a task block — a cost with no reader-visible effect. A type
 * that later grows task blocks is one entry away.
 *
 * Author-pinned blocks (a literal `snapshot`/`task` and no `query`) are left
 * untouched by the server either way, so this can only FILL blocks that were
 * empty — it never overwrites an author's pinned rows.
 */
export interface DocReadOptions {
  resolve?: ResolveSpec;
}

/** Types whose PortableDoc content can carry query-shaped task blocks. */
const RESOLVES_TASKS = new Set(["paper"]);

/**
 * The read options for `type`, or `undefined` when the plain read is right.
 *
 * `undefined` (not `{}`) is the answer for every other type so the request line
 * stays byte-identical to what it was before this existed — core omits the
 * param entirely when `resolve` is absent.
 */
export function docReadOptions(type: string): DocReadOptions | undefined {
  return RESOLVES_TASKS.has(type) ? { resolve: "tasks" } : undefined;
}
