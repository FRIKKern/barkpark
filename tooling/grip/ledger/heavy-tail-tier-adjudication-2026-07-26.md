# Re-derivation recipes — heavy-tail-tier-adjudication (mobile blocks wave, 2026-07-26)

Verifier lane: per-type rulings for the six heavy types (sheet, task-board, form, questionnaire, video, asciicast) + the turn-fallback design. Every row re-derives from a clean checkout.

| # | Claim | Command |
|---|---|---|
| 1 | @barkpark/react suite green (15 files / 322 tests) | `cd js && pnpm --filter @barkpark/react test` |
| 2 | sheet/task-board/form/questionnaire/video/asciicast each covered green by wrapper + Elixir-golden parity + toPlainText tests | `cd js/packages/react && npx vitest run --reporter=verbose 2>&1 \| grep -iE 'sheet\|task-board\|form\|questionnaire\|video\|asciicast'` |
| 3 | react board = 7 roles; Go TUI board = 5 (no thought states) | `grep -n 'BOARD_ROLES\|boardColumns' js/packages/react/src/blocks/taskboard.ts internal/pdrender/taskblocks.go` |
| 4 | Elixir board = the SAME 7 roles as react | `grep -n 'defp board_roles' api/lib/barkpark/portable_doc/render/components.ex` |
| 5 | Go roleForStatus RESOLVES considering/researching (so the 5-column TUI board silently DROPS those rows: byRole keyed by full role set, lanes collected from boardColumns only) | `grep -n -A22 'func roleForStatus' internal/pdrender/gridblocks.go` then read `internal/pdrender/taskblocks.go:655-683` |
| 6 | tlv-s3 (the thought-columns slice, merged #4394) listed gridblocks.go + components.ex + fleet_email.ex but NOT taskblocks.go — the TUI board columns were missed, so 5-role is stale drift, not frozen design | `bp task get tlv-s3-status-manifest-papers-chain -o json \| python3 -c "import json,sys; d=json.load(sys.stdin)['doc']; print(d['lifecycle_status'], d['content']['files'])"` |
| 7 | react fail-open: cancelled→'cancel', unknown non-empty→'unknown', both homed in the `open` column with their own glyph (never dropped) | `grep -n -B2 -A14 'STATUS_TO_ROLE' js/packages/react/src/inline.tsx` + `js/packages/react/src/blocks/taskboard.ts:72-77` |
| 8 | form/questionnaire render-only on all three surfaces; questionnaire = pure alias; rationale (no prefix) + `Recommendation: ` lines preserved | `sed -n '59,88p' js/packages/react/src/blocks/forms.ts` + `sed -n '9,65p' internal/pdrender/form.go` |
| 9 | TUI sheet narrows to head/rows/truncated — merges/styles/px-widths/URL-anchors documented losses | `sed -n '32,63p' internal/pdrender/sheet.go` |
| 10 | react sheet honors head/rows/truncated + merges + b/i/bg/al + col_widths(px) + error styling + URL anchors + default alignment | `cat js/packages/react/src/blocks/sheet.ts` |
| 11 | mobile table precedent = horizontal ScrollView, but per-cell minWidth 96/maxWidth 220 (columns can misalign across rows — do NOT copy for sheet) | `sed -n '389,427p' apps/mobile/src/papers/portabledoc/blocks.tsx` |
| 12 | TUI video degrade anatomy: `▶ Video · N caption track(s) · open in browser`, OSC8/dim-src, src-less renders NOTHING | `cat internal/pdrender/video.go` |
| 13 | TUI asciicast degrade anatomy: `▶ Asciicast · M:SS · COLSxROWS · open in browser`, renders the box even src-less | `grep -n -B8 -A45 'asciicastRenderer) Render' internal/pdrender/hardblocks.go` |
| 14 | chat fence = 14 types; of the six heavy types NONE is chat-arrivable today (of the gap-23 only chart+heatmap are) | `sed -n '23,29p' api/lib/barkpark/portable_doc/from_markdown.ex` |
| 15 | anyRenderableBlocks keys directly off BLOCK_RENDERERS — registering a degrade card flips a degrade-only turn from full source_markdown to the card (the DEGRADE_ONLY trap) | `sed -n '238,284p' apps/mobile/src/screens/ChatSessionScreen.tsx` |
| 16 | mobile has no video/asciicast/sheet/task-board/form/questionnaire renderer (all six absent from BLOCK_RENDERERS) | `sed -n '906,950p' apps/mobile/src/papers/portabledoc/blocks.tsx` |
| 17 | video corpus count 0 / questionnaire 0 (degrade cards cost nothing today) | corpus census artifact of the survey phase (553-paper scan); re-derive via the census script the survey lane recorded |
