defmodule Barkpark.Media.Usage do
  @moduledoc """
  Which documents use a media file, as ONE caller may see them: the Studio
  media library's "Used in" list and `GET /v1/media/:dataset/:id/usage`
  (`bp media usage`).

  The documents are the ones `Media.WhereUsed` finds for the delete guard, the
  same two halves and no second walker:

    * the TEXTUAL half: a document whose content holds the file's delivery
      path (`/media/files/<path>`), as a paper block embeds it;
    * the STRUCTURAL half: a document whose schema image/file field holds a
      `_ref` to the file's companion `mediaAsset` document.

  ## Who sees what

  The delete guard counts every referrer in the file's workspace on purpose (a
  guard that missed one would blank a page). This list must not: it names only
  documents the caller could read anyway, so neither half answers from the
  guard's own reads.

    * Textual: `WhereUsed.textual_rows/4` runs the scan with the caller's
      read scope in the SQL — the stack every id hydration uses
      (`Content.Query.scope_as_id_read/3`: dataset, workspace and project,
      owner-scoped types, grants, private schemas) — so a document the
      caller cannot read is never fetched. Each fetched document is then
      rendered through `Envelope.render/3` as the caller, and must still hold
      the delivery path: a path inside a field this caller may not read does
      not count. The scan pages until more than the cap have passed that
      check, so a dropped document never takes a cap slot either.
    * Structural: `Content.Query.list_reference_holders/3` (the backlinks
      read) runs with the caller's own context and scope, so its row, grant,
      type and field-visibility fences apply as they do to backlinks.

  A caller held to the published perspective (`published_only: true`) sees no
  draft rows. `total` counts the documents the caller may see, never the
  guard's count. `truncated` is true when more than the cap of textual uses
  pass both checks, so `total` is then a floor. Neither `total`, `truncated`
  nor the list depends on a document or field the caller may not read. Time
  can: each extra page the field check forces is one more scan.

  The caller must already hold the file (the route reads it through
  `Media.get_file/2` with the same scope first); this module does not check it.
  """

  alias Barkpark.Content
  alias Barkpark.Content.{Envelope, Query, Schema}
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Media.WhereUsed

  # The most documents one answer lists; `total` still counts them all.
  @shown 100

  @typedoc "One document that uses the file."
  @type row :: %{
          id: String.t(),
          type: String.t(),
          title: String.t() | nil,
          draft: boolean(),
          published: boolean()
        }

  @doc "The most documents one answer lists."
  def shown, do: @shown

  @doc """
  The documents in `dataset` that use `file`, as the caller behind `opts` may
  read them: `%{documents: [row], total: n, truncated: boolean}`.

  `opts` are the caller's read opts (`ScopeHelpers.scope_opts/1`:
  `workspace_id`, `project_id`, `caller_context`, `grant_scoped`) plus
  `published_only`. A draft and its published version are one row; `draft`
  and `published` say which of them uses the file.
  """
  @spec list(MediaFile.t(), String.t(), keyword()) :: %{
          documents: [row()],
          total: non_neg_integer(),
          truncated: boolean()
        }
  def list(%MediaFile{} = file, dataset, opts) when is_binary(dataset) do
    {published_only, read_opts} = Keyword.pop(opts, :published_only, false)

    {textual, truncated} = textual(file, dataset, read_opts)

    rows =
      (textual ++ structural(file, dataset, read_opts))
      |> Enum.reject(&(published_only and Content.draft?(&1.doc_id)))
      |> Enum.uniq_by(& &1.doc_id)

    documents =
      rows
      |> Enum.group_by(&Content.published_id(&1.doc_id))
      |> Enum.map(fn {id, versions} -> one_row(id, versions) end)
      |> Enum.sort_by(&{String.downcase(&1.title || ""), &1.id})

    %{documents: Enum.take(documents, @shown), total: length(documents), truncated: truncated}
  end

  defp textual(file, dataset, opts) do
    url = WhereUsed.delivery_path(file)
    ctx = Keyword.get(opts, :caller_context)
    keep = &holding_url(&1, url, dataset, opts, ctx)
    {docs, truncated} = WhereUsed.textual_rows(file, dataset, opts, keep)
    {Enum.map(docs, &%{doc_id: &1.doc_id, type: &1.type, title: &1.title}), truncated}
  end

  # The documents of one page that, as the caller would receive them, still
  # hold the path. An admin sees every field, so its render can only equal the
  # stored content. One schema read per type per page.
  defp holding_url(page, _url, _dataset, _opts, %{is_admin: true}), do: page

  defp holding_url(page, url, dataset, opts, ctx) do
    schemas =
      page
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Map.new(fn type ->
        case Schema.get_schema_for_redaction(type, dataset, opts) do
          {:ok, schema} -> {type, schema}
          :error -> {type, nil}
        end
      end)

    Enum.filter(page, fn doc ->
      doc
      |> Envelope.render(schemas[doc.type], ctx)
      |> Jason.encode!()
      |> String.contains?(url)
    end)
  end

  defp structural(file, dataset, opts) do
    case WhereUsed.structural_target(file) do
      nil ->
        []

      {target, patterns} ->
        target
        |> Query.list_reference_holders(dataset, [asset_ref_patterns: patterns] ++ opts)
        |> Enum.map(&%{doc_id: &1.doc_id, type: &1.type, title: &1.title})
    end
  end

  # A draft's title wins, as in the desk's incoming references: it is what the
  # editor will see when the link opens.
  defp one_row(id, versions) do
    draft = Enum.find(versions, &Content.draft?(&1.doc_id))
    published = Enum.find(versions, &(not Content.draft?(&1.doc_id)))
    shown = draft || published

    %{
      id: id,
      type: shown.type,
      title: shown.title,
      draft: draft != nil,
      published: published != nil
    }
  end
end
