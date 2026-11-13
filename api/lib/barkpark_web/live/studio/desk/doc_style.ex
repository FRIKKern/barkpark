defmodule BarkparkWeb.Studio.Desk.DocStyle do
  @moduledoc """
  The desk's document pane, drawn as the TanStack Studio draws it
  (barkpark-studio `app/src/styles.css`), over the Studio's own editor
  markup, which stays as the old Studio has it. Only rules under
  `.dk .dk-edit` are here, so the old Studio is not touched.

  The values are TanStack's, measured from its CSS (the form column
  `.doc-form`, the type label `.kind` and title `h1`, `.field`, its label and
  description, `.input`, the group tabs `.group-tabs [role=tab]`), light and
  dark. Its colours are its own tokens (`--fg`, `--muted`, `--line`, …),
  carried here as `--dk-*` properties on the edit pane; they are written as
  `rgb()` values from its hex.

    * The form is one centred column, 600 px wide, 28 px from the top.
    * Over it, the type's name and the document's title, large (the
      title heading mirrors the title field; the pane's heading is the
      Studio's own). A singleton has no type line, as TanStack's.
    * Group tabs are pills, not underlined.
    * A label is the field's name as written, 13 px, 500; a required
      field's mark is kept for screen readers only, as TanStack shows none.
    * 59 px under each field; 15 px from a label to its input.
    * The title steps down with the pane, not the 600 px column: 27 px at
      600 px and under, 21 px at 464 and under. TanStack queries its
      `.doc-column`; here that is the Studio's `.editor-panel`, already a
      container named `panel` (root.html.heex), as wide as the pane less any
      preview beside it.
    * An input is ringed, not bordered: a 1 px inset ring, darker under the
      pointer, blue with the focus. Generate is TanStack's secondary
      button (35 px, filled, ringed). A focused button, link or tab is
      outlined in the same blue, as TanStack's, not the Studio's green.
    * The pane is TanStack's page colour (`--dk-bg`, light and dark), and
      inputs sit on it.
  """

  use Phoenix.Component

  def sheet(assigns) do
    ~H"""
    <style>
      .dk .dk-edit {
        --dk-fg: rgb(37 40 55); --dk-muted: rgb(81 88 112); --dk-line: rgb(227 228 232); --dk-input-fg: rgb(13 14 18);
        --dk-selected-fill: rgb(238 238 241); --dk-tab-selected-fg: rgb(99 103 118); --dk-icon-muted: rgb(106 110 125);
        --dk-icon-btn-hover: rgb(246 246 248); --dk-focus-ring: rgb(85 107 252); --dk-input-hover-ring: rgb(187 189 201);
        --dk-danger-text: rgb(189 51 40); --dk-placeholder: rgb(148 153 173);
        --dk-bg-soft: rgb(246 246 248); --dk-btn2-fg: rgb(78 85 109); --dk-btn2-ring: rgb(230 230 234);
        --dk-btn2-hover-bg: rgb(238 238 241); --dk-btn2-hover-fg: rgb(53 58 77); --dk-btn2-hover-ring: rgb(222 222 228);
        --bg: var(--dk-bg); background: var(--bg);
      }
      html[data-theme="dark"] .dk .dk-edit {
        --dk-fg: rgb(228 229 233); --dk-muted: rgb(151 156 176); --dk-line: rgb(61 66 88); --dk-input-fg: rgb(228 229 233);
        --dk-selected-fill: rgb(42 45 63); --dk-tab-selected-fg: rgb(157 159 174); --dk-icon-muted: rgb(147 148 159);
        --dk-icon-btn-hover: rgb(33 35 47); --dk-focus-ring: rgb(89 111 252); --dk-input-hover-ring: rgb(61 66 88);
        --dk-danger-text: rgb(255 123 114); --dk-placeholder: rgb(85 92 117);
        --dk-bg-soft: rgb(25 26 36); --dk-btn2-fg: rgb(153 158 179); --dk-btn2-ring: rgb(38 40 55);
        --dk-btn2-hover-bg: rgb(33 35 47); --dk-btn2-hover-fg: rgb(193 195 208); --dk-btn2-hover-ring: rgb(46 49 65);
      }
      .dk .dk-edit .editor-body.editor-panel-main { max-width: none; padding: 28px max(20px, calc(50% - 300px)) 161px; }
      .dk .dk-edit .editor-meta { display: block; margin: 0 0 52px; color: var(--dk-muted); font-size: 13px; line-height: 19px; }
      .dk .dk-edit .dk-kind { font-size: 13px; line-height: 19px; color: var(--dk-muted); }
      .dk .dk-edit .dk-big-title { margin: 8px 0 0; font-size: 33px; line-height: 41px; font-weight: 700; color: var(--dk-fg); overflow-wrap: anywhere; }
      .dk .dk-edit[data-desk-document] .dk-kind { display: none; }
      .dk .dk-edit[data-desk-document] .dk-big-title { margin-top: -2px; }
      @container panel (max-width: 600px) { .dk .dk-edit .dk-big-title { font-size: 27px; line-height: 35px; } }
      @container panel (max-width: 464px) { .dk .dk-edit .dk-big-title { font-size: 21px; line-height: 29px; } }
      .dk .dk-edit .bp-tab-bar { gap: 8px; padding: 0; margin: -7px 0 79px; border-bottom: 0; }
      .dk .dk-edit .bp-tab { padding: 3px 8px; margin: 0; border: 0; border-radius: 3px; font-size: 13px; line-height: 19px; font-weight: 500; color: var(--dk-icon-muted); }
      .dk .dk-edit .bp-tab .bp-tab-label { line-height: 19px; }
      .dk .dk-edit .bp-tab:hover { background: var(--dk-icon-btn-hover); color: var(--dk-icon-muted); }
      .dk .dk-edit .bp-tab.is-active { background: var(--dk-selected-fill); color: var(--dk-tab-selected-fg); font-weight: 500; }
      .dk .dk-edit .bp-tab:focus-visible { outline: none; box-shadow: inset 0 0 0 1px var(--dk-focus-ring); }
      .dk .dk-edit .editor-field, .dk .dk-edit .editor-field-self-titled { margin-bottom: 59px; }
      .dk .dk-edit .editor-field-label, .dk .dk-edit .bp-field > legend { display: block; margin: 0 0 15px; padding: 0; font-size: 13px; line-height: 19px; font-weight: 500; letter-spacing: 0; text-transform: none; color: var(--dk-fg); }
      .dk .dk-edit .field-required { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
      .dk .dk-edit .editor-field-description, .dk .dk-edit .bp-field-description { margin: -9px 0 11px; font-size: 13px; line-height: 19px; color: var(--dk-muted); }
      .dk .dk-edit .form-input { height: auto; min-height: 35px; padding: 6px 12px; font-size: 15px; line-height: 23px; color: var(--dk-input-fg); background: var(--bg); border: 0; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--dk-line); }
      .dk .dk-edit textarea.form-input { padding: 6px 12px; line-height: 23px; }
      .dk .dk-edit .form-input::placeholder { color: var(--dk-placeholder); }
      .dk .dk-edit .form-input:hover:not(:focus, :disabled, [readonly]) { box-shadow: inset 0 0 0 1px var(--dk-input-hover-ring); }
      .dk .dk-edit .form-input:focus { outline: none; box-shadow: inset 0 0 0 1px var(--dk-focus-ring); }
      .dk .dk-edit .editor-field.has-error .form-input { box-shadow: inset 0 0 0 1px var(--destructive); }
      .dk .dk-edit button[phx-click="slug-generate"] { box-sizing: border-box; flex: none; height: 35px; padding: 0 12px; border: 0; border-radius: 3px; background: var(--dk-bg-soft); box-shadow: inset 0 0 0 1px var(--dk-btn2-ring); color: var(--dk-btn2-fg); font-size: 13px; line-height: 19px; font-weight: 500; }
      .dk .dk-edit button[phx-click="slug-generate"]:hover:not(:disabled) { background: var(--dk-btn2-hover-bg); box-shadow: inset 0 0 0 1px var(--dk-btn2-hover-ring); color: var(--dk-btn2-hover-fg); }
      .dk .dk-edit :where(button, a, [role=tab], [tabindex]):focus-visible { outline: 1px solid var(--dk-focus-ring); outline-offset: -1px; }
      .dk .dk-edit .field-errors, .dk .dk-edit .field-error { font-size: 13px; color: var(--dk-danger-text); }
    </style>
    """
  end
end
