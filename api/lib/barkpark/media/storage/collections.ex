defmodule Barkpark.Media.Storage.Collections do
  @moduledoc """
  Folder and virtual media collections — membership queries and member CRUD.
  """

  import Ecto.Query
  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Document
  alias Barkpark.Content.Schema
  alias Barkpark.Content.Scope
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @collection_type "mediaCollection"
  @asset_type "mediaAsset"

  # Keys threaded into the tenancy WHERE clause (`Content.Scope`). Membership
  # writes and inner doc reads are dataset-keyed; the scope opts ride the
  # collection list/get reads so a workspace-B caller never sees workspace-A
  # collections (Wave 1.5 media-collections scope, Goal barkpark-qprk).
  #
  # `:grant_scoped` + `:caller_context` are here for task-2b7cbaf8265f6b4e.
  # `Content.Query.get_document/4` DOES call `Scope.maybe_scope_to_grants/2`,
  # but that gate reads its own flag off the opts it is handed: with the flag
  # taken out by `scope_opts/1` it saw `grant_scoped: false` and no-opped, so a
  # grant-derived caller resolved collections across the WHOLE workspace rather
  # than their grant ladder. `Scope`'s "there is no private copy of the gate
  # anywhere" is true and was beside the point — the one gate was being REACHED
  # with the input that disables it. Both keys are absent on every member
  # request (`ScopeHelpers.scope_opts/1` sets `:grant_scoped` only when
  # `ResolveWorkspace` admitted a grantee), so a member's read is unchanged.
  @scope_keys [:workspace_id, :project_id, :grant_scoped, :caller_context]

  # The NON-tenancy half of what the collection-assets search door accepts.
  #
  # The tenancy half is deliberately NOT repeated here:
  # `collection_search_opts/3` takes `@scope_keys ++ @search_passthrough_keys`,
  # so the search door and the collection GATE (`scope_opts/1`) read the same
  # constant and cannot drift apart. That linkage is the point — this module's
  # allowlists have now silently dropped a security-relevant key THREE times,
  # each time by hand-maintaining a second list:
  #
  #   1. `:grant_scoped` / `:caller_context` (task-2b7cbaf8265f6b4e) — the gate
  #      was reached with the input that disables it, so a grant-derived caller
  #      resolved collections across the whole workspace.
  #   2. `:visibility_clamp` — the unauthenticated read ceiling enforced nothing
  #      on this door while enforcing on its `/v1/media/:ds` sibling.
  #   3. `:workspace_id` / `:project_id` (task-f42f7f9c2d10f0bb) — the gate was
  #      scoped and the PAYLOAD was not, so a `virtual` collection answered with
  #      an unscoped media search over the dataset STRING.
  #
  # A `Keyword.take/2` allowlist is still the right shape for the door: the
  # search opts are a closed vocabulary, and passing unknown keys through to
  # `Media.search_files/2` is how the ORIGINAL leak on this module happened.
  # What was wrong was maintaining the tenancy vocabulary TWICE. Deriving it
  # from `@scope_keys` means the next key added for the gate reaches the search
  # for free, which is the failure mode all three incidents share.
  @search_passthrough_keys [
    :limit,
    :offset,
    :sort,
    :facets,
    :facet_selections,
    :visibility_clamp
  ]

  @doc "List collection documents for a dataset (workspace-scoped via opts)."
  @spec list(String.t(), keyword()) :: [Document.t()]
  def list(dataset, opts \\ []) when is_binary(dataset) do
    limit = Keyword.get(opts, :limit, 200) |> min(1000)
    offset = Keyword.get(opts, :offset, 0) |> max(0)

    dataset
    |> list_query(opts)
    |> order_by([d], asc: d.title)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Grand total of collections matching `list/2`'s predicates, ignoring paging.

  The sibling `list/2` returns a bare list, so `/v1/media/:ds/collections` could
  only report `count: length(collections)` — the PAGE ROWS — while its
  `/v1/media/:ds` sibling reports `count: total`, the GRAND TOTAL. One noun, two
  opposite meanings, and both readings produce a plausible non-negative integer,
  so a client pages wrong with no error (task-3d7a770cf4ea11cd). This exists so
  the collections envelope can carry an unambiguous `total`/`hasMore` pair
  additively, WITHOUT re-pointing the shipped `count` key on either route.

  It shares `list_query/2` with `list/2` on purpose: a count derived from a
  hand-copied set of predicates is exactly how a total drifts away from the rows
  it is supposed to be counting — including the public-read tier clamp, which
  must narrow the total the same way it narrows the page.
  """
  @spec count(String.t(), keyword()) :: non_neg_integer()
  def count(dataset, opts \\ []) when is_binary(dataset) do
    dataset
    |> list_query(opts)
    |> Repo.aggregate(:count, :id)
  end

  defp list_query(dataset, opts) do
    Document
    |> where([d], d.type == ^@collection_type and d.dataset == ^dataset)
    |> Scope.scope_to_workspace_or_global(opts[:workspace_id], opts[:project_id])
    |> restrict_public_read_tier(dataset, opts)
    |> exclude_shadowed_drafts()
  end

  # ONE ROW PER FOLDER. A share used to be written through `upsert_document/4`,
  # which writes `drafts.<id>`, so sharing a PUBLISHED folder forked it into a
  # draft twin (fixed at the write in task-9289f78cfbe3dd3d). Folders forked
  # before that fix are still in deployed databases, and the index listed both
  # rows: the sidebar and the "Add to collection" select showed the folder
  # twice. Read-side heal, no stored-data change: a draft whose published twin
  # exists in the same tenancy is not listed; the published row stands for the
  # folder and `pending_drafts/3` flags it when the draft differs. A folder that
  # is ONLY a draft (never published) is still listed. The page rows and
  # `count/2` share this predicate, so `total` agrees with the rows.
  defp exclude_shadowed_drafts(query) do
    where(
      query,
      [d],
      not fragment(
        "(? LIKE 'drafts.%' AND EXISTS (SELECT 1 FROM documents p WHERE p.type = ? AND p.dataset = ? AND 'drafts.' || p.doc_id = ? AND p.workspace_id IS NOT DISTINCT FROM ? AND p.project_id IS NOT DISTINCT FROM ?))",
        d.doc_id,
        d.type,
        d.dataset,
        d.doc_id,
        d.workspace_id,
        d.project_id
      )
    )
  end

  @doc """
  The published folder ids among `docs` whose draft twin carries different
  title or content — the "draft pending" indicator for the one row `list/2`
  shows per forked folder. The draft itself stays readable by its own id
  (`get/3`, `assets/3`), so an author can still see and edit it.
  """
  @spec pending_drafts([Document.t()], String.t(), keyword()) :: MapSet.t(String.t())
  def pending_drafts(docs, dataset, opts \\ []) when is_list(docs) and is_binary(dataset) do
    published =
      for %Document{doc_id: id} = doc <- docs, not draft_id?(id), into: %{}, do: {id, doc}

    case Map.keys(published) do
      [] ->
        MapSet.new()

      ids ->
        draft_ids = Enum.map(ids, &("drafts." <> &1))

        Document
        |> where([d], d.type == ^@collection_type and d.dataset == ^dataset)
        |> where([d], d.doc_id in ^draft_ids)
        |> Scope.scope_to_workspace_or_global(opts[:workspace_id], opts[:project_id])
        |> Repo.all()
        |> Enum.flat_map(fn draft ->
          pub = Map.fetch!(published, Content.published_id(draft.doc_id))
          if differs?(draft, pub), do: [pub.doc_id], else: []
        end)
        |> MapSet.new()
    end
  end

  @doc """
  The folder a share link SERVES. A link minted on a draft twin before
  task-9289f78cfbe3dd3d resolves to that draft row, but membership names the
  folder's published id, so the link served an empty gallery. When the token's
  row is a draft whose published twin exists in the same tenancy, the share
  serves the PUBLISHED folder — its metadata and its assets, never the draft's
  unpublished state. A draft-only folder serves itself, as before.
  """
  @spec shared_folder(Document.t(), String.t()) :: Document.t()
  def shared_folder(%Document{doc_id: doc_id} = token_row, dataset) when is_binary(dataset) do
    if draft_id?(doc_id) do
      Document
      |> where([d], d.type == ^@collection_type and d.dataset == ^dataset)
      |> where([d], d.doc_id == ^Content.published_id(doc_id))
      |> same_tenancy(token_row)
      |> Repo.one()
      |> case do
        %Document{} = published -> published
        nil -> token_row
      end
    else
      token_row
    end
  end

  defp same_tenancy(query, %Document{workspace_id: nil, project_id: nil}),
    do: where(query, [d], is_nil(d.workspace_id) and is_nil(d.project_id))

  defp same_tenancy(query, %Document{workspace_id: ws, project_id: nil}),
    do: where(query, [d], d.workspace_id == ^ws and is_nil(d.project_id))

  defp same_tenancy(query, %Document{workspace_id: nil, project_id: pj}),
    do: where(query, [d], is_nil(d.workspace_id) and d.project_id == ^pj)

  defp same_tenancy(query, %Document{workspace_id: ws, project_id: pj}),
    do: where(query, [d], d.workspace_id == ^ws and d.project_id == ^pj)

  defp draft_id?(id), do: String.starts_with?(id, "drafts.")

  defp differs?(%Document{} = draft, %Document{} = published),
    do: draft.title != published.title or (draft.content || %{}) != (published.content || %{})

  @doc """
  Fetch a collection document by id (workspace-scoped via opts).

  CLAMPED for the public-read tier — see `restrict_public_read_tier?/1`. The
  UNCLAMPED read is `fetch/3` and it is private on purpose: `assets/3` is the
  one caller entitled to it, because `share_view/2` reaches it with a resolved
  share token and no caller context at all.
  """
  @spec get(String.t(), String.t(), keyword()) :: {:ok, Document.t()} | {:error, :not_found}
  def get(collection_id, dataset, opts \\ [])
      when is_binary(collection_id) and is_binary(dataset) do
    if restrict_public_read_tier?(opts[:caller_context]) and
         @collection_type not in Schema.public_type_names(dataset, scope_opts(opts)) do
      {:error, :not_found}
    else
      fetch(collection_id, dataset, opts)
    end
  end

  @doc """
  Search assets belonging to a collection.

  DELIBERATELY reaches the UNCLAMPED `fetch/3` rather than `get/3`, and that is
  the whole reason this row was split out of PR #14582:
  `MediaCollectionsController.share_view/2` resolves a share token to a
  collection and then calls THIS function with no caller context — the resolved
  share token IS the principal, by documented design. Routing the collection
  lookup here through the clamp would 404 every live share link onto a
  collection whose type is not public-visibility.

  This does NOT re-open the door the clamp closes. The scoped assets endpoint
  (`MediaCollectionsController.assets/2`) calls `get/3` itself as an explicit
  pre-gate before it ever reaches this function, so a public-read caller is
  refused upstream; and the ASSETS in the payload carry their own ceiling via
  `visibility_clamp_opts/1` (PR #14582). A shared predicate is only as good as
  its least-compliant consumer, so the exemption is named here rather than left
  to whichever opts a future caller happens to pass.
  """
  @spec assets(String.t(), String.t(), keyword()) :: {[struct()], non_neg_integer(), map()}
  def assets(collection_id, dataset, opts \\ []) when is_binary(collection_id) do
    with {:ok, collection} <- fetch(collection_id, dataset, opts) do
      search_opts = collection_search_opts(collection, collection_id, opts)
      {files, total, facets, _meta} = Media.search_files(dataset, search_opts)
      {files, total, facets}
    else
      _ -> {[], 0, %{}}
    end
  end

  @doc "Add an asset blob to a folder collection (workspace-scoped via opts)."
  @spec add_member(String.t(), %MediaFile{}, String.t(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def add_member(collection_id, %MediaFile{} = file, dataset, opts \\ []) do
    with {:ok, _collection} <- get(collection_id, dataset, opts),
         {:ok, doc} <- Media.patch_asset_metadata(file, %{}, dataset) do
      patch_membership(doc, file, dataset, collection_id, :add)
    end
  end

  @doc "Remove an asset blob from a folder collection (workspace-scoped via opts)."
  @spec remove_member(String.t(), %MediaFile{}, String.t(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def remove_member(collection_id, %MediaFile{} = file, dataset, opts \\ []) do
    with {:ok, _collection} <- get(collection_id, dataset, opts),
         %Document{} = doc <- Media.asset_doc_for_file(file, dataset) do
      patch_membership(doc, file, dataset, collection_id, :remove)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Render a collection for API responses."
  @spec render(Document.t()) :: map()
  def render(%Document{} = doc), do: render(doc, false)

  @doc """
  `render/1` plus the draft-pending indicator `list/2`'s one-row-per-folder
  index carries: `draftPending: true` and the twin's `draftId` when the folder
  has an unpublished draft that differs (`pending_drafts/3`).
  """
  @spec render(Document.t(), boolean()) :: map()
  def render(%Document{} = doc, true),
    do: doc |> render(false) |> Map.merge(%{draftPending: true, draftId: "drafts." <> doc.doc_id})

  def render(%Document{} = doc, false) do
    content = doc.content || %{}

    %{
      id: doc.doc_id,
      title: doc.title,
      slug: Map.get(content, "slug"),
      description: Map.get(content, "description"),
      kind: Map.get(content, "kind", "folder"),
      virtualFilter: Map.get(content, "virtualFilter"),
      parent: Map.get(content, "parent"),
      coverAsset: Map.get(content, "coverAsset"),
      sortOrder: Map.get(content, "sortOrder"),
      shareEnabled: share_enabled?(content),
      shareExpiresAt: share_expires_at(content),
      createdAt: doc.inserted_at,
      updatedAt: doc.updated_at
    }
  end

  # ── the public-read schema-visibility clamp (task-b4a4b33bfb6e2954) ─────────
  #
  # THE LEAK. `list/2` was a bare `Repo.all` over `mediaCollection` documents
  # with tenancy scoping and NO schema-visibility filter, and `get/3` goes
  # through `Content.Query.get_document/4`, a single-type keyed read that
  # carries none either. So a `public-read` token — the browser-shipped site
  # credential `cloud/sites/deploy.ex` bakes into a built site as
  # `BARKPARK_TOKEN` — was served a private-visibility collection's TITLE and
  # DESCRIPTION. `Tenancy.Auth`'s `@read_perms` maps `public-read -> :read`, so
  # it clears `ResolveWorkspace`'s membership gate, and `:scoped_api` mounts no
  # `Plugs.PublicRead` and must not (search-template D49). This is the THIRD
  # door around the one clamp: the document surface 404s the type
  # (`PublicRead`'s `schema_public?` arm), the scoped search door filters it
  # (`DocumentsRetriever.restrict_anonymous_to_public_types/3`), and this one
  # had nothing. MEASURED, with the admin control green in the same run:
  # `test/barkpark/media/scoped_media_public_read_tier_audit_test.exs`.
  #
  # THE TIER TEST IS BORROWED, NEVER RE-IMPLEMENTED.
  # `Schema.bypasses_visibility_gate?/1` (canonical slug
  # `visibility-gate-tier`) is the one owner of "which tier is asking", shared
  # with the anonymous search allowlist, the batch document read and the
  # corpus-graph clamp. PR #14582 keyed `Media.Storage.Access.authenticated?/1`
  # on it for the ASSET tier rather than adding a fourth hand-rolled
  # `"public-read" in permissions`; this is the same move at the collection
  # seat. A literal role check here would be the fourth copy.
  #
  # WHY THIS IS NOT SIMPLY `not bypasses_visibility_gate?/1`, WHICH WOULD BE
  # THE SHORTER LINE. That predicate is default-narrow: it answers FALSE for an
  # anonymous caller too, by construction. Using it alone as the clamp key
  # would therefore clamp ANONYMOUS as well — and the flat
  # `/v1/media/:dataset/collections` route is anonymous-reachable, so that
  # flips the anonymous index from "every collection" to "none" whenever
  # `mediaCollection` is not a public-visibility schema. That is a PRODUCT
  # decision about the public demo surface, not a mechanical security fix, and
  # it is left OPEN on task-b4a4b33bfb6e2954 rather than smuggled in here.
  #
  # So the key is narrowed to what is unambiguous: a caller that carries an
  # AUTHENTICATED principal and is in the public-read tier. The two halves are
  # different questions and only the second is delegated:
  #
  #   * `principal_type in [:api_token, :user]` — is a principal present at
  #     all? Anonymous and the no-context share path fall out here, unchanged.
  #   * `bypasses_visibility_gate?/1` — has that principal earned the wide
  #     view? THE canonical owner, membership-keyed (`TokenController` mints
  #     `["public-read", "read"]` over a public route, so a list-equality pin
  #     would be escapable by construction).
  #
  # The narrow arm FAILS CLOSED for the tier it does cover: `public_type_names`
  # is derived at READ TIME, so a schema flipped to private drops out on the
  # very next read, and an empty allowlist means the caller sees NOTHING.
  defp restrict_public_read_tier?(%CallerContext{principal_type: p} = ctx)
       when p in [:api_token, :user],
       do: not Schema.bypasses_visibility_gate?(ctx)

  # Anonymous, `nil` (the `share_view/2` path passes no caller context), a bare
  # map, and any future principal shape: today's answer, untouched.
  defp restrict_public_read_tier?(_), do: false

  defp restrict_public_read_tier(query, dataset, opts) do
    if restrict_public_read_tier?(opts[:caller_context]) do
      where(query, [d], d.type in ^Schema.public_type_names(dataset, scope_opts(opts)))
    else
      query
    end
  end

  # Keep only the tenancy keys so the rest of `opts` (limit/offset/sort/…) never
  # leaks into the keyed `Content.get_document` read.
  defp scope_opts(opts), do: Keyword.take(opts, @scope_keys)

  # The UNCLAMPED collection read. Private, and it stays private: `get/3` is the
  # public entry point and carries the clamp, so a new caller reaching for a
  # collection gets the clamped answer by default. `assets/3` is the one
  # exemption and says why at its own @doc.
  defp fetch(collection_id, dataset, opts) do
    case Content.get_document(collection_id, @collection_type, dataset, scope_opts(opts)) do
      {:ok, doc} -> {:ok, doc}
      _ -> {:error, :not_found}
    end
  end

  defp collection_search_opts(%Document{content: content}, collection_id, opts) do
    base =
      opts
      # A key absent from this take is dropped SILENTLY, which is why both
      # halves are named constants rather than a literal list here.
      #
      # `@scope_keys` carries the tenancy pair the caller actually resolved.
      # Without it `Search.build_query/2` read `nil` for `:workspace_id` and
      # handed it to `scope_to_workspace_or_global/3`, whose nil arm returns
      # the query UNTOUCHED — so a `virtual` collection (which sets no
      # `:collection` filter) answered with an unscoped media search across
      # every workspace sharing the dataset string, in its rows, its `total`,
      # AND every facet bucket.
      #
      # `:visibility_clamp` is the unauthenticated read ceiling and MUST also
      # survive: it rides ALONGSIDE `:visibility` (set by a virtual
      # collection's own filter, below) rather than replacing it — the filter
      # narrows, the clamp bounds.
      |> Keyword.take(@scope_keys ++ @search_passthrough_keys)
      |> Keyword.put_new(:limit, 50)
      |> Keyword.put_new(:offset, 0)
      |> Keyword.put_new(:sort, "created-desc")

    case Map.get(content || %{}, "kind", "folder") do
      "virtual" ->
        virtual_filter = Map.get(content || %{}, "virtualFilter", %{})
        virtual_to_search_opts(base, virtual_filter)

      _ ->
        Keyword.put(base, :collection, collection_id)
    end
  end

  defp virtual_to_search_opts(base, filter) when is_map(filter) do
    base
    |> maybe_put(:kind, blank_to_nil(filter["kind"]))
    |> maybe_put(:tags, blank_to_nil(filter["tags"]))
    |> maybe_put(:q, blank_to_nil(filter["q"]))
    |> maybe_put(:mime_type, blank_to_nil(filter["mimeType"]))
    |> maybe_put(:visibility, blank_to_nil(filter["visibility"]))
  end

  defp virtual_to_search_opts(base, _), do: base

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp patch_membership(doc, file, dataset, collection_id, :add) do
    content = doc.content || %{}
    collections = normalize_ref_list(Map.get(content, "collections", []))

    collections =
      if collection_id in collections do
        collections
      else
        collections ++ [collection_id]
      end

    primary = Map.get(content, "collection") || collection_id

    attrs = %{
      "doc_id" => doc.doc_id,
      "title" => doc.title,
      "status" => doc.status,
      "content" =>
        content
        |> Map.put("collection", primary)
        |> Map.put("collections", collections)
        |> Map.put("mediaFileId", file.id)
    }

    Content.upsert_document(
      @asset_type,
      attrs,
      dataset,
      [source: :api] ++ MediaFile.scope_opts(file)
    )
  end

  defp patch_membership(doc, file, dataset, collection_id, :remove) do
    content = doc.content || %{}
    collections = normalize_ref_list(Map.get(content, "collections", [])) -- [collection_id]

    primary =
      if Map.get(content, "collection") == collection_id do
        List.first(collections)
      else
        Map.get(content, "collection")
      end

    attrs = %{
      "doc_id" => doc.doc_id,
      "title" => doc.title,
      "status" => doc.status,
      "content" =>
        content
        |> Map.put("collection", primary)
        |> Map.put("collections", collections)
        |> Map.put("mediaFileId", file.id)
    }

    Content.upsert_document(
      @asset_type,
      attrs,
      dataset,
      [source: :api] ++ MediaFile.scope_opts(file)
    )
  end

  defp normalize_ref_list(list) when is_list(list) do
    list
    |> Enum.map(fn
      %{"_ref" => ref} -> ref
      ref when is_binary(ref) -> ref
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_ref_list(_), do: []

  defp share_enabled?(content) do
    link = Map.get(content, "shareLink", %{})
    Map.get(link, "enabled") in [true, "true"]
  end

  defp share_expires_at(content) do
    content
    |> Map.get("shareLink", %{})
    |> Map.get("expiresAt")
  end
end
