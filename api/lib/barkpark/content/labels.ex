defmodule Barkpark.Content.Labels do
  @moduledoc """
  Reference- and codelist-label resolution for View-mode rendering.

  Resolves a stored reference value (a plain doc-id string) to the referenced
  document's title, and a codelist CODE to its human LABEL. Builds the
  dataset-bound `render_opts` (and per-doc `paper_render_opts`) maps threaded
  into `Barkpark.PortableDoc.Render` so the rendered `field-reference` /
  `codelist` rows show the title / label instead of the raw id / code.

  Extracted from `Barkpark.Content` (concern C); the parent keeps a thin
  delegating facade for `reference_title/4` and `codelist_label/3`. The private
  `render_opts/1`, `paper_render_opts/2`, and `paper_style/2` are `@doc false`
  publics here, called by `Barkpark.Content`'s write/paper paths through this
  module.

  Reads `Repo` + `Document`. Scope resolution (`resolve_read_dataset_id/2`,
  `scope_to_workspace_or_global/3`) is borrowed through the facade /
  `Content.Scope` until the scope concern (K) is itself extracted — the
  `scope_to_dataset/3` query helper below is byte-identical to the facade's
  private copy, so behaviour is unchanged.
  """

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Content.{Document, DraftId}

  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]

  @doc """
  Resolve a referenced document's display title from a stored reference value.

  `value` is a plain doc-id string (the v1 reference-field persistence model);
  `ref_type` is the optional target schema (`""` when a paper field-reference
  block has no refType set). Returns the title of the matching document, or the
  original `value` as a fallback when no document is found / `value` is blank.

  Cheap by design — a single keyed read on `(doc_id, dataset)`, narrowed
  by `type` when `ref_type` is non-empty. The published id is preferred (a
  reference value stores the published id); both the published row and its
  `drafts.` twin satisfy the `doc_id IN (...)` clause, so an unpublished target
  still resolves — UNLESS `opts[:published_only]` is set (the anonymous/public
  reader), in which case the `drafts.` twin is dropped and a draft-only target
  degrades to the raw id rather than leaking a draft title. Used by the
  View-mode renderer to show the title instead of the raw id.

  NEVER raises on a non-unique `doc_id`. When `ref_type` is empty there is no
  type narrowing, so the same `doc_id` can match several rows (e.g. `p1` exists
  as both a `book` and a `post`). We therefore use `Repo.all` + an explicit
  in-Elixir pick (published row before its `drafts.` twin) instead of
  `Repo.one`, which would raise `Ecto.MultipleResultsError` if the `limit(1)`
  guard were ever dropped.
  """
  @spec reference_title(String.t() | nil, String.t() | nil, String.t(), keyword()) :: String.t()
  def reference_title(value, ref_type, dataset, opts \\ [])

  def reference_title(value, _ref_type, _dataset, _opts) when value in [nil, ""],
    do: value || ""

  def reference_title(value, ref_type, dataset, opts) when is_binary(value) do
    pub_id = DraftId.published_id(value)
    draft = DraftId.draft_id(pub_id)

    query =
      Document
      |> scope_to_dataset(dataset, opts)
      |> where([d], d.doc_id == ^pub_id or d.doc_id == ^draft)
      # Scope the reference resolution to the caller's tenant when supplied so a
      # reference value never resolves a same-id doc in another workspace
      # (barkpark-af50). Render-pipeline callers that pass no scope keep the
      # explicit-global behaviour via scope_to_workspace_or_global/3.
      |> scope_to_workspace_or_global(
        Keyword.get(opts, :workspace_id),
        Keyword.get(opts, :project_id)
      )
      |> order_by([d], asc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 ELSE 0 END", d.doc_id))

    query =
      if is_binary(ref_type) and ref_type != "" do
        where(query, [d], d.type == ^ref_type)
      else
        query
      end

    # D5 published-perspective gate (mirrors Query.maybe_published_only/2): an
    # anonymous/public caller passes `published_only: true` so a `drafts.`-only
    # target NEVER resolves its title (the `drafts.` twin is dropped and the
    # published row must actually be published). The reference then degrades to
    # the raw id instead of leaking a draft title. Absent/false ⇒ query
    # untouched, so the write/cache render path keeps its explicit behaviour.
    query =
      if Keyword.get(opts, :published_only, false) do
        prefix = DraftId.drafts_prefix() <> "%"
        where(query, [d], d.status == "published" and not like(d.doc_id, ^prefix))
      else
        query
      end

    # Repo.all + List.first: the published row (CASE = 0) sorts ahead of its
    # `drafts.` twin (CASE = 1), so the first row is the published-preferred
    # pick. Multiple-type matches (empty ref_type) never raise.
    case query |> Repo.all() |> List.first() do
      %Document{title: title} when is_binary(title) and title != "" -> title
      _ -> value
    end
  end

  @doc """
  Resolve a codelist CODE to its human LABEL for View-mode rendering.

  Looks the code up in the registered codelist `(plugin, codelist_id)` via
  `Barkpark.Content.Codelists.lookup/4` and returns its preferred-language
  label. Falls back to the raw `code` when the codelist is unregistered, the
  code is unknown, or `code`/`codelist_id` is blank. Dataset-independent —
  the codelist registry is keyed by `(plugin, list_id)`, not by dataset.
  """
  @spec codelist_label(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def codelist_label(plugin, codelist_id, code)

  def codelist_label(_plugin, _codelist_id, code) when code in [nil, ""], do: code || ""

  def codelist_label(plugin, codelist_id, code)
      when is_binary(plugin) and is_binary(codelist_id) and codelist_id != "" and is_binary(code) do
    case Barkpark.Content.Codelists.lookup(plugin, codelist_id, code) do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> code
    end
  end

  def codelist_label(_plugin, _codelist_id, code) when is_binary(code), do: code

  @doc false
  # Render options carrying the resolvers bound to a dataset. Passed to
  # `Render.render_block/2` / `render_blocks/2` so the View-mode
  # `field-reference` row shows the referenced doc's TITLE instead of the raw
  # id, and the `codelist` row shows the selected code's LABEL instead of the
  # raw code; everything else in `Render` stays pure.
  def render_opts(dataset), do: render_opts(dataset, [])

  @doc false
  # Scope-aware twin used by every persisted block render. The legacy arity
  # above intentionally remains explicit-global for callers whose data model is
  # global; scoped Paper/document writers bind reference resolution to the row
  # they are rendering so a same-id document in another tenant cannot leak into
  # a cached HTML projection.
  def render_opts(dataset, scope) when is_list(scope) do
    %{
      ref_resolver: fn value, ref_type -> reference_title(value, ref_type, dataset, scope) end,
      codelist_resolver: fn plugin, codelist_id, code ->
        codelist_label(plugin, codelist_id, code)
      end
    }
  end

  @doc false
  # The same resolvers as `render_opts/1`, plus the per-doc render `:style`.
  # Threaded into `Render.render_blocks/2` so a paper's body_html cache (and its
  # delta fragments) come out in the on-screen palette.
  #
  # task-1d095b61a47bf057: BOTH clauses now name `:article`. They used to
  # differ — a nil / non-"article" style returned style-less opts, so
  # `Render.render_block/2`'s `Map.get(opts, :style, :email)` default decided,
  # and every NON-article paper's `body_html` was inline-stamped EMAIL HTML.
  # That string is what the public web reader injects into `.bp-paper-surface`
  # (web/components/document-detail.tsx), so mail-client typography reached a
  # screen surface. The census on this row found no reader of `body_html` that
  # wants email HTML; the one consumer that does
  # (`bulldocs_email_controller.ex:39`) passes `style: :email` itself and
  # re-renders from blocks, so it is unaffected. The clauses are kept SEPARATE
  # rather than collapsed because the article/non-article split is still a real
  # distinction the renderer may re-acquire; today both map to `:article`.
  def paper_render_opts(dataset, style), do: paper_render_opts(dataset, style, [])

  @doc false
  def paper_render_opts(dataset, style, scope) when style in ["article", "article-wide"],
    do: Map.put(render_opts(dataset, scope), :style, :article)

  def paper_render_opts(dataset, _style, scope),
    do: Map.put(render_opts(dataset, scope), :style, :article)

  @doc false
  # Resolve the per-doc style marker for an upsert: an explicit `style` in attrs
  # wins (so an ingest/POST can set it), else the existing doc's stored style is
  # preserved (a partial update never silently demotes an article paper), else
  # nil (the email default). The two article widths share one render palette;
  # anything else is normalized away so we never persist a stray marker.
  def paper_style(attrs, existing) do
    explicit = attrs["style"]
    existing_style = existing && get_in(existing.content || %{}, ["style"])

    cond do
      explicit in ["article", "article-wide"] -> explicit
      is_binary(explicit) -> nil
      existing_style in ["article", "article-wide"] -> existing_style
      true -> nil
    end
  end

  # Byte-identical to `Barkpark.Content`'s private `scope_to_dataset/3` (concern
  # K, not yet extracted). Borrows the public `resolve_read_dataset_id/2`
  # through the facade so behaviour stays unchanged until K moves out.
  defp scope_to_dataset(query, dataset, opts) do
    case Barkpark.Content.resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [x], x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset))

      _ ->
        where(query, [x], x.dataset == ^dataset)
    end
  end
end
