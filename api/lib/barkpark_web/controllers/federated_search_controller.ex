defmodule BarkparkWeb.FederatedSearchController do
  @moduledoc """
  Unified discovery across documents and media via GET /v1/search/:dataset.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Media
  alias Barkpark.Media.Storage.Access, as: MediaAccess
  alias Barkpark.Search.HitEnvelope
  alias Barkpark.Search.Intelligence
  alias BarkparkWeb.AnonPerspective
  alias BarkparkWeb.SearchIntel

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]
  import BarkparkWeb.ParamCoercion, only: [bin: 1]

  @default_surfaces ["documents", "media"]
  @max_limit 100

  def search(conn, %{"dataset" => dataset} = params) do
    t0 = System.monotonic_time(:microsecond)
    q = bin(params["q"]) || ""
    limit = bound_limit(params["limit"])
    surfaces = parse_surfaces(params["surfaces"])
    scope = scope_opts(conn)
    # Pin anonymous callers to :published (returns an ATOM). Previously this
    # controller passed `params["perspective"] || "published"` — a STRING that
    # never matched the retriever's atom-keyed filter, so it fell through to the
    # fail-open catch-all and returned drafts to anonymous callers by default.
    perspective = AnonPerspective.resolve(conn, params)

    results =
      surfaces
      |> Enum.map(fn surface ->
        Task.async(fn ->
          search_surface(surface, dataset, q, limit, params, scope, perspective)
        end)
      end)
      |> Enum.map(&Task.await(&1, 30_000))

    ms = div(System.monotonic_time(:microsecond) - t0, 1000)
    total_hits = Enum.reduce(results, 0, fn r, acc -> acc + r.total end)

    record_opts = [
      actor_key: SearchIntel.actor_key(conn),
      parent_event_id: SearchIntel.parent_event_id(conn),
      session_key: SearchIntel.session_key(conn),
      source: SearchIntel.source(conn, "federated"),
      record: SearchIntel.should_record?(conn),
      tags: SearchIntel.tags(conn) ++ ["federated"]
    ]

    context = %{
      query: q,
      offset: 0,
      filters: %{"surfaces" => Enum.join(surfaces, ",")}
    }

    record_result =
      Intelligence.record("federated", dataset, context, total_hits, ms, record_opts)

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

    json(conn, %{
      query: q,
      surfaces: surfaces,
      results:
        Map.new(results, fn r ->
          {r.surface, surface_payload(r, CallerContext.from_conn(conn), params["view"])}
        end),
      searchEventId: search_event_id,
      ms: ms
    })
  end

  defp surface_payload(
         %{
           surface: "documents",
           hits: hits,
           total: total,
           meta: meta,
           dataset: dataset,
           scope: scope
         },
         caller_context,
         view
       ) do
    # The documents surface rides the SAME shared hit-envelope builder as
    # REST/loopback/WS search (AXI R3), re-keyed to this surface's historical
    # shape (hits/total; no correctedTo/facets/truncation). Multi-type schema
    # resolution drops a non-encrypted private/owner_only/readable_by field for
    # a non-authorized caller; `?view=brief` returns brief hit cards.
    hits
    |> HitEnvelope.build(total, nil, meta,
      caller_context: caller_context,
      schema_resolver: schema_resolver(dataset, scope),
      view: view
    )
    |> HitEnvelope.rekey_federated()
  end

  defp surface_payload(
         %{
           surface: "media",
           hits: files,
           total: total,
           meta: meta,
           dataset: dataset,
           scope: scope
         },
         caller_context,
         # Media hits are AssetResponse renders, not documents — the brief
         # document-card view does not apply (out of scope for AXI R3).
         _view
       ) do
    docs = Media.asset_docs_for_files(files, dataset, scope)
    render_opts = [include_urls: true]

    # VISIBILITY CLAMP (task-0fcec595765a7b00): this was the one AssetResponse
    # door with no ceiling — `caller_context` used to be discarded (`_caller_context`
    # in the head) and every hit rendered with `include_urls: true` regardless of
    # who asked. Predicate mirrors the private
    # `Barkpark.Media.Storage.Access.delivery_ok?/3` clauses in
    # api/lib/barkpark/media/storage/access.ex: `public` is visible to everyone; `token`/`private`
    # require an AUTHENTICATED caller. This clause mints no SignedUrl
    # (`render_opts` carries no `:conn`/`:sign_urls`), so `delivery_ok?/3`'s
    # `signed` arm never applies here and is intentionally not reproduced.
    # Shape (a), DROP rather than redact: a dropped hit cannot leak a filename,
    # matching the documents-surface sibling above (caller_context threaded into
    # `HitEnvelope.build/5`).
    visible_files =
      Enum.filter(files, fn file ->
        MediaAccess.visibility(Map.get(docs, file.id)) == "public" or
          authenticated_caller?(caller_context)
      end)

    dropped = length(files) - length(visible_files)

    hits =
      Enum.map(visible_files, fn file ->
        Barkpark.Media.Delivery.AssetResponse.render(file, Map.get(docs, file.id), render_opts)
      end)

    %{
      hits: hits,
      # `total` is the retriever's PRE-FILTER corpus count (`Media.search_files/2`
      # counts before this clamp runs). Subtract the rows dropped from THIS page
      # so the number stays consistent with `hits` actually returned — it must
      # never advertise a clamped-away row. CAVEAT: rows clamped on pages this
      # request never fetched (beyond `limit`/`offset`) are not reflected here,
      # so `total` can still overstate an anonymous caller's true visible corpus
      # across the full result set, not just this page.
      total: max(total - dropped, 0),
      parsedQuery: meta[:parsed],
      highlights: meta[:highlights] || %{},
      recovery: meta[:recovery]
    }
  end

  defp surface_payload(
         %{surface: _surface, hits: hits, total: total, meta: meta},
         _caller_context,
         _view
       ) do
    %{
      hits: hits,
      total: total,
      parsedQuery: meta[:parsed],
      highlights: meta[:highlights] || %{},
      recovery: meta[:recovery]
    }
  end

  defp search_surface("documents", dataset, q, limit, params, scope, perspective) do
    type = bin(params["type"])

    opts =
      [
        limit: limit,
        offset: 0,
        perspective: perspective,
        type: type
      ] ++ scope

    {docs, total, meta} = Content.search_documents(q, dataset, opts)

    %{
      surface: "documents",
      hits: docs,
      total: total,
      meta: meta,
      dataset: dataset,
      scope: scope
    }
  end

  defp search_surface("media", dataset, q, limit, params, scope, _perspective) do
    opts =
      [
        q: q,
        limit: limit,
        offset: 0,
        sort: params["sort"] || "relevance"
      ] ++ scope

    {files, total, _facets, meta} = Media.search_files(dataset, opts)

    %{
      surface: "media",
      hits: files,
      total: total,
      meta: meta,
      dataset: dataset,
      scope: scope
    }
  end

  defp search_surface(surface, _dataset, _q, _limit, _params, _scope, _perspective) do
    %{surface: surface, hits: [], total: 0, meta: %{}}
  end

  # Per-type schema resolver memoised by `Envelope.render_many_by_type` across
  # the federated document hits — closes the non-encrypted private-field leak on
  # this multi-type surface. Falls back to nil (ciphertext-guard only) on a type
  # whose schema cannot be resolved.
  defp schema_resolver(dataset, scope) do
    fn type ->
      case Content.get_schema(type, dataset, scope) do
        {:ok, schema} -> schema
        _ -> nil
      end
    end
  end

  # Authenticated, per `Barkpark.Content.CallerContext`: a verified `%User{}`
  # session OR a verified `%ApiToken{}` — either sets `user_id`/`token_id`.
  # `CallerContext.anonymous/0` has both `nil`, which is what `from_conn/1`
  # returns when `Plugs.OptionalToken` (the `:api` pipeline's terminal plug)
  # saw no credential. Mirrors the `auth` input `delivery_ok?/3` takes.
  defp authenticated_caller?(%CallerContext{token_id: token_id, user_id: user_id}) do
    not is_nil(token_id) or not is_nil(user_id)
  end

  defp authenticated_caller?(_), do: false

  defp parse_surfaces(nil), do: @default_surfaces

  defp parse_surfaces(str) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 in @default_surfaces))
    # `?surfaces=documents,documents` would otherwise fan the same surface out
    # twice — a redundant parallel Postgres query that also double-counts
    # `total_hits`. Dedup so each requested surface is queried exactly once.
    |> Enum.uniq()
    |> case do
      [] -> @default_surfaces
      list -> list
    end
  end

  # Phoenix parses `?surfaces[]=x` into a list and `?surfaces[k]=v` into a map —
  # neither matched a clause, so an anonymous request 500'd (FunctionClauseError).
  # Fail soft to the defaults, same idiom as bin/1 and the parse_int catch-all below.
  defp parse_surfaces(_), do: @default_surfaces

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(n, _default) when is_integer(n) and n > 0, do: n
  defp parse_int(_, default), do: default

  @doc """
  Clamp a caller-supplied `limit` param to a ceiling of #{@max_limit}, defaulting
  a missing, non-numeric, or non-positive value to 10 (via `parse_int/2`, whose
  `n > 0` guard already rejects `0`/negative).

  This endpoint is anonymous (`pipe_through :api`, no `:require_token`) and fans
  the limit out to EVERY surface (documents + media) in parallel with no
  downstream clamp, so an uncapped value lets a client ask Postgres for unbounded
  rows on two surfaces at once. The ceiling bounds worst-case row counts. Mirrors
  the sibling `SearchController.search` (`min(20)`) and `MediaController`
  (`@max_limit`) clamps.

  ## Examples

      iex> BarkparkWeb.FederatedSearchController.bound_limit("1000000")
      100

      iex> BarkparkWeb.FederatedSearchController.bound_limit("0")
      10

      iex> BarkparkWeb.FederatedSearchController.bound_limit(nil)
      10

      iex> BarkparkWeb.FederatedSearchController.bound_limit("25")
      25
  """
  def bound_limit(raw), do: parse_int(raw, 10) |> min(@max_limit)
end
