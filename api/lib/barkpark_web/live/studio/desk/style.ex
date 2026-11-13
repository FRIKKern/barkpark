defmodule BarkparkWeb.Studio.Desk.Style do
  @moduledoc """
  The desk slice's own CSS, in one place (`BarkparkWeb.Studio.DeskLive`
  draws it once, above the panes). The layout that depends on the window
  (strips, narrow, resize) is written by `bp-desk.js`, not here.

  The panes and rows carry the TanStack Studio's own look (main's ruling,
  2026-11-13, reversing "Barkpark tokens only" for the desk): its measured
  values as `--dk-*` properties on `.dk`, light and dark, declared once at
  the top under the literal gate's skip region. A selected row is TanStack's
  solid blue while its pane is the last one open (its `aria-current`), and
  the soft chain fill once a pane is open further right (its `data-selected`).

  Other colours are design tokens, chosen to pass in both themes (measured
  on guerrilla in light and dark): a reference chip's resting border is
  `--fg-dim` (3:1 for a control boundary), a selected row's sub line is
  `--fg` (the `--fg-muted` sub line is 4.2:1 on the selected fill in light),
  skeleton bones and pane separators are `--border` (`--border-subtle` is
  near invisible in dark). On a touch screen (`pointer: coarse`) rows, the
  close link and reference chips are at least 44 px; a mouse layout is
  unchanged.

  A titled divider (`.desk-divider`, the root's "Settings") is the TanStack
  Studio's, as Sanity's measures at 1440: its title 11 px under the row above,
  its line 6 px under the title and 8 px over the next row. Its words start at
  the rows' x (20 px): `.dk-rows` already insets it 12 px.

  The edit pane's header is the TanStack Studio's (`styles.css`
  `.pane-header`, `.icon-btn`, `.chip`): 51 px, 25 px buttons with 21 px
  icons, and the Published / Draft pills (`DocStatus`) at its left, light
  and dark as `--dk-*` properties. The Studio's own toolbar row under it is
  hidden, its document heading kept for screen readers; its actions are in
  the "…" menu (`DocMenu`). Only the Classic editor's row is hidden: the Beta
  editor's header holds the way back to Classic.

  The three menus (`.dk-menu`, `Desk.Menu`) are TanStack's `.popover.menu`:
  no border, its popover shadow (a hairline ring that shows in dark too),
  33 px items in its menu ink, a 21 px icon. An item is lit (TanStack's blue)
  under the pointer, or under the focus when the keys moved it there
  (`:focus-visible`): a click opens a menu with nothing lit.

  Inspect (`.dk-inspect`) is TanStack's card: radius 6, the popover shadow,
  the page dimmed by its backdrop, its tree in a monospace with its syntax
  colours (styles.css `--syntax-*`), light and dark.

  The edit pane (`.dk-edit`) is not positioned: the Studio draws a dialog's
  backdrop `position: absolute; inset: 0` inside its shell and means the
  page. A positioned edit pane boxed the backdrop in, so the other panes
  stayed bright and clickable under an open dialog.
  """

  use Phoenix.Component

  def sheet(assigns) do
    ~H"""
    <style>
      /* studio-literal-check: skip-begin (the desk's own look: the TanStack Studio's
         measured values, barkpark-studio app/src/styles.css, light and dark; main's ruling 11-13) */
      .dk div.dk-edit-footer { --dk-foot-meta: rgb(106 110 125); --dk-foot-icon: rgb(106 110 125); --dk-foot-hover: rgb(246 246 248); --dk-publish-bg: rgb(31 34 48); --dk-publish-fg: rgb(255 255 255); --dk-publish-off-bg: rgb(187 189 201); --dk-publish-off-fg: rgb(236 237 243); }
      html[data-theme="dark"] .dk div.dk-edit-footer { --dk-foot-meta: rgb(147 148 159); --dk-foot-icon: rgb(147 148 159); --dk-foot-hover: rgb(33 35 47); --dk-publish-bg: rgb(228 229 233); --dk-publish-fg: rgb(19 20 27); --dk-publish-off-bg: rgb(85 92 117); --dk-publish-off-fg: rgb(33 38 57); }
      .dk { --dk-fg: #252837; --dk-muted: #515870; --dk-border: #e3e4e8; --dk-bg: #fff; --dk-icon-muted: #6a6e7d; --dk-card-hover: #f6f6f8; --dk-row-hover-fg: #363b4f; --dk-row-hover-muted: #666a79; --dk-hover-strong: #e9eaee; --dk-row-chain-bg: #eeeef1; --dk-row-chain-fg: #353a4d; --dk-selected: #465be8; --dk-on-selected: #fff; --dk-on-selected-soft: rgba(255, 255, 255, 0.9); --dk-dot-on-selected: #55d8fd; --dk-published: #0db770; --dk-caution-dot: #d08412; --dk-fg-header: #383d51; --dk-icon-btn-hover: #f6f6f8; --dk-icon-btn-hover-fg: #636570; --dk-placeholder: #9499ad; --dk-focus-ring: #556bfc; }
      html[data-theme="dark"] .dk { --dk-fg: #e4e5e9; --dk-muted: #979cb0; --dk-border: #2a2d3f; --dk-bg: #13141b; --dk-icon-muted: #93949f; --dk-card-hover: #191a24; --dk-row-hover-fg: #bec0cd; --dk-row-hover-muted: #9597a3; --dk-hover-strong: #2a2d3f; --dk-row-chain-bg: #21232f; --dk-row-chain-fg: #c1c3d0; --dk-selected: #7898ff; --dk-on-selected: #0d0e12; --dk-on-selected-soft: rgba(19, 20, 27, 0.8); --dk-dot-on-selected: #0d6e70; --dk-published: #13c184; --dk-caution-dot: #d8931b; --dk-fg-header: #bdbfcb; --dk-icon-btn-hover: #21232f; --dk-icon-btn-hover-fg: #9193a0; --dk-placeholder: #555c75; --dk-focus-ring: #596ffc; }
      .dk section.dk-doc { --dk-head-fg: rgb(56 61 81); --dk-head-icon: rgb(106 110 125); --dk-head-hover: rgb(246 246 248); --dk-head-hover-fg: rgb(99 101 112); --dk-chip-ring: rgb(227 228 232); --dk-chip-selected-fg: rgb(35 38 53); --dk-chip-active-bg: rgb(253 243 200); --dk-chip-positive-fg: rgb(13 81 51); --dk-chip-off-fg: rgb(143 148 168); --dk-chip-off-bg: rgb(246 246 248); --dk-chip-off-ring: rgb(230 230 234); --dk-published: rgb(13 183 112); --dk-caution-dot: rgb(208 132 18); --dk-line-strong: rgb(199 202 211); }
      html[data-theme="dark"] .dk section.dk-doc { --dk-head-fg: rgb(189 191 203); --dk-head-icon: rgb(147 148 159); --dk-head-hover: rgb(33 35 47); --dk-head-hover-fg: rgb(145 147 160); --dk-chip-ring: rgb(42 45 63); --dk-chip-selected-fg: rgb(230 231 236); --dk-chip-active-bg: rgb(59 50 22); --dk-chip-positive-fg: rgb(93 243 189); --dk-chip-off-fg: rgb(90 96 123); --dk-chip-off-bg: rgb(25 26 36); --dk-chip-off-ring: rgb(38 40 55); --dk-published: rgb(19 193 132); --dk-caution-dot: rgb(216 147 27); --dk-line-strong: rgb(77 82 105); }
      .dk { --dk-menu-fg: #383d51; --dk-menu-hover-fg: #fff; --dk-menu-hover-icon: #bfcbfe; --dk-menu-danger: #8b2018; --dk-menu-danger-icon: #a85852; --dk-menu-danger-hover: #d63a2c; --dk-menu-danger-hover-icon: #fabab3; --dk-popover-shadow: 0 0 0 0.5px rgba(114, 120, 146, 0.3), 0 7px 8px -4px rgba(114, 120, 146, 0.1), 0 12px 17px 2px rgba(114, 120, 146, 0.07), 0 5px 22px 4px rgba(114, 120, 146, 0.06); }
      html[data-theme="dark"] .dk { --dk-menu-fg: #bdbfcb; --dk-menu-hover-fg: #0d0e12; --dk-menu-hover-icon: #303c7a; --dk-menu-danger: #fdafa8; --dk-menu-danger-icon: #c38885; --dk-menu-danger-hover: #f77a6f; --dk-menu-danger-hover-icon: #6c312f; --dk-popover-shadow: 0 0 0 0.5px rgba(117, 123, 150, 0.4), 0 7px 8px -4px rgba(0, 0, 0, 0.2), 0 12px 17px 2px rgba(0, 0, 0, 0.14), 0 5px 22px 4px rgba(0, 0, 0, 0.12); }
      .dk { --dk-toast-shadow: 0 0 0 0.5px rgba(110, 116, 142, 0.3), 0 3px 5px -2px rgba(114, 120, 146, 0.1), 0 6px 10px 0 rgba(114, 120, 146, 0.07), 0 1px 18px 1px rgba(114, 120, 146, 0.06); --dk-fill-soft: #eeeef1; --dk-badge-fg: #4c536a; --dk-badge-lit-bg: #e6e6ea; --dk-badge-lit-fg: #4a5068; }
      html[data-theme="dark"] .dk { --dk-toast-shadow: 0 0 0 0.5px rgba(121, 127, 154, 0.4), 0 3px 5px -2px rgba(0, 0, 0, 0.2), 0 6px 10px 0 rgba(0, 0, 0, 0.14), 0 1px 18px 1px rgba(0, 0, 0, 0.12); --dk-fill-soft: #21232f; --dk-badge-fg: #9da2b7; --dk-badge-lit-bg: #262837; --dk-badge-lit-fg: #9fa4ba; }
      /* ::backdrop may not inherit the --dk-* properties: TanStack's --backdrop, as values. */
      .dk-search-dialog::backdrop { background: rgba(227, 228, 232, 0.5); }
      html[data-theme="dark"] .dk-search-dialog::backdrop { background: rgba(19, 20, 27, 0.5); }
      /* The Studio's top bar sits outside .dk: on the desk it takes TanStack's navbar values (--bg, --border, --menu-fg, --icon-btn-hover, --menu-active-fg, --selected-fill, --tab-strong-fg, --focus-ring). */
      .studio-shell:has(.dk) .studio-bar { --dk-nav-bg: #fff; --dk-nav-border: #e3e4e8; --dk-nav-fg: #383d51; --dk-nav-hover: #f6f6f8; --dk-nav-hover-fg: #242736; --dk-nav-selected: #eeeef1; --dk-nav-selected-fg: #232635; --dk-nav-focus: #556bfc; }
      html[data-theme="dark"] .studio-shell:has(.dk) .studio-bar { --dk-nav-bg: #13141b; --dk-nav-border: #2a2d3f; --dk-nav-fg: #bdbfcb; --dk-nav-hover: #21232f; --dk-nav-hover-fg: #e5e6eb; --dk-nav-selected: #2a2d3f; --dk-nav-selected-fg: #e6e7ec; --dk-nav-focus: #596ffc; }
      .dk { --dk-icon-hover: #f6f6f8; --dk-selected-fill: #eeeef1; --dk-tab-selected-fg: #636776; --dk-focus: #556bfc; --dk-backdrop: rgba(227, 228, 232, 0.5); --dk-syntax-property: #4043e7; --dk-syntax-string: #965912; --dk-syntax-constant: #721fe5; --dk-syntax-punctuation: #515870; }
      html[data-theme="dark"] .dk { --dk-icon-hover: #21232f; --dk-selected-fill: #2a2d3f; --dk-tab-selected-fg: #9d9fae; --dk-focus: #596ffc; --dk-backdrop: rgba(19, 20, 27, 0.5); --dk-syntax-property: #7898ff; --dk-syntax-string: #f9be1e; --dk-syntax-constant: #b28af7; --dk-syntax-punctuation: #979cb0; }
      /* The read-only document pane's values (`PaneComponent`), as TanStack's disabled form: its --input-fg, --bg-soft fill, --line ring and the ring under the pointer. */
      .dk { --dk-field-fg: #0d0e12; --dk-field-fill: #f6f6f8; --dk-field-ring: #e3e4e8; --dk-field-hover-ring: #bbbdc9; }
      html[data-theme="dark"] .dk { --dk-field-fg: #e4e5e9; --dk-field-fill: #191a24; --dk-field-ring: #3d4258; --dk-field-hover-ring: #3d4258; }
      /* studio-literal-check: skip-end */
      .dk { background: var(--dk-bg); }
      .dk .dk-pane { box-sizing: border-box; flex: 1 1 0; width: auto; min-width: 321px; max-width: 351px; border-right-color: var(--border); background: var(--dk-bg); }
      .dk .dk-doc { width: auto; min-width: 320px; max-width: none; flex: 1 1 600px; border-right: 0; }
      .studio-shell:has(.dk) > .studio-footer { display: none; }
      .dk .dk-edit .editor-panel { min-width: 0; }
      .dk .dk-edit .editor-panel .bp-paper-surface, .dk .dk-edit .editor-panel .editor-body, .dk .dk-edit .editor-panel .editor-body.editor-panel-main:not(.bp-paper-body) { min-inline-size: 0; }
      .dk a.pane-item { text-decoration: none; box-sizing: border-box; }
      .dk h2.pane-header-title { margin: 0; }
      .dk a.pane-item:hover { color: var(--fg); }
      .dk [data-lit] > a.pane-item:not(.selected) { background: var(--dk-card-hover); }
      .dk a.pane-item:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .pane-item-chevron, .dk .pane-item:hover .pane-item-chevron, .dk .pane-item.selected .pane-item-chevron { opacity: 0.5; color: inherit; display: flex; margin-right: -2px; }
      .dk .pane-item-chevron svg { width: 21px; height: 21px; }
      /* The rows' containing block: a row's sr-only words (position: absolute) must not escape the pane's scroll area and make the page scroll. */
      .dk .dk-rows { position: relative; padding: 0 12px 12px; }
      .dk .dk-row > .pane-item { box-sizing: border-box; display: flex; align-items: center; gap: 8px; margin: 0 0 4px; padding: 7px 8px; height: 33px; min-height: 33px; border: 0; border-radius: 3px; font-size: 13px; line-height: 19px; font-weight: 500; color: var(--dk-fg); background: none; }
      .dk [data-pane-kind="list"] .dk-row > a.pane-item[data-desk-opens="doc"] { padding: 5px 8px; height: auto; min-height: 49px; }
      .dk .dk-row > a.pane-item:hover:not(.selected) { background: var(--dk-card-hover); color: var(--dk-fg); }
      .dk [data-pane-kind="list"] .dk-row > a.pane-item[data-desk-opens="doc"]:hover:not(.selected) .dk-row-title { color: var(--dk-row-hover-fg); }
      .dk [data-pane-kind="list"] .dk-row > a.pane-item[data-desk-opens="doc"]:hover:not(.selected) .dk-row-sub { color: var(--dk-row-hover-muted); }
      .dk .dk-row > a.pane-item.selected { background: var(--dk-selected); color: var(--dk-on-selected); }
      .dk .dk-row > a.pane-item.selected .dk-row-sub { color: var(--dk-on-selected-soft); }
      .dk [data-pane-index]:has(~ [data-pane-index]:not([data-desk-leaving]) ~ [data-pane-index]:not([data-desk-leaving])) .dk-row > a.pane-item.selected { background: var(--dk-row-chain-bg); color: var(--dk-row-chain-fg); }
      .dk [data-pane-index]:has(~ [data-pane-index]:not([data-desk-leaving]) ~ [data-pane-index]:not([data-desk-leaving])) .dk-row > a.pane-item.selected[data-desk-opens="doc"] { background: var(--dk-hover-strong); color: var(--dk-fg); }
      .dk [data-pane-index]:has(~ [data-pane-index]:not([data-desk-leaving]) ~ [data-pane-index]:not([data-desk-leaving])) .dk-row > a.pane-item.selected .dk-row-sub { color: var(--dk-muted); }
      .dk .dk-note { padding: 16px; color: var(--fg-muted); font-size: var(--text-sm); overflow-wrap: anywhere; }
      .dk .dk-lost { padding-top: 0; }
      .dk .dk-lost summary { cursor: pointer; color: var(--fg); }
      .dk .dk-lost-text { margin: 8px 0; padding: 6px 10px; border-left: 2px solid var(--border-subtle); color: var(--fg); white-space: pre-wrap; max-height: 12em; overflow: auto; }
      .dk .dk-lost-copy { border: 1px solid var(--border-subtle); background: none; color: var(--fg); font: inherit; padding: 4px 10px; border-radius: 6px; cursor: pointer; }
      .dk .dk-lost-copy:hover { background: var(--bg-accent); }
      .dk .dk-lost-copy:focus-visible, .dk .dk-lost summary:focus-visible { outline: 2px solid var(--primary); outline-offset: 2px; }
      .dk .dk-doc:not(.dk-edit) > .pane-body { container: dk-ro / inline-size; }
      .dk .dk-ro { padding: 28px max(20px, calc(50% - 300px)) 161px; }
      .dk .dk-ro .dk-kind { font-size: 13px; line-height: 19px; color: var(--dk-muted); }
      .dk .dk-ro .dk-big-title { margin: 8px 0 52px; font-size: 33px; line-height: 41px; font-weight: 700; color: var(--dk-fg); overflow-wrap: anywhere; }
      @container dk-ro (max-width: 600px) { .dk .dk-ro .dk-big-title { font-size: 27px; line-height: 35px; } }
      @container dk-ro (max-width: 464px) { .dk .dk-ro .dk-big-title { font-size: 21px; line-height: 29px; } }
      .dk .dk-fields { display: grid; gap: 59px; margin: 0; padding: 0; }
      .dk .dk-fields dt { margin: 0 0 15px; font-size: 13px; line-height: 19px; font-weight: 500; color: var(--dk-fg); }
      .dk .dk-fields dd { box-sizing: border-box; min-height: 35px; margin: 0; padding: 6px 12px; border-radius: 3px; background: var(--dk-field-fill); box-shadow: inset 0 0 0 1px var(--dk-field-ring); color: var(--dk-field-fg); font-size: 15px; line-height: 23px; white-space: pre-wrap; overflow-wrap: anywhere; }
      .dk .dk-fields dd.dk-refs { display: grid; gap: 8px; min-height: 0; padding: 0; background: none; box-shadow: none; white-space: normal; }
      .dk .dk-fields .dk-refs > * { box-sizing: border-box; display: block; min-width: 0; min-height: 35px; margin: 0; padding: 6px 12px; border: 0; border-radius: 3px; background: var(--dk-field-fill); box-shadow: inset 0 0 0 1px var(--dk-field-ring); color: var(--dk-field-fg); font-size: 15px; line-height: 23px; overflow-wrap: anywhere; text-decoration: none; }
      .dk .dk-fields .dk-refs > .dk-ref-missing, .dk .dk-fields .dk-refs > .dk-ref-none { color: var(--dk-muted); }
      .dk .dk-fields .dk-refs > .ref-box { display: flex; align-items: center; gap: 4px; padding: 5px; }
      .dk .dk-fields .ref-box > .preview { flex: 1; min-width: 0; display: flex; align-items: center; gap: 8px; box-sizing: border-box; min-height: 49px; padding: 5px 8px; border-radius: 3px; font-size: 13px; line-height: 19px; color: var(--dk-fg); }
      .dk .dk-fields .ref-box .text { flex: 1; min-width: 0; margin-right: 20px; display: flex; flex-direction: column; }
      .dk .dk-fields .ref-box .t { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .dk-fields .ref-box .s { margin-top: -2px; color: var(--dk-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .dk-fields a.dk-ref:hover { background: var(--dk-field-fill); box-shadow: inset 0 0 0 1px var(--dk-field-hover-ring); }
      .dk .dk-fields a.dk-ref[aria-current] { background: var(--dk-row-chain-bg); color: var(--dk-row-chain-fg); }
      .dk .dk-fields a.dk-ref:focus-visible { outline: none; box-shadow: inset 0 0 0 1px var(--dk-focus-ring); }
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
      .dk .dk-edit-footer { flex: none; box-sizing: border-box; min-height: 49px; display: flex; align-items: flex-start; gap: 8px; padding: 12px 16px; font-size: 13px; line-height: 19px; color: var(--dk-foot-meta); }
      .dk .dk-footer-status { flex: 1 1 0; min-width: 0; padding: 3px 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .dk-publish { display: inline-flex; align-items: center; gap: 2px; min-height: 25px; padding: 2px 8px 2px 2px; border: 0; border-radius: 3px; background: var(--dk-publish-bg); color: var(--dk-publish-fg); font: inherit; font-size: 13px; font-weight: 500; white-space: nowrap; cursor: pointer; }
      .dk .dk-publish:disabled { background: var(--dk-publish-off-bg); color: var(--dk-publish-off-fg); cursor: default; }
      .dk .dk-publish svg { width: 21px; height: 21px; margin: 0; }
      .dk .dk-edit-footer .dk-doc-menu { margin-left: 4px; }
      .dk .dk-edit-footer .dk-doc-menu-button { display: inline-grid; place-items: center; box-sizing: border-box; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-foot-icon); font-size: 17px; line-height: 1; cursor: pointer; }
      .dk .dk-edit-footer .dk-doc-menu-button:hover { background: var(--dk-foot-hover); }
      .dk .form-switch input[type="checkbox"] { left: 0; top: 50%; width: 34px; height: 20px; margin: -10px 0 0; z-index: 1; cursor: pointer; }
      .dk .dk-inspect { margin: auto; width: min(774px, calc(100vw - 32px)); max-height: calc(100vh - 64px); padding: 0; border: 0; border-radius: 6px; background: var(--dk-bg); color: var(--dk-fg); box-shadow: var(--dk-popover-shadow); font-size: 13px; line-height: 19px; }
      .dk .dk-inspect[open] { display: flex; flex-direction: column; }
      .dk .dk-inspect::backdrop { background: var(--dk-backdrop); }
      .dk .dk-inspect-head { display: flex; align-items: center; gap: 8px; padding: 12px 12px 0 20px; }
      .dk .dk-inspect-head h2 { flex: 1 1 auto; margin: 0; font-size: 13px; line-height: 19px; font-weight: 600; color: var(--dk-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .dk-inspect-head h2 em { font-style: italic; }
      .dk .dk-inspect-close { display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
      .dk .dk-inspect-close:hover { background: var(--dk-icon-hover); color: var(--dk-fg); }
      .dk .dk-inspect-tabs { display: flex; gap: 4px; padding: 12px; border-bottom: 1px solid var(--dk-border); }
      .dk .dk-inspect-tabs [role="tab"] { border: 0; background: none; color: var(--dk-icon-muted); font: inherit; font-size: 13px; line-height: 19px; font-weight: 500; padding: 3px 8px; border-radius: 3px; cursor: pointer; }
      .dk .dk-inspect-tabs [role="tab"]:hover { background: var(--dk-icon-hover); }
      .dk .dk-inspect-tabs [role="tab"][aria-selected="true"] { background: var(--dk-selected-fill); color: var(--dk-tab-selected-fg); }
      .dk .dk-inspect-close:focus-visible, .dk .dk-inspect-tabs [role="tab"]:focus-visible { outline: 2px solid var(--dk-focus); outline-offset: -2px; }
      .dk .dk-inspect-body { flex: 1 1 auto; min-height: 0; overflow: auto; padding: 19px 20px 16px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; line-height: 19px; }
      .dk .dk-inspect-panel { padding: 0; }
      .dk .dk-inspect-panel pre { margin: -6px 0 0; font: inherit; white-space: pre; color: var(--dk-syntax-punctuation); }
      .dk .dk-inspect-panel pre code { font: inherit; }
      .dk .dk-inspect-tree { list-style: none; margin: 0; padding: 0; }
      .dk .dk-inspect-tree .dk-inspect-tree { padding-left: 20px; }
      .dk .dk-inspect-tree li { overflow-wrap: anywhere; }
      .dk .dk-inspect-tree summary { display: block; list-style: none; cursor: pointer; }
      .dk .dk-inspect-tree summary::-webkit-details-marker { display: none; }
      .dk .dk-inspect-tree summary::before { content: "▸"; display: inline-block; width: 1.5ch; margin-left: -1.5ch; color: var(--dk-syntax-punctuation); }
      .dk .dk-inspect-tree details[open] > summary::before { content: "▾"; }
      .dk .dk-inspect-tree summary:hover { background: var(--dk-card-hover); }
      .dk .dk-inspect-tree summary:focus-visible { outline: 2px solid var(--dk-focus); outline-offset: -2px; }
      .dk .dk-inspect-key { margin-right: 1ch; color: var(--dk-syntax-property); }
      .dk .dk-inspect-count, .dk .dk-inspect-value { color: var(--dk-syntax-constant); }
      .dk .dk-inspect-value[data-type="string"] { color: var(--dk-syntax-string); }
      .dk .dk-doc-menu-button { border: 0; background: none; color: var(--fg-muted); font: inherit; line-height: 1; padding: 4px 8px; border-radius: 6px; cursor: pointer; }
      .dk .dk-doc-menu-button:hover, .dk .dk-doc-menu-button[aria-expanded="true"] { background: var(--bg-accent); color: var(--fg); }
      .dk .dk-doc-menu-button:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-create-new, .dk .dk-list-options { margin-left: auto; display: inline-flex; align-items: center; }
      .dk .dk-create-new + .dk-list-options { margin-left: 0; }
      .dk .dk-menu { box-sizing: border-box; min-width: 160px; padding: 4px; border: 0; border-radius: 6px; background: var(--dk-bg); color: var(--dk-menu-fg); box-shadow: var(--dk-popover-shadow); }
      .dk .dk-menu:popover-open { display: flex; flex-direction: column; gap: 4px; }
      .dk .dk-menu .dk-menu-label { padding: 10px 12px 6px; font-size: 9.5px; line-height: 11px; letter-spacing: 0.5px; font-weight: 600; text-transform: uppercase; color: var(--dk-fg); }
      .dk .dk-menu .dk-menu-sep { width: 100%; margin: 0; border: 0; border-top: 1px solid var(--dk-border); }
      .dk .dk-menu-item { box-sizing: border-box; display: flex; align-items: center; gap: 6px; width: 100%; padding: 7px 12px; border: 0; border-radius: 3px; background: none; color: var(--dk-menu-fg); font: inherit; font-size: 13px; line-height: 19px; font-weight: 500; text-align: start; text-decoration: none; white-space: nowrap; cursor: pointer; }
      .dk .dk-menu-item:focus { outline: none; }
      .dk .dk-menu-icon { order: -1; display: flex; margin: -1px 0 -1px -6px; color: var(--dk-icon-muted); }
      .dk .dk-menu-icon svg { width: 21px; height: 21px; }
      .dk .dk-menu-icon svg[stroke-width] { stroke-width: 1.4; }
      .dk .dk-menu-item[aria-checked="true"]::after { content: "✓"; margin-left: auto; padding-left: 16px; color: var(--dk-icon-muted); }
      .dk .dk-menu-item[aria-disabled="true"] { background: none; cursor: default; color: color-mix(in srgb, var(--dk-menu-fg) 14%, var(--dk-bg)); }
      .dk .dk-menu-item.danger { color: var(--dk-menu-danger); }
      .dk .dk-menu-item.danger .dk-menu-icon { color: var(--dk-menu-danger-icon); }
      .dk :is(.dk-menu .dk-menu-item:hover, .dk-menu:not(:hover) .dk-menu-item:focus-visible):not(:disabled, [aria-disabled="true"]) { background: var(--dk-selected); color: var(--dk-menu-hover-fg); }
      .dk :is(.dk-menu .dk-menu-item:hover, .dk-menu:not(:hover) .dk-menu-item:focus-visible):not(:disabled, [aria-disabled="true"]) .dk-menu-icon { color: var(--dk-menu-hover-icon); }
      .dk :is(.dk-menu .dk-menu-item:hover, .dk-menu:not(:hover) .dk-menu-item:focus-visible):not(:disabled, [aria-disabled="true"])::after { color: inherit; }
      .dk :is(.dk-menu .dk-menu-item.danger:hover, .dk-menu:not(:hover) .dk-menu-item.danger:focus-visible):not(:disabled, [aria-disabled="true"]) { background: var(--dk-menu-danger-hover); }
      .dk :is(.dk-menu .dk-menu-item.danger:hover, .dk-menu:not(:hover) .dk-menu-item.danger:focus-visible):not(:disabled, [aria-disabled="true"]) .dk-menu-icon { color: var(--dk-menu-danger-hover-icon); }
      .dk .dk-bone { display: block; height: 10px; width: 60%; border-radius: 5px; background: var(--border); }
      .dk .dk-skeleton .pane-item { cursor: default; }
      .dk .dk-skeleton .pane-item:nth-child(even) .dk-bone { width: 42%; }
      .dk [data-desk-leaving] { display: none; }
      .dk .dk-pane:not(.dk-doc) > .pane-header { box-sizing: border-box; height: 49px; min-height: 49px; padding: 0 12px 0 20px; gap: 4px; border-bottom: 0; }
      .dk .dk-pane:not(.dk-doc) > .pane-header .pane-header-title { flex: 1; min-width: 0; font-size: 13px; line-height: 19px; font-weight: 600; color: var(--dk-fg-header); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .dk-pane:not(.dk-doc) > .pane-header .icon-btn { box-sizing: border-box; flex: none; width: 25px; height: 25px; margin: 0; padding: 0; display: grid; place-items: center; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); }
      .dk .dk-pane:not(.dk-doc) > .pane-header .icon-btn:hover { background: var(--dk-icon-btn-hover); color: var(--dk-icon-btn-hover-fg); }
      .dk .dk-pane:not(.dk-doc) > .pane-header .icon-btn svg { width: 21px; height: 21px; }
      .dk:not([data-narrow]) .dk-pane:not(.dk-doc) > .pane-header .dk-close:not(:focus-visible) { position: absolute; width: 1px; height: 1px; min-width: 0; min-height: 0; margin: -1px; padding: 0; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
      .dk .dk-list-search { position: relative; margin: -1px 12px 7px; padding: 0; border: 0; }
      .dk .dk-list-search .search-icon { position: absolute; left: 2px; top: 2px; color: var(--dk-muted); pointer-events: none; }
      .dk .dk-list-search .search-icon > svg { display: block; width: 21px; height: 21px; }
      .dk .dk-list-search input { box-sizing: border-box; width: 100%; height: auto; min-height: 0; margin: 0; border: 0; outline: none; box-shadow: none; background: none; font: inherit; font-size: 13px; line-height: 19px; padding: 3px 8px 3px 29px; color: var(--dk-fg); border-radius: 3px; }
      .dk .dk-list-search input::placeholder { color: var(--dk-placeholder); }
      .dk .dk-list-search input:focus-visible { box-shadow: inset 0 0 0 1px var(--dk-focus-ring); }
      .dk .dk-list-search input::-webkit-search-cancel-button { display: none; }
      .dk .dk-list-search .search-clear { position: absolute; right: 2px; top: 0; box-sizing: border-box; width: 25px; height: 25px; margin: 0; padding: 0; display: grid; place-items: center; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
      .dk .dk-list-search .search-clear:hover { background: var(--dk-icon-btn-hover); color: var(--dk-icon-btn-hover-fg); }
      .dk .dk-list-search .search-clear:focus-visible { outline: none; box-shadow: inset 0 0 0 1px var(--dk-focus-ring); }
      .dk .dk-list-search .search-clear svg { display: block; width: 21px; height: 21px; }
      .dk .pane-divider { margin: 4px 0; padding: 0; border: 0; border-top: 1px solid var(--dk-border); }
      .dk .dk-media { box-sizing: border-box; width: 33px; height: 33px; flex: none; display: grid; place-items: center; overflow: hidden; border-radius: 2px; box-shadow: inset 0 0 0 1px var(--dk-border); color: var(--dk-muted); background: var(--dk-bg); }
      .dk .dk-media svg { width: 21px; height: 21px; }
      .dk .dk-media img { width: 100%; height: 100%; object-fit: cover; }
      .dk .dk-media:has(> img) { box-shadow: none; background: none; }
      .dk .dk-status { display: flex; align-items: center; flex: none; }
      .dk .dk-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--dk-published); margin: 0 7px 0 12px; }
      .dk .dk-ring { width: 7px; height: 7px; border-radius: 50%; box-shadow: inset 0 0 0 1.5px var(--dk-caution-dot); margin-left: 8px; }
      .dk .dk-ring + .dk-dot { margin-left: 8px; }
      .dk .dk-row > a.pane-item.selected .dk-media { background: transparent; color: var(--dk-on-selected); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--dk-on-selected) 30%, transparent); }
      .dk .dk-row > a.pane-item.selected .dk-dot { background: var(--dk-dot-on-selected); }
      .dk .dk-row > a.pane-item.selected .dk-ring { box-shadow: inset 0 0 0 1.5px var(--dk-on-selected); }
      .dk [data-pane-index]:has(~ [data-pane-index]:not([data-desk-leaving]) ~ [data-pane-index]:not([data-desk-leaving])) .dk-row > a.pane-item.selected .dk-media { background: var(--dk-bg); color: var(--dk-muted); box-shadow: inset 0 0 0 1px var(--dk-border); }
      .dk [data-pane-index]:has(~ [data-pane-index]:not([data-desk-leaving]) ~ [data-pane-index]:not([data-desk-leaving])) .dk-row > a.pane-item.selected .dk-dot { background: var(--dk-published); }
      .dk [data-pane-index]:has(~ [data-pane-index]:not([data-desk-leaving]) ~ [data-pane-index]:not([data-desk-leaving])) .dk-row > a.pane-item.selected .dk-ring { box-shadow: inset 0 0 0 1.5px var(--dk-caution-dot); }
      .dk .dk-row-title { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .dk-row-sub { display: block; margin-top: -2px; font-weight: 400; font-size: 13px; line-height: 19px; color: var(--dk-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .desk-divider { margin: 4px 0 8px; padding: 7px 8px 6px; border-bottom: 1px solid var(--dk-border); font-size: 13px; line-height: 19px; font-weight: 600; color: var(--dk-muted); }
      .dk .dk-sort { display: flex; align-items: center; gap: 8px; padding: 8px 16px; border-bottom: 1px solid var(--border-subtle); font-size: var(--text-xs); color: var(--fg-muted); }
      .dk .dk-more { margin: 12px 16px; }
      .dk .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
      .dk .dk-edit { display: flex; flex-direction: column; min-width: 0; }
      .dk .dk-edit > .pane-layout { flex: 1 1 auto; min-height: 0; }
      .dk fieldset.editor-field { border: 0; margin-inline: 0; padding: 0; min-width: 0; }
      .dk fieldset.editor-field > legend { padding: 0; }
      .dk .dk-edit-refs { padding: 8px 48px 8px 16px; border-bottom: 1px solid var(--border-subtle); }
      .dk-search-dialog { box-sizing: border-box; inset: 0; width: min(800px, calc(100vw - 32px)); max-width: none; height: fit-content; max-height: min(735px, calc(88vh - 20px)); margin: 12vh auto auto; padding: 0; border: 0; border-radius: 6px; background: var(--dk-bg); color: var(--dk-fg); box-shadow: var(--dk-toast-shadow); overflow: hidden; font-size: 13px; line-height: 19px; }
      .dk-search-dialog[open] { display: flex; flex-direction: column; }
      .dk-search { display: flex; flex-direction: column; min-height: 0; }
      .dk .dk-search-bar { display: flex; align-items: center; gap: 4px; padding: 4px 8px; border-bottom: 1px solid var(--dk-border); color: var(--dk-muted); }
      .dk .dk-search-bar > svg { flex: none; margin: 0 2px; }
      .dk .dk-search-bar > form:first-of-type { flex: 1; min-width: 0; display: flex; }
      .dk .dk-search-bar input[type="search"] { flex: 1; min-width: 0; padding: 7px 0; border: 0; outline: none; background: none; color: var(--dk-fg); font: inherit; font-size: 13px; font-weight: 400; }
      .dk .dk-search-bar input[type="search"]::placeholder { color: var(--dk-placeholder); }
      .dk .dk-search-bar input[type="search"]::-webkit-search-cancel-button { appearance: none; }
      .dk .dk-search-close { display: grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
      .dk .dk-search-close:hover { background: var(--dk-card-hover); }
      .dk .dk-search-close:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: -2px; }
      .dk-search-hits { position: static; width: auto; display: flex; flex-direction: column; min-height: 0; padding: 8px; }
      .dk .dk-search-hits > [role="listbox"] { flex: 0 1 auto; min-height: 0; overflow: auto; display: flex; flex-direction: column; gap: 4px; }
      .dk .dk-search-empty { margin: 4px; font-size: 13px; color: var(--dk-muted); }
      .dk a.dk-search-hit { box-sizing: border-box; display: flex; align-items: center; gap: 8px; min-height: 49px; margin: 0; padding: 5px 8px; border: 0; border-radius: 3px; background: none; color: var(--dk-fg); font-size: 13px; line-height: 19px; font-weight: 400; text-decoration: none; }
      .dk a.dk-search-hit .pane-item-label { flex: 1; min-width: 0; }
      .dk a.dk-search-hit .dk-status { justify-content: center; width: 17px; }
      .dk a.dk-search-hit .dk-status > * { flex: none; margin: 0; }
      .dk a.dk-search-hit .dk-row-title { display: block; font-weight: 500; color: var(--dk-fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk a.dk-search-hit:is(:hover, [aria-selected="true"]) { background: var(--dk-card-hover); }
      .dk a.dk-search-hit:is(:hover, [aria-selected="true"]) .dk-row-title { color: var(--dk-row-hover-fg); }
      .dk a.dk-search-hit:is(:hover, [aria-selected="true"]) .dk-media { color: var(--dk-row-hover-muted); }
      .dk .dk-badge { flex: none; margin-right: -3px; padding: 0 4px; border-radius: 9999px; background: var(--dk-fill-soft); color: var(--dk-badge-fg); font-size: 13px; font-weight: 400; line-height: 17px; }
      .dk a.dk-search-hit[aria-selected="true"] .dk-badge { background: var(--dk-badge-lit-bg); color: var(--dk-badge-lit-fg); }
      @media (max-width: 599px) { .dk-search-dialog { width: 100%; height: 100%; max-height: none; margin: 0; border-radius: 0; box-shadow: none; } }
      .dk .dk-refs { display: flex; flex-wrap: wrap; gap: 6px; font-size: var(--text-sm); }
      .dk .dk-ref { padding: 2px 8px; border: 1px solid var(--fg-dim); border-radius: 6px; color: var(--fg); text-decoration: none; }
      .dk .dk-ref:hover, .dk .dk-ref[aria-current] { background: var(--bg-accent); border-color: var(--primary); }
      .dk .dk-ref:focus-visible { outline: 2px solid var(--primary); outline-offset: -2px; }
      .dk .dk-ref-missing { color: var(--fg-muted); }
      .dk .dk-doc > .pane-header { flex: none; box-sizing: border-box; height: 51px; min-height: 51px; gap: 4px; padding: 0 12px; font-size: 13px; line-height: 19px; font-weight: 600; color: var(--dk-head-fg); }
      .dk .dk-doc > .pane-header > .pane-header-title { flex: 1 1 0; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .dk .dk-doc:has(.dk-big-title) > .pane-header > .pane-header-title:not(:has(nav)) { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
      .dk .dk-doc > .pane-header .icon-btn { display: inline-grid; place-items: center; box-sizing: border-box; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-head-icon); font-size: 17px; line-height: 1; text-decoration: none; }
      .dk .dk-doc > .pane-header .icon-btn svg { width: 21px; height: 21px; }
      .dk .dk-doc > .pane-header .icon-btn:hover { background: var(--dk-head-hover); color: var(--dk-head-hover-fg); }
      .dk .dk-chips { display: flex; align-items: center; gap: 4px; min-width: 0; margin-right: auto; }
      .dk .dk-chips .presence-dots { margin: 0 6px 0 0; }
      .dk .dk-chip { display: inline-flex; align-items: center; gap: 8px; min-width: 0; padding: 3px 10px; border-radius: 999px; font-size: 13px; line-height: 19px; font-weight: 500; white-space: nowrap; color: var(--dk-head-fg); box-shadow: inset 0 0 0 1px var(--dk-chip-ring); }
      .dk .dk-chip-label { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
      .dk .dk-chip[data-selected] { color: var(--dk-chip-selected-fg); }
      .dk .dk-chip[data-active] { background: var(--dk-chip-active-bg); box-shadow: none; }
      .dk .dk-chip[data-tone="positive"] { color: var(--dk-chip-positive-fg); }
      .dk .dk-chip[data-off] { color: var(--dk-chip-off-fg); background: var(--dk-chip-off-bg); box-shadow: inset 0 0 0 1px var(--dk-chip-off-ring); }
      .dk .dk-chip-dot { flex: none; width: 5px; height: 5px; border-radius: 50%; }
      .dk .dk-chip-dot-published { background: var(--dk-published); }
      .dk .dk-chip-dot-draft { background: var(--dk-caution-dot); }
      .dk .dk-chip[data-off] .dk-chip-dot { background: var(--dk-line-strong); }
      .dk .dk-edit .editor-panel[role=main] > .editor-header { visibility: hidden; height: 0; min-height: 0; padding: 0; border: 0; overflow: hidden; }
      .dk .dk-edit .editor-panel[role=main] > .editor-header h1 { visibility: visible; }
      .dk .dk-doc-menu-list a[role="menuitem"] { box-sizing: border-box; text-decoration: none; }
      @media (pointer: coarse) {
        .dk .pane-item { min-height: 44px; }
        .dk .dk-row > .pane-item { height: auto; min-height: 44px; }
        .dk .dk-list-search .search-clear { width: 44px; height: 44px; top: -10px; }
        .dk:not([data-narrow]) .dk-pane:not(.dk-doc) > .pane-header .dk-close:not(:focus-visible) { position: static; width: auto; height: auto; min-width: 44px; min-height: 44px; margin: 0 -12px 0 0; padding: 4px 8px; overflow: visible; clip-path: none; white-space: normal; }
        .dk .dk-close { display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; min-width: 44px; min-height: 44px; margin-right: -12px; }
        .dk .dk-edit-refs { padding-right: 60px; }
        .dk .dk-split { justify-content: center; box-sizing: border-box; min-width: 44px; min-height: 44px; }
        .dk .dk-doc-menu-button { display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; min-width: 44px; min-height: 44px; }
        .dk .dk-menu-item { min-height: 44px; }
        .dk .dk-inspect-close, .dk .dk-inspect-tabs [role="tab"] { min-width: 44px; min-height: 44px; }
        .dk .dk-ref { display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; min-width: 44px; min-height: 44px; }
      }
      /* The desk's navbar (Desk.Navbar): TanStack's .navbar, 52 px, 13/19 w500,
         text tabs, and one More popover at the end. Only where a desk is. */
      .studio-shell:has(.dk) .studio-bar { height: 52px; min-height: 52px; padding-inline: 12px; font-size: 13px; line-height: 19px; font-weight: 500; background: var(--dk-nav-bg); border-bottom: 1px solid var(--dk-nav-border); }
      html[data-width-bucket="narrow"] .studio-shell:has(.dk) .studio-bar, html[data-width-bucket="phone"] .studio-shell:has(.dk) .studio-bar { height: auto; }
      .studio-shell:has(.dk) .dk-nav { align-items: center; gap: 4px; }
      .studio-shell:has(.dk) .dk-nav .dk-nav-tab { width: auto; height: auto; padding: 3px 8px; border-radius: 3px; color: var(--dk-nav-fg); text-decoration: none; transition: none; }
      .studio-shell:has(.dk) .dk-nav .dk-nav-tab:hover { background: var(--dk-nav-hover); color: var(--dk-nav-hover-fg); }
      .studio-shell:has(.dk) .dk-nav .dk-nav-tab.active, .studio-shell:has(.dk) .dk-nav .dk-nav-tab.active:hover { background: var(--dk-nav-selected); color: var(--dk-nav-selected-fg); }
      .studio-shell:has(.dk) .dk-nav .dk-nav-more { box-sizing: border-box; width: 25px; height: 25px; margin: 0; padding: 0; display: grid; place-items: center; border: 0; border-radius: 3px; background: none; color: var(--dk-nav-fg); cursor: pointer; }
      .studio-shell:has(.dk) .dk-nav .dk-nav-more:hover { background: var(--dk-nav-hover); color: var(--dk-nav-hover-fg); }
      .studio-shell:has(.dk) .dk-nav .dk-nav-more svg { display: block; width: 21px; height: 21px; }
      .studio-shell:has(.dk) .dk-nav .dk-nav-tab:focus-visible, .studio-shell:has(.dk) .dk-nav .dk-nav-more:focus-visible, .studio-shell:has(.dk) .dk-nav-more-list .dk-nav-item:focus-visible { outline: none; box-shadow: inset 0 0 0 1px var(--dk-nav-focus); }
      .studio-shell:has(.dk) .dk-nav-more-list { min-width: 180px; padding: 4px; background: var(--bg-card); color: var(--fg); border: 1px solid var(--border-subtle); border-radius: 8px; }
      .studio-shell:has(.dk) .dk-nav-more-list .dk-nav-item { display: flex; align-items: center; justify-content: flex-start; width: auto; height: auto; padding: 6px 10px; border-radius: 4px; color: inherit; text-decoration: none; }
      .studio-shell:has(.dk) .dk-nav-more-list .dk-nav-item:hover, .studio-shell:has(.dk) .dk-nav-more-list .dk-nav-item.active { background: var(--bg-accent); }
      .studio-shell:has(.dk) .dk-nav-more-list .studio-tab-disabled { opacity: 0.45; cursor: not-allowed; }
      @media (pointer: coarse) {
        .studio-shell:has(.dk) .dk-nav .dk-nav-tab { min-height: 44px; display: inline-flex; align-items: center; }
        .studio-shell:has(.dk) .dk-nav .dk-nav-more { width: 44px; height: 44px; }
        .studio-shell:has(.dk) .dk-nav-more-list .dk-nav-item { min-height: 44px; }
      }
    </style>
    """
  end
end
