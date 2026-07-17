---
'@barkpark/react': patch
---

Grow the `diff` and `filetree` PortableDoc block types from starter parity to their real renderers (Scaffy W7 grow slice, charter D75–D78). `diff` now parses its verbatim unified-diff `diff` attr at render time — `@@` hunk headers as dim verbatim context rows, git file headers dropped from the +/− tally with a bold path sub-header per `+++` transition, optional `file`/`lang` metadata leading the tally, and the same 20-row details-fold as `chat-tool-diff` — reusing the shared chat diff-row vocabulary (`rowStyle`/`rowPrefix`/`diffRowsHtml`/`CHAT_DIFF_BUDGET`, now exported from `blocks/chat.ts` with zero output change). `filetree` renders its verbatim `text` tree lines (`white-space: pre`), splits trailing ` ● `/` ○ `/` ✕ ` annotations into colored spans, and renders an optional dim `legend` row. `toPlainText` reads `diff` from its `diff` attr (the `code` precedent); shape parity to the regenerated Elixir goldens holds for both.
