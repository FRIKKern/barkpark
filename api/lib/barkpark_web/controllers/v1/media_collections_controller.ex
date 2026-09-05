defmodule BarkparkWeb.V1.MediaCollectionsController do
  @moduledoc """
  Collections, membership, and share links at `/v1/media/:dataset/collections`.
  """

  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Storage.{Access, Collections, Share}
  alias Barkpark.Media.Delivery.AssetResponse
  alias Barkpark.Media.Delivery.SearchParams, as: MediaSearchParams
  alias BarkparkWeb.Plugs.RequireWritePermission

  action_fallback BarkparkWeb.FallbackController

  @default_limit 50
  @max_limit 500

  def index(conn, %{"dataset" => dataset} = params) do
    limit = parse_int(params["limit"], 200) |> min(1000)
    offset = parse_int(params["offset"], 0)

    list_opts = [limit: limit, offset: offset] ++ scope_opts(conn)

    collections =
      dataset
      |> Collections.list(list_opts)
      |> Enum.map(&Collections.render/1)

    # `count` here has always meant the PAGE ROWS, while `count` on the
    # `/v1/media/:ds` sibling has always meant the GRAND TOTAL. Both readings
    # produce a plausible integer, so a client that guesses wrong mis-pages in
    # silence. Neither key is re-pointed — that would break whichever consumer
    # is currently right — so the two envelopes are reconciled by ADDING the
    # unambiguous pair. `total` comes from `Collections.count/2`, which shares
    # `list_query/2` with `list/2` so the total cannot count rows the page is
    # not allowed to show (the public-read tier clamp narrows both).
    total = Collections.count(dataset, list_opts)
    returned = length(collections)
    has_more = offset + returned < total

    result =
      %{
        collections: collections,
        count: returned,
        total: total,
        hasMore: has_more,
        limit: limit,
        offset: offset
      }

    result = if has_more, do: Map.put(result, :nextOffset, offset + returned), else: result

    json(conn, %{
      result: result,
      syncTags: ["bp:ds:#{dataset}:media:collections"]
    })
  end

  def show(conn, %{"dataset" => dataset, "id" => id}) do
    with {:ok, collection} <- Collections.get(id, dataset, scope_opts(conn)) do
      json(conn, %{
        result: Collections.render(collection),
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}"]
      })
    end
  end

  def assets(conn, %{"dataset" => dataset, "id" => id} = params) do
    t0 = System.monotonic_time(:microsecond)

    with {:ok, _collection} <- Collections.get(id, dataset, scope_opts(conn)) do
      opts = MediaSearchParams.parse(params) ++ scope_opts(conn) ++ visibility_clamp_opts(conn)

      {files, total, facets} = Collections.assets(id, dataset, opts)
      docs = Media.asset_docs_for_files(files, dataset, scope_opts(conn))
      render_opts = render_opts(conn, params, dataset)

      hits =
        Enum.map(files, fn file ->
          AssetResponse.render(file, Map.get(docs, file.id), render_opts)
        end)

      ms = div(System.monotonic_time(:microsecond) - t0, 1000)

      # This leg already reported an honest `total`; what it lacked was any
      # truncation signal at all, so an exhausted page and a truncated one were
      # byte-identical. Same exact `hasMore` as its two list siblings.
      returned = length(hits)
      has_more = (opts[:offset] || 0) + returned < total

      result =
        %{
          collectionId: id,
          hits: hits,
          total: total,
          hasMore: has_more,
          limit: opts[:limit],
          offset: opts[:offset],
          facets: facets
        }

      result =
        if has_more,
          do: Map.put(result, :nextOffset, (opts[:offset] || 0) + returned),
          else: result

      json(conn, %{
        result: result,
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}"],
        ms: ms
      })
    end
  end

  def share(conn, %{"dataset" => dataset, "id" => id} = params) do
    ttl = parse_int(params["ttl"], 60 * 60 * 24 * 7)

    with :ok <- require_write(conn),
         {:ok, share} <- Share.create(id, dataset, [ttl: ttl] ++ scope_opts(conn)) do
      json(conn, %{
        result: share,
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}"]
      })
    end
  end

  def revoke_share(conn, %{"dataset" => dataset, "id" => id}) do
    with :ok <- require_write(conn),
         {:ok, doc} <- Share.revoke(id, dataset, scope_opts(conn)) do
      # RECEIPT LAW (pds w40): `Share.revoke/3` (share.ex:69-82) tail-calls
      # `Content.upsert_document/4` and so returns `{:ok, %Document{}}` — the
      # UPDATED row, not a literal. This used to discard it and echo the `:id`
      # path param, which is true whether or not the flip landed. `shareEnabled`
      # is read off the returned document's own persisted content, so a write
      # that silently failed to flip the flag can no longer answer "revoked".
      json(conn, %{
        result: %{
          revoked: doc.doc_id,
          shareEnabled: get_in(doc.content, ["shareLink", "enabled"])
        },
        syncTags: ["bp:ds:#{dataset}:media:collections:#{id}"]
      })
    end
  end

  def share_view(conn, %{"dataset" => dataset, "token" => token} = params) do
    t0 = System.monotonic_time(:microsecond)

    with {:ok, collection} <- Share.resolve(token, dataset) do
      share_scope = share_scope_opts(collection)

      opts =
        params
        |> MediaSearchParams.parse()
        |> Keyword.put(:limit, parse_int(params["limit"], @default_limit) |> min(@max_limit))
        |> Keyword.merge(share_scope)

      {files, total, _facets} = Collections.assets(collection.doc_id, dataset, opts)
      docs = Media.asset_docs_for_files(files, dataset, doc_scope_opts(conn, share_scope))
      render_opts = render_opts(conn, params, dataset, sign_urls: true)

      hits =
        Enum.map(files, fn file ->
          AssetResponse.render(file, Map.get(docs, file.id), render_opts)
        end)

      ms = div(System.monotonic_time(:microsecond) - t0, 1000)

      # A share view is a media list like any other: without `hasMore` a
      # truncated page and an exhausted one are byte-identical, and the share
      # recipient is precisely the consumer with no other way to find out.
      returned = length(hits)
      has_more = (opts[:offset] || 0) + returned < total

      result =
        %{
          collection: Collections.render(collection),
          hits: hits,
          total: total,
          hasMore: has_more,
          limit: opts[:limit],
          offset: opts[:offset]
        }

      result =
        if has_more,
          do: Map.put(result, :nextOffset, (opts[:offset] || 0) + returned),
          else: result

      json(conn, %{
        result: result,
        syncTags: ["bp:ds:#{dataset}:media:share:#{token}"],
        ms: ms
      })
    else
      {:error, :expired} ->
        conn
        |> put_status(:gone)
        |> json(%{
          error: %{
            code: "share_expired",
            message: "share link has expired or been revoked"
          }
        })

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def add_member(conn, %{"dataset" => dataset, "id" => id, "assetId" => asset_id}) do
    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(asset_id, scope_opts(conn)),
         :ok <- ensure_dataset(file, dataset),
         {:ok, doc} <- Collections.add_member(id, file, dataset, scope_opts(conn)) do
      json(conn, %{
        result: AssetResponse.render(file, doc, dataset: dataset, conn: conn),
        syncTags: [
          "bp:ds:#{dataset}:media:collections:#{id}",
          "bp:ds:#{dataset}:media:#{asset_id}"
        ]
      })
    end
  end

  def remove_member(conn, %{"dataset" => dataset, "id" => id, "asset_id" => asset_id}) do
    with :ok <- require_write(conn),
         {:ok, file} <- Media.get_file(asset_id, scope_opts(conn)),
         :ok <- ensure_dataset(file, dataset),
         {:ok, doc} <- Collections.remove_member(id, file, dataset, scope_opts(conn)) do
      json(conn, %{
        result: AssetResponse.render(file, doc, dataset: dataset, conn: conn),
        syncTags: [
          "bp:ds:#{dataset}:media:collections:#{id}",
          "bp:ds:#{dataset}:media:#{asset_id}"
        ]
      })
    end
  end

  # ONE JUDGMENT, ONE OWNER (task-6e22b3922dc42e8c) — the SECOND instance of the
  # class, collapsed with its media_controller.ex twin. This arm re-derived the
  # write judgment `BarkparkWeb.Plugs.RequireWritePermission` had already made on
  # the same request, and diverged from it harder than the twin did: it carried
  # NEITHER a `share_writer` arm NOR an account arm, so a principal the gate
  # admits on either of those grounds collected a 401 here. It now reads the
  # gate's verdict. Still fails CLOSED on a route that ever loses the plug: no
  # grant assign, no write.
  defp require_write(conn) do
    if RequireWritePermission.granted?(conn), do: :ok, else: {:error, :forbidden}
  end

  defp ensure_dataset(%{dataset: ds}, ds), do: :ok
  defp ensure_dataset(_, _), do: {:error, :not_found}

  # A FORK OF `V1.MediaController.render_opts/3`, and it needed the same fix
  # (task-d55b02001cf589f0). The query-string arm minted a real `SignedUrl` for a
  # `token` asset with no principal consulted, so the collection-assets door was
  # a second, identically-shaped route from "I know a collection id" to gated
  # BYTES. Fixing only the sibling would have left this one open.
  #
  # THE TWO ARMS ARE NOT THE SAME AUTHORITY and are deliberately gated
  # differently:
  #
  #   * `extra[:sign_urls]` is set ONLY by `share_view/2`, where `Share.resolve/2`
  #     has already validated a share TOKEN. That token IS the credential — the
  #     whole point of a share link is delivery without a login — so it keeps
  #     signing and must not be routed through `Access.authenticated?/1`, which
  #     would break every live share link.
  #
  #   * `params["appendRequestSecret"]` is caller-typed and carries no authority
  #     whatsoever. It now only expresses a PREFERENCE for signed URLs; the
  #     principal decides whether that preference is honoured.
  defp render_opts(conn, params, dataset, extra \\ []) do
    [
      conn: conn,
      dataset: dataset,
      sign_urls:
        Keyword.get(extra, :sign_urls, false) or
          (params["appendRequestSecret"] in ["true", "1"] and Access.authenticated?(conn))
    ]
  end

  # THE SHARE'S OWN TENANCY, NEVER THE REQUEST'S (task-09c411d26528dd86).
  #
  # `share_view/2` used to hand `Collections.assets/3` nothing but the parsed
  # search params and a `:limit`. Since the collection-search take derives its
  # tenancy half from `@scope_keys`, a caller that passes no tenancy keys yields
  # none — `Media.search_files/2` then read a nil `workspace_id` and
  # `Content.Scope.scope_to_workspace_or_global/3`'s nil arm returns the query
  # UNTOUCHED, the deliberate all-tenants read. For a `kind: "virtual"`
  # collection the only surviving filters are kind/tags/q/mimeType/visibility,
  # so the rows, the `total` AND every facet bucket spanned every workspace
  # sharing that dataset STRING.
  #
  # THIS IS NOT THE SIBLING'S SCOPE. `assets/2` passes `scope_opts(conn)` — the
  # REQUESTER's workspace — because there the requester is the principal. Here
  # the principal is the TOKEN, and the token was minted inside one workspace,
  # so the read is bounded by the SHARE's own workspace/project (carried on the
  # resolved collection document) and not by whichever tenant the request
  # happened to resolve. A share link is therefore a window onto its minting
  # workspace from anywhere, which is what a share link is for, and never a
  # window onto anyone else's.
  #
  # THE OTHER OMISSION IS DELIBERATE AND STAYS. `visibility_clamp_opts/1` is
  # still NOT applied here — see its own comment below. That half is a
  # VISIBILITY tier, not a tenancy boundary; clamping a resolved share token to
  # `:public` would empty every shared collection of exactly the non-public
  # assets being shared. Only the cross-tenant half was ever open.
  #
  # The `:shared_only` fallback is the same sentinel `ScopeHelpers.scope_opts/1`
  # emits for a request that resolved no workspace: a collection carrying no
  # `workspace_id` lives in the shared (`workspace_id IS NULL`) layer, so its
  # share reads that layer — never, by falling through to a nil workspace_id,
  # every tenant at once. That fall-through is the defect being closed; it must
  # not survive as the nil-collection arm.
  defp share_scope_opts(%Document{workspace_id: workspace_id, project_id: project_id})
       when is_binary(workspace_id) do
    [workspace_id: workspace_id] |> put_scope(:project_id, project_id)
  end

  defp share_scope_opts(_collection), do: [workspace_id: :shared_only]

  defp put_scope(opts, _key, nil), do: opts
  defp put_scope(opts, key, value) when is_binary(value), do: Keyword.put(opts, key, value)

  # The asset-document lookup that annotates the hits must resolve in the SAME
  # tenancy as the files it annotates, so it takes the share's scope too. The
  # non-tenancy half of `scope_opts(conn)` (`memoize:`, `caller_context:`) is
  # request-shaped and is kept; the tenancy pair is DROPPED before the merge so
  # the requester's `project_id` cannot survive alongside the share's workspace
  # when the share carries no project of its own.
  defp doc_scope_opts(conn, share_scope) do
    conn
    |> scope_opts()
    |> Keyword.drop([:workspace_id, :project_id])
    |> Keyword.merge(share_scope)
  end

  # See `V1.MediaController.visibility_clamp_opts/1` — same ceiling, same reason.
  # NOT applied to `share_view/2`: a resolved share token is a principal, and
  # clamping there would empty every shared collection of its non-public assets,
  # which is the thing being shared.
  defp visibility_clamp_opts(conn) do
    if Access.authenticated?(conn), do: [], else: [visibility_clamp: :public]
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
end
