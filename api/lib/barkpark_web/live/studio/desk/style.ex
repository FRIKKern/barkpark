defmodule BarkparkWeb.Studio.Desk.Style do
  @moduledoc """
  The desk slice's own CSS, in one place (`BarkparkWeb.Studio.DeskLive`
  draws it once, above the panes). The layout that depends on the window
  (strips, narrow, resize) is written by `bp-desk.js`, not here.
  """

  use Phoenix.Component

  def sheet(assigns) do
    ~H"""
    <style>
      .dk .dk-pane { width: 320px; min-width: 320px; flex-shrink: 0; }
      .dk .dk-doc { width: auto; flex: 1 0 600px; border-right: 0; }
      .dk a.pane-item { text-decoration: none; box-sizing: border-box; }
      .dk a.pane-item:hover { color: var(--fg); }
      .dk a.pane-item:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-note { padding: 16px; color: var(--fg-muted); font-size: var(--text-sm); }
      .dk .dk-fields { padding: 24px 32px; margin: 0; display: grid; gap: 20px; max-width: 72ch; }
      .dk .dk-fields dt { font-size: var(--text-xs); color: var(--fg-muted); margin-bottom: 4px; }
      .dk .dk-fields dd { margin: 0; font-size: var(--text-sm); white-space: pre-wrap; overflow-wrap: anywhere; }
      .dk .dk-close { color: var(--fg-muted); text-decoration: none; padding: 4px 8px; }
      .dk .dk-bone { display: block; height: 10px; width: 60%; border-radius: 5px; background: var(--border-subtle); }
      .dk .dk-skeleton .pane-item { cursor: default; }
      .dk .dk-skeleton .pane-item:nth-child(even) .dk-bone { width: 42%; }
      .dk [data-desk-leaving] { display: none; }
      .dk .dk-row-sub { display: block; font-weight: 400; font-size: var(--text-xs); color: var(--fg-muted); overflow: hidden; text-overflow: ellipsis; }
      .dk .dk-draft { color: var(--fg-muted); font-size: var(--text-xs); }
      .dk .dk-sort { display: flex; align-items: center; gap: 8px; padding: 8px 16px; border-bottom: 1px solid var(--border-subtle); font-size: var(--text-xs); color: var(--fg-muted); }
      .dk .dk-more { margin: 12px 16px; }
      .dk .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
      .dk .dk-edit { position: relative; display: flex; flex-direction: column; min-width: 600px; }
      .dk .dk-edit > .pane-layout { flex: 1 1 auto; min-height: 0; }
      .dk .dk-edit-refs { padding: 8px 48px 8px 16px; border-bottom: 1px solid var(--border-subtle); }
      .dk .dk-edit-close { position: absolute; top: 8px; right: 8px; z-index: 2; }
      .dk-search { position: relative; padding: 8px 16px; border-bottom: 1px solid var(--border-subtle); background: var(--bg-card); }
      .dk-search form { max-width: 420px; }
      .dk-search-hits { position: absolute; z-index: 5; left: 16px; top: 100%; width: 420px; max-height: 60vh; overflow-y: auto; background: var(--bg-card); border: 1px solid var(--border-subtle); border-radius: 8px; }
      .dk .dk-refs { display: flex; flex-wrap: wrap; gap: 6px; }
      .dk .dk-ref { padding: 2px 8px; border: 1px solid var(--border-subtle); border-radius: 6px; color: var(--fg); text-decoration: none; }
      .dk .dk-ref:hover, .dk .dk-ref[aria-current] { background: var(--bg-accent); border-color: var(--primary); }
      .dk .dk-ref-missing { color: var(--fg-muted); }
    </style>
    """
  end
end
