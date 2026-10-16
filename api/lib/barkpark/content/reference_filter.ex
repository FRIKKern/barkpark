defmodule Barkpark.Content.ReferenceFilter do
  @moduledoc """
  A reference field's GROQ filter (task-281dfb5b6e350517): Sanity's
  `options.filter` and `options.filterParams`, so the twin's Hovedarrangement
  picker lists only events with `isSeriesParent == true`.

      "options": {
        "filter": "isSeriesParent == true && _id != $self",
        "filterParams": {"self": {"fromDocument": "_id"}, "kind": "series"}
      }

  `filter` is a GROQ boolean expression over the candidate document, the text
  Sanity puts between `*[` and `]`. A `filterParams` value is passed as it is,
  except `{"fromDocument": path}`, which reads the open document's value at the
  dotted `path` (`_id` is its published id) each time the form changes.

  The Studio picker searches as before, then keeps only the hits the filter
  matches: `*[_id in $bpCandidateIds && (<filter>)]._id` on the GROQ endpoint.

  Writes are not checked against the filter, as in Sanity. A target can stop
  matching after it is linked (an event that is no longer a series parent),
  and refusing then would block every later save of the linking document over
  a field the editor did not touch. The filter can also read the document's own
  unsaved values, which the write path does not see.
  """

  alias Barkpark.Groq.Parser

  @candidates "bpCandidateIds"

  @doc "The GROQ parameter that carries the picker's candidate ids."
  def candidates_param, do: @candidates

  @doc "`%{filter: groq, params: spec}` for a reference field (or an `arrayOf` item), or nil."
  @spec of(map() | nil) :: %{filter: String.t(), params: map()} | nil
  def of(%{raw: %{} = raw}), do: of(raw)

  def of(%{} = field) do
    options = Map.get(field, "options") || Map.get(field, :options)

    with %{} <- options,
         filter when is_binary(filter) <- Map.get(options, "filter"),
         trimmed when trimmed != "" <- String.trim(filter) do
      params =
        case Map.get(options, "filterParams") do
          %{} = p -> p
          _ -> %{}
        end

      %{filter: trimmed, params: params}
    else
      _ -> nil
    end
  end

  def of(_), do: nil

  @doc """
  The parameters for one form state: literals as declared, `fromDocument`
  values read from `root` (the form, or the document content). `doc_id` is
  what `_id` reads.
  """
  @spec params(map(), map() | nil, String.t() | nil) :: map()
  def params(spec, root, doc_id) when is_map(spec) do
    Map.new(spec, fn
      {name, %{"fromDocument" => path}} when is_binary(path) -> {name, read(root, path, doc_id)}
      {name, value} -> {name, value}
    end)
  end

  def params(_spec, _root, _doc_id), do: %{}

  defp read(_root, "_id", doc_id) when is_binary(doc_id), do: Barkpark.Content.published_id(doc_id)

  defp read(root, path, _doc_id) when is_map(root) do
    path
    |> String.split(".")
    |> Enum.reduce_while(root, fn key, acc ->
      case acc do
        %{} -> {:cont, Map.get(acc, key)}
        _ -> {:halt, nil}
      end
    end)
    |> plain_ref()
  end

  defp read(_root, _path, _doc_id), do: nil

  # A reference value reads as its id, the form GROQ compares with `_id`.
  defp plain_ref(%{"_ref" => id}) when is_binary(id), do: id
  defp plain_ref(value), do: value

  @doc """
  One message per reference filter in `fields` that is not usable: a filter
  that is not a string, or GROQ that does not parse with its parameters.
  """
  @spec problems(list(), [String.t()]) :: [String.t()]
  def problems(fields, prefix \\ [])

  def problems(fields, prefix) when is_list(fields) do
    Enum.flat_map(fields, fn
      %{} = field ->
        name = to_string(Map.get(field, "name") || "?")
        path = prefix ++ [name]
        own = field_problem(field, Enum.join(path, "."))

        kids =
          case Map.get(field, "fields") do
            list when is_list(list) -> problems(list, path)
            _ -> []
          end

        of =
          case Map.get(field, "of") do
            %{} = item -> field_problem(item, Enum.join(path ++ ["of"], "."))
            list when is_list(list) -> problems(list, path ++ ["of"])
            _ -> []
          end

        own ++ kids ++ of

      _ ->
        []
    end)
  end

  def problems(_, _), do: []

  defp field_problem(field, path) do
    case Map.get(field, "options") do
      %{"filter" => filter} when not is_binary(filter) ->
        ["#{path}: options.filter must be a GROQ string"]

      %{"filter" => filter} = options ->
        spec =
          case Map.get(options, "filterParams") do
            %{} = p -> p
            nil -> %{}
            _ -> :bad
          end

        cond do
          spec == :bad ->
            ["#{path}: options.filterParams must be an object"]

          true ->
            params = spec |> Map.new(fn {k, _} -> {k, nil} end) |> Map.put(@candidates, [])

            case Parser.parse("*[_id in $#{@candidates} && (#{filter})]._id", params) do
              {:ok, _} -> []
              {:error, %{description: d}} -> ["#{path}: options.filter is not valid GROQ: #{d}"]
              {:error, _} -> ["#{path}: options.filter is not valid GROQ"]
            end
        end

      _ ->
        []
    end
  end
end
