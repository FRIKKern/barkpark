# Re-derivation: BARKPARK_PAPER_CANVAS on guerrilla, data-rev on the canvas arm, and every save-binary OUTSIDE the ignore wrapper

Measured 2026-07-30 against the DEPLOYED guerrilla build `e4ed31a103fac3b29c6310e82e27cfd83c61c50a`
(`e4ed31a10 feat(sites): the box ingests a prebuilt artifact …`) and `origin/main`.

## Q1 — Is BARKPARK_PAPER_CANVAS unset on guerrilla? YES, unset everywhere. Canvas is ON.

The serving unit is **`barkpark-slot@blue.service`** (PID 2020336), NOT `barkpark.service`
(whose MainPID is 0 — the assignment's prescribed `systemctl show barkpark.service` reads a
DEAD unit and its empty `Environment=` proves nothing).

```sh
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'systemctl list-units --all --no-pager | grep -i barkpark; \
   ps -eo pid,args | grep "[m]ix phx.server"'
# -> barkpark-slot@blue.service  loaded active running  Barkpark content instance (slot blue)
# -> 2020336 beam.smp ... mix phx.server

ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'tr "\0" "\n" < /proc/2020336/environ | grep -ic canvas; \
   grep -ri canvas /opt/barkpark/.env /opt/barkpark/.slots/*.env /opt/barkpark/.release-capture.env; echo rc=$?; \
   grep -in canvas /opt/barkpark/api/start.sh; echo start_rc=$?'
# -> 0            (zero CANVAS vars in the live process environment)
# -> rc=1         (no CANVAS in any env file)
# -> start_rc=1   (no CANVAS in start.sh)
# MIX_ENV=prod, PHX_HOST=guerrilla.barkpark.cloud confirmed in the same environ read.
```

Both independent code paths then force ON:

```sh
git show origin/main:api/config/runtime.exs | sed -n '51,56p'
# if config_env() == :prod and System.get_env("BARKPARK_PAPER_CANVAS") in [nil, ""] do
#   System.put_env("BARKPARK_PAPER_CANVAS", "1")
git show origin/main:api/lib/barkpark_web/live/studio/studio_live/paper_canvas.ex | sed -n '331,340p'
# def paper_canvas_enabled? do  case System.get_env(...) do  nil -> true
```

`paper_canvas.ex` lives at `api/lib/barkpark_web/live/studio/studio_live/paper_canvas.ex`
(NOT `.../live/studio/paper_canvas.ex` — that path does not exist on origin).

## Q2 — Is data-rev on the canvas path? NO. ZERO occurrences.

```sh
# authenticated GET of a real deployed paper (login-ticket auth half of studio-desk-measure.mjs)
curl -s -b jar.txt \
 'https://guerrilla.barkpark.cloud/w/default/p/default/d/production/studio/paper/studio-space-priority-desk-browser-2026-07-19' > paper.html
grep -c data-rev paper.html          # substring count via node indexOf: 0
```

The `cond` at `components.ex:213-263` puts `data-rev` on **three** arms only — nil-slug
(`<article id="paper-body" data-rev=…>`), stream (`phx-update="stream"`), legacy HTML — and
NOT on the `@show_editor ->` arm that the canvas default takes.
Proven both ways: the same authenticated GET of a **draft-only fossil** (legacy arm) DOES
carry it: `<article id="paper-body-drafts.paper-b28358ff271b260e" data-rev="0"></article>`.

## Deployed-DOM marker inventory (node indexOf counts on `paper.html`, 775,260 bytes)

```
  1  phx-submit="paper-add-block"        <-- PRESENT on the canvas build
  1  data-test-id="paper-add-block"
  1  data-test-id="paper-canvas-run"
  1  data-test-id="studio-paper-shell"   (aria-label="Editing <title>")
  1  data-test-id="bp-paper-footer"      ("10764 words" · "134 blocks")
  1  data-test-id="bp-paper-footer-save" (empty at rest; role=status aria-live=polite)
  1  data-test-id="bp-expected-fields"
  1  id="paper-sentinel"                 (data-slug=<slug>)
  5  data-canvas-blocks                  (1 DOM attr on the ignore wrapper + CSS/JS mentions)
  0  data-rev / data-rev=
  0  paper-edit-toggle
  0  data-edit-block-id=
  0  phx-click="paper-move-block  /  phx-click="paper-delete-block
  0  aria-busy
  0  "Saving"  /  "Auto-saved"  /  "Last saved"
  1  aria-live   (the whole page — the footer save span)
```

