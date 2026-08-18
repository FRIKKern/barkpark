defmodule BarkparkWeb.ShareController do
  @moduledoc """
  `/v1/shares` — admin-only CRUD over the PERSISTENT scoped-sharing registry
  (P4b). The HTTP surface behind `bp share ls/add/rm` and the Studio Shares
  panel.

  Mounted under `[:api, :require_admin]`: managing which tenant scopes are
  exposed on the network is an administrative act, so every verb requires an
  admin token. The anonymous reader/query/media surfaces a share opens are
  unauthenticated, but DECLARING a share is not.

  Each write goes through `Barkpark.Sharing.add_share/1` / `remove_share/3`,
  which validate through the SAME parser as a `BARKPARK_SHARES` env entry and
  call `refresh/0`, so a new share is live immediately (no restart) and a
  malformed request can never widen access.

  ## Tenancy confinement on `/v1/shares/tokens` (arpss-w8)

  `:require_admin` is a GLOBAL-permission gate — it proves the caller holds
  `"admin"` somewhere, not that it may act on THIS tenant. The three edit-token
  actions therefore additionally require the caller to be an ADMIN MEMBER of
  the workspace the REQUEST targets (`Tenancy.Auth.workspace_admin?/2`, the
  grant-reading chokepoint): mint against the SCOPE's workspace (403), list
  filtered to the caller's admin workspaces (200, foreign rows absent), revoke
  against the TARGET ROW's workspace (404, byte-identical to a missing row).

  BEHAVIOUR CHANGE THAT SHIPS: an admin bound to workspace A can no longer
  mint/list/revoke edit tokens for workspace B, even when it holds a plain
  `member` membership in B. That flow used to succeed and is the cross-tenant
  hole this closes; two `share_token_controller_test.exs` assertions moved to
  the fail-closed status to state the new contract.

  SELF-HOSTED HOST-IS-ADMIN IS PRESERVED: `Auth.create_token/5` writes an
  admin-role membership in the resolved (Default) workspace, so the
  single-tenant admin remains a workspace admin of everything it created.
  HONEST LIMIT of that proof (`share_token_controller_test.exs`, "self-hosted
  host-is-admin …"): it is a PERMISSIVE assertion, so it can NEVER go red under
  a full reversion of this confinement, and on its own it does NOT catch an
  actor-vs-target confusion — authorizing against the ACTOR's own
  `workspace_id` leaves that test green (measured; the file's two cross-tenant
  tests are what red on that mutation, 3 failures). It is mutation-verified
  against OVER-confinement instead: raising the role floor to `owner`, and
  refusing to honour a Default-workspace membership, each turn it red (403
  where 201 is expected).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.Errors
  alias Barkpark.Repo
  alias Barkpark.Sharing
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.ErrorResponse

  @doc """
  `GET /v1/shares` — list every live share, env baseline + persisted, each
  tagged with its `source` (`"env"` | `"stored"`). Only `"stored"` shares are
  mutable here; `"env"` shares come from `BARKPARK_SHARES`.
  """
  def index(conn, _params) do
    env = Enum.map(Sharing.shares_env(), &share_json(&1, "env"))
    stored = Enum.map(Sharing.list_stored(), &share_json(&1, "stored"))

    json(conn, %{shares: env ++ stored, active: Sharing.active?()})
  end

  @doc """
  `POST /v1/shares` — add (or upsert) a stored share.

  Body/params: `scope` (required, `"ws[/project[/dataset]]"`), `surfaces`
  (required, comma list of `papers,docs,media`), `access` (optional,
  `read|edit`, default `read`). 201 on success, 422 on an invalid scope /
  surface / access.
  """
  def create(conn, params) do
    scope = params["scope"]
    surfaces = params["surfaces"]
    access = params["access"] || "read"

    cond do
      not is_binary(scope) or scope == "" ->
        unprocessable(conn, "scope is required")

      not is_binary(surfaces) or surfaces == "" ->
        unprocessable(conn, "surfaces is required (comma list of papers,docs,media)")

      true ->
        case Sharing.add_share("#{scope}:#{surfaces}:#{access}") do
          {:ok, share} ->
            conn |> put_status(:created) |> json(%{share: share_json(share, "stored")})

          {:error, :invalid} ->
            unprocessable(
              conn,
              "invalid share — check scope, surfaces (papers,docs,media), access (read,edit)"
            )

          {:error, %Ecto.Changeset{} = changeset} ->
            unprocessable(conn, changeset_errors(changeset))
        end
    end
  end

  @doc """
  `DELETE /v1/shares` — remove the stored share for a scope.

  Body/params: `scope` (required). Applies the same default project/dataset as
  the parser, so `"gyldendal"` deletes `gyldendal/default/production`. Returns
  the count removed (0 if none / if the scope was env-only). 422 on a malformed
  scope.
  """
  def delete(conn, params) do
    scope = params["scope"]

    case scope && Sharing.scope_triple(scope) do
      {:ok, {ws, proj, dataset}} ->
        {:ok, count} = Sharing.remove_share(ws, proj, dataset)
        json(conn, %{removed: count, scope: "#{ws}/#{proj}/#{dataset}"})

      _ ->
        unprocessable(conn, "scope is required and must be ws[/project[/dataset]]")
    end
  end

  @doc """
  `POST /v1/shares/tokens` — mint a scoped-share EDIT token (P5).

  Body/params: `scope` (required), `surfaces` (required, comma list of
  `docs,media`), `ttl` (optional seconds; default 7d, cap 1y), `label`
  (optional). 201 with the RAW token shown ONCE; 422 if the scope is not
  `:edit`-shared for the surfaces; 403 when the caller is not a workspace
  admin of the SCOPE's workspace (see the tenancy-confinement note above).

  ORDERING IS LOAD-BEARING: the scope slug is resolved to a workspace BEFORE
  the tenancy check. A scope whose workspace does not exist has no tenant to
  confine to, so it falls through to `Auth.create_share_token/5` and keeps its
  422 "the scope is not edit-shared" contract instead of turning into a 403/404.
  """
  def mint_token(conn, params) do
    scope = params["scope"]
    surfaces = params["surfaces"]

    with true <- is_binary(scope) and scope != "",
         true <- is_binary(surfaces) and surfaces != "",
         {:ok, {ws, proj, dataset}} <- Sharing.scope_triple(scope) do
      # Resolve FIRST (see the ordering note above), authorize SECOND.
      case Tenancy.get_workspace_by_slug(ws) do
        %Tenancy.Workspace{id: ws_id} ->
          if workspace_admin?(conn, ws_id),
            do: do_mint(conn, ws, proj, dataset, surfaces, params),
            else: forbidden(conn)

        nil ->
          do_mint(conn, ws, proj, dataset, surfaces, params)
      end
    else
      _ -> unprocessable(conn, "scope and surfaces (comma list of docs,media) are required")
    end
  end

  defp do_mint(conn, ws, proj, dataset, surfaces, params) do
    surface_list =
      surfaces |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    opts = token_opts(params)

    case Barkpark.Auth.create_share_token(ws, proj, dataset, surface_list, opts) do
      {:ok, {raw, token}} ->
        conn
        |> put_status(:created)
        |> json(%{token: raw, share_token: token_json(token)})

      {:error, reason} ->
        unprocessable(conn, "could not mint edit token: #{describe_token_error(reason)}")
    end
  end

  @doc """
  `GET /v1/shares/tokens` — list share-edit tokens (optional `?scope=` filter).
  Never returns the raw token or its hash.

  CONFINED: without `?scope=` the underlying query returns EVERY workspace's
  share tokens, so the rows are filtered to the workspaces the caller is an
  admin member of BEFORE `token_json/1` runs. Status stays 200 — foreign rows
  are simply absent, never a 403 that would confirm they exist.
  """
  def list_tokens(conn, params) do
    scope = if is_binary(params["scope"]) and params["scope"] != "", do: params["scope"]
    rows = Barkpark.Auth.list_share_tokens(scope)

    # One membership lookup per DISTINCT workspace, not per row.
    allowed =
      rows
      |> Enum.map(& &1.workspace_id)
      |> Enum.uniq()
      |> Enum.filter(&workspace_admin?(conn, &1))
      |> MapSet.new()

    tokens =
      rows
      |> Enum.filter(&MapSet.member?(allowed, &1.workspace_id))
      |> Enum.map(&token_json/1)

    json(conn, %{tokens: tokens})
  end

  @doc """
  `DELETE /v1/shares/tokens/:token_id` — revoke one share-edit token.

  CONFINED: the target ROW is read first and the caller must be a workspace
  admin of the ROW's workspace. A denial is the SAME 404 "token not found" as a
  missing row (byte-identical), so an opaque token id never becomes an
  existence oracle. `Barkpark.Auth.revoke_token/1` itself stays UNSCOPED — 9 of
  its 12 call sites have no HTTP actor.
  """
  def revoke_token(conn, %{"token_id" => token_id}) do
    if revocable_by?(conn, token_id) do
      do_revoke(conn, token_id)
    else
      not_found(conn, "token not found")
    end
  end

  defp do_revoke(conn, token_id) do
    case Barkpark.Auth.revoke_token(token_id) do
      # RECEIPT LAW (pds w39): `Auth.revoke_token/1` returns the UPDATED row
      # (auth.ex:200-226). `revoked: true` was a literal and `token_id` echoed
      # the path param — neither could change if the update wrote nothing. Both
      # now descend from the returned row's own `revoked_at` stamp.
      {:ok, revoked} ->
        json(conn, %{
          revoked: not is_nil(revoked.revoked_at),
          token_id: revoked.id,
          revoked_at: revoked.revoked_at
        })

      {:error, :not_found} ->
        not_found(conn, "token not found")

      {:error, _} ->
        unprocessable(conn, "could not revoke token")
    end
  end

  # ── tenancy confinement for the /tokens actions ────────────────────────

  # The predicate is the MEMBERSHIP GRANT in the TARGET workspace
  # (`Tenancy.Auth.workspace_admin?/2`), never `authorize/3`: authorize/3's
  # api_token arm is `member? AND the token's GLOBAL permissions[]`, so a
  # global-admin token holding a plain "member" row in workspace B passes
  # `authorize(tok, B, :admin)` while `workspace_admin?(tok, B)` denies. The
  # leak-closed test is written against exactly that shape (a real "member"
  # membership in the foreign workspace), so swapping this call for authorize/3
  # turns it RED.
  #
  # TOTALITY: `workspace_admin?/2` raises FunctionClauseError on a nil id and
  # Ecto.Query.CastError on any non-UUID binary (including ""), so every id is
  # routed through `Repo.uuid_or_nil/1` first and anything that does not cast is
  # a DENIAL — a 500 here would trade a leak for a crash oracle.
  defp workspace_admin?(conn, workspace_id) do
    actor = conn.assigns[:api_token]

    case {actor, Repo.uuid_or_nil(workspace_id)} do
      {%ApiToken{}, ws_id} when is_binary(ws_id) -> TenancyAuth.workspace_admin?(actor, ws_id)
      _ -> false
    end
  end

  # A token id is revocable when its row exists AND the caller is a workspace
  # admin of the ROW's workspace. A row with no workspace_id is not revocable
  # through this surface (nil is a denial, never a pass).
  defp revocable_by?(conn, token_id) do
    with id when is_binary(id) <- Repo.uuid_or_nil(token_id),
         %ApiToken{workspace_id: ws_id} <- Repo.get(ApiToken, id) do
      workspace_admin?(conn, ws_id)
    else
      _ -> false
    end
  end

  defp forbidden(conn) do
    ErrorResponse.emit(conn, {:error, :forbidden}, "workspace access required")
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp token_opts(params) do
    ttl =
      case params["ttl"] do
        t when is_integer(t) ->
          t

        t when is_binary(t) ->
          case Integer.parse(t) do
            {n, _} -> n
            :error -> nil
          end

        _ ->
          nil
      end

    [ttl: ttl, label: params["label"]]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # The token row, MINUS the secret (token_hash never leaves the server).
  defp token_json(token) do
    %{
      id: token.id,
      label: token.label,
      scope: token.share_scope,
      surfaces:
        token.permissions
        |> List.wrap()
        |> Enum.map(&String.replace_prefix(&1, "share-edit-", "")),
      dataset: token.dataset,
      expires_at: token.expires_at,
      revoked_at: token.revoked_at,
      inserted_at: Map.get(token, :inserted_at)
    }
  end

  defp describe_token_error(:not_edit_shared), do: "the scope is not edit-shared"
  defp describe_token_error(:surface_not_shared), do: "a requested surface is not edit-shared"
  defp describe_token_error(:unsupported_surface), do: "only docs and media are editable surfaces"
  defp describe_token_error(:no_surfaces), do: "no valid surfaces"
  defp describe_token_error(:unknown_scope), do: "the workspace/project does not exist"
  defp describe_token_error(%Ecto.Changeset{}), do: "validation failed"
  defp describe_token_error(other), do: inspect(other)

  defp share_json(%Sharing.Share{} = s, source) do
    %{
      scope: "#{s.workspace_slug}/#{s.project_slug}/#{s.dataset}",
      workspace: s.workspace_slug,
      project: s.project_slug,
      dataset: s.dataset,
      surfaces: Enum.map(s.surfaces, &Atom.to_string/1),
      access: Atom.to_string(s.access),
      source: source
    }
  end

  # Canonical v1 validation envelope (code + request_id), the same contract as
  # the content endpoints — was a bare `%{error: message}` with neither. A string
  # rides as the human `message`; a changeset-errors map rides as `details`.
  defp unprocessable(conn, message) do
    base =
      {:error, :malformed}
      |> Errors.to_envelope(conn)
      |> Map.put(:code, "validation_failed")

    env =
      case message do
        msg when is_binary(msg) -> Map.put(base, :message, msg)
        details -> base |> Map.put(:message, "validation failed") |> Map.put(:details, details)
      end

    conn |> put_status(422) |> json(%{error: Map.delete(env, :status)})
  end

  # Canonical not_found with a resource-specific message.
  defp not_found(conn, message) do
    env =
      {:error, :not_found}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, message)

    conn |> put_status(env.status) |> json(%{error: Map.delete(env, :status)})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
