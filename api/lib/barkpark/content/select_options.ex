defmodule Barkpark.Content.SelectOptions do
  @moduledoc """
  ONE normaliser for a `select` field's `options` list, shared by the top-level
  field renderer (`BarkparkWeb.Components.FieldInputs`) and the composite
  sub-field renderer (`BarkparkWeb.Components.Fields.CompositeField`) so the
  two can never disagree on what an option looks like.

  Gyldendal parity E1.5 — Sanity declares `options.list` as either bare values
  or `{title, value}` pairs and renders the TITLE ("Lik bredde"), storing the
  VALUE ("equal"). Barkpark schemas may now do the same:

      "options": ["equal", "left-larger"]
      "options": [{"value": "equal", "title": "Lik bredde"}, …]
      "options": [{"value": "equal", "label": "Lik bredde"}, …]   # legacy key

  Every shape normalises to `[%{value: String.t(), label: String.t()}]`.
  A `"layout": "radio"` on the field (Sanity's `options.layout`) asks for a
  radio group instead of a `<select>`; `radio?/1` reads it from a raw
  string-keyed field map or a `%Field{}` struct.
  """

  @type option :: %{value: String.t(), label: String.t()}

  @spec normalize(term()) :: [option()]
  def normalize(opts) when is_list(opts) do
    opts
    |> Enum.map(fn
      %{"value" => v} = o ->
        %{value: to_string(v), label: to_string(label_of(o, v))}

      %{value: v} = o ->
        %{value: to_string(v), label: to_string(label_of(o, v))}

      v when is_binary(v) or is_atom(v) or is_number(v) ->
        %{value: to_string(v), label: to_string(v)}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  def normalize(_), do: []

  @doc "The stored values, in declaration order — what `val in values(opts)` tests."
  @spec values(term()) :: [String.t()]
  def values(opts), do: opts |> normalize() |> Enum.map(& &1.value)

  @doc "True when the field asks for Sanity's `layout: \"radio\"`."
  @spec radio?(map()) :: boolean()
  def radio?(%{"layout" => "radio"}), do: true
  def radio?(%{layout: "radio"}), do: true
  def radio?(%{raw: %{} = raw}), do: radio?(raw)
  def radio?(_), do: false

  defp label_of(o, v) do
    Map.get(o, "title") || Map.get(o, :title) || Map.get(o, "label") || Map.get(o, :label) || v
  end
end
