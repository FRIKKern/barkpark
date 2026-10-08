defmodule Barkpark.Content.PreviewLocations do
  @moduledoc """
  "Used on N pages" (Studio J62, task-c5d5e045e7efcc96): resolves a
  document's backlinks into readable consumer-site URLs, not just
  referencing document ids.

  Reuses `Content.Graph.reverse_referencers/2`'s own fail-closed hydration
  for scoping (an unreadable source is dropped, never stubbed -- see that
  function's doc) and OWNS the SAME `desk.preview`/schema-action URL-template
  interpolation StudioLive's editor-header Preview action and every other
  schema-declared `"link"` action use for a single document
  (`interpolate/5`, below) -- `studio_components/editor.ex`'s
  `do_interpolate_href/5` delegates to it, so there is exactly ONE
  placeholder-substitution implementation for both the batch (backlinks ->
  locations) and single-document (StudioLive) callers, pinned equal by
  `studio_preview_link_action_test.exs`.

  A location is OMITTED, never emitted with a guessed/wrong URL, when:

    * its type's schema declares no `desk.preview` template, or
    * the template needs `:slug` and the referencing document has none.

  This mirrors `preview_doc_action/2`'s own "no button is better than a
  wrong one" rule for the single-document case.
  """

  alias Barkpark.Content

  @doc """
  `backlinks` is `Content.Graph.reverse_referencers/2`'s own result list
  (each entry carries `:from_doc_id`, `:type`, `:title`). `url_scope` names
  the SLUGS (not ids) a scoped caller's URL already carries:
  `%{workspace_slug: ..., project_slug: ...}` -- both `nil` for a flat
  (unscoped) caller, which interpolates to `""` same as an un-scoped
  schema-declared link action already does.

  Returns one location map per backlink whose type resolves to a URL --
  `%{doc_id, type, title, url}` -- so the list can be SHORTER than
  `backlinks` when some entries don't resolve. Same read scope (`opts`) as
  the backlinks call this wraps.
  """
  @spec resolve([map()], String.t(), keyword(), map()) :: [map()]
  def resolve(backlinks, dataset, opts, url_scope \\ %{}) when is_list(backlinks) do
    types = backlinks |> Enum.map(& &1.type) |> Enum.uniq()
    templates = Map.new(types, &{&1, preview_template(&1, dataset, opts)})

    ids = backlinks |> Enum.map(& &1.from_doc_id) |> Enum.uniq()
    docs_by_id = Content.get_documents_by_ids(ids, dataset, opts)

    Enum.flat_map(backlinks, &resolve_one(&1, templates, docs_by_id, dataset, url_scope))
  end

  @doc """
  The raw placeholder substitution ANY schema-declared `href` template uses
  -- `:workspace` · `:project` · `:dataset` · `:slug` · `:id`,
  longest-token-first (`:workspace`/`:project` before `:id` is not a prefix
  ambiguity today, but the ORDER is the invariant this list is built on, see
  `editor.ex`'s own comment). No resolvability check here — an unfilled
  placeholder becomes `""`; `resolve/4` is what REFUSES to emit a location
  whose `:slug` can't be filled. `studio_components/editor.ex`'s
  `do_interpolate_href/5` calls this directly, so a StudioLive-rendered
  link's href and this module's own `url` field are the SAME computation for
  the same inputs.
  """
  @spec interpolate(String.t(), map() | nil, String.t() | nil, String.t() | nil, String.t() | nil) ::
          String.t()
  def interpolate(template, doc, dataset, workspace_slug \\ nil, project_slug \\ nil) do
    id = Content.published_id(Map.get(doc || %{}, :doc_id) || "")

    template
    |> String.replace(":workspace", to_string(workspace_slug || ""))
    |> String.replace(":project", to_string(project_slug || ""))
    |> String.replace(":dataset", to_string(dataset || ""))
    |> String.replace(":slug", doc_slug(doc) || "")
    |> String.replace(":id", id)
  end

  defp resolve_one(bl, templates, docs_by_id, dataset, url_scope) do
    with template when is_binary(template) <- Map.get(templates, bl.type),
         %{} = doc <- Map.get(docs_by_id, bl.from_doc_id),
         {:ok, url} <- fill_template(template, doc, dataset, url_scope) do
      [%{doc_id: bl.from_doc_id, type: bl.type, title: bl.title, url: url}]
    else
      _ -> []
    end
  end

  defp preview_template(type, dataset, opts) do
    with {:ok, schema} <- Content.get_schema(type, dataset, opts),
         desk when is_map(desk) <- Map.get(schema, :desk) || Map.get(schema, "desk") || %{},
         template when is_binary(template) and template != "" <-
           Map.get(desk, "preview") || Map.get(desk, :preview) do
      template
    else
      _ -> nil
    end
  end

  defp fill_template(template, doc, dataset, url_scope) do
    if String.contains?(template, ":slug") and not is_binary(doc_slug(doc)) do
      :error
    else
      url =
        interpolate(
          template,
          doc,
          dataset,
          Map.get(url_scope, :workspace_slug),
          Map.get(url_scope, :project_slug)
        )

      {:ok, url}
    end
  end

  # Mirrors `BarkparkWeb.Studio.StudioLive.DocActions.doc_slug/1` exactly
  # (content["slug"] first, then the stored `slug_text` generated column) --
  # duplicated rather than called, per this module's own fence note above.
  defp doc_slug(%{} = doc) do
    content = Map.get(doc, :content) || %{}

    candidates = [
      if(is_map(content), do: Map.get(content, "slug")),
      Map.get(doc, :slug_text)
    ]

    Enum.find(candidates, fn
      s when is_binary(s) -> s != ""
      _ -> false
    end)
  end

  defp doc_slug(_), do: nil
end
