defmodule BarkparkWeb.Studio.Desk.ArrayItemStyle do
  @moduledoc """
  The look of an object array's items in the desk's form
  (`ArrayItemDialog`, `ArrayItemMenu`), the TanStack Studio's
  (barkpark-studio `app/src/styles.css`: `.array-box`, `.array-row`,
  `.drag-handle`, `.array-item-preview`, `.item-actions`, `.item-menu`,
  `.dialog.item-dialog` and its crumbs), in the desk's own colour tokens,
  so it follows light and dark with the rest of the desk.

    * The rows sit in one ringed box, 5 px in, 4 px apart. A row is the
      handle (25 x 33, its dots muted), the preview (a 33 px tile with the
      item's image or its type's icon, the title in 500 and the subtitle
      muted, each on one line) and the 25 px "…".
    * A string row (`ArrayStringRow`) is the handle, the value's input and
      the "…": 5 px round its 35 px input, which ends 12 px before the
      "…", and the box 5 px in all round.
    * A row being moved is ringed in the selected blue and lifted.
    * The menu opens beside its "…", as wide as its items.
    * The dialog is 640 px wide at most and 597 px tall at least, 9 px
      round, over the dimmed page; its crumbs name the array and the item's
      place and title, and its body holds the item's fields.
    * Touch phones get 44 px targets.

  `DocStyle.sheet/1` draws these rules with the rest of the edit pane's.
  """

  @doc "The rules, for the edit pane's sheet."
  @spec css() :: String.t()
  def css do
    """
    .dk .dk-edit fieldset[data-desk-items] > ol.bp-array-rows { display: flex; flex-direction: column; gap: 4px; margin: 0; padding: 5px 5px 3px; list-style: none; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--dk-border); }
    .dk .dk-edit fieldset[data-desk-items] > ol.bp-array-rows:empty { display: none; }
    .dk .dk-edit .dk-array-row { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; margin: 0; padding: 5px; border: 0; border-radius: 3px; background: var(--dk-bg); }
    .dk .dk-edit fieldset[data-desk-items] > ol.bp-array-rows:has(> .dk-string-row) { padding: 5px; }
    .dk .dk-edit .dk-string-value { flex: 1; min-width: 0; margin-right: 8px; }
    .dk .dk-edit .dk-string-value > :is(input, textarea, pre) { box-sizing: border-box; width: 100%; margin: 0; }
    .dk .dk-edit .dk-string-value > input.bp-input { height: auto; min-height: 35px; padding: 6px 12px; border: 0; border-radius: 3px; background: var(--bg); box-shadow: inset 0 0 0 1px var(--dk-line); color: var(--dk-input-fg); font-size: 15px; line-height: 23px; }
    .dk .dk-edit .dk-string-value > input.bp-input:hover:not(:focus, :disabled, [readonly]) { box-shadow: inset 0 0 0 1px var(--dk-input-hover-ring); }
    .dk .dk-edit .dk-string-value > input.bp-input:focus { outline: none; box-shadow: inset 0 0 0 1px var(--dk-focus-ring); }
    .dk .dk-edit .dk-array-row[data-moving] { position: relative; z-index: 1; box-shadow: 0 0 0 1px var(--dk-selected), var(--dk-popover-shadow); }
    .dk .dk-edit .dk-array-row > :is(.error, .warning) { flex: 1 0 100%; padding: 0 8px; }
    .dk .dk-edit .dk-array-row .icon-btn { box-sizing: border-box; display: grid; place-items: center; width: 25px; height: 25px; margin: 0; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
    .dk .dk-edit .dk-array-row .icon-btn:hover:not(:disabled) { background: var(--dk-icon-btn-hover); }
    .dk .dk-edit .dk-array-row .icon-btn:disabled { cursor: default; opacity: 0.5; }
    .dk .dk-edit .dk-array-row > .dk-drag-handle { height: 33px; cursor: grab; touch-action: none; }
    .dk .dk-edit .dk-drag-handle[aria-pressed="true"] { cursor: grabbing; color: var(--dk-selected); }
    .dk .dk-edit .dk-item-preview { flex: 1; display: flex; align-items: center; gap: 8px; min-width: 0; padding: 8px; border: 0; border-radius: 3px; background: none; color: var(--dk-fg); font: inherit; text-align: left; cursor: pointer; }
    .dk .dk-edit .dk-item-preview:hover { background: var(--dk-card-hover); }
    .dk .dk-edit .dk-item-preview .media { flex: none; display: grid; place-items: center; width: 33px; height: 33px; overflow: hidden; border-radius: 2px; background: var(--dk-bg); box-shadow: inset 0 0 0 1px var(--dk-border); color: var(--dk-muted); }
    .dk .dk-edit .dk-item-preview .media.has-image { box-shadow: none; }
    .dk .dk-edit .dk-item-preview .media img { width: 100%; height: 100%; object-fit: cover; display: block; }
    .dk .dk-edit .dk-item-preview .text { display: flex; flex-direction: column; min-width: 0; margin: -1.5px 0; font-size: 13px; line-height: 19px; }
    .dk .dk-edit .dk-item-preview .title { font-weight: 500; }
    .dk .dk-edit .dk-item-preview .subtitle { margin-top: -2px; color: var(--dk-muted); }
    .dk .dk-edit .dk-item-preview :is(.title, .subtitle) { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
    .dk .dk-edit .dk-item-actions > .icon-btn[aria-expanded="true"] { background: var(--dk-selected-fill); color: var(--dk-fg); }
    .dk .dk-edit .dk-item-menu { inset: auto; margin: 4px; min-width: 0; position-anchor: --dk-item-menu; position-area: right center; position-try-fallbacks: left center, top, bottom; }
    .dk .dk-edit fieldset[data-desk-items] .bp-array-btn-add { display: flex; align-items: center; justify-content: center; gap: 6px; width: 100%; height: auto; margin-top: 8px; padding: 6px 10px 6px 4px; border: 0; border-radius: 3px; background: var(--dk-bg); box-shadow: inset 0 0 0 1px var(--dk-border); color: var(--dk-fg); font: inherit; font-size: 13px; font-weight: 500; line-height: 19px; cursor: pointer; }
    .dk .dk-edit fieldset[data-desk-items] .bp-array-btn-add:hover:not(:disabled) { background: var(--dk-card-hover); }
    .dk .dk-edit .dk-item-dialog { box-sizing: border-box; width: min(640px, calc(100vw - 24px)); min-height: min(597px, calc(100vh - 24px)); max-height: calc(100vh - 24px); padding: 0; border: 0; border-radius: 9px; background: var(--dk-bg); color: var(--dk-fg); box-shadow: var(--dk-popover-shadow); font-size: 13px; line-height: 19px; }
    .dk .dk-edit .dk-item-dialog[open] { display: flex; flex-direction: column; }
    .dk .dk-edit .dk-item-dialog::backdrop { background: var(--dk-backdrop); }
    .dk .dk-edit .dk-item-head { display: flex; align-items: flex-start; gap: 8px; padding: 12px 12px 9px 20px; border-bottom: 1px solid var(--dk-border); }
    .dk .dk-edit .dk-crumbs { flex: 1 1 auto; display: flex; align-items: center; gap: 2px; min-width: 0; margin-top: 3px; color: var(--dk-muted); }
    .dk .dk-edit .dk-crumb { display: inline-flex; align-items: center; gap: 4px; min-width: 0; max-width: 250px; padding: 3px 8px; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); font: inherit; font-weight: 500; white-space: nowrap; text-transform: capitalize; cursor: pointer; }
    .dk .dk-edit button.dk-crumb:hover { background: var(--dk-icon-btn-hover); }
    .dk .dk-edit .dk-crumb.current { padding-left: 4px; color: var(--dk-menu-fg); font-weight: 700; cursor: default; }
    .dk .dk-edit .dk-crumb .place { flex: none; padding: 0 4px; border-radius: 9999px; line-height: 17px; background: var(--dk-fill-soft); color: var(--dk-muted); font-weight: 400; }
    .dk .dk-edit .dk-crumb .crumb-title { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
    .dk .dk-edit .dk-item-close { box-sizing: border-box; display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-menu-fg); cursor: pointer; }
    .dk .dk-edit .dk-item-close:hover { background: var(--dk-icon-btn-hover); }
    .dk .dk-edit .dk-item-body { flex: 1 1 auto; min-height: 0; overflow: auto; padding: 34px 32px 20px 20px; }
    .dk .dk-edit :is(.dk-item-preview, .dk-crumb, .dk-item-close, .dk-array-row .icon-btn):focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: -1px; }
    @media (max-width: 768px) and (pointer: coarse) { .dk .dk-edit .dk-array-row .icon-btn, .dk .dk-edit .dk-item-close { width: 44px; height: 44px; } .dk .dk-edit .dk-item-preview, .dk .dk-edit button.dk-crumb { min-height: 44px; } }
    """
  end
end
