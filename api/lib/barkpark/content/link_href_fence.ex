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

  ## What is read: fail closed (r3)

  Every `markDefs` list in the content (blocks, custom blocks, inline
  objects): a `link`'s `href`, a `linkAnnotation`'s `url`, `href` and
  `damFileUrl`. The schema only decides what is skipped: a `json` field
  (any value) and a scalar value, which holds no link. An object walks its
  declared fields and reads every other key whole. A named object type is
  resolved at any depth, the way `get_schema` inlines one, including an
  array's member and a recursive type's leaf; the walk goes as deep as the
  value does. A value the walk cannot type (an unknown type, an array row
  with no matching member, a list or map in a `string` or `number` field)
  is read whole, and so is a type with no schema (#28393 review of r2).
  Content keyed by atoms (an Elixir caller) is read as JSON is.

  ## A rich text value stored as an HTML string

  A `richText` field can hold an HTML string, not Portable Text (an import, an
  older client, the desk editor's legacy arm). Each `<a href>` and
  `<area href>` in it is read the same way, from a LazyHTML parse, never a
  pattern over the bytes: a top-level field, or one nested in an object or
  array row. Only a string the schema types `richText` is read. A `string` or
  `text` field is not markup, and an untyped string (a paper's `body_html`
  cache, which the writer sanitizes) is not rich text. The finding's path is
  the field's, since the address sits inside one string
  (task-5272840f43511e20). Any string's addresses count as held, so a row an
  import wrote stays editable.
  An address the desk editor refused is stored as `data-refused-href` (#28402),
  which is not a link, so an edit of that field is not refused.

  The refusal is the mutate door's `validation_failed` (422), with one
  finding per address under the code `pt_link_href_refused`. Nothing is
  written.
  """

  alias Barkpark.Content
  alias Barkpark.Content.LinkHref
  alias Barkpark.Content.Schema

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

      # Nothing refused anywhere, in markDefs or in any string: no schema read.
      refused(content, "") == [] and html_hrefs(content) == [] ->
        :ok

      true ->
        scope = scope(attrs, opts)

        dataset
        |> with_resolver(scope, &rich_text_refused(content, fields(type, dataset, scope), &1))
        |> drop_held(held(prev_doc))
        |> drop_twin_held(type, dataset, doc_id, opts)
        |> refusal()
    end
  end

  defp restore?(opts) when is_list(opts), do: Keyword.get(opts, :restore_revision) == true
  defp restore?(_opts), do: false

  # The schema's fields, named types inlined; nil when the type has none.
  defp fields(type, dataset, scope) do
    case Content.get_schema(type, dataset, scope) do
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

  defp rich_text_refused(content, nil, _resolve), do: refused(content, "")

  defp rich_text_refused(%{} = content, fields, resolve),
    do: walk_object(fields, content, "", resolve)

  defp rich_text_refused(content, _fields, _resolve), do: refused(content, "")

  # Fail closed (r3 ruling): a value is skipped only where the schema types it
  # as `json`, or where it is a scalar, which holds no link. An object walks
  # its declared fields and reads every other key whole; a named type is
  # resolved as `get_schema` inlines one; a value the walk cannot type (an
  # unknown type, an array row with no member, a mismatched shape such as a
  # list in a `string` field) is read whole.
  defp walk_object(fields, %{} = value, path, resolve) do
    declared = for %{"name" => name} = f when is_binary(name) <- fields, into: %{}, do: {name, f}

    own_defs(value, path) ++
      Enum.flat_map(value, fn {k, v} ->
        sub = "#{path}/#{escape(k)}"

        case Map.fetch(declared, k) do
          {:ok, field} -> walk(field, v, sub, resolve)
          :error -> refused(v, sub)
        end
      end)
  end

  defp walk(%{"type" => "json"}, _value, _path, _resolve), do: []

  defp walk(%{"type" => "richText"}, value, path, _resolve) when is_binary(value),
    do: html_findings(value, path)

  defp walk(_field, value, _path, _resolve) when not is_map(value) and not is_list(value), do: []

  defp walk(%{"fields" => [_ | _] = fields}, %{} = value, path, resolve),
    do: walk_object(fields, value, path, resolve)

  defp walk(%{"of" => of}, value, path, resolve) when is_list(value) do
    members = if is_list(of), do: of, else: [of]

    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, i} ->
      case member(members, item) do
        %{} = field -> walk(field, item, "#{path}/#{i}", resolve)
        nil -> refused(item, "#{path}/#{i}")
      end
    end)
  end

  defp walk(%{"type" => type} = field, value, path, resolve) when is_binary(type) do
    if named?(field) do
      case resolve.(type) do
        {:ok, %{"fields" => [_ | _] = fields}} ->
          walk(%{"fields" => fields}, value, path, resolve)

        _ ->
          refused(value, path)
      end
    else
      refused(value, path)
    end
  end

  defp walk(_field, value, path, _resolve), do: refused(value, path)

  # A field that names an object type, not inlined: an array member, or a
  # type `get_schema`'s inliner left as a leaf because it is already on its
  # walk (a recursive type).
  defp named?(%{"type" => type} = field),
    do: type not in Schema.builtin_field_types() and not is_map_key(field, "fields")

  # An array row's member type: the one its `_type` names; with no `_type`,
  # the only member. Anything else has none and is read whole.
  defp member(members, item) do
    case if(is_map(item), do: Map.get(item, "_type")) do
      nil ->
        case members do
          [%{} = only] -> only
          _ -> nil
        end

      type ->
        Enum.find(members, fn m -> is_map(m) and type in [m["name"], m["type"]] end)
    end
  end

  # The named object types this write reaches, each resolved once
  # (`Schema.object_type_field/3`: the scope ladder and inliner `get_schema`
  # uses). The walk recurses by the value's depth, so a recursive type ends
  # where the value does.
  defp with_resolver(dataset, scope, fun) do
    key = {__MODULE__, make_ref()}

    resolve = fn name ->
      memo = Process.get(key, %{})

      case Map.fetch(memo, name) do
        {:ok, found} ->
          found

        :error ->
          found =
            case Schema.object_type_field(name, dataset, scope) do
              {:ok, field} -> {:ok, stringify(field)}
              :error -> :error
            end

          Process.put(key, Map.put(memo, name, found))
          found
      end
    end

    try do
      fun.(resolve)
    after
      Process.delete(key)
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
    own_defs(map, path) ++ Enum.flat_map(map, fn {k, v} -> refused(v, "#{path}/#{escape(k)}") end)
  end

  def refused(list, path) when is_list(list) do
    list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> refused(v, "#{path}/#{i}") end)
  end

  def refused(_value, _path), do: []

  # The refused addresses in every HTML string in `value`, whatever its type.
  defp html_hrefs(html) when is_binary(html),
    do: html |> html_findings("") |> Enum.map(&elem(&1, 1))

  defp html_hrefs(%{} = map) when not is_struct(map), do: map |> Map.values() |> html_hrefs()
  defp html_hrefs(list) when is_list(list), do: Enum.flat_map(list, &html_hrefs/1)
  defp html_hrefs(_value), do: []

  # Every `<a href>` / `<area href>` in an HTML string. Only a string that
  # holds an `<a` (`<a`, `<A`, `<area`…: no space may follow `<`) is parsed.
  defp html_findings(html, path) do
    if :binary.match(String.downcase(html), "<a") == :nomatch do
      []
    else
      for href <-
            html
            |> LazyHTML.from_fragment()
            |> LazyHTML.query("a[href], area[href]")
            |> LazyHTML.attribute("href"),
          href != "" and LinkHref.write_refused?(href),
          do: {path, href}
    end
  end

  defp own_defs(map, path) do
    case Map.get(map, "markDefs") do
      list when is_list(list) -> def_findings(list, path <> "/markDefs")
      _ -> []
    end
  end

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

  defp held(%{content: content}) do
    content = stringify(content)
    MapSet.new(Enum.map(refused(content, ""), &elem(&1, 1)) ++ html_hrefs(content))
  end

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
