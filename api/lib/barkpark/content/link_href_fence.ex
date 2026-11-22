defmodule Barkpark.Content.LinkHrefFence do
  @moduledoc """
  A write that brings a `javascript:`, `vbscript:` or `data:` link address
  into Portable Text is refused (task-b923a915151d2038).

  #28371 draws a stored one as its words and keeps the editors from making
  one, as TanStack does (`app/src/lib/link-href.ts`). A JSON write (the
  mutate door, an import, another client) could still store one, and every
  reader of the stored JSON other than ours would get it.

  ## What is refused: script, nothing else (r2)

  Only an address `Content.LinkHref.write_refused?/1` names: after its
  character references, control characters and whitespace are taken out and
  it is lower-cased, its scheme is `javascript:`, `vbscript:` or `data:`.
  An address with no scheme (`www.example.com`, `docs/x`), a blank one,
  `sms:`, `ftp:`, `webcal:`, `geo:` and the like are stored as given: they
  cannot run script, and the reader's allowlist (`LinkHref.allowed?/1`)
  still draws them as words (#28393 review, blocker 1).

  ## The level: every write, new addresses only, every dataset

  TanStack refuses the address where it is made, not at publish. Refusing
  only at publish would leave it in a draft, which preview clients read. So
  the check runs on every create and update, on every dataset: it is a
  security rule, not a schema rule, and does not wait for
  `Validation.enforce?/1`.

  A row stored before this check (or written outside the Writer) must stay
  editable, so only a NEW address is refused: one that neither the row being
  written nor its draft or published twin already holds. A revision restore
  (`Revisions.restore_revision/4`, opt `:restore_revision`) puts back what
  was stored and is not checked (review, blocker 2).

  ## What is read

  Only values the schema types as rich text (`richText`, `portableText`, a
  `localizedText` of format `rich`), found through objects (`fields`) and
  arrays (`of`); inside one, every `markDefs` list (blocks, custom blocks,
  inline objects): a `link`'s `href`, a `linkAnnotation`'s `url`, `href` and
  `damFileUrl`. A `json` field holding the same shape is not rich text and
  is written untouched. A type with no schema is read whole. Content keyed by
  atoms (an Elixir caller) is read as JSON is.

  The refusal is the mutate door's `validation_failed` (422), with one
  finding per address under the code `pt_link_href_refused`. Nothing is
  written.
  """

  alias Barkpark.Content
  alias Barkpark.Content.LinkHref

  @code :pt_link_href_refused

  @link_keys %{"link" => ~w(href), "linkAnnotation" => ~w(url href damFileUrl)}

  @doc "The finding code this fence refuses with."
  @spec code() :: atom()
  def code, do: @code

  @doc """
  A pre-write fence (`Content.PreWriteFences.run/2`'s argument list): `:ok`,
  or `{:error, {:schema_validation_failed, errors, findings}}` naming each
  new refused address.
  """
  def refuse_new(type, attrs, dataset, doc_id, prev_doc, opts) do
    content = attrs |> content() |> stringify()

    cond do
      restore?(opts) ->
        :ok

      # Nothing refused anywhere: no schema read.
      refused(content, "") == [] ->
        :ok

      true ->
        content
        |> rich_text_refused(fields(type, dataset, attrs, opts))
        |> drop_held(held(prev_doc))
        |> drop_twin_held(type, dataset, doc_id, opts)
        |> refusal()
    end
  end

  defp restore?(opts) when is_list(opts), do: Keyword.get(opts, :restore_revision) == true
  defp restore?(_opts), do: false

  # The schema's fields, named types inlined; nil when the type has none.
  defp fields(type, dataset, attrs, opts) do
    case Content.get_schema(type, dataset, scope(attrs, opts)) do
      {:ok, %{fields: [_ | _] = fields}} -> stringify(fields)
      _ -> nil
    end
  end

  defp scope(attrs, opts) do
    from_opts = if is_list(opts), do: Keyword.take(opts, [:workspace_id, :project_id]), else: []

    stamped =
      for key <- [:workspace_id, :project_id],
          value = Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key),
          not is_nil(value),
          do: {key, value}

    Keyword.merge(from_opts, stamped)
  end

  defp rich_text_refused(content, nil), do: refused(content, "")

  defp rich_text_refused(content, fields) when is_map(content),
    do: walk_fields(fields, content, "")

  defp rich_text_refused(_content, _fields), do: []

  defp walk_fields(fields, %{} = value, path) do
    Enum.flat_map(fields, fn
      %{"name" => name} = field when is_binary(name) ->
        walk(field, Map.get(value, name), "#{path}/#{escape(name)}")

      _ ->
        []
    end)
  end

  defp walk(_field, nil, _path), do: []

  defp walk(%{"type" => type}, value, path) when type in ~w(richText portableText block),
    do: refused(value, path)

  defp walk(%{"type" => "localizedText", "format" => "rich"}, %{} = value, path),
    do: Enum.flat_map(value, fn {lang, v} -> refused(v, "#{path}/#{escape(lang)}") end)

  defp walk(%{"fields" => [_ | _] = fields}, %{} = value, path),
    do: walk_fields(fields, value, path)

  defp walk(%{"of" => of}, value, path) when is_list(value) do
    members = if is_list(of), do: of, else: [of]

    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, i} ->
      case member(members, item) do
        %{} = field -> walk(field, item, "#{path}/#{i}")
        nil -> []
      end
    end)
  end

  defp walk(_field, _value, _path), do: []

  # An array row's member type: by its `_type`, else the only one.
  defp member(members, item) do
    type = if is_map(item), do: Map.get(item, "_type")

    Enum.find(members, fn m -> is_map(m) and type != nil and type in [m["name"], m["type"]] end) ||
      case members do
        [%{} = only] -> only
        _ -> nil
      end
  end

  defp stringify(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  @doc """
  Each refused address in `content` as `{path, address}`, the path a JSON
  pointer from the content's root.
  """
  @spec refused(term(), String.t()) :: [{String.t(), String.t()}]
  def refused(%{} = map, path) when not is_struct(map) do
    defs =
      case Map.get(map, "markDefs") do
        list when is_list(list) -> def_findings(list, path <> "/markDefs")
        _ -> []
      end

    defs ++ Enum.flat_map(map, fn {k, v} -> refused(v, "#{path}/#{escape(k)}") end)
  end

  def refused(list, path) when is_list(list) do
    list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> refused(v, "#{path}/#{i}") end)
  end

  def refused(_value, _path), do: []

  defp def_findings(defs, path) do
    for {%{"_type" => type} = def, i} <- Enum.with_index(defs),
        key <- Map.get(@link_keys, type, []),
        href = def[key],
        is_binary(href) and href != "",
        LinkHref.write_refused?(href),
        do: {"#{path}/#{i}/#{key}", href}
  end

  defp content(attrs) when is_map(attrs),
    do: Map.get(attrs, "content") || Map.get(attrs, :content)

  defp content(_attrs), do: nil

  defp held(%{content: content}),
    do: MapSet.new(refused(stringify(content), ""), &elem(&1, 1))

  defp held(_doc), do: MapSet.new()

  defp drop_held(found, held), do: Enum.reject(found, fn {_path, href} -> href in held end)

  # Read only when an address is still new: the draft's first write carries
  # what the published row holds, and a publish what the draft held.
  defp drop_twin_held([], _type, _dataset, _doc_id, _opts), do: []

  defp drop_twin_held(found, type, dataset, doc_id, opts) when is_binary(doc_id) do
    twin =
      case doc_id do
        "drafts." <> published -> published
        draft -> "drafts." <> draft
      end

    case Content.get_document(twin, type, dataset, opts) do
      {:ok, doc} -> drop_held(found, held(doc))
      _ -> found
    end
  end

  defp drop_twin_held(found, _type, _dataset, _doc_id, _opts), do: found

  defp refusal([]), do: :ok

  defp refusal(found) do
    findings =
      for {path, _href} <- found do
        %{
          path: path,
          message:
            "link address not allowed: a javascript:, vbscript: or data: " <>
              "address is never stored",
          code: @code,
          params: %{key: path |> String.split("/") |> List.last()}
        }
      end

    errors =
      findings
      |> Enum.group_by(&top_level/1, &"#{&1.path}: #{&1.message}")

    {:error, {:schema_validation_failed, errors, findings}}
  end

  defp top_level(%{path: "/" <> rest}), do: rest |> String.split("/") |> hd()

  defp escape(key) when is_binary(key),
    do: key |> String.replace("~", "~0") |> String.replace("/", "~1")

  defp escape(key), do: to_string(key)
end
