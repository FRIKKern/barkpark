defmodule BarkparkWeb.Studio.Desk.FieldClip do
  @moduledoc """
  A copied field as it goes on the system clipboard: the TanStack Studio's
  format (barkpark-studio `app/src/lib/clipboard.ts`), which is Sanity's
  clipboard item with Barkpark's own copy inside it under `barkpark`.

  One copy is three clipboard types, so it pastes in another tab, another
  browser, the TanStack Studio and Sanity:

    * `web application/vnd.sanity-clipboard-item+json`: the item as JSON.
    * `text/html`: the same JSON, base64, in `data-sanity-clipboard-base64`
      (for a browser without web custom types), around the words.
    * `text/plain`: the words.

  A field's signature (`sig/1`) is its type reduced to what decides whether a
  value fits it: `string`, `number`, `reference:author`, `array:string`,
  `object:url=string`. A copied document (`doc_copy/3`) carries each of its
  fields with its signature. Nothing here reads or writes a document.
  """

  @string_types ~w(string text url email select)

  @doc "A field's signature, as `clipboard.ts` `signature()`."
  @spec sig(map()) :: String.t()
  def sig(%{"type" => type}) when type in @string_types, do: "string"
  def sig(%{"type" => "reference"} = field), do: "reference:" <> ref_types(field)
  def sig(%{"type" => "arrayOf"} = field), do: "array:" <> member_sig(field["of"])

  def sig(%{"type" => "composite"} = field) do
    subs =
      for %{"name" => name} = sub <- List.wrap(field["fields"]), is_binary(name) do
        "#{name}=#{sig(sub)}"
      end

    "object:" <> (subs |> Enum.sort() |> Enum.join(","))
  end

  def sig(%{"type" => type}) when is_binary(type), do: type
  def sig(_field), do: "?"

  # The type a reference field takes.
  defp ref_types(%{"refType" => type}) when is_binary(type), do: type

  defp ref_types(_field), do: "?"

  # An array's member: one type, or several (a list of one is that one).
  defp member_sig(%{} = member), do: sig(member)
  defp member_sig([%{} = member]), do: sig(member)

  defp member_sig([_ | _] = members),
    do: members |> Enum.filter(&is_map/1) |> Enum.map(&sig/1) |> Enum.sort() |> Enum.join("|")

  defp member_sig(_of), do: "?"

  @doc """
  Sanity's `isEmptyValue`, as `clipboard.ts` `isEmpty`: nothing, an empty
  list, or an object holding only its `_key`. An empty text and an object
  with no keys are values: they copy, and they paste.
  """
  @spec empty?(term()) :: boolean()
  def empty?(nil), do: true
  def empty?([]), do: true
  def empty?(%{} = map), do: Map.keys(map) == ["_key"]
  def empty?(_value), do: false

  @doc "The value in words (the clipboard's plain text), as `clipboard.ts` `asText`."
  @spec as_text(term()) :: String.t()
  def as_text(nil), do: ""
  def as_text(list) when is_list(list), do: joined(list)

  def as_text(%{} = map) do
    map
    |> Enum.reject(fn {key, _value} -> String.starts_with?(to_string(key), "_") end)
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {_key, value} -> value end)
    |> joined()
  end

  def as_text(value) when is_binary(value), do: value
  def as_text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  def as_text(_value), do: ""

  defp joined(values),
    do: values |> Enum.map(&as_text/1) |> Enum.reject(&(&1 == "")) |> Enum.join(", ")

  @typedoc "The three clipboard types of one copy."
  @type copy :: %{json: String.t(), html: String.t(), text: String.t()}

  @doc """
  The copy of `field`, holding `value`, from the document `doc_id` of
  `doc_type`.
  """
  @spec field_copy(map(), term(), String.t() | nil, String.t() | nil) :: copy()
  def field_copy(%{"name" => name} = field, value, doc_id, doc_type) do
    sig = sig(field)

    item = %{
      "type" => "sanityClipboardItem",
      "documentId" => doc_id,
      "documentType" => doc_type,
      "isDocument" => false,
      "schemaTypeName" => sanity_type(sig),
      "valuePath" => [name],
      "value" => value,
      "patchType" => "replace",
      "barkpark" => %{
        "kind" => "field",
        "field" => %{"name" => name, "sig" => sig, "value" => value}
      }
    }

    json = Jason.encode!(item)
    text = as_text(value)

    html =
      ~s(<div data-sanity-clipboard-base64="#{Base.encode64(json)}"><p>#{escape(text)}</p></div>)

    %{json: json, html: html, text: text}
  end

  @doc """
  The copy of one item, at `index`, of the array `field`: a one-item list
  under the array's signature, marked to be appended (the TanStack Studio's
  `copyItem`), so a Paste field on an array of that kind adds it at the end
  with a new `_key` (`Handlers.FieldPaste`).
  """
  @spec item_copy(map(), term(), non_neg_integer(), String.t() | nil, String.t() | nil) :: copy()
  def item_copy(%{"name" => name} = field, item, index, doc_id, doc_type) do
    sig = sig(field)
    step = if is_map(item) and is_binary(item["_key"]), do: %{"_key" => item["_key"]}, else: index

    clip = %{
      "type" => "sanityClipboardItem",
      "documentId" => doc_id,
      "documentType" => doc_type,
      "isDocument" => false,
      "schemaTypeName" => sanity_type(sig),
      "valuePath" => [name, step],
      "value" => [item],
      "patchType" => "append",
      "barkpark" => %{
        "kind" => "field",
        "field" => %{
          "name" => "#{name}[#{index}]",
          "sig" => sig,
          "value" => [item],
          "append" => true
        }
      }
    }

    json = Jason.encode!(clip)
    text = as_text(item)

    html =
      ~s(<div data-sanity-clipboard-base64="#{Base.encode64(json)}"><p>#{escape(text)}</p></div>)

    %{json: json, html: html, text: text}
  end

  @doc """
  The copy of a whole document of `doc_type`: each of its `fields` that holds
  a value, as `{field, value}`, under Sanity's document item (`isDocument`,
  the values under their names, the document's `_type`) with Barkpark's own
  copy inside it, each field with its signature (the TanStack Studio's
  `copy` of `{kind: 'document'}`). The words are every value's, in order.
  """
  @spec doc_copy([{map(), term()}], String.t() | nil, String.t() | nil) :: copy()
  def doc_copy(fields, doc_id, doc_type) do
    held =
      for {%{"name" => name} = field, value} <- fields,
          not is_nil(value),
          do: {name, field, value}

    clip = %{
      "type" => "sanityClipboardItem",
      "documentId" => doc_id,
      "documentType" => doc_type,
      "isDocument" => true,
      "schemaTypeName" => doc_type,
      "valuePath" => [],
      "value" =>
        Map.new([{"_type", doc_type} | for({name, _f, value} <- held, do: {name, value})]),
      "patchType" => "replace",
      "barkpark" => %{
        "kind" => "document",
        "docType" => doc_type,
        "fields" =>
          for({name, f, value} <- held, do: %{"name" => name, "sig" => sig(f), "value" => value})
      }
    }

    json = Jason.encode!(clip)

    text =
      held
      |> Enum.map(fn {_name, _f, value} -> as_text(value) end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(", ")

    html =
      ~s(<div data-sanity-clipboard-base64="#{Base.encode64(json)}"><p>#{escape(text)}</p></div>)

    %{json: json, html: html, text: text}
  end

  # Sanity's schema type name for a signature.
  defp sanity_type("reference:" <> _types), do: "reference"
  defp sanity_type("array:" <> _member), do: "array"
  defp sanity_type("object:" <> _fields), do: "object"
  defp sanity_type(sig), do: sig

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
