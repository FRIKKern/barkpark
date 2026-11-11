defmodule BarkparkWeb.Studio.Desk.Style do
  @moduledoc """
  The desk slice's own CSS, in one place (`BarkparkWeb.Studio.DeskLive`
  draws it once, above the panes). The layout that depends on the window
  (strips, narrow, resize) is written by `bp-desk.js`, not here.

  Colours are design tokens only, chosen to pass in both themes (measured
  on guerrilla in light and dark): a reference chip's resting border is
  `--fg-dim` (3:1 for a control boundary), a selected row's sub line is
  `--fg` (the `--fg-muted` sub line is 4.2:1 on the selected fill in light),
  skeleton bones and pane separators are `--border` (`--border-subtle` is
  near invisible in dark). On a touch screen (`pointer: coarse`) rows, the
  close link and reference chips are at least 44 px; a mouse layout is
  unchanged.

  The edit pane (`.dk-edit`) is not positioned: the Studio draws a dialog's
  backdrop `position: absolute; inset: 0` inside its shell and means the
  page. A positioned edit pane boxed the backdrop in, so the other panes
  stayed bright and clickable under an open dialog.
  """

  use Phoenix.Component

  def sheet(assigns) do
    ~H"""
    <style>
      .dk .dk-pane { width: 320px; min-width: 320px; flex-shrink: 0; border-right-color: var(--border); }
      .dk .dk-doc { width: auto; flex: 1 0 600px; border-right: 0; }
      .dk a.pane-item { text-decoration: none; box-sizing: border-box; }
      .dk a.pane-item:hover { color: var(--fg); }
      .dk a.pane-item:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-note { padding: 16px; color: var(--fg-muted); font-size: var(--text-sm); }
      .dk .dk-fields { padding: 24px 32px; margin: 0; display: grid; gap: 20px; max-width: 72ch; }
      .dk .dk-fields dt { font-size: var(--text-xs); color: var(--fg-muted); margin-bottom: 4px; }
      .dk .dk-fields dd { margin: 0; font-size: var(--text-sm); white-space: pre-wrap; overflow-wrap: anywhere; }
      .dk .dk-close { color: var(--fg-muted); text-decoration: none; padding: 4px 8px; }
      .dk .dk-close:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-doc-menu { margin-left: auto; }
      .dk .dk-split { margin-left: auto; display: inline-flex; align-items: center; color: var(--fg-muted); padding: 4px 8px; border-radius: 6px; }
      .dk .dk-split:hover { background: var(--bg-accent); color: var(--fg); }
      .dk .dk-split:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-split + .dk-split, .dk .dk-split + .dk-doc-menu { margin-left: 0; }
      .dk .dk-doc-menu-button { border: 0; background: none; color: var(--fg-muted); font: inherit; line-height: 1; padding: 4px 8px; border-radius: 6px; cursor: pointer; }
      .dk .dk-doc-menu-button:hover, .dk .dk-doc-menu-button[aria-expanded="true"] { background: var(--bg-accent); color: var(--fg); }
      .dk .dk-doc-menu-button:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-doc-menu-list { min-width: 180px; padding: 4px; background: var(--bg-card); color: var(--fg); border: 1px solid var(--border-subtle); border-radius: 8px; }
      .dk .dk-doc-menu-list [role="menuitem"] { display: block; width: 100%; text-align: left; border: 0; background: none; color: inherit; font: inherit; font-size: var(--text-sm); padding: 6px 10px; border-radius: 4px; cursor: pointer; }
      .dk .dk-doc-menu-list [role="menuitem"]:hover, .dk .dk-doc-menu-list [role="menuitem"]:focus { background: var(--bg-accent); outline: none; }
      .dk .dk-doc-menu-list [role="menuitem"][data-desk-doc-action="delete-doc"] { color: var(--destructive); }
      .dk .dk-bone { display: block; height: 10px; width: 60%; border-radius: 5px; background: var(--border); }
      .dk .dk-skeleton .pane-item { cursor: default; }
      .dk .dk-skeleton .pane-item:nth-child(even) .dk-bone { width: 42%; }
      .dk [data-desk-leaving] { display: none; }
      .dk .dk-row-sub { display: block; font-weight: 400; font-size: var(--text-xs); color: var(--fg-muted); overflow: hidden; text-overflow: ellipsis; }
      .dk a.pane-item.selected .dk-row-sub { color: var(--fg); }
      .dk .dk-draft { color: var(--fg-muted); font-size: var(--text-xs); }
      .dk .dk-sort { display: flex; align-items: center; gap: 8px; padding: 8px 16px; border-bottom: 1px solid var(--border-subtle); font-size: var(--text-xs); color: var(--fg-muted); }
      .dk .dk-more { margin: 12px 16px; }
      .dk .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
      .dk .dk-edit { display: flex; flex-direction: column; min-width: 600px; }
      .dk .dk-edit > .pane-layout { flex: 1 1 auto; min-height: 0; }
      .dk fieldset.editor-field { border: 0; margin-inline: 0; padding: 0; min-width: 0; }
      .dk fieldset.editor-field > legend { padding: 0; }
      .dk .dk-edit-refs { padding: 8px 48px 8px 16px; border-bottom: 1px solid var(--border-subtle); }
      .dk-search { position: relative; padding: 8px 16px; border-bottom: 1px solid var(--border-subtle); background: var(--bg-card); }
      .dk-search form { max-width: 420px; }
      .dk-search-hits { position: absolute; z-index: 5; left: 16px; top: 100%; width: min(420px, calc(100% - 32px)); max-height: 60vh; overflow-y: auto; background: var(--bg-card); border: 1px solid var(--border-subtle); border-radius: 8px; }
      .dk .dk-refs { display: flex; flex-wrap: wrap; gap: 6px; }
      .dk .dk-ref { padding: 2px 8px; border: 1px solid var(--fg-dim); border-radius: 6px; color: var(--fg); text-decoration: none; }
      .dk .dk-ref:hover, .dk .dk-ref[aria-current] { background: var(--bg-accent); border-color: var(--primary); }
      .dk .dk-ref:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-ref-missing { color: var(--fg-muted); }
      @media (pointer: coarse) {
        .dk .pane-item { min-height: 44px; }
        .dk .dk-close { display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; min-width: 44px; min-height: 44px; margin-right: -12px; }
        .dk .dk-edit-refs { padding-right: 60px; }
        .dk .dk-split { justify-content: center; box-sizing: border-box; min-width: 44px; min-height: 44px; }
        .dk .dk-doc-menu-button { display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; min-width: 44px; min-height: 44px; }
        .dk .dk-doc-menu-list [role="menuitem"] { min-height: 44px; }
        .dk .dk-ref { display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; min-width: 44px; min-height: 44px; }
      }
    </style>
    """
  end
end
