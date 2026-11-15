defmodule BarkparkWeb.Studio.StudioLive.Handlers.FieldPaste do
  @moduledoc """
  What a "Paste field" writes: the clipboard's item, read against the field it
  is pasted into, as the TanStack Studio's `transfer` (barkpark-studio
  `app/src/lib/clipboard.ts`), or the words that refuse it.

  THE CLIPBOARD IS NOT TRUSTED. It is text any page or program can put there.
  The item's own account of itself (its signature, `_type`, `_key`, ids) is
  used for one thing, the words of a refusal. What is written is decided by
  the target field's schema alone (`fit/4`):

    * a text, number or boolean must be one; a whole number is at most
      2^53 - 1 either way, the largest every reader of the stored JSON holds
      exactly (typing has no such bound; that is the typed path's to fix);
    * a select takes only a value on its list, at every depth: the field
      itself, a subfield of an object, a row of a list of objects;
    * a reference must name a document of the field's type that exists
      (`ref?`, the caller's scoped read);
    * an object keeps only the subfields its schema declares, each read the
      same way; a key the schema does not have refuses the paste. A subfield
      the copy does not hold keeps its stored value: that is the save's own
      rule for an edited object, and a paste is one;
    * a list takes rows of its one member type, at most #{500} of them; a row
      that is an object gets a fresh `_key`, and its `_type` is dropped;
    * the item is at most #{262_144} bytes.

  Kinds that paste: string, text, url, email, select, slug, number, boolean,
  reference, an object of those, and a list of texts, numbers, booleans or
  objects. Refused in words, never written: image, rich text, date and
  date-time, a list with several member types or of references, and every
  other type.

  Nothing here writes. `plan/4` answers with the `doc` params a typed edit of
  that field would post; the caller hands them to the Studio's `autosave`, so
  the schema's coercion (`Barkpark.Content.Forms.coerce_params/2`), the write
  rules and the save are the ones every edit goes through.
  """
  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.Content.DraftId
  alias Barkpark.Content.SelectOptions
  alias Barkpark.Content.SlugValue
  alias BarkparkWeb.Studio.Desk.FieldClip

  @max_bytes 262_144
  @max_rows 500
  @max_depth 8

  @text_types ~w(string text url email)
  # The largest whole number a double holds exactly (JavaScript's
  # MAX_SAFE_INTEGER): past it the site and the Studio read another number.
  @max_integer 9_007_199_254_740_991
  @row_types ~w(string text url email number boolean composite)

  @typedoc """
  `{:save, params}`: the `autosave` params that write the paste.
  `:nothing`: the clipboard holds no copied field, or one with nothing in
  it to write (an object with no subfield set).
  `{:invalid, why}`: it holds one this field does not take; `why` says so.
  """
  @type plan :: {:save, map()} | :nothing | {:invalid, String.t() | nil}

  @doc """
  The paste of `clip` (the clipboard item's JSON) into `field`, which now
  stores `current`. `ref?` answers whether a document `id` of `type` exists
  for this editor.
  """
  @spec plan(map(), term(), term(), (String.t(), String.t() -> boolean())) :: plan()
  def plan(%{"name" => name} = field, current, clip, ref?)
      when is_binary(name) and is_binary(clip) and is_function(ref?, 2) do
    case read(clip) do
      {:ok, item} ->
        case transfer(item, field, current, ref?) do
          # An object that sets no subfield would save as a change of nothing.
          {:ok, value} when value == %{} -> :nothing
          {:ok, value} -> {:save, %{"doc" => %{name => value}, "_target" => ["doc", name]}}
          {:error, why} -> {:invalid, why}
        end

      other ->
        other
    end
  end

  def plan(_field, _current, _clip, _ref?), do: :nothing

  # ── The item ────────────────────────────────────────────────────────────

  defp read(clip) when byte_size(clip) > @max_bytes, do: {:invalid, nil}

  defp read(clip) do
    case Jason.decode(clip) do
      {:ok, %{"type" => "sanityClipboardItem"} = item} -> item(item)
      _ -> :nothing
    end
  end

  # Barkpark's own copy inside the item, else what Sanity's item says. A
  # copied document is not a field.
  defp item(%{"barkpark" => %{"kind" => "field", "field" => %{"sig" => sig} = field}})
       when is_binary(sig),
       do: entry(sig, field["value"], field["append"] == true)

  defp item(%{"barkpark" => %{"kind" => "document"}}), do: :nothing
  defp item(%{"isDocument" => true}), do: :nothing

  defp item(%{"schemaTypeName" => type} = item) when is_binary(type),
    do: entry(sanity_sig(type, item["value"]), item["value"], false)

  defp item(_item), do: :nothing

  defp entry(sig, value, append) do
    # An appended copy is a one-item list; an empty item in it is empty.
    probe = if append and is_list(value), do: List.first(value), else: value

    if FieldClip.empty?(probe),
      do: :nothing,
      else: {:ok, %{sig: sig, value: value, append: append}}
  end

  defp sanity_sig(type, _value) when type in ~w(string text url email), do: "string"
  defp sanity_sig(type, _value) when type in ~w(number boolean date datetime), do: type
  defp sanity_sig("", value) when is_binary(value), do: "string"
  defp sanity_sig(type, _value), do: "sanity:" <> type

  # ── The transfer ────────────────────────────────────────────────────────

  defp transfer(%{sig: sig, value: value, append: append}, field, current, ref?) do
    target = FieldClip.sig(field)

    # A number goes into text as its digits, and a number or a text into a
    # list of texts as one more row.
    numeric? = sig in ~w(number integer float) and is_number(value)
    # A copied number is one a field can hold, whatever it is pasted into.
    held = if numeric? and not in_range?(value), do: too_large(), else: :ok

    {sig, value} =
      if numeric? and in_range?(value) and target in ["string", "array:string"],
        do: {"string", number_text(value)},
        else: {sig, value}

    {sig, value, append} =
      if sig == "string" and target == "array:string",
        do: {target, [value], true},
        else: {sig, value, append}

    with :ok <- held,
         :ok <- same(sig, value, target),
         {:ok, clean} <- fit(field, value, ref?, 0) do
      {:ok, placed(clean, current, append)}
    end
  end

  defp in_range?(n) when is_integer(n), do: abs(n) <= @max_integer
  defp in_range?(n) when is_float(n), do: true

  defp same(sig, _value, sig), do: :ok
  defp same(sig, value, target), do: {:error, mismatch(sig, value, target)}

  defp placed(rows, current, true) when is_list(rows) and is_list(current), do: current ++ rows
  defp placed(clean, _current, _append), do: clean

  defp number_text(n) when is_integer(n), do: Integer.to_string(n)

  defp number_text(n) when is_float(n) do
    if n == Float.floor(n) and abs(n) < 1.0e15,
      do: n |> trunc() |> Integer.to_string(),
      else: :erlang.float_to_binary(n, [:short])
  end

  # A select's stored values, as the form offers them
  # (`Content.SelectOptions`): a number option is its digits.
  defp option_values(%{"list" => list}), do: option_values(list)
  defp option_values(options), do: SelectOptions.values(options)

  # ── The value, read against the field's schema ──────────────────────────
  #
  # `{:ok, value}` in the shape the form posts for that field (a reference is
  # its id, a slug its text), or `{:error, why}`.

  defp fit(_field, _value, _ref?, depth) when depth > @max_depth, do: incompatible()

  defp fit(%{"type" => type}, value, _ref?, _depth) when type in @text_types,
    do: if(is_binary(value), do: {:ok, value}, else: incompatible())

  # A select takes only its options, wherever it sits.
  defp fit(%{"type" => "select"} = field, value, _ref?, _depth) when is_binary(value) do
    allowed = option_values(field["options"])

    if value in allowed,
      do: {:ok, value},
      else:
        {:error,
         gettext("Value \"%{value}\" is not allowed in \"%{list}\"",
           value: value,
           list: Enum.join(allowed, ",")
         )}
  end

  defp fit(%{"type" => "select"}, _value, _ref?, _depth), do: incompatible()

  defp fit(%{"type" => "number"}, value, _ref?, _depth) do
    cond do
      not is_number(value) -> incompatible()
      in_range?(value) -> {:ok, value}
      true -> too_large()
    end
  end

  defp fit(%{"type" => "boolean"}, value, _ref?, _depth),
    do: if(is_boolean(value), do: {:ok, value}, else: incompatible())

  defp fit(%{"type" => "slug"}, value, _ref?, _depth) do
    case SlugValue.text(value) do
      text when is_binary(text) and text != "" -> {:ok, text}
      _ -> incompatible()
    end
  end

  defp fit(%{"type" => "reference", "refType" => type}, value, ref?, _depth)
       when is_binary(type) do
    with id when is_binary(id) <- ref_id(value),
         true <- Regex.match?(~r/\A[A-Za-z0-9._-]{1,200}\z/, id),
         id = DraftId.published_id(id),
         true <- ref?.(type, id) do
      {:ok, id}
    else
      _ ->
        {:error,
         gettext(
           "References of type \"%{source}\" is not allowed in reference field that accepts types \"%{target}\"",
           source: "?",
           target: type
         )}
    end
  end

  defp fit(%{"type" => "composite", "fields" => subs}, %{} = value, ref?, depth)
       when is_list(subs) do
    by_name = for %{"name" => name} = sub <- subs, is_binary(name), into: %{}, do: {name, sub}

    value
    |> Enum.reject(fn {key, v} ->
      is_nil(v) or (is_binary(key) and String.starts_with?(key, "_"))
    end)
    |> Enum.reduce_while({:ok, %{}}, fn {key, v}, {:ok, acc} ->
      with %{} = sub <- by_name[key],
           {:ok, clean} <- fit(sub, v, ref?, depth + 1) do
        # An inner object that sets nothing is not written, as a null is not.
        {:cont, {:ok, if(clean == %{}, do: acc, else: Map.put(acc, key, clean))}}
      else
        nil -> {:halt, incompatible()}
        error -> {:halt, error}
      end
    end)
  end

  defp fit(%{"type" => "arrayOf"} = field, rows, ref?, depth) when is_list(rows) do
    case member(field["of"]) do
      %{"type" => type} = member when type in @row_types and length(rows) <= @max_rows ->
        rows
        |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
          case fit(member, row, ref?, depth + 1) do
            {:ok, clean} -> {:cont, {:ok, [keyed(clean) | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, clean} -> {:ok, Enum.reverse(clean)}
          error -> error
        end

      %{"type" => _type} when length(rows) <= @max_rows ->
        unsupported(field)

      _ ->
        incompatible()
    end
  end

  defp fit(%{"type" => type} = field, _value, _ref?, _depth)
       when type not in ["composite", "arrayOf", "reference"],
       do: unsupported(field)

  defp fit(_field, _value, _ref?, _depth), do: incompatible()

  defp ref_id(%{"_ref" => id}) when is_binary(id), do: id
  defp ref_id(id) when is_binary(id), do: id
  defp ref_id(_value), do: nil

  # An array's one member type; none when it declares several.
  defp member(%{} = member), do: member
  defp member([%{} = member]), do: member
  defp member(_of), do: nil

  # A row that is an object gets a key of its own, never the copied one.
  defp keyed(%{} = row),
    do: Map.put(row, "_key", 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))

  defp keyed(row), do: row

  # ── The words ───────────────────────────────────────────────────────────

  defp incompatible,
    do: {:error, gettext("Source and target schema types are not compatible")}

  defp too_large, do: {:error, gettext("The number is too large to paste")}

  defp unsupported(%{"type" => type}),
    do: {:error, gettext("A field of type \"%{type}\" cannot be pasted into", type: type)}

  # Sanity's words for a copy that does not fit, as `clipboard.ts` `mismatch`.
  defp mismatch("reference:" <> source, _value, "reference:" <> target) do
    gettext(
      "References of type \"%{source}\" is not allowed in reference field that accepts types \"%{target}\"",
      source: source,
      target: target
    )
  end

  defp mismatch("array:" <> _source, value, "array:" <> _target) do
    gettext("Value of type \"%{type}\" is not allowed in this array field", type: row_type(value))
  end

  defp mismatch(_sig, _value, _target),
    do: gettext("Source and target schema types are not compatible")

  defp row_type([%{"_type" => type} | _rows]) when is_binary(type), do: type
  defp row_type([%{} | _rows]), do: "object"
  defp row_type([row | _rows]) when is_binary(row), do: "string"
  defp row_type([row | _rows]) when is_number(row), do: "number"
  defp row_type([row | _rows]) when is_boolean(row), do: "boolean"
  defp row_type(_rows), do: "object"
end
