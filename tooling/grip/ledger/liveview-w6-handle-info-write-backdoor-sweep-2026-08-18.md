<!-- doc-tier: cold | canonical-for: liveview-w6-handle-info-write-backdoor-rederivation | budget: 900tok -->

# LiveView W6 — handle_info / send(self) write-backdoor sweep (re-derivation)

Verifier assignment v6: is there any OTHER handle_info or send(self) write
back-door across studio_live/handlers/ that bypasses the Caps `:handle_event`
attach_hook (the pds_w42 paper_op shape), reaching a Content mutation without
re-checking write capability at the chokepoint?

VERDICT: REFUTED. paper_op is the SOLE component-hop write and it is
triple-gated at the handle_info landing. No sibling un-gated path.

## Re-derive the send(self) universe

    cd api && grep -rn 'send(self' lib/barkpark_web/live/studio/

7 hits: media.ex:29/36/63 + refs.ex:42/49 → `{:autosave_form, form}`;
paper_field_block.ex:318 → `{:paper_op, op}`; chat_live.ex:485 →
`{:dispatch_send,...}`. (remaining 2 are comments in shared/paper.ex.)

## Re-derive which handle_info bodies reach a Content write

    cd api && grep -n 'def paper_op\|def autosave_form\|Content\.' \
      lib/barkpark_web/live/studio/studio_live/handlers/lifecycle.ex

Only `autosave_form → Shared.do_autosave → Content.upsert_draft` and
`paper_op → Shared.paper_op → apply_paper_block_op(s)/apply_document_block_op`
are writes. doc_updated / paper_block / paper_updated / sheets_op /
sheets_persisted / document_changed / tree_codelist_change / presence_diff are
read/refresh/relay only (self()-sender guards + send_update relays).

## Why each write path is NOT a bypass

- `{:autosave_form}` originates in PARENT-socket handle_events (select-media,
  clear-image, upload-image, select-ref, clear-ref). All five are in
  `Caps @write_events` (caps.ex:105-118) → classified `:write` → the socket
  `:studio_caps_gate` HALTS a write-denied principal BEFORE the handler runs.
  The send(self) hop happens post-gate. NOT a bypass.
- `{:paper_op}` originates in the PaperFieldBlock LiveComponent — component
  events never reach the parent `:handle_event` hook (the pds_w42 hole). Now
  gated at the LANDING: all three write branches in shared/paper.ex —
  paper_pane_op (228/233), paper_ops (300/306), document_op (710/716) — call
  `write_denied?/1` (Caps.write_capable?) + `grant_target_denied?/3`
  (Access.validate) before any apply_*. CLOSED.
- `{:dispatch_send}` (chat_live) → `Runtime.send_turn` = chat runtime dispatch,
  not a Content document mutation; chat_live is a distinct admin/ops mount-gated
  LiveView that does not attach the studio Caps gate.

## LiveComponents (the only bypass vector)

    cd api && grep -rln 'use Phoenix.LiveComponent' lib/barkpark_web/live/studio/

3: paper_field_block (send(self){:paper_op}, gated), sheet_grid (send_update
only + own read_only prop wall), graph_view (read-only, no send).

## Proof the gate is live (mutation-proven)

    cd api && mix test \
      test/barkpark_web/live/studio/pds_w42_paper_op_principal_gate_test.exs \
      test/barkpark_web/live/studio/pds_w44_grant_door_test.exs
    # => 11 tests, 0 failures

These push `{:paper_op,...}` on write-denied / out-of-grant sockets and assert
the write is refused. Red without the paper.ex gates.
