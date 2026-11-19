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

  @doc """
  The option list a field declares: `options` itself when it is a list, or
  Sanity's `options.list` (`"options": {"list": [...], "direction": ...}`).
  `nil` when there is none.
  """
  @spec list(term()) :: list() | nil
  def list(opts) when is_list(opts), do: opts
  def list(%{"list" => opts}) when is_list(opts), do: opts
  def list(%{list: opts}) when is_list(opts), do: opts
  def list(_), do: nil

  @doc """
  The options as the TanStack Studio titles them (`optionsOf`, Sanity's):
  a bare value's title is the value with its first letter capitalised
  (`"idea"` is shown "Idea", `"idea"` stored); a `{value, title}` pair keeps
  its title.
  """
  @spec titled(term()) :: [option()]
  def titled(opts) do
    opts
    |> list()
    |> List.wrap()
    |> Enum.map(fn
      v when is_binary(v) or is_atom(v) or is_number(v) ->
        %{"value" => v, "title" => upcase_first(to_string(v))}

      o ->
        o
    end)
    |> normalize()
  end

  @doc "True when a radio list asks to lie in a row (`options.direction`)."
  @spec horizontal?(map()) :: boolean()
  def horizontal?(%{"options" => %{"direction" => "horizontal"}}), do: true
  def horizontal?(%{"direction" => "horizontal"}), do: true
  def horizontal?(_), do: false

  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp upcase_first(other), do: other

  @doc "True when the field asks for Sanity's `layout: \"radio\"`."
  @spec radio?(map()) :: boolean()
  def radio?(%{"layout" => "radio"}), do: true
  def radio?(%{"options" => %{"layout" => "radio"}}), do: true
  def radio?(%{layout: "radio"}), do: true
  def radio?(%{raw: %{} = raw}), do: radio?(raw)
  def radio?(_), do: false

  defp label_of(o, v) do
    Map.get(o, "title") || Map.get(o, :title) || Map.get(o, "label") || Map.get(o, :label) || v
  end
end
