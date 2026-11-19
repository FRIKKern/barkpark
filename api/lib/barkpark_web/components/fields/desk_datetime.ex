defmodule BarkparkWeb.Components.Fields.DeskDatetime do
  @moduledoc """
  A `datetime` field in the desk, as the TanStack Studio draws it
  (barkpark-studio `DateTimeInput`, Sanity's date-time input, J31).

    * A text box in local time, `2026-09-06 11:00`, with an "Open calendar"
      button at its end. What is typed is committed when it reads as a date,
      on Enter or on leaving the box; an empty box clears the field; anything
      else is marked, and an alert says the format. Half-typed dates never
      land.
    * The calendar (`bp-desk-datepicker.js`): a dialog named "Select date"
      with a month select, the year between two year buttons, a grid of days
      driven by the keyboard, the time, and "Set to current time".
    * The value is stored as an ISO instant in UTC, as TanStack stores it
      (`2026-09-07T09:00:00.000Z`).

  As in the old Studio (`FieldInputs`), the form posts only a hidden input;
  the box and the calendar sit in a `phx-update="ignore"` part, and
  `BarkparkDatetimeField` (bp-datetime-field.js) converts between them and
  keeps an unposted edit through a redraw.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  @doc "The field, from `FieldInputs.input/1`'s assigns."
  def datetime(%{field: %{"name" => name} = field} = assigns) do
    value = Map.get(assigns.editor_form || %{}, name, "")
    doc = Barkpark.Content.DraftId.published_id(to_string(assigns.doc_key))

    assigns =
      assign(assigns,
        n: name,
        v: if(is_binary(value), do: value, else: ""),
        doc: doc,
        required:
          Barkpark.Content.Validation.rules_at(field["validation"], :error)["required"] == true,
        locale: Gettext.get_locale(BarkparkWeb.Gettext),
        strings: Jason.encode!(strings())
      )

    ~H"""
    <div id={"bp-dt-wrap-#{@n}"} phx-hook="BarkparkDatetimeField" class="bp-datetime-field datetime" data-value={@v} data-doc={@doc} data-locale={@locale} data-strings={@strings}>
      <input type="hidden" name={"doc[#{@n}]"} value={@v} data-datetime-value phx-debounce="300" />
      <div id={"bp-dt-pick-#{@n}"} phx-update="ignore" class="bp-datetime-picker">
        <div class="datetime-box">
          <input type="text" id={@n} class="form-input input" autocomplete="off" data-datetime-text aria-required={@required && "true"} />
          <button type="button" class="icon-btn" aria-label={gettext("Open calendar")} title={gettext("Select date")} aria-expanded="false" data-datetime-open>
            <svg width="25" height="25" viewBox="0 0 25 25" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" aria-hidden="true">
              <path d="M5.5 18.5H19.5V6.5H5.5V18.5Z" />
              <path d="M16.5 8V4M8.5 8V4M8 12.5H10M8 15.5H10M11.5 12.5H13.5M11.5 15.5H13.5M15 12.5H17M15 15.5H17M12.5 8V4M5.5 9.5H19.5" />
            </svg>
          </button>
        </div>
        <p class="field-error" role="alert" hidden data-datetime-error></p>
      </div>
    </div>
    """
  end

  # The calendar's words, in the studio's language (the month and day names
  # are the browser's Intl).
  defp strings do
    %{
      select_date: gettext("Select date"),
      month: gettext("Month"),
      year: gettext("Year"),
      prev_year: gettext("Go to previous year"),
      next_year: gettext("Go to next year"),
      select_time: gettext("Select time"),
      now: gettext("Set to current time"),
      example: gettext("e.g. %{example}", example: "%{example}"),
      invalid: gettext("Not a valid date. Use the format %{format}.", format: "%{format}")
    }
  end
end
