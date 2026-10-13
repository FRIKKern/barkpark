defmodule BarkparkWeb.Plugs.PreviewToken do
  @moduledoc """
  Verifies a short-lived preview JWT from `Authorization: Preview <jwt>`
  or `?preview_token=<jwt>`. Forces perspective to drafts on success, UNLESS
  the request explicitly asks for `?perspective=published` or `?perspective=
  raw` (task-500b916ecdb0d1c0) — see `requested_perspective/1` below.

  ## What a token may read (owner ruling #17, task-8bac87cd4b34aeb6)

  * `doc_ids` — when the claim lists any ids, the token reads those documents
    and nothing else: `GET …/doc/:dataset/:type/:doc_id` must name a listed id
    (a `drafts.` prefix on either side is ignored), `GET …/query/:dataset/:type`
    returns only listed documents (`ScopeHelpers` threads `:only_doc_ids`), and
    the backlinks / related / tags reads and `?expand=` are refused, because
    each returns documents the token does not name. An empty or absent list
    keeps the dataset-wide behaviour existing integrations rely on.
    `GET /v1/preview/listen/:dataset` (task-78dc25a4f117fa07) is ALSO allowed
    with a non-empty list — the SSE/listen route carries neither `:doc_id` nor
    `:type` in its path, so it needs its own `listen_route?/1` match below; the
    per-event fence for what a doc-scoped token's stream actually forwards
    lives in `BarkparkWeb.ListenFilter`'s `only_doc_ids`.
  * `workspace_id` (optional) — reads run in that workspace instead of the
    Default workspace; `project_id` (optional) narrows to one of its projects.
    A workspace or project the box does not have is refused.

  Every refusal happens before the JTI is recorded, so a token aimed at the
  wrong document is not burned. Refusals are 403 `forbidden` with reason
  `preview_scope`.

  ## Scoped routes: `optional: true`, and a signed scope must MATCH the URL
  (task-88e9094df76d31c6)

  Mounted with `plug(BarkparkWeb.Plugs.PreviewToken, optional: true)` on
  `/w/:workspace_slug/p/:project_slug/v1/preview/*` (`:scoped_api_preview`,
  alongside every other `:scoped_api` route's session/Bearer path, never
  replacing it): a request with NO `Authorization: Preview`/`?preview_token=`
  at all is a no-op pass-through (`{:cont, conn}`, unchanged) rather than the
  flat mount's `deny(:unauthorized)` — the membership gate downstream
  (`ResolveWorkspace`) still gets its turn. A PRESENT token is verified
  exactly as on the flat route, with ONE extra check: its signed
  `workspace_id` (and `project_id`, if the route carries one) must equal
  what the URL's `:workspace_slug`/`:project_slug` resolve to —
  `{:error, :workspace_mismatch}` → 403 otherwise, same `forbidden` envelope
  `dataset_mismatch` already uses. A token minted for workspace A is
  refused on `/w/B/...`, never silently re-scoped to B and never left to
  fall through to `ResolveWorkspace`'s own gate (which would report
  `not_a_member` — the wrong reason for a scope mismatch, and one that
  would also apply to a legitimate member with no Preview token at all).

  ## Single-use, unless `multi_use` (task-8f7cba7f65cb343c)

  `record_jti/1` is single-use by construction (`INSERT … ON CONFLICT DO
  NOTHING` on `jti`): the first request to verify a given token wins, every
  later one gets `{:error, :already_used}`. A token signed with `multi_use:
  true` — a claim that can ONLY originate from `PreviewTokenController.mint/2`,
  since it rides inside the signed payload — skips that call here instead:
  its jti was already registered once, at mint time, so `revoke/1` /
  `revoked?/1` (checked on every `verify/2` call regardless of `multi_use`)
  and `sweep`/`sweep_batch` GC still have a row to act on, but no request
  ever burns it. TTL (clamped to a hard max by the mint route) and revocation
  are what bound a `multi_use` token instead of single-use's one-shot burn.
  """

  import Plug.Conn

  alias Barkpark.Content.{DraftId, Errors}
  alias Barkpark.PreviewToken
  alias Barkpark.Tenancy

  def init(opts), do: opts

  def call(conn, opts) do
    case extract_token(conn) do
      nil ->
        # task-88e9094df76d31c6 — `optional: true` is the ONLY thing that
        # makes this pipeline-safe to ADD to an existing route family
        # (:scoped_api_preview) rather than replace it: no Preview header at
        # all is simply not this plug's business, and the conn continues
        # unchanged into whatever runs next (ResolveWorkspace's ordinary
        # session/Bearer membership gate). The flat mount (opts == [],
        # `optional` defaults false) keeps denying outright — byte-identical
        # to before this task.
        if Keyword.get(opts, :optional, false), do: conn, else: deny(conn, :unauthorized)

      raw ->
        verify_and_assign(conn, raw)
    end
  end

  defp verify_and_assign(conn, raw) do
    secret = Application.get_env(:barkpark, :preview, [])[:secret]

    with true <- is_binary(secret) and byte_size(secret) > 0,
         {:ok, claims} <- PreviewToken.verify(raw, secret),
         :ok <- check_dataset_scope(conn, claims),
         :ok <- check_workspace_scope(conn, claims),
         # A token without a dataset claim is structurally unusable (401 via
         # record_jti's contract); refuse it before judging what it names.
         true <- is_binary(Map.get(claims, "dataset")),
         {:ok, doc_ids} <- check_doc_scope(conn, claims),
         {:ok, conn} <- assign_claimed_scope(conn, claims),
         {:ok, _} <- maybe_record_jti(claims) do
      conn
      |> assign(:preview_claims, claims)
      |> assign(:forced_perspective, requested_perspective(conn))
      |> maybe_assign_doc_ids(doc_ids)
    else
      {:error, :already_used} -> deny(conn, :replay)
      {:error, :dataset_mismatch} -> deny(conn, :forbidden)
      {:error, :workspace_mismatch} -> deny(conn, :forbidden)
      {:error, :preview_scope} -> deny(conn, :preview_scope)
      _ -> deny(conn, :unauthorized)
    end
  end

  # task-88e9094df76d31c6 — only binds on a route that CARRIES a
  # :workspace_slug (the scoped /w/:ws/p/:proj/v1/preview/* family). The flat
  # /v1/preview/* mount has no such param, so this is `:ok` there, unchanged,
  # and `assign_claimed_scope/2` below still seats the read in whatever
  # workspace the CLAIM alone names — exactly as it always has.
  #
  #   * :workspace_slug unresolvable → :ok. An unknown slug is THIS ROUTE's
  #     404 to report (ResolveWorkspace, downstream), not a token-scope
  #     question — this plug fails closed only on a REAL mismatch, never on
  #     a URL error that belongs to someone else.
  #   * resolvable, claim's workspace_id disagrees (or is absent) → refused.
  #   * agrees → check the project half the same way, if the route carries
  #     one.
  defp check_workspace_scope(conn, claims) do
    case conn.path_params["workspace_slug"] do
      nil ->
        :ok

      slug ->
        case Tenancy.get_workspace_by_slug(slug) do
          %{id: ws_id} = ws ->
            if Map.get(claims, "workspace_id") == ws_id,
              do: check_project_scope(conn, claims, ws),
              else: {:error, :workspace_mismatch}

          nil ->
            :ok
        end
    end
  end

  defp check_project_scope(conn, claims, ws) do
    case conn.path_params["project_slug"] do
      nil ->
        :ok

      slug ->
        case Tenancy.get_project(ws.slug, slug) do
          %{id: proj_id} ->
            if Map.get(claims, "project_id") == proj_id,
              do: :ok,
              else: {:error, :workspace_mismatch}

          nil ->
            :ok
        end
    end
  end

  # The token's document list, as published ids. `[]` = dataset-wide.
  # task-8f7cba7f65cb343c — a `multi_use` token was already registered once,
  # at mint time (`PreviewTokenController.mint/2`), so calling `record_jti`
  # here on every read would ALWAYS hit the existing row and refuse every
  # request past the first with `:already_used` — exactly the single-use
  # behaviour this claim exists to opt out of. `revoked?/1` is still checked
  # on every call, inside `PreviewToken.verify/2` above, regardless of
  # `multi_use` — a revoked multi_use token is refused immediately, same as
  # any other revoked token.
  defp maybe_record_jti(%{"multi_use" => true} = claims), do: {:ok, claims}
  defp maybe_record_jti(claims), do: PreviewToken.record_jti(claims)

  defp claimed_doc_ids(claims) do
    case Map.get(claims, "doc_ids") do
      ids when is_list(ids) ->
        ids
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.map(&DraftId.published_id/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  # A token that names documents reads only those (see the moduledoc).
  defp check_doc_scope(conn, claims) do
    case claimed_doc_ids(claims) do
      [] ->
        {:ok, []}

      ids ->
        params = conn.path_params
        conn = fetch_query_params(conn)

        cond do
          Map.has_key?(conn.query_params, "expand") ->
            {:error, :preview_scope}

          is_binary(params["doc_id"]) ->
            if DraftId.published_id(params["doc_id"]) in ids,
              do: {:ok, ids},
              else: {:error, :preview_scope}

          is_binary(params["type"]) ->
            {:ok, ids}

          # task-78dc25a4f117fa07: GET /v1/preview/listen/:dataset carries
          # neither `:doc_id` nor `:type` in its path — a dataset-only shape
          # none of the arms above recognise. Matched by EXACT path_info,
          # not by "no doc_id and no type", so a future preview route that
          # also lacks those params does not silently fall into this arm —
          # it stays {:error, :preview_scope} until it is named here too.
          # The per-event doc_id fence for what this token actually streams
          # lives downstream, in ListenFilter's only_doc_ids (listen_filter.ex).
          listen_route?(conn) ->
            {:ok, ids}

          true ->
            {:error, :preview_scope}
        end
    end
  end

  defp listen_route?(%{path_info: ["v1", "preview", "listen", _dataset]}), do: true
  defp listen_route?(_), do: false

  defp maybe_assign_doc_ids(conn, []), do: conn
  defp maybe_assign_doc_ids(conn, ids), do: assign(conn, :preview_doc_ids, ids)

  # Optional `workspace_id` / `project_id` claims seat the read in that tenant.
  # `AssignDefaultScope` runs after this plug and leaves an existing assign
  # alone, so a token without the claim keeps reading the Default workspace.
  defp assign_claimed_scope(conn, claims) do
    case Map.get(claims, "workspace_id") do
      nil ->
        {:ok, conn}

      ws_id when is_binary(ws_id) ->
        case Tenancy.get_workspace_by_id(ws_id) do
          %{id: id} = ws ->
            assign_claimed_project(assign(conn, :current_workspace, ws), id, claims)

          nil ->
            {:error, :preview_scope}
        end

      _ ->
        {:error, :preview_scope}
    end
  end

  defp assign_claimed_project(conn, ws_id, claims) do
    case Map.get(claims, "project_id") do
      nil ->
        {:ok, conn}

      p_id when is_binary(p_id) ->
        case Tenancy.get_project_by_id(p_id) do
          %{workspace_id: ^ws_id} = project -> {:ok, assign(conn, :current_project, project)}
          _ -> {:error, :preview_scope}
        end

      _ ->
        {:error, :preview_scope}
    end
  end

  # Bind the token's `dataset` claim to the dataset the request actually reads.
  # Without this a token minted for one dataset (e.g. `production`) could read
  # drafts from ANY other dataset in the same workspace simply by typing that
  # dataset into the `/v1/preview/.../:dataset/...` path — cross-dataset draft
  # scope escalation. The check runs BEFORE `record_jti` so a wrong-dataset
  # attempt never consumes (burns) the JTI of an otherwise-legitimate token.
  #
  #   * claim carries no dataset  → :ok here; `record_jti` rejects it (:invalid
  #     → 401), preserving the pre-existing "missing dataset claim" contract.
  #   * route carries no :dataset → :ok (no such preview route today; keeps the
  #     plug route-agnostic rather than failing shapes it can't bind).
  #   * both present + differ     → {:error, :dataset_mismatch} → 403.
  defp check_dataset_scope(conn, claims) do
    route_ds = conn.path_params["dataset"]
    claim_ds = Map.get(claims, "dataset")

    cond do
      not is_binary(claim_ds) -> :ok
      not is_binary(route_ds) -> :ok
      claim_ds == route_ds -> :ok
      true -> {:error, :dataset_mismatch}
    end
  end

  # task-500b916ecdb0d1c0 — a Preview JWT used to force "drafts" NO MATTER
  # what the caller asked for, so a Presentation Published-view switch (J63)
  # reading through the SAME scoped token as its draft preview could never
  # see the published page: `AnonPerspective.resolve/2` reads
  # `conn.assigns[:forced_perspective]` FIRST and ignores `?perspective=`
  # entirely once it is set (see that module's moduledoc). "drafts" is still
  # the default when the caller asks for nothing — unchanged for every
  # existing integration — but an EXPLICIT `?perspective=published` or
  # `?perspective=raw` now rides through instead of being silently
  # overridden. `AnonPerspective.parse/1` already treats anything else as
  # `:published`, so this never WIDENS what a value could resolve to — it
  # only lets the token's own scope (dataset/workspace/doc_ids, checked
  # above) decide what is readable, same as it always has for a Bearer
  # caller.
  defp requested_perspective(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["perspective"] do
      p when p in ["published", "raw"] -> p
      _ -> "drafts"
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Preview " <> jwt] ->
        jwt

      _ ->
        conn = fetch_query_params(conn)
        conn.query_params["preview_token"]
    end
  end

  defp deny(conn, reason) do
    env = Errors.to_envelope({:error, reason}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
