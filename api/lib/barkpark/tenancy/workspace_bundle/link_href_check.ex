defmodule Barkpark.Tenancy.WorkspaceBundle.LinkHrefCheck do
  @moduledoc """
  A bundle import refuses a bundle whose content holds a link address a
  write refuses (task-9d0496cb3f369ed1, #28393 review).

  The import writes document rows with a raw `COPY … FROM STDIN`, past the
  Writer and its pre-write fences, `Content.LinkHrefFence` among them. So a
  bundle could store a Portable Text link whose address is `javascript:`,
  `vbscript:` or `data:` (`Content.LinkHref.write_refused?/1`). The reader
  draws such a link as its words (#28371), so nothing ran, but every other
  reader of the stored JSON would get it.

  The check reads the `documents` and `revisions` members before anything
  is written, for both the restore and the remap into a dataset. It reads
  every `markDefs` list in a row's content, as the fence does
  (`LinkHrefFence.refused/2`): a `link`'s `href`, a `linkAnnotation`'s
  `url`, `href` and `damFileUrl`. A revision is read too: restoring one puts
  its content back without the fence. A bundle that holds one is refused
  whole, as an `InvalidBundleError` with the code `pt_link_href_refused`
  (422 at the HTTP edge), naming each row and the address's JSON pointer.

  Not read: an `<a href>` inside a rich text value stored as an HTML string.
  The fence reads those only where the schema types the field `richText`,
  and the check has no schema before the import.
  """

  alias Barkpark.Content.LinkHrefFence
  alias Barkpark.Tenancy.WorkspaceBundle.{CopyText, InvalidBundleError}

  @tables ~w(documents revisions)
  @code "pt_link_href_refused"
  @shown 10
  @chunk_bytes 64 * 1024

  @doc "The error code a refused bundle carries."
  @spec code() :: String.t()
  def code, do: @code

  @doc """
  `:ok`, or raises `InvalidBundleError` naming the link addresses in the
  bundle's `documents` and `revisions` rows that a write refuses. `dumps`
  maps a member's name to its bytes or `{:file, path}`.
  """
  @spec refuse!(map(), Enumerable.t()) :: :ok
  def refuse!(manifest, dumps) do
    dumps = Map.new(dumps)

    found =
      for %{"name" => table, "columns" => cols} <- manifest["tables"] || [],
          table in @tables,
          content = Enum.find_index(cols, &(&1 == "content")),
          dump = dumps[table],
          dump != nil,
          finding <- found(dump, content, Enum.find_index(cols, &(&1 == "doc_id"))),
          do: Tuple.insert_at(finding, 0, table)

    if found == [] do
      :ok
    else
      raise InvalidBundleError, code: @code, message: message(found)
    end
  end

  defp found(dump, content, doc_id) do
    dump
    |> source()
    |> CopyText.rows()
    # Only a row whose content names `markDefs` can hold a link.
    |> Stream.filter(&(:binary.match(Enum.at(&1, content) || "", "markDefs") != :nomatch))
    |> Enum.flat_map(fn fields ->
      id = doc_id && CopyText.value(fields, doc_id)

      case Jason.decode(CopyText.value(fields, content) || "null") do
        {:ok, value} -> for {path, href} <- LinkHrefFence.refused(value, ""), do: {id, path, href}
        {:error, _} -> []
      end
    end)
  end

  defp source({:file, path}), do: File.stream!(path, @chunk_bytes)
  defp source(dump) when is_binary(dump), do: [dump]

  defp message(found) do
    shown =
      found
      |> Enum.take(@shown)
      |> Enum.map_join("; ", fn {table, id, path, href} ->
        "#{table} #{id || "(no doc_id)"} #{path}: #{inspect(String.slice(href, 0, 40))}"
      end)

    more = if length(found) > @shown, do: " (and #{length(found) - @shown} more)", else: ""

    "the bundle holds #{length(found)} link address(es) a write refuses " <>
      "(javascript:, vbscript: or data:), so nothing was imported: #{shown}#{more}"
  end
end
