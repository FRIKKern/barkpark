defmodule BarkparkWeb.SearchController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, SearchIntelligence}
  alias Barkpark.Search.{HitEnvelope, SurfaceConfigs, Synonyms}
  alias BarkparkWeb.{AnonPerspective, SearchIntel}

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]
  import BarkparkWeb.ParamCoercion, only: [bin: 1]

  require Logger

  @doc """
  Localhost fast-path search (Barkpark Cloud P4 / Move B). Identical surface to
  `search/2`, but the route is gated by `RequireLoopback` so it answers ONLY
  to callers on the box (the co-located Next.js demo, the agent, etc.). The
  pipeline skips OptionalToken, RateLimit, and tenancy back-compat shims, so
  the per-request Phoenix floor is reduced from ~1–5 ms to the loopback-plus-
  router minimum.

  Tenancy: trusted query params. The same-box caller passes `workspace_id` /
  `project_id` directly if it needs scoped reads; absent both, the read is the
  flat unscoped default. The control-plane authority that gates which sites
  exist on this box is the cloud control plane (not the Phoenix API), so a
  loopback caller is implicitly trusted to ask whatever it wants of the local
  Postgres.
  """
  def search_local(conn, %{"dataset" => dataset} = params) do
    case bin(params["q"]) do
      nil ->
        missing_q(conn)

      "" ->
        missing_q(conn)

      query ->
        t0 = System.monotonic_time(:microsecond)

        opts =
          [
            type: bin(params["type"]),
            types: parse_types(params["types"]),
            perspective: parse_perspective(params["perspective"]),
            limit: parse_int(params["limit"], 50) |> min(200) |> max(1),
            offset: parse_int(params["offset"], 0) |> max(0) |> min(100_000),
            engine: params["engine"] || "postgres",
            # Retrieval column projection (search-latency slice a). The SAME
            # `fields=` allowlist the response is projected to below — threaded
            # to the retriever so heavy content blobs are dropped at the DB, not
            # shipped-then-discarded. Envelope.project stays the authoritative
            # response filter; this only spares the wire+decode.
            fields: bin(params["fields"])
          ]
          |> maybe_put_opt(:workspace_id, params["workspace_id"])
          |> maybe_put_opt(:project_id, params["project_id"])

        caller_context = CallerContext.from_conn(conn)

        # Row/ownership ACL (Phase 4, core-auth): the retriever drops another
        # user's owner_scoped rows. Loopback callers are trusted for tenancy
        # scope but still carry their principal here, so an owner_scoped read
        # stays isolated. nil/anonymous → only unowned rows, never an owned one.
        opts = Keyword.put(opts, :caller_context, caller_context)

        {docs, count, meta} = Content.search_documents(query, dataset, opts)
        ms = div(System.monotonic_time(:microsecond) - t0, 1000)

        # ONE shared envelope builder (AXI R3) — same function REST/loopback/WS
        # all consume. `?view=brief` returns brief hit cards; default stays full.
        # `:offset` echoes the page start so the envelope's `hasMore` is honest.
        envelope =
          HitEnvelope.build(docs, count, query, meta,
            caller_context: caller_context,
            schema_resolver: schema_resolver(conn, dataset),
            fields: params["fields"],
            view: params["view"],
            offset: opts[:offset]
          )

        json(conn, Map.put(envelope, :ms, ms))
    end
  end

  defp maybe_put_opt(opts, _, nil), do: opts
  defp maybe_put_opt(opts, _, ""), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  def search(conn, %{"dataset" => dataset} = params) do
    case bin(params["q"]) do
      nil ->
        missing_q(conn)

      "" ->
        missing_q(conn)

      query ->
        t0 = System.monotonic_time(:microsecond)

        opts =
          [
            type: bin(params["type"]),
            types: parse_types(params["types"]),
            # Anonymous callers are pinned to :published — a tokenless reader
            # passing ?perspective=drafts must NOT get drafts (same invariant
            # QueryController enforces; this public path previously trusted the
            # raw param and leaked unpublished content).
            perspective: AnonPerspective.resolve(conn, params),
            limit: parse_int(params["limit"], 50) |> min(200) |> max(1),
            offset: parse_int(params["offset"], 0) |> max(0) |> min(100_000),
            engine: params["engine"] || "postgres",
            # Retrieval column projection (search-latency slice a) — see
            # search_local/2. Threads the response's `fields=` allowlist to the
            # retriever so heavy content is dropped at the DB.
            fields: bin(params["fields"])
          ] ++ scope_opts(conn)

        {docs, count, meta} = Content.search_documents(query, dataset, opts)
        ms = div(System.monotonic_time(:microsecond) - t0, 1000)

        record_opts = [
          actor_key: SearchIntel.actor_key(conn),
          parent_event_id: SearchIntel.parent_event_id(conn),
          session_key: SearchIntel.session_key(conn),
          source: SearchIntel.source(conn, "documents-api"),
          record: SearchIntel.should_record?(conn),
          tags: SearchIntel.tags(conn),
          metadata: search_metadata(meta),
          # Stamp the resolved tenant at ingest so the crystallizer can roll this
          # event up on its OWN row instead of merging tenants that share a scope.
          workspace_id: workspace_id(conn)
        ]

        record_result =
          SearchIntelligence.record(dataset, params, count, ms, record_opts)

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

        caller_context = CallerContext.from_conn(conn)

        # ONE shared envelope builder (AXI R3): documents/count/query/
        # parsedQuery/highlights/recovery/correctedTo/facets/truncation/hasMore
        # come from `HitEnvelope.build/5` — the same function the loopback route
        # and the WS channel consume — with this route's extras (searchEventId,
        # ms) put on top. `?view=brief` returns brief hit cards; default stays
        # full. `:offset` echoes the page start so `hasMore` is honest.
        envelope =
          HitEnvelope.build(docs, count, query, meta,
            caller_context: caller_context,
            schema_resolver: schema_resolver(conn, dataset),
            fields: params["fields"],
            view: params["view"],
            offset: opts[:offset]
          )

        json(
          conn,
          envelope
          |> Map.put(:searchEventId, search_event_id)
          |> Map.put(:ms, ms)
        )
    end
  end

  # Advisory only. As of the types-blind rebuild fix (task
  # indx-rebuild-types-dedup), `IndexerWorker`'s rebuild op IGNORES the enqueued
  # `types` and re-indexes the whole public-schema corpus itself — a blue/green
  # swap must carry every public type or it erases the rest. So this list no
  # longer gates what gets indexed (the drift TODO is resolved worker-side); it
  # only shapes the echoed `types` field in this endpoint's response.
  @reindex_types ~w(post page author category project paper sheet)

  @doc """
  Enqueue an Indx blue/green rebuild for the scope. Token-gated (router); any
  member token works. Oban-unique per scope, so spamming collapses to one
  rebuild. Returns immediately with the enqueued job id — the live node's
  `:indx` queue runs the rebuild (~30s) and atomically swaps the dataset.
  """
  def reindex(conn, %{"dataset" => dataset} = params) do
    types =
      case parse_types(params["types"]) do
        nil -> @reindex_types
        list -> list
      end

    opts = [types: types, perspective: :published] ++ scope_opts(conn)

    case Barkpark.Plugins.Indx.IndexerWorker.enqueue(dataset, opts) do
      {:ok, job} ->
        json(conn, %{ok: true, scope: dataset, jobId: job.id, types: types})

      {:error, reason} ->
        # Never leak the enqueue internals (inspect(reason)) or an unregistered
        # code in the body — log the detail, return the canonical §9 internal_error.
        Logger.error("search reindex enqueue failed: " <> inspect(reason))
        error_json(conn, {:error, :internal_error})
    end
  end

  def search_suggestions(conn, %{"dataset" => dataset} = params) do
    prefix = bin(params["q"]) || bin(params["prefix"])
    limit = parse_int(params["limit"], 8) |> min(20)

    result =
      SearchIntelligence.suggestions(
        dataset,
        SearchIntel.actor_key(conn),
        prefix,
        limit: limit,
        workspace_id: workspace_id(conn)
      )

    json(conn, %{
      result: result,
      syncTags: ["bp:ds:#{dataset}:documents:search"]
    })
  end

  def search_insights(conn, %{"dataset" => dataset} = params) do
    period = params["period"] || "week"

    # Read the caller's resolved `current_workspace`, matching the workspace the
    # record path stamps at ingest — so insights and events roll up on the SAME
    # tenant row. On the flat `[:api, :require_admin]` route AssignDefaultScope
    # resolves the seeded Default workspace (no DeriveWorkspaceFromToken here);
    # true per-tenant isolation comes via the scoped `/w/:ws/p/:project` mirror
    # or a workspace-bound token that sets `current_workspace` upstream. The
    # crystallizer + reads are tenant-safe at the module layer regardless.
    opts = [period: period, workspace_id: workspace_id(conn)]

    opts =
      case SearchIntel.parse_period_start(params["periodStart"]) do
        %Date{} = date -> Keyword.put(opts, :period_start, date)
        _ -> opts
      end

    result = SearchIntelligence.insights(dataset, opts)

    json(conn, %{
      result: result,
      syncTags: ["bp:ds:#{dataset}:documents:search:insights"]
    })
  end

  def search_synonyms(conn, %{"dataset" => dataset}) do
    json(conn, %{
      result: Synonyms.list("documents", dataset, workspace_id(conn)),
      syncTags: ["bp:ds:#{dataset}:documents:search:synonyms"]
    })
  end

  def create_search_synonym(conn, %{"dataset" => dataset} = params) do
    # D58/D71 fail-closed — mirrors update_search_settings. `workspace_id(conn)`
    # reads `:current_workspace`, which `AssignDefaultScope` has ALREADY masked
    # from nil to Default, so a genuinely nil-workspace admin token would silently
    # write the Default/global synonym row (an operator footgun). Read the RAW
    # pre-mask token workspace_id and refuse when nil, BEFORE any insert. A
    # workspace-bound admin token is unaffected — it writes its own row.
    case token_workspace_id(conn) do
      nil ->
        nil_workspace_write_error(conn)

      _ws_id ->
        case Synonyms.create("documents", dataset, params, workspace_id(conn)) do
          {:ok, row} ->
            json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:documents:search:synonyms"]})

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
        case Synonyms.promote("documents", dataset, params, workspace_id(conn)) do
          {:ok, row} ->
            json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:documents:search:synonyms"]})

          {:error, reason} when reason in [:invalid, :missing_fields] ->
            error_json(conn, {:error, promote_fields_changeset()}, "from and to are required")

          {:error, %Ecto.Changeset{} = changeset} ->
            validation_error(conn, changeset)
        end
    end
  end

  def preview_search_synonym(conn, %{"dataset" => dataset} = params) do
    q = bin(params["q"]) || bin(params["from"])

    result = Synonyms.preview("documents", dataset, q, params, workspace_id(conn))
    json(conn, %{result: result})
  end

  def search_settings(conn, %{"dataset" => dataset}) do
    json(conn, %{
      result: SurfaceConfigs.get("documents", dataset, workspace_id(conn)),
      syncTags: ["bp:ds:#{dataset}:documents:search:settings"]
    })
  end

  def update_search_settings(conn, %{"dataset" => dataset} = params) do
    # D58/D71 fail-closed. The admin settings WRITE attributes the config row to
    # a `(workspace_id, surface, scope)` key. `workspace_id(conn)` reads
    # `:current_workspace`, which `AssignDefaultScope` has ALREADY masked from
    # nil to the Default Workspace — so a genuinely nil-workspace admin token
    # would silently write the Default/global row (an operator footgun). Read
    # the RAW pre-mask token workspace_id (assigned by `RequireToken`) and refuse
    # the write when it is nil, BEFORE any upsert. A workspace-bound admin token
    # is unaffected — it writes its own row. (READs stay global-legacy by D59.)
    case token_workspace_id(conn) do
      nil ->
        nil_workspace_write_error(conn)

      _ws_id ->
        case SurfaceConfigs.upsert("documents", dataset, params, workspace_id(conn)) do
          {:ok, row} ->
            json(conn, %{result: row, syncTags: ["bp:ds:#{dataset}:documents:search:settings"]})

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
        case Synonyms.delete(id, "documents", dataset, workspace_id(conn)) do
          :ok ->
            json(conn, %{ok: true, syncTags: ["bp:ds:#{dataset}:documents:search:synonyms"]})

          {:error, :not_found} ->
            error_json(conn, {:error, {:not_found, "synonym not found"}})
        end
    end
  end

  def search_interaction(conn, %{"dataset" => dataset} = params) do
    record_opts = [
      actor_key: SearchIntel.actor_key(conn),
      session_key: SearchIntel.session_key(conn),
      source: SearchIntel.source(conn, "documents-api"),
      disabled: SearchIntel.recording_disabled?(conn),
      workspace_id: workspace_id(conn)
    ]

    # `recorded:` is the post-condition the caller actually asked about. A
    # switched-off recorder is a deliberate no-op and keeps its honest 200; a
    # lost write says so, with a status to match.
    case SearchIntelligence.record_interaction(dataset, params, record_opts) do
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

  def correction(conn, %{"dataset" => dataset} = params) do
    record_opts = [
      actor_key: SearchIntel.actor_key(conn),
      session_key: SearchIntel.session_key(conn),
      source: SearchIntel.source(conn, "web"),
      disabled: SearchIntel.recording_disabled?(conn),
      workspace_id: workspace_id(conn)
    ]

    # `record_correction/3` answers five causally different outcomes that all
    # carry `promoted: false, distinct_sessions: 0`, so the counters alone
    # cannot tell a written correction from a lost one. `status:` is the
    # discriminator; surfacing it is the whole receipt. `recorded:` restates
    # the post-condition the caller asked about, exactly as the interaction
    # receipt above does.
    #
    # The HTTP status stays 200 for all five (PDS-D695): this endpoint is a
    # fire-and-forget signal every caller already treats as non-blocking, and
    # inverting `res.ok` for a lost write would break callers that never
    # branched on it — the honest field, not the transport, carries the news.
    {:ok, %{status: status, promoted: promoted, distinct_sessions: distinct}} =
      SearchIntelligence.record_correction(dataset, params, record_opts)

    json(conn, %{
      ok: status != :error,
      status: Atom.to_string(status),
      recorded: status == :recorded,
      promoted: promoted,
      distinctSessions: distinct
    })
  end

  # Per-type schema resolver for field-visibility redaction. Returns a closure
  # `(type -> %SchemaDefinition{} | nil)` that `Envelope.render_many_by_type`
  # memoises across the result set, so a non-encrypted `private` / `visibility`
  # / `owner_only` / `readable_by` field is dropped on multi-type search exactly
  # as on single-type. The encrypted-ciphertext guard still applies for any type
  # whose schema fails to resolve.
  defp schema_resolver(conn, dataset) do
    opts = scope_opts(conn)

    fn type ->
      case Content.get_schema(type, dataset, opts) do
        {:ok, schema} -> schema
        _ -> nil
      end
    end
  end

  defp missing_q(conn) do
    error_json(conn, {:error, :malformed}, "missing required parameter: q")
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

  defp parse_perspective("drafts"), do: :drafts
  defp parse_perspective("raw"), do: :raw
  defp parse_perspective(_), do: :published

  # Optional comma-separated allowlist restricting results + facets to a set of
  # document types (the finder passes its content types). nil = no restriction.
  defp parse_types(nil), do: nil

  defp parse_types(csv) when is_binary(csv) do
    case csv |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      types -> types
    end
  end

  defp parse_types(_), do: nil

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> max(n, 0)
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

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

  # The resolved tenant for per-workspace surface-config attribution (charter
  # D45/D49). The bespoke `:flat_admin_api` pipeline derives
  # `:current_workspace` from the admin token BEFORE `AssignDefaultScope`, so on
  # a multi-tenant instance this is the caller's OWN workspace — workspace A can
  # no longer overwrite workspace B's config on a shared dataset slug. `nil` on a
  # fresh DB with no Default Workspace → the workspace-agnostic global config
  # (pre-tenancy behaviour preserved).
  defp workspace_id(conn) do
    case conn.assigns[:current_workspace] do
      %{id: id} -> id
      _ -> nil
    end
  end

  # The RAW pre-mask workspace of the calling admin token (assigned by
  # `RequireToken`, BEFORE `AssignDefaultScope` masks nil → Default). The D58/D71
  # fail-closed guard reads THIS, not `workspace_id/1`, so a legacy-null token
  # can be refused instead of silently attributing its write to Default.
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