Exactly ONE real `phx-update="ignore"` element inside the paper editor:
`<div phx-update="ignore" id="paper-canvas-studio-space-priority-desk-browser-2026-07-19-run-0"
phx-hook="BarkparkPaperCanvas" class="bp-paper-edit-canvas" data-canvas-blocks="[…]" …>`.
(The other 7 hits are CSS/JS comment text plus the unrelated `#studio-theme-toggle` button.)

## Persistence binaries OUTSIDE the ignore wrapper — the complete set

```sh
git show origin/main:api/lib/barkpark_web/live/studio/studio_live/components/paper_editor.ex \
  | sed -n '367,400p'     # add-block form + footer, both AFTER the `if @canvas_on?` branch
git show origin/main:api/lib/barkpark_web/live/studio/studio_live/shared/paper.ex \
  | sed -n '85,95p'       # {:ok,_} -> sync_paper_edit_doc() |> assign(save_status: "Auto-saved")
```

1. `[data-test-id="bp-paper-footer-save"]` text — server-set: `"✓ Auto-saved"`, `"Save failed"`,
   `"Read-only"`, `"Save cancelled"`, `"Updated by another user"` (`save_status_label/1`).
   Empty on load, so empty→"✓ Auto-saved" is a clean transition.
2. Footer counts inside `[data-test-id="bp-paper-footer"]` — `beta_doc_stats(@blocks)`,
   recomputed by `sync_paper_edit_doc/1`: `134 blocks` → `135 blocks` on a landed add.
3. `[data-test-id="paper-add-block"]` — a real `<select name="block-type">` + `<button type="submit">Add</button>`
   posting `phx-submit="paper-add-block"`. A **server round-trip add that never touches the contenteditable.**
4. `[data-test-id="bp-expected-fields"]` `data-expected-fields` JSON — the source comment states it
   is deliberately outside any ignore wrapper and re-renders when `@blocks` change.
5. `#paper-sentinel[data-slug]` — the no-reload proof, outside the wrapper.
6. `main[data-test-id="studio-paper-shell"]` `aria-label` — `@canvas_on && @show_editor && @slug &&
   "Editing #{@title}"`; ABSENT whenever the editor did not open (see below).
7. `data-canvas-blocks` **on** the ignore wrapper (attributes of an ignored element are patched;
   its children are not) — server-encoded JSON of the run. Weakest of the set; verify empirically.
8. `paper_halt_banner` — server reason verbatim on a halted write.

NOT available: `data-rev`, `aria-busy`, any "Saving…" transient, `paper-edit-toggle`,
`data-edit-block-id`, the per-block ▲/▼/delete toolbar.

## Byproduct: the never-blank hole is LIVE on the deployed build, on a PAPER

```sh
curl -s -b jar.txt '…/studio/paper/drafts.paper-b28358ff271b260e' | grep -A1 paper-sentinel
# <div id="paper-sentinel" data-slug="drafts.paper-b28358ff271b260e" hidden></div>
# <article id="paper-body-drafts.paper-b28358ff271b260e" data-rev="0"></article>     <-- EMPTY
curl -s -b jar.txt '…/studio/paper/drafts.paper-3149ef706e777628' | grep -c 'paper-body-drafts'   # 1, same empty article
curl -s -b jar.txt '…/studio/paper/definitely-does-not-exist-zzz-9999' | grep -c 'Select a document to edit'  # 1
```

Three distinct outcomes, one URL shape:
- resolves + readable blocks → canvas editor, `aria-label="Editing …"`;
- **resolves + `Projection.read_blocks/1` non-list → `paper_block_mode: false` → legacy arm → `raw("")` → an EMPTY `<article>`, no shell aria-label, no named state at all;**
- does not resolve → the generic `"Select a document to edit"` empty state (carries no id, no type).
