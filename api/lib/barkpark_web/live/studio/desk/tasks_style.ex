defmodule BarkparkWeb.Studio.Desk.TasksStyle do
  @moduledoc """
  The look of the desk's Tasks sidebar (`Desk.TasksPanel`) and its buttons,
  after the TanStack Studio's `styles.css` (`.tasks-panel`, `.tasks-head`,
  `.tasks-tabs`, `.tasks-group`, `.task-row`, `.drawer-tasks`):

  - The sidebar is 360 px at the right under the navbar. From 900 px the
    panes make room for it; under 900 px it lies over them, and under 600 px
    it takes the whole width.
  - The bar's Tasks button gives way under 900 px, where the drawer has one.
  - On a touch screen (`pointer: coarse`) every target in the sidebar is
    44 px.

  Colours are the desk's tokens (`--dk-*`, `Desk.Style`); the buttons in the
  bar use the navbar's.
  """
  use Phoenix.Component

  def sheet(assigns) do
    ~H"""
    <style>
      .studio-shell:has(.dk) .navbar .tasks-btn[aria-pressed="true"] { background: var(--dk-nav-selected); color: var(--dk-nav-selected-fg); }
      .studio-shell:has(.dk) .navbar .nav-drawer .drawer-tasks { display: none; }
      @media (max-width: 899px) {
        .studio-shell:has(.dk) .navbar .studio-bar-right > .tasks-btn { display: none; }
        .studio-shell:has(.dk) .navbar .nav-drawer .drawer-tasks { display: flex; }
      }
      .dk.dk-tasks-host { position: relative; }
      .dk.dk-tasks-host[data-tasks-open] > .panes { margin-right: 360px; }
      .dk .tasks-panel { box-sizing: border-box; position: absolute; top: 0; right: 0; bottom: 0; z-index: 30; width: 360px; max-width: 100%; display: flex; flex-direction: column; border-left: 1px solid var(--dk-border); background: var(--dk-bg); color: var(--dk-fg); font-size: 13px; }
      .dk .tasks-head { display: flex; align-items: center; gap: 4px; min-height: 49px; padding: 9px 12px 7px 20px; }
      .dk .tasks-head:has(.tasks-crumbs) { padding-left: 12px; border-bottom: 1px solid var(--dk-border); }
      .dk .tasks-head h2 { flex: 1; min-width: 0; margin: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 15px; font-weight: 600; color: var(--dk-fg); }
      .dk .tasks-crumbs { flex: 1; min-width: 0; display: flex; align-items: center; gap: 4px; font-size: 13px; }
      .dk .tasks-crumbs h2 { font-size: 13px; line-height: 19px; }
      .dk .tasks-crumbs .btn-text { flex: none; padding: 4px; border: 0; border-radius: 3px; background: none; font: inherit; font-weight: 500; color: var(--dk-muted); cursor: pointer; }
      .dk .tasks-crumb-sep { display: inline-flex; color: var(--dk-icon-muted); }
      .dk .tasks-panel .icon-btn { flex: none; display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
      .dk .tasks-panel .icon-btn:hover, .dk .tasks-crumbs .btn-text:hover { background: var(--dk-icon-btn-hover); color: var(--dk-icon-btn-hover-fg); }
      .dk .tasks-panel .icon-btn[aria-disabled="true"] { opacity: 0.45; cursor: default; }
      .dk .tasks-panel .icon-btn[aria-disabled="true"]:hover { background: none; color: var(--dk-icon-muted); }
      .dk .tasks-panel svg { flex: none; width: 21px; height: 21px; }
      .dk .tasks-panel :is(button, a, summary):focus-visible { outline: none; box-shadow: inset 0 0 0 1px var(--dk-focus-ring); }
      .dk .tasks-tabs { display: flex; gap: 4px; padding: 2px 12px 13px; border-bottom: 1px solid var(--dk-border); }
      .dk .tasks-tabs button { padding: 6px 8px; border: 0; border-radius: 3px; background: none; font: inherit; font-size: 13px; font-weight: 500; color: var(--dk-fg); cursor: pointer; }
      .dk .tasks-tabs button:hover { background: var(--dk-card-hover); }
      .dk .tasks-tabs button[aria-selected="true"] { background: var(--dk-fill-soft); }
      .dk .tasks-body { flex: 1; min-height: 0; overflow: auto; padding: 16px; }
      .dk .tasks-empty { padding: 120px 16px; text-align: center; }
      .dk .tasks-empty h3 { margin: 0 0 8px; font-size: 13px; font-weight: 600; color: var(--dk-fg-header); }
      .dk .tasks-empty p { margin: 0; color: var(--dk-fg); }
      .dk .tasks-body > .tasks-group { margin: 5px 4px 0; }
      .dk .tasks-body > .tasks-group.tasks-done { margin-top: 40px; }
      .dk .tasks-group > summary { display: flex; align-items: center; width: max-content; list-style: none; font-weight: 500; line-height: 19px; color: var(--dk-muted); cursor: pointer; }
      .dk .tasks-group > summary::-webkit-details-marker { display: none; }
      .dk .tasks-group > summary svg { margin-left: -2px; }
      .dk .tasks-group:not([open]) > summary svg { rotate: -90deg; }
      .dk .tasks-list { margin: 0; padding: 9px 0 0; list-style: none; }
      .dk .task-row { display: flex; align-items: flex-start; gap: 12px; padding: 8px 0; }
      .dk .task-state { flex: none; display: grid; place-items: center; width: 19px; height: 19px; color: var(--dk-icon-muted); }
      .dk [data-done] > .task-state { color: var(--dk-published); }
      .dk .task-circle { box-sizing: border-box; width: 13px; height: 13px; border: 1.2px solid currentColor; border-radius: 50%; }
      .dk .task-text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 9px; }
      .dk .task-title { padding: 0; border: 0; border-radius: 3px; background: none; font: inherit; font-weight: 600; line-height: 19px; text-align: left; color: var(--dk-fg-header); overflow-wrap: anywhere; cursor: pointer; }
      .dk .task-title:hover { text-decoration: underline; }
      .dk .task-row[data-done] .task-title { color: var(--dk-muted); text-decoration: line-through; }
      .dk .task-meta { display: flex; flex-wrap: wrap; gap: 8px; font-size: 13px; line-height: 19px; color: var(--dk-muted); }
      .dk .task-meta-target { display: inline-flex; align-items: center; gap: 2px; min-width: 0; margin-left: -2px; font-weight: 500; color: var(--dk-fg); }
      .dk .task-assignee { flex: none; display: grid; place-items: center; width: 25px; height: 25px; border-radius: 50%; background: var(--dk-fill-soft); font-size: 10px; font-weight: 600; color: var(--dk-fg-header); }
      .dk .tasks-more { margin: 8px 0 0; color: var(--dk-muted); }
      .dk .task-view-title { display: flex; align-items: flex-start; gap: 8px; }
      .dk .task-view-title > .task-state { height: 27px; }
      .dk .task-view-title h3 { margin: 0; font-size: 18px; line-height: 27px; font-weight: 600; color: var(--dk-fg-header); overflow-wrap: anywhere; }
      .dk .task-description { margin: 12px 0 0; white-space: pre-wrap; overflow-wrap: anywhere; color: var(--dk-fg); }
      .dk .task-facts { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 8px 16px; margin: 20px 0 0; }
      .dk .task-facts dt { color: var(--dk-muted); }
      .dk .task-facts dd { margin: 0; overflow-wrap: anywhere; color: var(--dk-fg); }
      .dk .task-open { display: inline-flex; align-items: center; margin-top: 20px; border-radius: 3px; color: var(--dk-selected); }
      @media (max-width: 899px) {
        .dk.dk-tasks-host[data-tasks-open] > .panes { margin-right: 0; }
        .dk .tasks-panel { box-shadow: var(--dk-popover-shadow); }
      }
      @media (max-width: 599px) {
        .dk .tasks-panel { left: 0; width: auto; border-left: 0; }
      }
      @media (pointer: coarse) {
        .dk .tasks-panel .icon-btn { width: 44px; height: 44px; }
        .dk .tasks-tabs button, .dk .tasks-crumbs .btn-text, .dk .tasks-group > summary, .dk .task-open { min-height: 44px; }
        .dk .tasks-tabs button { min-width: 44px; }
        .dk .tasks-crumbs .btn-text { padding: 4px 8px; }
        .dk .task-row { padding: 0; }
        .dk .task-title { min-height: 44px; padding: 12px 0; }
        .dk .task-text { gap: 0; }
        .dk .task-meta { padding-bottom: 8px; }
        .dk .task-row > .task-state { margin-top: 12px; }
        .dk .task-row > .task-assignee { margin-top: 9px; }
      }
    </style>
    """
  end
end
