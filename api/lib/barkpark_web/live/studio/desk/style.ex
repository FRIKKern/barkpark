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

  A titled divider (`.desk-divider`, the root's "Settings") is the TanStack
  Studio's, as Sanity's measures at 1440: its title 11 px under the row above,
  its line 6 px under the title and 8 px over the next row.

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
      .dk .dk-doc { width: auto; flex: 1 1 600px; border-right: 0; }
      .dk .dk-edit .editor-panel { min-width: 0; }
      .dk .dk-edit .editor-panel .bp-paper-surface, .dk .dk-edit .editor-panel .editor-body, .dk .dk-edit .editor-panel .editor-body.editor-panel-main:not(.bp-paper-body) { min-inline-size: 0; }
      .dk a.pane-item { text-decoration: none; box-sizing: border-box; }
      .dk h2.pane-header-title { margin: 0; }
      .dk a.pane-item:hover { color: var(--fg); }
      .dk [data-lit] > a.pane-item:not(.selected) { background: var(--bg-muted); }
      .dk a.pane-item:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .pane-item-chevron { opacity: 0.5; }
      .dk .dk-note { padding: 16px; color: var(--fg-muted); font-size: var(--text-sm); overflow-wrap: anywhere; }
      .dk .dk-fields { padding: 24px 32px; margin: 0; display: grid; gap: 20px; max-width: 72ch; }
      .dk .dk-fields dt { font-size: var(--text-xs); color: var(--fg-muted); margin-bottom: 4px; }
      .dk .dk-fields dd { margin: 0; font-size: var(--text-sm); white-space: pre-wrap; overflow-wrap: anywhere; }
      .dk .dk-fields dd.dk-refs { white-space: normal; }
      .dk .dk-close { color: var(--fg-muted); text-decoration: none; padding: 4px 8px; }
      .dk .dk-close:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-doc-menu { margin-left: auto; }
      .dk .codelist-current { display: flex; align-items: baseline; gap: 8px; margin-bottom: 6px; font-size: var(--text-sm); }
      .dk .codelist-current .codelist-label { flex: 1; min-width: 0; color: var(--fg); overflow-wrap: anywhere; }
      .dk .dk-split { margin-left: auto; display: inline-flex; align-items: center; color: var(--fg-muted); padding: 4px 8px; border-radius: 6px; }
      .dk .dk-split:hover { background: var(--bg-accent); color: var(--fg); }
      .dk .dk-split:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-split + .dk-split, .dk .dk-split + .dk-doc-menu, .dk .dk-doc-menu + .dk-doc-menu { margin-left: 0; }
      .dk .dk-share-menu .dk-doc-menu-button { display: inline-flex; align-items: center; }
      .dk button.dk-focus { border: 0; background: none; font: inherit; cursor: pointer; }
      .dk .dk-focus-crumbs { display: flex; align-items: center; gap: 4px; min-width: 0; font-size: 13px; font-weight: 400; color: var(--fg); }
      .dk .dk-crumb { flex: none; font: inherit; padding: 4px; border: 0; border-radius: 3px; background: none; color: inherit; cursor: pointer; white-space: nowrap; }
      .dk button.dk-crumb:hover { background: var(--bg-accent); }
      .dk button.dk-crumb:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-crumb.current { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; cursor: default; }
      .dk .dk-toast { inset: auto; left: 50%; bottom: 56px; transform: translateX(-50%); margin: 0; max-width: calc(100vw - 32px); padding: 8px 14px; border-radius: 8px; background: var(--bg-card); color: var(--fg); border: 1px solid var(--border-subtle); font-size: var(--text-sm); }
      .dk .dk-edit-footer { display: flex; justify-content: flex-end; padding: 4px 8px; border-top: 1px solid var(--border-subtle); }
      .dk .form-switch input[type="checkbox"] { left: 0; top: 50%; width: 34px; height: 20px; margin: -10px 0 0; z-index: 1; cursor: pointer; }
      .dk .dk-inspect { margin: auto; width: min(720px, calc(100vw - 32px)); max-height: calc(100vh - 64px); padding: 0; border: 1px solid var(--border-subtle); border-radius: 8px; background: var(--bg-card); color: var(--fg); }
      .dk .dk-inspect[open] { display: flex; flex-direction: column; }
      .dk .dk-inspect::backdrop { background: color-mix(in srgb, var(--fg) 30%, transparent); }
      .dk .dk-inspect-head { display: flex; align-items: center; gap: 8px; padding: 12px 16px 8px; }
      .dk .dk-inspect-head h2 { flex: 1 1 auto; margin: 0; font-size: var(--text-sm); font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .dk-inspect-close { border: 0; background: none; color: var(--fg-muted); font: inherit; padding: 4px 8px; border-radius: 6px; cursor: pointer; }
      .dk .dk-inspect-close:hover { background: var(--bg-accent); color: var(--fg); }
      .dk .dk-inspect-tabs { display: flex; gap: 4px; padding: 0 16px 8px; border-bottom: 1px solid var(--border-subtle); }
      .dk .dk-inspect-tabs [role="tab"] { border: 0; background: none; color: var(--fg-muted); font: inherit; font-size: var(--text-sm); padding: 4px 10px; border-radius: 6px; cursor: pointer; }
      .dk .dk-inspect-tabs [role="tab"][aria-selected="true"] { background: var(--bg-accent); color: var(--fg); }
      .dk .dk-inspect-close:focus-visible, .dk .dk-inspect-tabs [role="tab"]:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-inspect-body { flex: 1 1 auto; min-height: 0; overflow: auto; }
      .dk .dk-inspect-panel { padding: 12px 16px 16px; font-size: var(--text-sm); }
      .dk .dk-inspect-panel pre { margin: 0; font-family: var(--paper-font-mono, ui-monospace, Menlo, monospace); white-space: pre; }
      .dk .dk-inspect-panel pre code { font: inherit; }
      .dk .dk-inspect-tree { list-style: none; margin: 0; padding: 0; }
      .dk .dk-inspect-tree .dk-inspect-tree { padding-left: 16px; }
      .dk .dk-inspect-tree li { padding: 2px 0; overflow-wrap: anywhere; }
      .dk .dk-inspect-key { font-weight: 600; margin-right: 6px; }
      .dk .dk-inspect-count { color: var(--fg-muted); }
      .dk .dk-inspect-tree summary { cursor: pointer; }
      .dk .dk-doc-menu-button { border: 0; background: none; color: var(--fg-muted); font: inherit; line-height: 1; padding: 4px 8px; border-radius: 6px; cursor: pointer; }
      .dk .dk-doc-menu-button:hover, .dk .dk-doc-menu-button[aria-expanded="true"] { background: var(--bg-accent); color: var(--fg); }
      .dk .dk-doc-menu-button:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-create-new, .dk .dk-list-options { margin-left: auto; display: inline-flex; align-items: center; }
      .dk .dk-create-new + .dk-list-options { margin-left: 0; }
      .dk .dk-doc-menu-list { min-width: 180px; padding: 4px; background: var(--bg-card); color: var(--fg); border: 1px solid var(--border-subtle); border-radius: 8px; }
      .dk .dk-doc-menu-list [role="menuitem"] { display: block; width: 100%; text-align: left; border: 0; background: none; color: inherit; font: inherit; font-size: var(--text-sm); padding: 6px 10px; border-radius: 4px; cursor: pointer; }
      .dk .dk-doc-menu-list [role="menuitem"]:hover, .dk .dk-doc-menu-list [role="menuitem"]:focus { background: var(--bg-accent); outline: none; }
      .dk .dk-doc-menu-list [role="menuitem"][data-desk-doc-action="delete-doc"] { color: var(--destructive); }
      .dk .dk-list-menu { min-width: 220px; padding: 4px; background: var(--bg-card); color: var(--fg); border: 1px solid var(--border-subtle); border-radius: 8px; }
      .dk .dk-list-menu .menu-label { padding: 8px 10px 4px; font-size: var(--text-xs); font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; color: var(--fg-muted); }
      .dk .dk-list-menu [role="menuitemradio"] { display: flex; align-items: center; gap: 12px; width: 100%; text-align: start; border: 0; background: none; color: inherit; font: inherit; font-size: var(--text-sm); padding: 6px 10px; border-radius: 4px; cursor: pointer; }
      .dk .dk-list-menu [role="menuitemradio"]:hover, .dk .dk-list-menu [role="menuitemradio"]:focus { background: var(--bg-accent); outline: none; }
      .dk .dk-list-menu [role="menuitemradio"][aria-disabled="true"] { background: none; cursor: default; color: color-mix(in srgb, var(--fg) 14%, var(--bg-card)); }
      .dk .dk-list-menu [role="menuitemradio"][aria-checked="true"]::after { content: "✓"; margin-left: auto; color: var(--fg-muted); }
      .dk .dk-bone { display: block; height: 10px; width: 60%; border-radius: 5px; background: var(--border); }
      .dk .dk-skeleton .pane-item { cursor: default; }
      .dk .dk-skeleton .pane-item:nth-child(even) .dk-bone { width: 42%; }
      .dk [data-desk-leaving] { display: none; }
      .dk .dk-row-sub { display: block; font-weight: 400; font-size: var(--text-xs); color: var(--fg-muted); overflow: hidden; text-overflow: ellipsis; }
      .dk a.pane-item.selected .dk-row-sub { color: var(--fg); }
      .dk .dk-draft { color: var(--fg-muted); font-size: var(--text-xs); }
      .dk .desk-divider { margin: 4px 12px 8px; padding: 7px 8px 6px; border-bottom: 1px solid var(--border); font-size: 13px; line-height: 19px; font-weight: 600; color: var(--fg-muted); }
      .dk .dk-sort { display: flex; align-items: center; gap: 8px; padding: 8px 16px; border-bottom: 1px solid var(--border-subtle); font-size: var(--text-xs); color: var(--fg-muted); }
      .dk .dk-more { margin: 12px 16px; }
      .dk .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
      .dk .dk-edit { display: flex; flex-direction: column; min-width: 0; }
      .dk .dk-edit > .pane-layout { flex: 1 1 auto; min-height: 0; }
      .dk .dk-edit[data-desk-document] .editor-meta { display: none; }
      .dk fieldset.editor-field { border: 0; margin-inline: 0; padding: 0; min-width: 0; }
      .dk fieldset.editor-field > legend { padding: 0; }
      .dk .dk-edit-refs { padding: 8px 48px 8px 16px; border-bottom: 1px solid var(--border-subtle); }
      .dk-search { position: relative; padding: 8px 16px; border-bottom: 1px solid var(--border-subtle); background: var(--bg-card); }
      .dk-search form { max-width: 420px; }
      .dk-search-hits { position: absolute; z-index: 5; left: 16px; top: 100%; width: min(420px, calc(100% - 32px)); max-height: 60vh; overflow-y: auto; background: var(--bg-card); border: 1px solid var(--border-subtle); border-radius: 8px; }
      .dk-search-hits a[aria-selected="true"] { background: var(--bg-muted); }
      .dk .dk-refs { display: flex; flex-wrap: wrap; gap: 6px; font-size: var(--text-sm); }
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
        .dk .dk-inspect-close, .dk .dk-inspect-tabs [role="tab"] { min-width: 44px; min-height: 44px; }
        .dk .dk-ref { display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; min-width: 44px; min-height: 44px; }
      }
    </style>
    """
  end
end
