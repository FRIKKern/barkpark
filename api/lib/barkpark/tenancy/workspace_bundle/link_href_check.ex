defmodule Barkpark.Tenancy.WorkspaceBundle.LinkHrefCheck do
  @moduledoc """
  A bundle import takes the script out of a link address a write refuses
  (task-9d0496cb3f369ed1, #28393 review).

  The import writes document rows with a raw `COPY … FROM STDIN`, past the
  Writer and its pre-write fences, `Content.LinkHrefFence` among them. So a
  bundle could store a Portable Text link whose address is `javascript:`,
  `vbscript:` or `data:` (`Content.LinkHref.write_refused?/1`). The reader
  draws such a link as its words (#28371), so nothing ran, but every other
  reader of the stored JSON would get it.

  ## Stripped, not refused

  A real export can hold such a link from before #28393, which the write
  fence leaves stored on purpose (only a new address is refused). Refusing
  the whole bundle would make that workspace impossible to move or restore
  over one old link. So the import keeps the link and its words and takes
  the address out of reach, as the desk editor keeps a refused `<a href>` as
  `data-refused-href` (#28402): the key is dropped and its value kept under
  `refused_<key>` (`refused_href` for a `link`), which no reader follows.
  Each stripped address is a finding, `{table, doc_id, JSON pointer,
  address}`, logged and returned in the import's stats as `:refused_links`.

  ## What is read

  Every `json` and `jsonb` column of every member, before anything is
  written, for the restore and the remap into a dataset alike. The columns
  are read off the target's own schema (`json_columns/1`), not a list, so a
  member added later is read too (#28728 review: `mutation_events.document`
  is served by the listen replay, the sync outbox and the webhook rebuild).
  A revision is stripped too: restoring one puts its content back without
  the fence, which assumes a stored revision passed it.

  In each value, every `markDefs` list, as the fence reads it
  (`LinkHrefFence.refused/2`): a `link`'s `href`, a `linkAnnotation`'s
  `url`, `href` and `damFileUrl`. A value is read after both its COPY
  escapes and its JSON escapes are undone, as Postgres reads it: the only
  values skipped unread are those that after the COPY escapes hold neither
  `markDefs` nor a `\\u` escape, so cannot spell the key. A value read and
  not decoded refuses the bundle (`pt_content_undecodable`): Postgres must
  never get a value the check could not read. A member whose rows the
  check cannot split as `COPY FROM` does (a raw carriage return, a `\\.`
  line) refuses the bundle too (`copy_rows_unreadable`). Numbers are decoded as
  decimals and written back as they were, so a stripped value keeps every
  other value.

  Not read: an `<a href>` inside a rich text value stored as an HTML string.
  The fence reads those only where the schema types the field `richText`,
  and the check has no schema before the import; rewriting every string
  that looks like markup would change plain text (task-f696490d16ac11da).
  """

  require Logger

  alias Barkpark.Content.LinkHref
  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle.{CopyText, InvalidBundleError}

  @chunk_bytes 64 * 1024

  # As `LinkHrefFence`'s `@link_keys`; the tests hold the two together
  # (after a strip, `LinkHrefFence.refused/2` finds nothing).
  @link_keys %{"link" => ~w(href), "linkAnnotation" => ~w(url href damFileUrl)}

  @typedoc "One stripped address."
  @type finding :: %{
          table: String.t(),
          column: String.t(),
          doc_id: String.t() | nil,
          path: String.t(),
          href: String.t()
        }

  @doc """
  The bundle's members with each refused link address stripped, and the
  findings. `dumps` maps a member's name to its bytes or `{:file, path}`; a
  member with nothing to strip is returned as it was. Raises
  `InvalidBundleError` on a value it cannot decode.
  """
  @spec strip(map(), Enumerable.t()) :: {map(), [finding()]}
  def strip(manifest, dumps) do
    dumps = Map.new(dumps)
    members = manifest["tables"] || []
    json = json_columns(for %{"name" => t} <- members, do: t)
    for %{"name" => t} <- members, dumps[t] != nil, do: splittable!(t, dumps[t])

    for %{"name" => table, "columns" => cols} <- members,
        at = for({c, i} <- Enum.with_index(cols), c in Map.get(json, table, []), do: {c, i}),
        at != [],
        dump = dumps[table],
        dump != nil,
        reduce: {dumps, []} do
      {dumps, found} ->
        id = Enum.find_index(cols, &(&1 == "doc_id")) || Enum.find_index(cols, &(&1 == "id"))

        case rows_found(dump, table, at, id) do
          [] -> {dumps, found}
          here -> {Map.put(dumps, table, rewrite(dump, at)), found ++ here}
        end
    end
  end

  @doc """
  `%{table => [column]}`: the `json` and `jsonb` columns of `tables` in the
  target's schema, the columns the import must read.
  """
  @spec json_columns([String.t()]) :: %{String.t() => [String.t()]}
  def json_columns(tables) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = ANY($1)
          AND data_type IN ('json', 'jsonb')
        """,
        [tables]
      )

    Enum.group_by(rows, &hd/1, &List.last/1)
  end

  @doc """
  The import's result with the findings in its stats (`:refused_links`),
  each one logged. Any other result is returned as it is.
  """
  @spec report(term(), [finding()]) :: term()
  def report({:ok, stats}, found) when is_map(stats) do
    for f <- found do
      Logger.warning(
        "workspace bundle import: stripped a #{f.table} link address a write refuses " <>
          "(#{f.doc_id || "no id"} #{f.column}#{f.path}): #{inspect(String.slice(f.href, 0, 40))}"
      )
    end

    {:ok, Map.put(stats, :refused_links, found)}
  end

  def report(other, _found), do: other

  @doc """
  `content` with each refused address in a `markDefs` list taken out of
  its key and kept under `refused_<key>`, and each one as `{path, address}`.
  """
  @spec strip_content(term(), String.t()) :: {term(), [{String.t(), String.t()}]}
  def strip_content(%{} = map, path) when not is_struct(map) do
    {map, own} =
      case map["markDefs"] do
        defs when is_list(defs) ->
          {defs, own} = strip_defs(defs, path <> "/markDefs")
          {Map.put(map, "markDefs", defs), own}

        _ ->
          {map, []}
      end

    Enum.reduce(map, {map, own}, fn {k, v}, {acc, found} ->
      case strip_content(v, "#{path}/#{escape(k)}") do
        {_v, []} -> {acc, found}
        {v, more} -> {Map.put(acc, k, v), found ++ more}
      end
    end)
  end

  def strip_content(list, path) when is_list(list) do
    {list, found} =
      list
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {v, i}, found ->
        {v, more} = strip_content(v, "#{path}/#{i}")
        {v, found ++ more}
      end)

    {list, found}
  end

  def strip_content(value, _path), do: {value, []}

  defp strip_defs(defs, path) do
    defs
    |> Enum.with_index()
    |> Enum.map_reduce([], fn
      {%{"_type" => type} = def, i}, found ->
        Enum.reduce(Map.get(@link_keys, type, []), {def, found}, fn key, {def, found} ->
          href = def[key]

          if is_binary(href) and href != "" and LinkHref.write_refused?(href) do
            def = def |> Map.delete(key) |> Map.put("refused_" <> key, href)
            {def, found ++ [{"#{path}/#{i}/#{key}", href}]}
          else
            {def, found}
          end
        end)

      {def, _i}, found ->
        {def, found}
    end)
  end

  defp escape(key) when is_binary(key),
    do: key |> String.replace("~", "~0") |> String.replace("/", "~1")

  defp escape(key), do: to_string(key)

  # A value that after its COPY escapes holds neither `markDefs` nor a JSON
  # `\u` escape cannot hold the key `markDefs` once decoded; every other
  # value is decoded (#28728 review: `\x6darkDefs`, `\u006darkDefs`).
  defp candidate?(nil), do: false

  defp candidate?(value),
    do: String.contains?(value, "markDefs") or String.contains?(value, "\\u")

  defp decoded!(value, table, column, id) do
    case Jason.decode(value, floats: :decimals) do
      {:ok, decoded} ->
        decoded

      {:error, _} ->
        raise InvalidBundleError,
          code: "pt_content_undecodable",
          message:
            "bundle member #{table} row #{id || "with no id"}: #{column} is not JSON " <>
              "the import can read, so its link addresses cannot be checked"
    end
  end

  # The member split into rows as `COPY FROM` splits it, or refused
  # (task-ff1f9481f31ad3bc, #28728 r2 review). `COPY FROM` also ends a row
  # at a bare carriage return, and stops at a line of `\.`; the check
  # splits on newlines only, so a member with either is read as other rows
  # than Postgres loads: a link in a row ended by a CR went through
  # unread. `COPY TO` writes neither (it escapes a CR as `\r`, and a
  # backslash as `\\`), so a member holding one was not written by an
  # export, and the bundle is refused.
  defp splittable!(table, dump) do
    dump
    |> source()
    |> CopyText.rows()
    |> Stream.with_index(1)
    |> Enum.each(fn {fields, n} ->
      cond do
        Enum.any?(fields, &String.contains?(&1, "\r")) ->
          unsplittable!(table, n, "a raw carriage return, which ends a row for Postgres")

        fields == ["\\."] ->
          unsplittable!(table, n, "a \\. line, which ends the data for Postgres")

        true ->
          :ok
      end
    end)
  end

  defp unsplittable!(table, n, what) do
    raise InvalidBundleError,
      code: "copy_rows_unreadable",
      message:
        "bundle member #{table} row #{n} holds #{what}; an export never writes one, " <>
          "so its rows cannot be read as Postgres would load them"
  end

  # Each stripped address in the member, as findings.
  defp rows_found(dump, table, at, id_at) do
    dump
    |> source()
    |> CopyText.rows()
    |> Enum.flat_map(fn fields ->
      id = id_at && CopyText.value(fields, id_at)

      for {column, i} <- at,
          value = CopyText.value(fields, i),
          candidate?(value),
          {_v, found} = strip_content(decoded!(value, table, column, id), ""),
          {path, href} <- found,
          do: %{table: table, column: column, doc_id: id, path: path, href: href}
    end)
  end

  # The member again: each value with something to strip written stripped,
  # every other field and row as it was, byte for byte.
  defp rewrite(dump, at) do
    lines =
      dump
      |> source()
      |> CopyText.rows()
      |> Stream.map(fn fields ->
        fields =
          Enum.reduce(at, fields, fn {_column, i}, fields ->
            with value when is_binary(value) <- CopyText.value(fields, i),
                 true <- candidate?(value),
                 {:ok, decoded} <- Jason.decode(value, floats: :decimals),
                 {stripped, [_ | _]} <- strip_content(decoded, "") do
              List.replace_at(fields, i, CopyText.escape(encode!(stripped)))
            else
              _ -> fields
            end
          end)

        [Enum.join(fields, "\t"), "\n"]
      end)

    case dump do
      {:file, path} -> {:file, write!(path, lines)}
      _bytes -> lines |> Enum.to_list() |> IO.iodata_to_binary()
    end
  end

  # A decimal is written as its digits (`1.10`, `1E+400`), not as Jason's
  # quoted string.
  defp encode!(value), do: value |> exact() |> Jason.encode!()

  defp exact(%Decimal{} = d), do: Jason.Fragment.new(Decimal.to_string(d, :scientific))
  defp exact(%{} = map), do: Map.new(map, fn {k, v} -> {k, exact(v)} end)
  defp exact(list) when is_list(list), do: Enum.map(list, &exact/1)
  defp exact(value), do: value

  # Next to the extracted member, which it replaces: the member is deleted
  # the moment the stripped copy is written, as the import deletes each
  # member once its COPY is done. `path` is the import's own extracted
  # member (`Archive.unpack_to_dir/2`), never request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp write!(path, lines) do
    stripped = path <> ".links"
    lines |> Stream.into(File.stream!(stripped)) |> Stream.run()
    File.rm!(path)
    stripped
  end

  # As `WorkspaceBundle`'s `copy_source/1`: the import's own extracted member.
  # sobelow_skip ["Traversal.FileModule"]
  defp source({:file, path}), do: File.stream!(path, @chunk_bytes)
  defp source(dump) when is_binary(dump), do: [dump]
end
