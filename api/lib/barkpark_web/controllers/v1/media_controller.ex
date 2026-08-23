defmodule BarkparkWeb.V1.MediaController do
  @moduledoc """
  Versioned media API at `/v1/media/:dataset`.

  Returns unified assets (blob + `mediaAsset` metadata). Binary bytes are
  still served from `/media/files/*path`.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Auth
  alias Barkpark.Content.Errors
  alias Barkpark.Media
  alias Barkpark.Media.Storage.{Access, Checkout, Relations}
  alias Barkpark.Media.Delivery.AssetResponse
  alias Barkpark.Search.{MediaIntelligence, SurfaceConfigs, Synonyms}
  alias Barkpark.Media.Delivery.SearchParams, as: MediaSearchParams
  alias BarkparkWeb.SearchIntel

  import BarkparkWeb.ParamCoercion, only: [bin: 1]
  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  action_fallback BarkparkWeb.FallbackController

  @default_limit 50
  @max_limit 500

  def search(conn, %{"dataset" => dataset} = params) do
    t0 = System.monotonic_time(:microsecond)
    opts = MediaSearchParams.parse(params) ++ scope_opts(conn)
    {files, total, facets, meta} = Media.search_files(dataset, opts)
    docs = Media.asset_docs_for_files(files, dataset, scope_opts(conn))
    render_opts = render_opts(conn, params)

    hits =
      Enum.map(files, fn file ->
        AssetResponse.render(file, Map.get(docs, file.id), render_opts)
      end)

    ms = div(System.monotonic_time(:microsecond) - t0, 1000)

    record_opts = [
      actor_key: SearchIntel.actor_key(conn),
      parent_event_id: SearchIntel.parent_event_id(conn),
      session_key: SearchIntel.session_key(conn),
      source: SearchIntel.source(conn, "explorer"),
      record: SearchIntel.should_record?(conn),
      tags: SearchIntel.tags(conn),
      metadata: search_metadata(meta),
      # Stamp the resolved tenant at ingest so the crystallizer rolls this event
      # up on its OWN row instead of merging tenants that share a scope.
      workspace_id: workspace_id(conn)
    ]

    record_result =
      MediaIntelligence.record(dataset, params, total, ms, record_opts)

    # `searchEventId: null` IS the honest wire answer for every no-write
    # outcome here (pds-bl-w36-record6-conflation): the id's only use is
    # interaction linking, and "nothing was recorded" needs no companion
    # field — unlike the interaction receipt, no success claim is made. The
    # CAUSE is no longer destroyed: `record/6` names it ({:skipped, reason})
    # and telemetry carries it; a reader who wants it on the wire changes
    # this case, not the recorder.
    search_event_id =
      case record_result do
        {:ok, id} -> id
        {:skipped, _reason} -> nil
        {:rejected, _reason} -> nil
      end

    # A next page exists only when the current page is FULL *and* the rows the
    # client has now seen (`offset + length(files)`) are still short of the full
    # distinct match count (`total`). The old check was `length(files) >= limit`
    # alone, which false-positived on an exact page boundary — a final page that
    # happens to be exactly `limit` rows reported hasMore:true with a cursor onto
    # an empty page. The `offset + length(files) < total` term closes that: on an
    # exact-`limit` last page the running total equals `total`, so hasMore:false.
    # The `>= limit` term is retained so cursor-following (offset stays 0 while
    # `total` still counts earlier pages) doesn't over-report on a partial final
    # page. Emit the cursor only when a next page genuinely exists, so an
    # exhausted result set never leaves a dangling cursor.
    limit = opts[:limit] || @default_limit
    offset = opts[:offset] || 0
    has_more = length(files) >= limit and offset + length(files) < total
    next_cursor = if has_more, do: Barkpark.Media.Delivery.Search.next_cursor(files), else: nil

    json(conn, %{
      result: %{
        hits: hits,
        total: total,
        limit: opts[:limit],
        offset: opts[:offset],
        facets: facets,
        nextCursor: next_cursor,
        hasMore: has_more
      },
      parsedQuery: meta[:parsed],
      highlights: meta[:highlights] || %{},
      recovery: meta[:recovery],
      searchEventId: search_event_id,
      syncTags: ["bp:ds:#{dataset}:media"],
      ms: ms
    })
  end

  def search_insights(conn, %{"dataset" => dataset} = params) do
    period = params["period"] || "week"

    # Read the caller's resolved `current_workspace`, matching the workspace the
    # record path stamps at ingest — so insights and events roll up on the SAME
    # tenant row. On the flat `[:api, :require_admin]` route AssignDefaultScope
    # resolves the seeded Default workspace; true per-tenant isolation comes via
    # the scoped `/w/:ws/p/:project` mirror or a workspace-bound token upstream.
    opts = [period: period, workspace_id: workspace_id(conn)]

    opts =
      case SearchIntel.parse_period_start(params["periodStart"]) do
        %Date{} = date -> Keyword.put(opts, :period_start, date)
        _ -> opts
      end

    result = MediaIntelligence.insights(dataset, opts)

    json(conn, %{result: result, syncTags: ["bp:ds:#{dataset}:media:search:insights"]})
  end

  def search_synonyms(conn, %{"dataset" => dataset}) do
    json(conn, %{
      result: Synonyms.list("media", dataset, workspace_id(conn)),
      syncTags: ["bp:ds:#{dataset}:media:search:synonyms"]
    })
  end

  def create_search_synonym(conn, %{"dataset" => dataset} = params) do
    # D58/D71 fail-closed — mirrors update_search_settings. `workspace_id(conn)`
    # reads `:current_workspace`, which `AssignDefaultScope` has ALREADY masked
    # from nil to Default, so a genuinely nil-workspace admin token would silently
    # write the Default/global media synonym row (an operator footgun). Read the
    # RAW pre-mask token workspace_id and refuse when nil, BEFORE any insert. A
    # workspace-bound admin token is unaffected — it writes its own row.
    case token_workspace_id(conn) do
      nil ->
        nil_workspace_write_error(conn)

      _ws_id ->
        case Synonyms.create("media", dataset, params, workspace_id(conn)) do
          {:ok, row} ->
            json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:media:search:synonyms"]})

          {:error, %Ecto.Changeset{} = changeset} ->
            validation_error(conn, changeset)
        end
    end
  end

  def promote_search_synonym(conn, %{"dataset" => dataset} = params) do
    case token_workspace_id(conn) do
      nil ->
        nil_workspace_write_error(conn)

      _ws_id ->
        case Synonyms.promote("media", dataset, params, workspace_id(conn)) do
          {:ok, row} ->
            json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:media:search:synonyms"]})

          {:error, reason} when reason in [:invalid, :missing_fields] ->
            error_json(conn, {:error, promote_fields_changeset()}, "from and to are required")

          {:error, %Ecto.Changeset{} = changeset} ->
            validation_error(conn, changeset)
        end
    end
  end

  def preview_search_synonym(conn, %{"dataset" => dataset} = params) do
    q = bin(params["q"]) || bin(params["from"])
    result = Synonyms.preview("media", dataset, q, params, workspace_id(conn))
    json(conn, %{result: result})
  end

  def search_settings(conn, %{"dataset" => dataset}) do
    json(conn, %{
      result: SurfaceConfigs.get("media", dataset, workspace_id(conn)),
      syncTags: ["bp:ds:#{dataset}:media:search:settings"]
    })
  end

  def update_search_settings(conn, %{"dataset" => dataset} = params) do
    # D58/D71 fail-closed — mirrors the documents surface. `workspace_id(conn)`
    # reads `:current_workspace`, which `AssignDefaultScope` has ALREADY masked
    # from nil to Default, so a genuinely nil-workspace admin token would
    # silently write the Default/global media config. Read the RAW pre-mask token
    # workspace_id (assigned by `RequireToken`) and refuse when nil, BEFORE the
    # upsert. A workspace-bound admin token still writes its own row.
    case token_workspace_id(conn) do
      nil ->
        nil_workspace_write_error(conn)

      _ws_id ->
        case SurfaceConfigs.upsert("media", dataset, params, workspace_id(conn)) do
          {:ok, row} ->
            json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:media:search:settings"]})

          {:error, %Ecto.Changeset{} = changeset} ->
            validation_error(conn, changeset)
        end
    end
  end

  def delete_search_synonym(conn, %{"dataset" => dataset, "id" => id}) do
    case token_workspace_id(conn) do
      nil ->
        nil_workspace_write_error(conn)

      _ws_id ->
        case Synonyms.delete(id, "media", dataset, workspace_id(conn)) do
          :ok ->
            json(conn, %{ok: true, syncTags: ["bp:ds:#{dataset}:media:search:synonyms"]})

          {:error, :not_found} ->
            error_json(conn, {:error, {:not_found, "synonym not found"}})
        end
    end
  end

  def search_suggestions(conn, %{"dataset" => dataset} = params) do
    prefix = bin(params["q"]) || bin(params["prefix"])
    limit = parse_int(params["limit"], 8) |> min(20)

    result =
      MediaIntelligence.suggestions(
        dataset,
        SearchIntel.actor_key(conn),
        prefix,
        limit: limit,
        workspace_id: workspace_id(conn)
      )

    json(conn, %{
      result: result,
      syncTags: ["bp:ds:#{dataset}:media:search"]
    })
  end

  def search_interaction(conn, %{"dataset" => dataset} = params) do
    record_opts = [
      actor_key: SearchIntel.actor_key(conn),
      session_key: SearchIntel.session_key(conn),
      source: SearchIntel.source(conn, "explorer"),
      disabled: SearchIntel.recording_disabled?(conn),
      workspace_id: workspace_id(conn)
    ]

    # `recorded:` is the post-condition the caller actually asked about. A
    # switched-off recorder is a deliberate no-op and keeps its honest 200; a
    # lost write says so, with a status to match.
    case MediaIntelligence.record_interaction(dataset, params, record_opts) do
      {:ok, id} ->
        json(conn, %{ok: true, recorded: true, interactionEventId: id})

      {:skipped, :recording_disabled} ->
        json(conn, %{ok: true, recorded: false, reason: "recording_disabled"})

      {:skipped, reason} ->
        status = if reason == :error, do: :internal_server_error, else: :unprocessable_entity

        conn
        |> put_status(status)
        |> json(%{ok: false, recorded: false, reason: Atom.to_string(reason)})
    end
  end

  def index(conn, %{"dataset" => dataset} = params) do
    t0 = System.monotonic_time(:microsecond)

    opts =
      [
        limit: parse_int(params["limit"], @default_limit) |> min(@max_limit),
        offset: parse_int(params["offset"], 0),
        mime_type: blank_to_nil(params["type"] || params["mimeType"]),
        kind: blank_to_nil(params["kind"]),
        q: blank_to_nil(params["q"])
      ] ++ scope_opts(conn)

    {files, total} = Media.query_files(dataset, opts)
    docs = Media.asset_docs_for_files(files, dataset, scope_opts(conn))
    render_opts = render_opts(conn, params)

    assets =
      Enum.map(files, fn file ->
        AssetResponse.render(file, Map.get(docs, file.id), render_opts)
      end)

    ms = div(System.monotonic_time(:microsecond) - t0, 1000)

    json(conn, %{
      result: %{
        assets: assets,
        count: total,
        limit: opts[:limit],
        offset: opts[:offset]
      },
      syncTags: ["bp:ds:#{dataset}:media"],
      ms: ms
    })
  end

  def show(conn, %{"dataset" => dataset, "id" => id} = params) do
    t0 = System.monotonic_time(:microsecond)

    with {:ok, file} <- Media.get_file(id, scope_opts(conn)),
         true <- file.dataset == dataset do
      doc = Media.asset_doc_for_file(file, dataset)
      ms = div(System.monotonic_time(:microsecond) - t0, 1000)

      json(conn, %{
        result: AssetResponse.render(file, doc, render_opts(conn, params, dataset: dataset)),
        syncTags: sync_tags(dataset, file.id),
        ms: ms
      })
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def relations(conn, %{"dataset" => dataset, "id" => id} = params) do
    with {:ok, file} <- Media.get_file(id, scope_opts(conn)),
         :ok <- ensure_dataset(file, dataset) do
      # Thread the tenancy scope into the relation graph so every back-link
      # query + related-asset/file resolution is bounded to the caller's
      # workspace — the related assets/titles/signed-urls in another workspace
      # sharing the `dataset` STRING no longer leak (barkpark-m21z). The scope
      # opts ride alongside the render keys; graph/3 splits them.
      graph_opts = render_opts(conn, params, dataset: dataset) ++ scope_opts(conn)
      graph = Relations.graph(file, dataset, graph_opts)

      json(conn, %{
        result: graph,
        syncTags: sync_tags(dataset, file.id)
      })
    end
  end

  def upload(conn, %{"dataset" => dataset, "file" => upload} = params) do
    with :ok <- require_write(conn) do
      case Media.upload(upload, dataset, scope_opts(conn)) do
        {:ok, file} ->
          doc = Media.asset_doc_for_file(file, dataset)

          conn
          |> put_status(:created)
          |> json(%{
            result: AssetResponse.render(file, doc, render_opts(conn, params, dataset: dataset)),
            syncTags: sync_tags(dataset, file.id)
          })

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def upload(conn, %{"dataset" => _dataset}) do
    env =
      {:error, :malformed}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, "missing 'file' field in multipart upload")

    conn
    |> put_status(:bad_request)
    |> json(%{error: Map.delete(env, :status)})
  end

  def update(conn, %{"dataset" => dataset, "id" => id} = params) do
    metadata = metadata_params(params)

    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(id, scope_opts(conn)),
         :ok <- ensure_dataset(file, dataset),
         doc = Media.asset_doc_for_file(file, dataset),
         :ok <- ensure_edit(conn, file, doc),
         {:ok, doc} <- Media.patch_asset_metadata(file, metadata, dataset) do
      json(conn, %{
        result: AssetResponse.render(file, doc, render_opts(conn, params, dataset: dataset)),
        syncTags: sync_tags(dataset, file.id)
      })
    else
      error -> error
    end
  end

  def checkout(conn, %{"dataset" => dataset, "id" => id} = params) do
    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(id, scope_opts(conn)),
         :ok <- ensure_dataset(file, dataset),
         actor <- actor_label(conn),
         {:ok, doc} <- Checkout.checkout(file, actor, dataset) do
      json(conn, %{
        result: AssetResponse.render(file, doc, render_opts(conn, params, dataset: dataset)),
        syncTags: sync_tags(dataset, file.id)
      })
    else
      {:error, :checked_out} ->
        conflict(conn, "asset is checked out by another editor")

      error ->
        error
    end
  end

  def undo_checkout(conn, %{"dataset" => dataset, "id" => id} = params) do
    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(id, scope_opts(conn)),
         :ok <- ensure_dataset(file, dataset),
         actor <- actor_label(conn),
         admin? <- admin?(conn),
         {:ok, doc} <- Checkout.undo_checkout(file, actor, dataset, admin?) do
      json(conn, %{
        result: AssetResponse.render(file, doc, render_opts(conn, params, dataset: dataset)),
        syncTags: sync_tags(dataset, file.id)
      })
    else
      {:error, :forbidden} ->
        {:error, :forbidden}

      error ->
        error
    end
  end

  def delete(conn, %{"dataset" => dataset, "id" => id}) do
    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(id, scope_opts(conn)),
         :ok <- ensure_dataset(file, dataset),
         {:ok, deleted} <- Media.delete_file(id, scope_opts(conn)) do
      # RECEIPT LAW (pds w40): `Media.delete_file/2` returns the row
      # `Repo.delete(file, stale_error_field: :id)` removed (media.ex:413-455).
      # This used to discard it and echo the `:id` path param. NOTE the trap the
      # legacy twin (media_controller.ex:362-371) does not have: `file` is bound
      # at :403 by a PRE-WRITE `Media.get_file/2` read, so `file.filename` would
      # be store-SHAPED but not descended from the write. Every field below
      # comes off `deleted` — the delete's own return.
      json(conn, %{
        result: %{deleted: deleted.id, filename: deleted.filename, dataset: deleted.dataset},
        syncTags: ["bp:ds:#{dataset}:media"]
      })
    else
      error -> error
    end
  end

  defp ensure_dataset(%{dataset: ds}, ds), do: :ok
  defp ensure_dataset(_, _), do: {:error, :not_found}

  defp ensure_edit(conn, file, doc) do
    if Access.allowed?(conn, file, doc, :edit_metadata), do: :ok, else: {:error, :forbidden}
  end

  defp require_write(conn) do
    # P5: a scoped-share media-edit token proved its right to write THIS scope in
    # RequireShareEditToken (opaque `share-edit-media` perm + live :edit-share +
    # byte-exact scope) and carries no global :write perm — honor `share_writer`
    # here, mirroring BarkparkWeb.Plugs.RequireWritePermission, or a media upload
    # via a share token would 403 despite the plug grant.
    cond do
      conn.assigns[:share_writer] == true ->
        :ok

      not is_nil(conn.assigns[:api_token]) ->
        token = conn.assigns[:api_token]

        if Auth.has_permission?(token, "write") or Auth.has_permission?(token, "admin") do
          :ok
        else
          {:error, :forbidden}
        end

      # ACCOUNT ARM (gfr-w1-account-session-bearer-gap). A `user_session`
      # principal carries no api_token, so the arm above cannot answer for it.
      # Authority is the MEMBERSHIP ROLE on the workspace `ResolveWorkspace`
      # already derived from the URL, through the same `Tenancy.Auth.authorize/3`
      # the RequireWritePermission plug uses — the floor lives there
      # ("member"/"admin"/"owner" satisfy :write) and is NOT restated here.
      #
      # SCOPED ONLY, structurally: a flat request has no :current_workspace at
      # this point, so this clause cannot fire for one.
      #
      # NOT extended to checkout/undo_checkout. Those call `actor_label/1` and
      # `admin?/1`, which read a token's LABEL to stamp `checkedOutBy` — what a
      # human principal should be stamped as is a product decision nobody has
      # made, and guessing it writes user-visible data. An account session can
      # upload; it still cannot check out. Bounded on purpose.
      match?(%Barkpark.Accounts.User{}, conn.assigns[:current_user]) ->
        with %{id: ws_id} when is_binary(ws_id) <- conn.assigns[:current_workspace],
             :ok <- Barkpark.Tenancy.Auth.authorize(conn.assigns[:current_user], ws_id, :write) do
          :ok
        else
          _ -> {:error, :forbidden}
        end

      true ->
        {:error, :unauthorized}
    end
  end

  # Force-release privilege for `undo_checkout`. NOTE: write==force-release is
  # DELIBERATE here — any write token may release ANY actor's checkout lock,
  # diverging from the pure-admin sibling `Access.admin?/1` (access.ex). The
  # holder-only fallback in `Checkout.ensure_can_release/3` is therefore dead on
  # the API path (`require_write` runs first, so admin? is always true). This is
  # the current, intended posture; whether it SHOULD tighten to true-admin is
  # tracked separately (felix-w28-bl-checkout-tighten-adjudication) — do not
  # change behavior here.
  # A token-less principal reaches here since the account arm on `require_write/1`
  # (and, before it, `share_writer`). `Auth.has_permission?/2` is
  # `permission in (token.permissions || [])`, so a nil token RAISES BadMapError
  # rather than denying — a 500 where a boolean belongs. Match the token first.
  defp admin?(conn) do
    case conn.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token ->
        Auth.has_permission?(token, "admin") or Auth.has_permission?(token, "write")

      _ ->
        false
    end
  end

  # Attribution, not authorization. For a token this is its human-chosen LABEL;
  # for an account session the equivalent human identity is the email, matching
  # `auth_controller.ex`'s existing `created_by: user.email`. "member" would name
  # nobody, which is strictly worse than the token path.
  defp actor_label(conn) do
    case conn.assigns[:api_token] do
      %{label: label} when is_binary(label) and label != "" ->
        label

      _ ->
        case conn.assigns[:current_user] do
          %Barkpark.Accounts.User{email: email} when is_binary(email) and email != "" -> email
          _ -> "api"
        end
    end
  end

  defp render_opts(conn, params, extra \\ []) do
    dataset = Keyword.get(extra, :dataset, Map.get(params, "dataset", "production"))

    [
      conn: conn,
      dataset: dataset,
      sign_urls: params["appendRequestSecret"] in ["true", "1"]
    ]
  end

  defp conflict(conn, message) do
    BarkparkWeb.ErrorResponse.emit(conn, {:error, :conflict}, message)
  end

  # Emit a §9 error envelope ({error:{code,message,request_id,...}}) via the ONE
  # shared emitter, which routes through Content.Errors so code + hint +
  # request_id stay canonical. `message_override` swaps the human message while
  # keeping the canonical code/status (e.g. a resource-specific not_found text).
  defp error_json(conn, reason, message_override \\ nil) do
    BarkparkWeb.ErrorResponse.emit(conn, reason, message_override)
  end

  # Schemaless changeset that yields the canonical `validation_failed` envelope
  # for the promote endpoint's required from/to fields.
  defp promote_fields_changeset do
    {%{}, %{from: :string, to: :string}}
    |> Ecto.Changeset.cast(%{}, [:from, :to])
    |> Ecto.Changeset.validate_required([:from, :to])
  end

  defp sync_tags(dataset, file_id) do
    ["bp:ds:#{dataset}:media", "bp:ds:#{dataset}:media:#{file_id}"]
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp parse_int(_, default), do: default

  # Coerce a query param to a non-empty binary, or nil. A non-binary shape
  # (Phoenix parses `?q[]=x` into a list, `?q[k]=v` into a map) collapses to
  # nil — the "absent" sentinel query_files handles — rather than flowing into
  # the `:q`/`:mimeType`/`:kind` filter builders where `escape_like/1` would
  # 500 on a non-binary. Mirrors the `is_binary` guard on the sibling copies in
  # MediaSearchParams / BulldocsIngestController.
  defp blank_to_nil(v) when is_binary(v) and v != "", do: v
  defp blank_to_nil(_), do: nil

  defp metadata_params(%{"metadata" => metadata}) when is_map(metadata), do: metadata

  defp metadata_params(params) do
    Map.drop(params, ["dataset", "id"])
  end

  defp search_metadata(meta) when is_map(meta) do
    %{}
    |> maybe_put_meta("recovery", meta[:recovery])
    |> maybe_put_meta("parsed", meta[:parsed])
  end

  defp search_metadata(_), do: %{}

  defp maybe_put_meta(map, _key, nil), do: map
  defp maybe_put_meta(map, key, value), do: Map.put(map, key, value)

  # Canonical validation_failed envelope (code + details + request_id), built via
  # Content.Errors' changeset path — the details map matches the traverse_errors
  # shape this used to hand-roll. Keep the "validation failed" message override.
  defp validation_error(conn, changeset) do
    error_json(conn, {:error, changeset}, "validation failed")
  end

  # The resolved tenant for per-workspace media surface-config attribution
  # (charter D45/D49). The bespoke `:flat_admin_api` pipeline derives
  # `:current_workspace` from the admin token BEFORE `AssignDefaultScope`, so on
  # a multi-tenant instance this is the caller's OWN workspace — workspace A can
  # no longer overwrite workspace B's media config on a shared dataset slug.
  # `nil` on a fresh DB with no Default Workspace → the workspace-agnostic global
  # config (pre-tenancy behaviour preserved).
  defp workspace_id(conn) do
    case conn.assigns[:current_workspace] do
      %{id: id} -> id
      _ -> nil
    end
  end

  # The RAW pre-mask workspace of the calling admin token (assigned by
  # `RequireToken`, BEFORE `AssignDefaultScope` masks nil → Default). The D58/D71
  # fail-closed guard reads THIS, not `workspace_id/1`, so a legacy-null token is
  # refused instead of silently attributing its write to Default.
  defp token_workspace_id(conn) do
    case conn.assigns[:api_token] do
      %{workspace_id: ws_id} -> ws_id
      _ -> nil
    end
  end

  # 422 for a nil-workspace admin settings WRITE (D58/D71). `unprocessable` is a
  # registered §9 code; the message tells the operator to use a workspace-bound
  # token rather than have the write land on the global/Default config.
  defp nil_workspace_write_error(conn) do
    BarkparkWeb.ErrorResponse.emit_custom(
      conn,
      422,
      "unprocessable",
      "search-settings write requires a workspace-scoped token; this token has no workspace"
    )
  end
end
