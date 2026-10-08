defmodule Barkpark.Content.PreviewLocations do
  @moduledoc """
  "Used on N pages" (Studio J62, task-c5d5e045e7efcc96): resolves a
  document's backlinks into readable consumer-site URLs, not just
  referencing document ids.

  Reuses `Content.Graph.reverse_referencers/2`'s own fail-closed hydration
  for scoping (an unreadable source is dropped, never stubbed -- see that
  function's doc) and the SAME `desk.preview` URL-template vocabulary
  StudioLive's editor-header Preview action already interpolates for a
  single document (`doc_actions.ex` / `studio_components/editor.ex`) --
  independently RE-IMPLEMENTED here rather than imported, so a core HTTP
  read never depends on a LiveView-owned module (those live under
  `barkpark_web/live` and `barkpark_web/components/studio_components`,
  outside this module's fence).

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
    slug = doc_slug(doc)

    if String.contains?(template, ":slug") and not is_binary(slug) do
      :error
    else
      id = Content.published_id(Map.get(doc, :doc_id) || "")

      url =
        template
        |> String.replace(":workspace", to_string(Map.get(url_scope, :workspace_slug) || ""))
        |> String.replace(":project", to_string(Map.get(url_scope, :project_slug) || ""))
        |> String.replace(":dataset", to_string(dataset || ""))
        |> String.replace(":slug", slug || "")
        |> String.replace(":id", id)

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
