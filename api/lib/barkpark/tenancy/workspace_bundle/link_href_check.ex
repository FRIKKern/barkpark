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

  The `documents` and `revisions` members, before anything is written, for
  the restore and the remap into a dataset alike. A revision is stripped
  too: restoring one puts its content back without the fence, which
  assumes a stored revision passed it. In each row, every `markDefs` list in
  the content, as the fence reads it (`LinkHrefFence.refused/2`): a `link`'s
  `href`, a `linkAnnotation`'s `url`, `href` and `damFileUrl`.

  Not read: an `<a href>` inside a rich text value stored as an HTML string.
  The fence reads those only where the schema types the field `richText`,
  and the check has no schema before the import; rewriting every string
  that looks like markup would change plain text.
  """

  require Logger

  alias Barkpark.Content.{LinkHref, LinkHrefFence}
  alias Barkpark.Tenancy.WorkspaceBundle.CopyText

  @tables ~w(documents revisions)
  @chunk_bytes 64 * 1024

  # As `LinkHrefFence`'s `@link_keys`; the tests hold the two together
  # (after a strip, `LinkHrefFence.refused/2` finds nothing).
  @link_keys %{"link" => ~w(href), "linkAnnotation" => ~w(url href damFileUrl)}

  @typedoc "One stripped address."
  @type finding :: %{
          table: String.t(),
          doc_id: String.t() | nil,
          path: String.t(),
          href: String.t()
        }

  @doc """
  The bundle's members with each refused link address stripped, and the
  findings. `dumps` maps a member's name to its bytes or `{:file, path}`; a
  member with nothing to strip is returned as it was.
  """
  @spec strip(map(), Enumerable.t()) :: {map(), [finding()]}
  def strip(manifest, dumps) do
    dumps = Map.new(dumps)

    for %{"name" => table, "columns" => cols} <- manifest["tables"] || [],
        table in @tables,
        content = Enum.find_index(cols, &(&1 == "content")),
        dump = dumps[table],
        dump != nil,
        reduce: {dumps, []} do
      {dumps, found} ->
        doc_id = Enum.find_index(cols, &(&1 == "doc_id"))

        case rows_found(dump, content, doc_id) do
          [] ->
            {dumps, found}

          here ->
            here =
              Enum.map(here, fn {id, path, href} ->
                %{table: table, doc_id: id, path: path, href: href}
              end)

            {Map.put(dumps, table, rewrite(dump, content)), found ++ here}
        end
    end
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
          "(#{f.doc_id || "no doc_id"} #{f.path}): #{inspect(String.slice(f.href, 0, 40))}"
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

  # Only a row whose content names `markDefs` can hold a link.
  defp candidate?(fields, content),
    do: :binary.match(Enum.at(fields, content) || "", "markDefs") != :nomatch

  defp decoded(fields, content) do
    case Jason.decode(CopyText.value(fields, content) || "null") do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  defp rows_found(dump, content, doc_id) do
    dump
    |> source()
    |> CopyText.rows()
    |> Stream.filter(&candidate?(&1, content))
    |> Enum.flat_map(fn fields ->
      id = doc_id && CopyText.value(fields, doc_id)
      {_value, found} = strip_content(decoded(fields, content), "")
      for {path, href} <- found, do: {id, path, href}
    end)
  end

  # The member again, each row with something to strip written with its
  # content stripped and every other row as it was.
  defp rewrite(dump, content) do
    lines =
      dump
      |> source()
      |> CopyText.rows()
      |> Stream.map(fn fields ->
        fields =
          with true <- candidate?(fields, content),
               {value, [_ | _]} <- strip_content(decoded(fields, content), "") do
            List.replace_at(fields, content, CopyText.escape(Jason.encode!(value)))
          else
            _ -> fields
          end

        [Enum.join(fields, "\t"), "\n"]
      end)

    case dump do
      {:file, path} -> {:file, write!(path, lines)}
      _bytes -> lines |> Enum.to_list() |> IO.iodata_to_binary()
    end
  end

  # Next to the extracted member, which it replaces: the member is deleted
  # the moment the stripped copy is written, as the import deletes each
  # member once its COPY is done.
  # sobelow_skip ["Traversal.FileModule"]
  defp write!(path, lines) do
    stripped = path <> ".links"
    lines |> Stream.into(File.stream!(stripped)) |> Stream.run()
    File.rm!(path)
    stripped
  end

  defp source({:file, path}), do: File.stream!(path, @chunk_bytes)
  defp source(dump) when is_binary(dump), do: [dump]
end
