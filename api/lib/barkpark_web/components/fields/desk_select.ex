defmodule BarkparkWeb.Components.Fields.DeskSelect do
  @moduledoc """
  A `select` field in the desk, as the TanStack Studio draws it
  (barkpark-studio `SelectInput`, Sanity's string list, J31).

    * The options are the field's `options`, or Sanity's `options.list`. A
      bare value is titled with its first letter capitalised (`idea` is shown
      "Idea" and stored `idea`); a `{value, title}` pair keeps its title.
    * `layout: "radio"` (on the field or in `options`) is a box of radios, a
      `group` named by the field's title, stacked unless `options.direction`
      is "horizontal". A Clear button (named "Clear") sits on the chosen row,
      or after the row of options when they lie in a row. Clear posts "" for
      the field through a hidden input that is off until it is pressed
      (`bp-desk-select.js`), so the field is unset, and the focus goes to the
      first option.
    * Otherwise a dropdown, as the old Studio's.

  With no option checked nothing posts: a stored value that is not an
  option is kept, as in the old Studio.
  """

  use Phoenix.Component
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content.SelectOptions

  @doc "The field, from `FieldInputs.input/1`'s assigns."
  def select(%{field: %{"name" => name} = field} = assigns) do
    value = scalar(Map.get(assigns.editor_form || %{}, name, ""))
    options = SelectOptions.titled(field["options"])

    required =
      Barkpark.Content.Validation.rules_at(field["validation"], :error)["required"] == true

    assigns =
      assign(assigns,
        n: name,
        v: value,
        opts: options,
        chosen: value != "" and value in Enum.map(options, & &1.value),
        required: required,
        title: field["title"] || name,
        horizontal: SelectOptions.horizontal?(field)
      )

    if SelectOptions.radio?(field), do: radios(assigns), else: dropdown(assigns)
  end

  defp radios(assigns) do
    ~H"""
    <div class="radio-box" data-direction={if @horizontal, do: "horizontal", else: "vertical"} data-field={@n}>
      <div role="group" id={@n} aria-label={@title}>
        <div :for={o <- @opts} class="radio-row">
          <label class="radio">
            <input type="radio" name={"doc[#{@n}]"} value={o.value} checked={o.value == @v} phx-debounce="100" />
            <span><%= o.label %></span>
          </label>
          <.clear :if={not @horizontal and @chosen and o.value == @v} />
        </div>
      </div>
      <.clear :if={@horizontal and @chosen} />
      <input type="hidden" name={"doc[#{@n}]"} value="" disabled data-radio-cleared />
    </div>
    """
  end

  defp clear(assigns) do
    ~H"""
    <button type="button" class="icon-btn" aria-label={gettext("Clear")} title={gettext("Clear")} data-radio-clear>
      <svg width="25" height="25" viewBox="0 0 25 25" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" aria-hidden="true">
        <path d="M7 11L4.56189 13.5L2 11" />
        <path d="M9.50001 15.5L15.5 9.5M9.5 9.5L15.5 15.5M4.56189 13.5C4.52104 13.1724 4.5 12.8387 4.5 12.5C4.5 8.08172 8.08172 4.5 12.5 4.5C16.9183 4.5 20.5 8.08172 20.5 12.5C20.5 16.9183 16.9183 20.5 12.5 20.5C9.75033 20.5 7.32466 19.1128 5.88468 17" />
      </svg>
    </button>
    """
  end

  defp dropdown(assigns) do
    ~H"""
    <select id={@n} name={"doc[#{@n}]"} class="form-input" aria-required={@required && "true"} phx-debounce="300">
      <option :if={not @chosen} value="" selected disabled={@required}><%= gettext("Select…") %></option>
      <option :for={o <- @opts} value={o.value} selected={o.value == @v}><%= o.label %></option>
    </select>
    """
  end

  defp scalar(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp scalar(v) when is_binary(v), do: v
  defp scalar(_), do: ""
end
