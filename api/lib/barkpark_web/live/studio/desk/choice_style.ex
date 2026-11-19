defmodule BarkparkWeb.Studio.Desk.ChoiceStyle do
  @moduledoc """
  The look of a radio list and a date-time field in the desk's form
  (`DeskSelect`, `DeskDatetime`, `bp-desk-datepicker.js`), the TanStack
  Studio's (barkpark-studio `app/src/styles.css`: `.radio-box`, `.radio`,
  `.datetime`, `.datepicker`, `.dp-*`), in the desk's own colour tokens, so
  it follows light and dark.

    * A radio list is a box ringed 1 px, at least 43 px tall, 13 px in; its
      options 12 px apart in a row, or stacked 10 px apart. A radio is a
      17 px ringed circle, filled in the middle when chosen. Clear is a 25 px
      icon button on the chosen row.
    * A date-time is its text box with the calendar button in its last
      34 px, ruled off on its left. A box that does not read as a date is
      tinted, and the alert under it is in the danger ink.
    * The calendar is a 362 px popover 4 px under the box, centred under the
      date: the month select and the year with its two buttons, seven 46 px
      columns of 25 px days 4 px apart (other months' days muted, today
      tinted, the chosen day filled), and a ruled foot with the time and
      "Set to current time".

  On a touch screen (`pointer: coarse`) every control is at least 44 px:
  a radio's row, Clear, the calendar button, the month and year, the days,
  the time and "Set to current time".

  `DocStyle.sheet/1` draws these rules with the rest of the edit pane's.
  """

  @doc "The rules, for the edit pane's sheet."
  @spec css() :: String.t()
  def css do
    """
    .dk .dk-edit .radio-box { display: flex; align-items: center; min-height: 43px; padding: 0 13px; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--dk-line); }
    .dk .dk-edit .radio-box [role=group] { flex: 1; display: flex; flex-wrap: wrap; gap: 8px 12px; }
    .dk .dk-edit .radio-box[data-direction=vertical] { padding: 13px; }
    .dk .dk-edit .radio-box[data-direction=vertical] [role=group] { flex-direction: column; gap: 10px; }
    .dk .dk-edit .radio-row { display: flex; align-items: center; min-height: 17px; }
    .dk .dk-edit .radio { display: inline-flex; align-items: center; gap: 8px; font-size: 13px; line-height: 19px; color: var(--dk-fg); cursor: pointer; }
    .dk .dk-edit .radio input { appearance: none; flex: none; width: 17px; height: 17px; margin: 0; border-radius: 50%; background: var(--dk-bg); box-shadow: inset 0 0 0 1px var(--dk-line); cursor: pointer; }
    .dk .dk-edit .radio input:checked { background: radial-gradient(circle, var(--dk-fg-strong) 0 4.5px, var(--dk-bg) 5px); }
    .dk .dk-edit .radio input:focus-visible { outline: 2px solid var(--dk-focus-ring); outline-offset: 1px; }
    .dk .dk-edit .radio-box .icon-btn { display: inline-grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
    .dk .dk-edit .radio-box .icon-btn:hover { background: var(--dk-icon-btn-hover); color: var(--dk-icon-btn-hover-fg); }
    .dk .dk-edit .radio-box[data-direction=vertical] .radio-row .icon-btn { margin: -4px -1px -4px auto; }
    .dk .dk-edit .datetime { position: relative; }
    .dk .dk-edit .datetime-box { position: relative; }
    .dk .dk-edit .datetime-box .form-input { width: 100%; box-sizing: border-box; padding-right: 40px; }
    .dk .dk-edit .datetime-box .icon-btn { position: absolute; right: 1px; top: 1px; bottom: 1px; width: 34px; display: grid; place-items: center; padding: 0; border: 0; border-radius: 0 3px 3px 0; background: none; color: var(--dk-icon-muted); box-shadow: inset 1px 0 0 var(--dk-line); cursor: pointer; }
    .dk .dk-edit .datetime-box .icon-btn::before { content: ""; position: absolute; inset: 4px 4px 4px 5px; border-radius: 3px; }
    .dk .dk-edit .datetime-box .icon-btn:hover::before { background: var(--dk-icon-btn-hover); }
    .dk .dk-edit .datetime-box .icon-btn > svg { position: relative; }
    .dk .dk-edit .datetime[data-invalid] .form-input { background: var(--dk-diff-bg); }
    .dk .dk-edit .datetime .field-error { margin: 6px 0 0; font-size: 13px; line-height: 19px; color: var(--dk-danger-text); }
    .dk .dk-edit .datepicker { position: absolute; z-index: 20; top: calc(100% + 4px); left: max(-16px, calc((100% - 35px) / 2 - 181px)); width: 362px; box-sizing: border-box; padding: 8px; border-radius: 6px; background: var(--dk-bg); color: var(--dk-fg); box-shadow: var(--dk-popover-shadow); font-size: 13px; }
    .dk .dk-edit .dp-head { display: flex; align-items: center; gap: 4px; margin-bottom: 8px; }
    .dk .dk-edit .dp-head .icon-btn { display: inline-grid; place-items: center; width: 25px; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-icon-muted); cursor: pointer; }
    .dk .dk-edit .dp-head .icon-btn:hover { background: var(--dk-icon-btn-hover); }
    .dk .dk-edit .dp-month { position: relative; flex: 1; margin-right: 4px; }
    .dk .dk-edit .dp-month select { width: 100%; appearance: none; font: inherit; font-size: 13px; line-height: 19px; padding: 3px 29px 3px 8px; border: 0; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--dk-line); background: var(--dk-bg); color: var(--dk-input-fg); }
    .dk .dk-edit .dp-month svg { position: absolute; right: 2px; top: 50%; width: 21px; height: 21px; transform: translateY(-50%); color: var(--dk-muted); pointer-events: none; }
    .dk .dk-edit .dp-year { width: 48px; font: inherit; font-size: 13px; line-height: 19px; text-align: center; padding: 3px 8px; border: 0; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--dk-line); background: var(--dk-bg); color: var(--dk-input-fg); }
    .dk .dk-edit .dp-grid { display: grid; grid-template-columns: repeat(7, 46px); grid-auto-rows: 25px; gap: 4px; }
    .dk .dk-edit .dp-weekday { display: grid; place-items: center; font-weight: 500; line-height: 19px; color: var(--dk-fg); }
    .dk .dk-edit .dp-grid button { font: inherit; font-size: 13px; font-weight: 500; height: 25px; padding: 0; border: 0; border-radius: 3px; background: none; color: var(--dk-fg); cursor: pointer; }
    .dk .dk-edit .dp-grid button:hover { background: var(--dk-card-hover); }
    .dk .dk-edit .dp-grid button[data-outside] { font-weight: 400; color: var(--dk-muted); }
    .dk .dk-edit .dp-grid button[data-today] { background: var(--dk-hover-strong); color: var(--dk-fg-strong); }
    .dk .dk-edit .dp-grid button[data-selected] { background: var(--dk-selected); color: var(--dk-on-selected); }
    .dk .dk-edit .dp-grid button:focus-visible { outline: none; box-shadow: inset 0 0 0 2px var(--dk-selected); }
    .dk .dk-edit .dp-foot { display: flex; align-items: center; gap: 8px; margin: 16px -8px -8px; padding: 8px; border-top: 1px solid var(--dk-border); }
    .dk .dk-edit .dp-time input { width: 99px; height: 34px; box-sizing: border-box; font: inherit; font-size: 15px; line-height: 22px; padding: 6px 12px; border: 0; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--dk-line); background: var(--dk-bg); color: var(--dk-input-fg); }
    .dk .dk-edit .dp-foot .btn-text { padding: 3px 8px; font: inherit; font-size: 13px; line-height: 19px; border: 0; border-radius: 3px; background: none; color: var(--dk-menu-fg); cursor: pointer; }
    .dk .dk-edit .dp-foot .btn-text:hover { background: var(--dk-icon-btn-hover); }
    @media (pointer: coarse) {
      .dk .dk-edit .radio { min-height: 44px; min-width: 44px; }
      .dk .dk-edit .radio-box .icon-btn, .dk .dk-edit .dp-head .icon-btn { width: 44px; height: 44px; }
      .dk .dk-edit .radio-box[data-direction=vertical] .radio-row .icon-btn { margin: 0 -1px 0 auto; }
      .dk .dk-edit .datetime-box .form-input { min-height: 44px; padding-right: 50px; }
      .dk .dk-edit .datetime-box .icon-btn { width: 44px; top: 0; bottom: 0; }
      .dk .dk-edit .dp-month select, .dk .dk-edit .dp-year { min-height: 44px; }
      .dk .dk-edit .dp-grid { grid-auto-rows: 44px; }
      .dk .dk-edit .dp-grid button { height: 44px; }
      .dk .dk-edit .dp-time input, .dk .dk-edit .dp-foot .btn-text { min-height: 44px; }
    }
    """
  end
end
