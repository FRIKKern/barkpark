defmodule BarkparkWeb.Studio.Desk.VisionStyle do
  @moduledoc """
  The look of the desk's Vision (`Desk.Vision`), after the TanStack Studio's
  `styles.css` (`.vision*`, `.json-tree`), which follows Sanity's:

  - The perspective and the query URL on top; the query over its Params
    (left, 301 px at most, half each) and the result (the rest) below, each
    scrolled in its own column, so the page itself never scrolls. Params
    that are not a JSON object turn their pane the critical tone, with an
    error icon in its top right.
  - The result is a folding JSON tree in the syntax colours; a refused
    query turns the result column the critical tone.
  - Under 600 px one column, scrolled inside Vision: the selects, then the
    query, then the result. On a touch screen (`pointer: coarse`) the
    selects and buttons are 44 px, the result tree's rows too.

  Colours are the desk's tokens (`--dk-*`, `Desk.Style`).
  """
  use Phoenix.Component

  def sheet(assigns) do
    ~H"""
    <style>
      .dk .dk-vision { box-sizing: border-box; flex: 1 1 auto; align-self: stretch; width: 100%; min-width: 0; min-height: 0; display: flex; flex-direction: column; overflow: hidden; font-size: 13px; color: var(--dk-fg); background: var(--dk-bg); }
      .dk .dk-vision-top { display: flex; flex-wrap: wrap; gap: 8px; padding: 11px 16px 13px; border-bottom: 1px solid var(--dk-border); }
      .dk .dk-vision-field, .dk .dk-vision-url { display: flex; flex-direction: column; flex: 0 1 228px; min-width: 0; }
      .dk .dk-vision-url { flex: 1 1 320px; }
      .dk .dk-vision-url[hidden], .dk .dk-vision-field[hidden] { display: none; }
      .dk .dk-vision-input[aria-invalid="true"] { box-shadow: inset 0 0 0 1px var(--dk-menu-danger); }
      .dk .dk-vision-label { font-size: 10.8px; line-height: 12px; letter-spacing: .5px; color: var(--dk-muted); }
      .dk .dk-vision-top .dk-vision-label { display: flex; flex-wrap: wrap; align-items: baseline; column-gap: 4px; padding: 7px 0 10px; color: var(--dk-fg); }
      .dk .dk-vision-input { box-sizing: border-box; width: 100%; min-width: 0; height: 33px; padding: 0 8px; border: 0; border-radius: 3px; background: var(--dk-bg); box-shadow: inset 0 0 0 1px var(--dk-field-ring); color: var(--dk-fg); font: inherit; font-size: 13px; }
      .dk .dk-vision-input:hover { box-shadow: inset 0 0 0 1px var(--dk-field-hover-ring); }
      .dk .dk-vision-input:focus-visible { outline: none; box-shadow: inset 0 0 0 1px var(--dk-focus-ring); }
      .dk .dk-vision-copy { all: unset; cursor: pointer; color: var(--dk-selected); }
      .dk .dk-vision-copy:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: 1px; }
      .dk .dk-vision-copied { color: var(--dk-muted); }
      .dk .dk-vision-url-row { display: flex; gap: 4px; }
      .dk .dk-vision-url-row .icon-btn { flex: none; display: grid; place-items: center; width: 33px; padding: 0; border: 0; border-radius: 3px; background: none; box-shadow: inset 0 0 0 1px var(--dk-field-ring); color: var(--dk-icon-muted); cursor: pointer; }
      .dk .dk-vision-url-row .icon-btn:hover { background: var(--dk-icon-btn-hover); color: var(--dk-icon-btn-hover-fg); }
      .dk .dk-vision-url-row .icon-btn svg { width: 21px; height: 21px; }
      .dk .dk-vision-body { flex: 1 1 auto; min-height: 0; display: grid; grid-template-columns: minmax(240px, 301px) minmax(0, 1fr); grid-template-rows: minmax(0, 1fr); }
      .dk .dk-vision-query { display: flex; flex-direction: column; min-height: 0; border-right: 1px solid var(--dk-border); }
      .dk .dk-vision-pane { position: relative; flex: 1 1 0; display: flex; min-height: 0; }
      .dk .dk-vision-params { border-top: 1px solid var(--dk-border); }
      .dk .dk-vision-params[data-invalid] { background: color-mix(in srgb, var(--dk-critical-icon) 6%, var(--dk-bg)); }
      .dk .dk-vision-params[data-invalid] > .dk-vision-label { color: var(--dk-menu-danger); }
      .dk .dk-vision-params-error { position: absolute; z-index: 1; top: 8px; right: 5px; display: grid; place-items: center; width: 25px; height: 25px; color: var(--dk-critical-icon); }
      .dk .dk-vision-params-error[hidden] { display: none; }
      .dk .dk-vision-params-error svg { width: 25px; height: 25px; }
      .dk .dk-vision-pane > .dk-vision-label { position: absolute; z-index: 1; top: 14px; left: 33px; }
      .dk .dk-vision-code { font: 12px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--dk-fg); }
      .dk textarea.dk-vision-code { box-sizing: border-box; flex: 1 1 auto; width: 100%; min-height: 0; margin: 0; padding: 32px 4px 4px 33px; resize: none; border: 0; outline: none; background: none; }
      .dk textarea.dk-vision-code:focus-visible { box-shadow: inset 0 0 0 1px var(--dk-focus-ring); border-radius: 3px; }
      .dk .dk-vision-actions { display: flex; gap: 12px; padding: 12px; border-top: 1px solid var(--dk-border); }
      .dk .dk-vision-fetch { flex: 1; display: inline-flex; align-items: center; justify-content: center; gap: 6px; height: 33px; padding: 0 18px 0 12px; border: 0; border-radius: 3px; background: var(--dk-selected); color: var(--dk-on-selected); font: inherit; font-size: 13px; font-weight: 500; cursor: pointer; }
      .dk .dk-vision-fetch:not(.dk-vision-listen):hover { background: color-mix(in srgb, var(--dk-selected) 88%, var(--dk-fg)); }
      .dk .dk-vision-fetch:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: 1px; }
      .dk .dk-vision-fetch[aria-disabled="true"] { cursor: default; }
      .dk .dk-vision-fetch:not(.dk-vision-listen)[aria-disabled="true"] { opacity: .5; }
      .dk .dk-vision-fetch svg { width: 21px; height: 21px; }
      .dk .dk-vision-fetch > span { display: inline-flex; }
      .dk .dk-vision-fetch > span[hidden] { display: none; }
      .dk .dk-vision-listen { background: var(--dk-bg-soft); box-shadow: inset 0 0 0 1px var(--dk-btn2-ring); color: var(--dk-btn2-fg); }
      .dk .dk-vision-listen svg { color: var(--dk-btn2-icon); }
      .dk .dk-vision-listen[aria-disabled="true"], .dk .dk-vision-listen[aria-disabled="true"] svg { color: var(--dk-chip-off-fg); }
      .dk .dk-vision-listen:hover:not([aria-disabled="true"]) { background: var(--dk-btn2-hover-bg); box-shadow: inset 0 0 0 1px var(--dk-btn2-hover-ring); color: var(--dk-btn2-hover-fg); }
      .dk .dk-vision-listen:hover:not([aria-disabled="true"]) svg { color: var(--dk-btn2-hover-icon); }
      .dk .dk-vision-out > .dk-vision-hint { margin: 0; color: var(--dk-muted); font-size: 12px; line-height: 17px; }
      .dk .dk-vision-result { display: flex; flex-direction: column; min-width: 0; min-height: 0; padding: 12px 12px 0; }
      .dk .dk-vision-result > .dk-vision-label { padding: 2px 0 4px; }
      .dk .dk-vision-out { flex: 1 1 auto; min-height: 0; overflow: auto; font-size: 16px; line-height: 23px; white-space: pre-wrap; word-break: break-word; }
      .dk .dk-vision-result:has(> .dk-vision-out[data-error]) { background: color-mix(in srgb, var(--dk-critical-icon) 6%, var(--dk-bg)); }
      .dk .dk-vision-result:has(> .dk-vision-out[data-error]) > .dk-vision-label { color: var(--dk-menu-danger); }
      .dk .dk-vision-out [role="alert"] p, .dk .dk-vision-out [role="alert"] pre { margin: 0; font: 13px/19px ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--dk-menu-danger); white-space: pre-wrap; }
      .dk .dk-vision-out [role="alert"] pre { margin-top: 22px; white-space: pre; overflow-x: auto; }
      .dk .dk-vision-foot { display: flex; flex-wrap: wrap; gap: 20px; align-items: center; min-height: 60px; margin: 0 -12px; padding: 12px 20px; border-top: 1px solid var(--dk-border); background: var(--dk-bg); color: var(--dk-muted); font-size: 15px; line-height: 23px; }
      .dk .dk-vision-save[hidden] { display: none; }
      .dk .dk-vision-save { display: inline-flex; align-items: center; gap: 8px; }
      .dk .dk-vision-save-btn { display: inline-flex; align-items: center; gap: 4px; padding: 5px 10px 5px 6px; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--dk-field-ring); color: var(--dk-fg); font-size: 13px; line-height: 19px; text-decoration: none; }
      .dk .dk-vision-save-btn:hover { background: var(--dk-icon-btn-hover); }
      .dk .dk-vision-save-btn:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: 1px; }
      .dk .dk-vision-save-btn svg { width: 21px; height: 21px; }
      .dk .json-tree, .dk .json-tree ul { list-style: none; margin: 0; padding: 0 0 0 20px; }
      .dk .json-tree { padding-left: 0; }
      .dk .json-toggle { position: relative; font: inherit; border: 0; background: none; padding: 0; cursor: pointer; color: inherit; text-align: left; }
      .dk .json-toggle:disabled { cursor: default; }
      .dk .json-toggle:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: 1px; border-radius: 2px; }
      .dk .json-arrow { position: absolute; left: -16px; width: 16px; color: var(--dk-syntax-punctuation); }
      .dk .json-key { color: var(--dk-syntax-property); }
      .dk :is(.json-brace, .json-count, .json-null) { color: var(--dk-syntax-punctuation); }
      .dk .json-string { color: var(--dk-syntax-string); }
      .dk :is(.json-number, .json-boolean) { color: var(--dk-syntax-constant); }
      .dk .json-leaf:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: 1px; border-radius: 2px; }
      .dk .json-more { font: inherit; border: 0; background: none; padding: 0; color: var(--dk-selected); cursor: pointer; }
      @media (max-width: 600px) {
        .dk .dk-vision { overflow-y: auto; }
        .dk .dk-vision-top { flex-direction: column; gap: 0; }
        .dk .dk-vision-field, .dk .dk-vision-url { flex: none; }
        .dk .dk-vision-body { flex: none; grid-template-columns: minmax(0, 1fr); grid-template-rows: none; }
        .dk .dk-vision-query { height: 60vh; border-right: 0; border-bottom: 1px solid var(--dk-border); }
        .dk .dk-vision-params { flex: 0 0 33%; }
        .dk .dk-vision-result { min-height: 40vh; }
      }
      @media (max-width: 768px) and (pointer: coarse) {
        .dk .dk-vision-input, .dk .dk-vision-fetch, .dk .dk-vision-url-row .icon-btn { min-height: 44px; }
        .dk .dk-vision-url-row .icon-btn { width: 44px; }
        .dk .dk-vision-save-btn, .dk .dk-vision-copy { box-sizing: border-box; min-height: 44px; display: inline-flex; align-items: center; }
        .dk .json-toggle, .dk .json-more { min-height: 44px; }
      }
    </style>
    """
  end
end
