// task-fb938eb8be3bce48: the canvas emit reuses the projection of every
// top-level node that is the same ProseMirror node it was at the last
// acknowledged emit, and diffs only the nodes a transaction touched. That must
// never change what is sent. Two canvases mount the same run; one takes the fast
// path, the other is forced down the full projection on every emit. Both get the
// same edits (typing at the start, middle and end, Enter splits, a deleted
// block, an undo, and a server echo between edits), and every batch they emit
// must be the same ops, minted ids aside. The sibling host test runs this same
// script over the repository's whole pd-parity inventory. The runs the canvas
// keeps are deep-frozen as they are installed, so anything that edits one in
// place throws.
import { paragraphs } from "./__emit_bench.mjs";
import { script } from "./__emit_fast_path_support.mjs";

await script(paragraphs(60), "paragraphs");

console.log("emit_fast_path: ok");
process.exit(0);
