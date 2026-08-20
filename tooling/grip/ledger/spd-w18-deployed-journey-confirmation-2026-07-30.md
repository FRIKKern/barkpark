# Re-derivation recipes — deployed journey confirmation (Studio Space-Priority Desk wave 18, 2026-07-30)

Verifier lane `deployed-journey-confirmation`: does create → open → type a heading
→ type a paragraph → save actually work in a real authenticated chromium on the
DEPLOYED guerrilla build, and does a PRE-EXISTING draft-only paper open? Served
commit bracketed PRE/POST on every browser run
(`e4ed31a103fac3b29c6310e82e27cfd83c61c50a`, matched both times).

The three drivers are THROWAWAY (scratchpad, not committed) — the recipes below
re-derive the same facts. Local `main` was BEHIND `origin/main`
(`a31faa52d` vs `453ee749a`) during this lane, so every code fact is quoted
`git show origin/main:` and never from the worktree.

| # | Claim | Command |
|---|---|---|
| 1 | Guerrilla serves `e4ed31a103f` — the commit the confirmation is a confirmation OF | `ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'cd /opt/barkpark && git rev-parse HEAD'` |
| 2 | Both D228 fossils are real, live, draft-only, `blocks: 0`, `_updatedAt == _createdAt` | `curl -s -H "Authorization: Bearer $BP" 'https://guerrilla.barkpark.cloud/v1/data/query/production/paper?perspective=drafts&limit=200&offset=400' \| python3 -c "import sys,json;[print(d['_id'],d['_createdAt'],d['_updatedAt'],len(d.get('blocks') or [])) for d in json.load(sys.stdin)['result']['documents'] if 'b28358ff271b260e' in d['_id'] or '3149ef706e777628' in d['_id']]"` (page all offsets; 609 papers total) |
| 3 | The desk serves SIX Structure rows; `#item-paper` is a real `<button>` | in-page: `[...document.querySelectorAll('.pane-item')].map(e=>[e.id,e.tagName,e.innerText.trim()])` |
| 4 | Papers patches 100 doc rows in ~936ms — a fixed 1400ms wait is a coin-flip; poll `.pane-doc-item` count with a 20s+ ceiling | poll predicate `document.querySelectorAll('.pane-doc-item').length > 0`, never `waitForTimeout` |
| 5 | Structure rows are `.pane-item`, document rows are `.pane-doc-item` — the unambiguous discriminator (`[phx-click="select"]` matches BOTH) | `git show origin/main:api/lib/barkpark_web/live/studio/studio_live/components.ex \| sed -n '1075,1105p'` |
| 6 | The `+` button carries `aria-label="New paper"`, `title`, `tabIndex 0` | `git show origin/main:api/lib/barkpark_web/live/studio/studio_live/components.ex \| sed -n '990,1000p'` |
| 7 | A NEW paper lands on a bare (un-prefixed) id and opens a REAL editor: `studio-paper-block-editor`, 1 contenteditable (`tiptap ProseMirror`), `paper-add-block`, footer, `aria-label="Editing …"` | in-page after clicking `button.pane-add-btn[phx-click="new-document"][phx-value-type="paper"]` |
| 8 | Typing persists: server shows `blocks: 3` `[heading, paragraph, paragraph]`, `_updatedAt` 4s after `_createdAt`; the heading survives a full reload | `curl -s -H "Authorization: Bearer $BP" 'https://guerrilla.barkpark.cloud/v1/data/query/production/paper?perspective=drafts&limit=400' \| grep -o 'paper-844ec41c73b7e431'` then re-read `blocks` |
| 9 | `[data-test-id=bp-paper-footer-save]` is the EMPTY STRING after a proven-successful save (footer counts DID move to "9 words · 3 blocks") | in-page `JSON.stringify(document.querySelector('[data-test-id=bp-paper-footer-save]').innerText)` → `""` |
| 10 | Code cause of #9: `paper_ops/2`'s `{:ok, _}` branch never assigns `save_status`; every error branch assigns "Save failed" | `git show origin/main:api/lib/barkpark_web/live/studio/studio_live/shared/paper.ex \| sed -n '132,190p'` |
| 11 | PRE-EXISTING draft-only papers do NOT open into an editor: `shell=1 body=0 ce=0 addblock=0 footer=0` — a four-cell matrix (fossil bare / fossil `drafts.` / created bare / created `drafts.`) rules the id form OUT as the cause | drive all four URLs under `/w/default/p/default/d/production/studio/paper/<id>` and read the counters |
| 12 | The branch the fossil takes is `studio_paper_view/1`'s FINAL `true ->` arm: `<article id="paper-body-drafts.paper-b28358ff271b260e">` with `innerHTML.length == 0`. NOT `paper_block_mode` (no `phx-update="stream"`), NOT `.bp-paper-editor-empty` (0 occurrences) | in-page fingerprint of `main[data-test-id=studio-paper-shell]`'s children + `article.getAttribute('phx-update')` |
| 13 | The gate is `show_editor = paper_block_mode && (canvas_on \|\| paper_edit_mode)` — false for a blocks:0 fossil, so the raw-HTML arm renders `raw(@paper_html)` = "" | `git show origin/main:api/lib/barkpark_web/live/studio/studio_live/components.ex \| sed -n '94,100p;210,263p'` |
| 14 | `+ Add block` / `paper-add-block` IS on the deployed canvas-ON screen (refutes "flag-OFF-only") | in-page `document.querySelectorAll('[data-test-id=paper-add-block]').length` on the created doc → 1 |
| 15 | `BARKPARK_PAPER_CANVAS` defaults to "1" in prod at boot — derive the default from config, never from D233 | `git show origin/main:api/config/runtime.exs \| sed -n '51,56p'` |
