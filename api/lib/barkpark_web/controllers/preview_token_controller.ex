defmodule BarkparkWeb.PreviewTokenController do
  @moduledoc """
  HTTP mint for `Barkpark.PreviewToken` JWTs (task-8f7cba7f65cb343c): the
  FLAT route (`POST /v1/preview-tokens`) stays admin-only; the SCOPED route
  (`POST /w/:workspace_slug/p/:project_slug/v1/preview-tokens`) admits any
  write-capable MEMBER (task-ea6c9abb868593f8 — barkpark-studio's gap: Sanity
  lets any editor mint a preview link, not just an admin).

  Every `/v1/preview/*` read (QueryController, ListenController, piped
  through `:api_preview`) already verifies a signed preview JWT, but nothing
  minted one over HTTP — the only way to get a preview token was
  `PreviewToken.sign/2` called in-process (tests only). A real consumer site
  (or the Studio, handing a token to its preview frame) had no way to get one
  except reading with an editor's own bearer token server-side.

  ## Minting as a member is no wider than minting as admin

  `CallerContext.from_conn/1` never resolves a request authenticated by a
  BARE Preview JWT to anything but `anonymous()` — `BarkparkWeb.Plugs.PreviewToken`
  assigns `:preview_claims`/`:current_workspace`/`:current_project`, never
  `:api_token` or `:current_user`. So the token's OWN read ceiling at request
  time is capped at anonymous/public visibility regardless of who minted it
  or what THEY can see — a member minting one cannot hand out their own
  elevated (private-field, owner-scoped) read through it. `put_tenant_claims/2`
  below also never trusts a request param for the scope it signs, only the
  caller's OWN resolved `scope_opts/1` — so a member can mint only for their
  own workspace/project, same as an admin always could.

  ## Single-use stays the default (ruling, task-8f7cba7f65cb343c)

  A minted token is single-use — one `/v1/preview/*` read, or the whole
  `/v1/preview/listen/:dataset` SSE connection, then its `jti` is burned —
  UNLESS this mint sets a signed `multi_use: true` claim. That claim lives
  INSIDE the signed payload, so it can never be added to a token after
  minting; nothing else mints a preview token that could reasonably ask for
  it, so this is the one and only place `multi_use` can originate. Requesting
  it now ALSO requires an admin role (`authorize_multi_use/2` below) — the
  one knob the member-mint widening does not extend, since its wider TTL and
  skipped per-request replay check is a bigger blast radius than the
  single-use default every member mint gets.

  A `multi_use` token's TTL defaults to 600s and is clamped to a hard max of
  3600s regardless of what the caller asks for — `BarkparkWeb.Plugs.PreviewToken`
  skips the replay-dedup `record_jti` call for a multi_use token on every
  read past the first (see that module), so TTL + revocation
  (`Barkpark.PreviewToken.revoke/1` — the existing function, NOT wired to an
  HTTP route by this slice, see below) are the only things bounding a
  leaked multi_use token's blast radius — tighter than single-use, which
  self-destructs on first read regardless of TTL.

  A single-use token minted here gets no such cap: it behaves exactly like
  one minted by calling `PreviewToken.sign/2` directly, which nothing ever
  prevented.

  ## Tenant-scoped HTTP revoke (task-49a6a686bb88d9e5)

  The FLAT mint (`mint/2` below) never grew a flat revoke: `preview_token_jti`
  carried no workspace/tenant column at all (migration 20260417230200), so a
  bare `DELETE .../:jti` front door would have been a selector with no tenant
  re-derivation possible — `RequireAdminRouteCensusTest` classifies exactly
  that shape `:exploitable`. `revoke/2` below is the SCOPED twin instead,
  mounted only on `/w/:workspace_slug/p/:project_slug/...` — migration
  20261009050000 added `owner_workspace_id`/`owner_project_id` to the table
  (named with an `owner_` prefix, not `workspace_id`/`project_id` — that
  exact name would mechanically pull the table into
  `WorkspaceBundle.Catalog`'s E1 tenant-bundle export/teardown, which these
  short-lived rows have nothing to do with; see the migration's own
  moduledoc), populated at `record_jti/1` time, and
  `PreviewToken.revoke_scoped/3` reads the row's STORED scope before
  deciding, the same pattern
  `PreviewLinkController.revoke/2` already uses. An admin of workspace A
  calling `/w/B/.../v1/preview-tokens/:jti` never even reaches this action —
  `RequireWorkspaceRole` (the SAME `:scoped_admin` gate the scoped mint
  uses) 403s at the pipeline. `Barkpark.PreviewToken.revoke/1` (bare, no
  scope) still exists for an in-process caller that already holds the
  workspace boundary some other way (iex, a future mix task); this action
  never calls it.

  ## Tenant confinement (`RequireAdminRouteCensusTest`, :tenant_bound)

  `RequireAdmin` only answers "is this bearer an admin SOMEWHERE" — it reads
  no workspace at all. A caller-supplied `dataset` string alone would have let
  an admin of workspace A mint a token scoped to workspace B's `dataset` name
  (dataset names are not globally unique; they are scoped by
  `workspace_id`/`project_id`, same as every other tenant row). So this mint
  does NOT trust a caller-supplied workspace — it signs `workspace_id`/
  `project_id` from `ScopeHelpers.scope_opts(conn)`, which `:flat_admin_api`
  already resolved from the TOKEN (`DeriveWorkspaceFromToken`, fail-soft to
  Default; never from request params) before this action ran. The minted
  token can therefore only ever read within the calling admin's own tenant —
  exactly the confinement `SchemaController`/`StructureController` get from
  the same pipeline, and exactly what `BarkparkWeb.Plugs.PreviewToken`'s
  `assign_claimed_scope/2` already enforces for a token presenting EITHER
  claim (an unknown workspace/project is refused there, not here).
  """

  use BarkparkWeb, :controller

  alias Barkpark.Content.CallerContext
  alias Barkpark.PreviewToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.ErrorResponse

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  @default_ttl 600
  @multi_use_max_ttl 3600

  @doc "POST /v1/preview-tokens — mint a preview JWT. Raw token shown ONCE."
  def mint(conn, params) do
    with {:ok, dataset} <- fetch_dataset(params),
         {:ok, doc_ids} <- fetch_doc_ids(params),
         {:ok, multi_use} <- authorize_multi_use(params, conn),
         secret when is_binary(secret) and byte_size(secret) > 0 <- preview_secret() do
      ttl = clamp_ttl(params["ttl_seconds"], multi_use)

      claims =
        %{dataset: dataset, doc_ids: doc_ids, ttl_seconds: ttl}
        |> put_tenant_claims(scope_opts(conn))

      claims = if multi_use, do: Map.put(claims, :multi_use, true), else: claims

      {raw, full_claims} = PreviewToken.sign(claims, secret)
      string_claims = Map.new(full_claims, fn {k, v} -> {to_string(k), v} end)

      # Register the jti NOW only for multi_use: the verify plug skips
      # record_jti per-request for a multi_use token (that is the whole
      # point — see the plug), so without this the row `revoke/1` and
      # `revoked?/1` look up, and `sweep`/`sweep_batch` GC, would never
      # exist. A single-use token must NOT be registered here — the first
      # real read is what registers it (unchanged), so a token that is
      # never read stays usable until it expires, exactly as today.
      if multi_use, do: PreviewToken.record_jti(string_claims)

      conn
      |> put_status(:created)
      |> json(%{
        token: raw,
        jti: string_claims["jti"],
        dataset: string_claims["dataset"],
        doc_ids: string_claims["doc_ids"],
        workspace_id: string_claims["workspace_id"],
        project_id: string_claims["project_id"],
        multi_use: multi_use,
        expires_at: unix_to_iso8601(string_claims["exp"])
      })
    else
      {:error, msg} when is_binary(msg) -> unprocessable(conn, msg)
      _ -> unprocessable(conn, "preview signing is not configured")
    end
  end

  @doc "DELETE /w/:workspace_slug/p/:project_slug/v1/preview-tokens/:jti — revoke one token."
  def revoke(conn, %{"jti" => jti}) do
    opts = scope_opts(conn)

    case Keyword.get(opts, :workspace_id) do
      ws_id when is_binary(ws_id) ->
        case PreviewToken.revoke_scoped(jti, ws_id, Keyword.get(opts, :project_id)) do
          :ok -> json(conn, %{revoked: true, jti: jti})
          {:error, :not_found} -> not_found(conn)
        end

      _ ->
        # :scoped_api always resolves :current_workspace before this action
        # runs (ResolveWorkspace halts the pipeline otherwise), so this arm
        # is unreachable in practice — kept as a fail-closed 404 rather than
        # a bare-jti, unscoped revoke/1 call, which is exactly the
        # :exploitable shape this whole route exists to avoid.
        not_found(conn)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # Reads the admin's OWN resolved tenant off `scope_opts/1` — never caller
  # input — and signs it into the claims. `workspace_id`/`project_id` absent
  # from `opts` (an instance-root/pre-tenancy token) signs neither claim,
  # which is the SAME "unscoped, falls to Default at read time" shape every
  # other claim-less preview token already has.
  defp put_tenant_claims(claims, opts) do
    claims
    |> maybe_put_claim(:workspace_id, Keyword.get(opts, :workspace_id))
    |> maybe_put_claim(:project_id, Keyword.get(opts, :project_id))
  end

  defp maybe_put_claim(claims, _key, nil), do: claims
  defp maybe_put_claim(claims, key, value), do: Map.put(claims, key, value)

  defp fetch_dataset(%{"dataset" => ds}) when is_binary(ds) and ds != "", do: {:ok, ds}
  defp fetch_dataset(_), do: {:error, "dataset is required"}

  defp fetch_doc_ids(%{"doc_ids" => ids}) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1),
      do: {:ok, ids},
      else: {:error, "doc_ids must be a list of strings"}
  end

  defp fetch_doc_ids(%{"doc_ids" => _}), do: {:error, "doc_ids must be a list of strings"}
  defp fetch_doc_ids(_), do: {:ok, []}

  # task-ea6c9abb868593f8 — the scoped mint route now admits any write-capable
  # MEMBER (see the router's pipe_through), but `multi_use: true` stays
  # admin-only: its wider TTL and skipped per-request record_jti replay check
  # (see this module's own "Single-use stays the default" section) is a
  # bigger blast radius than the single-use default every member mint gets.
  # The flat route (still :flat_admin_api-only) never reaches this check with
  # a non-admin caller at all, so it stays byte-identical.
  #
  # TWO DIFFERENT "admin" DEFINITIONS, one per route, and `multi_use` must
  # honour whichever gate THIS request actually passed through:
  #
  #   * the FLAT route runs `:require_admin` — a GLOBAL `permissions[]` bit
  #     (`CallerContext.is_admin`). Its long-standing admin callers (the
  #     seeded dev token, any service token with the global bit) often hold
  #     NO workspace membership row at all, so a workspace-ROLE check would
  #     wrongly deny every one of them — a regression on a route this slice
  #     does not otherwise touch.
  #   * the SCOPED route runs `:require_write` (widened from `:scoped_admin`)
  #     — membership ROLE is the only authority that means anything there.
  #     `RequireWorkspaceRole`'s own moduledoc names the exact trap:
  #     "a `member` of workspace B — even one holding global
  #     `[\"read\",\"write\",\"admin\"]` — can NO LONGER perform scoped admin
  #     ops." Using `CallerContext.is_admin` here would let a plain member
  #     mint `multi_use` off an unrelated global permission bit, exactly the
  #     widening this gate exists to NOT grant.
  #
  # `conn.path_params["workspace_slug"]` is the same discriminator
  # `BarkparkWeb.Plugs.RequireToken` already uses to tell the two route
  # shapes apart.
  defp authorize_multi_use(%{"multi_use" => true}, conn) do
    if admin_for_multi_use?(conn),
      do: {:ok, true},
      else: {:error, "multi_use requires an admin role in this workspace"}
  end

  defp authorize_multi_use(_params, _conn), do: {:ok, false}

  defp admin_for_multi_use?(%{path_params: %{"workspace_slug" => _}} = conn),
    do: workspace_admin_caller?(conn)

  defp admin_for_multi_use?(conn), do: CallerContext.from_conn(conn).is_admin

  defp workspace_admin_caller?(conn) do
    with %{id: ws_id} <- conn.assigns[:current_workspace] do
      cond do
        token = conn.assigns[:api_token] -> TenancyAuth.workspace_admin?(token, ws_id)
        user = conn.assigns[:current_user] -> TenancyAuth.workspace_admin?(user.id, ws_id, :user)
        true -> false
      end
    else
      _ -> false
    end
  end

  # A multi_use token's TTL is clamped to [1, @multi_use_max_ttl] regardless
  # of what is asked for — the hard ceiling IS the safety property, not an
  # input-validation nicety. A single-use token keeps the plain `sign/2`
  # default with no cap: one read burns it no matter how long its TTL says.
  defp clamp_ttl(nil, _multi_use), do: @default_ttl

  defp clamp_ttl(ttl, true) when is_integer(ttl), do: max(1, min(ttl, @multi_use_max_ttl))
  defp clamp_ttl(_ttl, true), do: @default_ttl
  defp clamp_ttl(ttl, false) when is_integer(ttl) and ttl > 0, do: ttl
  defp clamp_ttl(_ttl, false), do: @default_ttl

  defp preview_secret, do: Application.get_env(:barkpark, :preview, [])[:secret]

  defp unix_to_iso8601(secs) when is_integer(secs) do
    case DateTime.from_unix(secs, :second) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end

  defp unix_to_iso8601(_), do: nil

  defp unprocessable(conn, msg),
    do: ErrorResponse.emit_custom(conn, 422, "validation_failed", msg)

  defp not_found(conn),
    do: ErrorResponse.emit(conn, {:error, :not_found}, "preview token not found")
end
