<!-- doc-tier: agent | canonical-for: paper-editor-integration | budget: 1000tok -->
# Paper editor integration

Public/Studio share canvas + `PaperViewer`. View flushes; focus pins revisions; overlaps need review. External revision-owning hosts may use `applyServerBlocksIfIdle`: only `true` permits advancing their revision; drafts/IME/source/island input refuse without discard. Same-type textblocks and unchanged list/table structure preserve caret mapping; mark/link-only updates retain selection with mark steps. Figure writes child `src`; empty captions are zero-flow. Null-type Card media stays contextual and exact. Card titles edit in place unless rich. Undo/Redo: authorized single-use 1h receipts, session queue; text history stays native. Clients get opaque refs, never inverses.
- **Plugin module:** `register_schemas/1` + `register_routes/1` expose the `:public_root` reader and `:ingest` API (`/v1/plugins/bulldocs/*`) for reuse.
- **Sessions:** 2nd blocks type (whitelist `{paper, session}`); routes `/v1/plugins/bulldocs/sessions*`; private+unwalled schema; Studio pane read-only v1 (`bp session publish` writes).

HTML table clipboard handling normalizes ordinary cell paragraphs/BRs to PortableDoc newlines before the schema parses them. Nested structures and merged headers keep the clipboard intact and show plain-text paste guidance. Canvas regression: `__html_table_paste.test.mjs`.

Paragraph/heading inline breaks serialize as newline text, including list bodies; DOM newline normalization and Undo preserve source carriers. Other field and list-shape boundaries remain guarded. Regression: `__inline_breaks.test.mjs`.

Clipboard format selection honors explicit plain paste before images. Unrepresented HTML images and ambiguous image-file plus rich/text payloads preserve the selection with visible recovery; file-only images retain the host uploader. One file plus image-only HTML uses that same upload and preserves alt text; independent text/captions/links or extra images stay explicit ambiguity. It does not fetch or convert external HTML image URLs.

Mounted save-ack tests await native blur before settlement assertions; press-watchdog tests use a deterministic clock for the exact grace boundary. Production delays remain unchanged.

Image upload completion stays outside native Undo history. Per-editor upload receipts restore settled metadata when Redo revives a pending node; they never replay uploads or cross editor teardown. Later human URL/alt edits win. Regression: `__upload_history_audit.test.mjs`.

Native splits materialize duplicate inherited top-level IDs before dispatch. The original first occurrence and unrelated references remain stable across pending writes, reorder/delete and native history. Regression: `__block_identity_mounted.test.mjs`.


Source: `api/assets/paper-editor/src/`; tests named above are relative to it. The shared converter is `convert.js`; `index.js` and `canvas/index.js` mount the same boundaries.
