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

  ## Tenancy confinement on the `/v1/shares` WRITE half (arpss-w8, slice 2)

  Confining mint/list/revoke while `POST`/`DELETE /v1/shares` stayed
  workspace-blind was DECORATIVE, because the share registry is the mint's
  PRECONDITION. `create/2` and `delete/2` therefore run the SAME predicate
  (`workspace_admin?/2` above — one helper, not a second mechanism), against
  the workspace the SCOPE names, BEFORE `Sharing.add_share/1` /
  `remove_share/3` touch the store.

  Three holes close, all reproduced on clean origin/main before the fix:

    * THE FORGE — a ws-A-bound admin POSTed `{scope: "<ws-B scope>", access:
      "edit"}` and got 201, manufacturing the very `:edit` share that
      `Auth.create_share_token/5` requires. Now 403.
    * THE DoS — the same actor `DELETE`d ws-B's share and `remove_share/3`
      hard-revoked every live ws-B edit token (`revoked_at` stamped,
      `Auth.verify_token/1` → `:error`). Now 403, with the victim row reloaded
      in the test rather than the status being trusted.
    * THE GHOST SHARE — `POST /v1/shares` for a workspace that does not exist
      returned 201 and PERSISTED a `StoredShare`, pre-planting a foreign
      `:edit` share that goes live the moment someone registers that slug.
      Now 422.

  WHY 422 AND NOT 404 FOR THE GHOST (the ruling, recorded here because the
  merge carries this file): `Auth.create_share_token/5` already answers
  `:unknown_scope` for exactly this condition and the controller already
  renders that as a 422 "the workspace/project does not exist"
  (`describe_token_error/1`), so the write half now says the same thing in the
  same words on the same status. Every other `create/2` rejection is already a
  422 — an unknown workspace is a bad ATTRIBUTE of the submitted entity, not a
  missing route or row, and 404 would additionally imply `POST /v1/shares`
  itself does not exist. No new error CODE is invented; it stays
  `validation_failed`.

  ACCEPTED SIGNAL, identical to the mint action's: an existing foreign
  workspace answers 403 and a nonexistent slug answers 422, so the pair
  distinguishes them. Answering 422 for both would mean confirming nothing —
  but it would also mean a caller could not tell a typo'd slug from a real
  denial, and the same signal is already public via `ResolveWorkspace`
  (404 unknown / 403 unreachable).

  `Barkpark.Sharing.add_share/1` and `remove_share/3` stay ACTOR-FREE library
  functions — no conn, no token, no membership lookup entered either (charter
  D10, same reason `Auth.revoke_token/1` stays unscoped). The authorization
  lives here, at the HTTP edge, where the actor exists.

  MUTATION RECEIPTS for this half (run in the builder's worktree, quoted in the
  commit body and the test moduledoc): deleting the `create/2` predicate turns
  the forge test RED (201 where 403 is expected, and the foreign `:edit` share
  goes live); deleting the `delete/2` predicate turns the DoS test RED with the
  victim's `revoked_at` stamped. NOTE the honest limit on the forge's last
  step: with slice 1 merged, `mint_token/2` independently denies the ws-B mint,
  so removing THIS predicate alone no longer produces a live `bpshare_` token —
  it takes removing BOTH predicates. That measured pair is recorded in the test
  moduledoc.
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

  CONFINED (the `"stored"` half only): `Sharing.list_stored/0` reads EVERY
  workspace's rows, so they are filtered to the workspaces the caller is an
  admin member of BEFORE `share_json/2` runs — the SAME shape `list_tokens/2`
  uses for share-edit tokens (one membership lookup per DISTINCT workspace, not
  per row). Status stays 200 and foreign rows are simply ABSENT, never a 403
  that would confirm they exist.

  THE `"env"` HALF IS DELIBERATELY LEFT UNCLAMPED, pending the owner ruling
  `arpss-stored-share-registry-ruling`. An env entry is DECLARED by whoever set
  `BARKPARK_SHARES` and may legally name a workspace that does not exist yet
  (or ever) — it has no tenancy row to authorize against, so any clamp here
  would have to invent an ownership rule and would hide an operator's own
  configuration from the admin who wrote it. It stays visible until that ruling
  lands. `active:` likewise stays global — it is a single "is sharing
  configured at all" bit already implied by the unclamped env half.
  """
  def index(conn, _params) do
    env = Enum.map(Sharing.shares_env(), &share_json(&1, "env"))
    stored = conn |> visible_stored_shares() |> Enum.map(&share_json(&1, "stored"))

    json(conn, %{shares: env ++ stored, active: Sharing.active?()})
  end

  # The stored-share twin of `list_tokens/2`'s filter. A `Sharing.Share` carries
  # a workspace SLUG rather than an id, so the slug is resolved through
  # `Tenancy.get_workspace_by_slug/1` first; the predicate itself is the same
  # `workspace_admin?/2` every other confined action in this controller uses.
  #
  # FAIL-CLOSED on an unresolvable slug: a stored row naming a workspace that no
  # longer exists (a GHOST left by the permissive create that shipped before
  # arpss-w8 slice 2) is not listed. It stays deletable — `delete/2`
  # deliberately does not confine an unresolvable workspace, which is the
  # cleanup path for exactly those rows.
  defp visible_stored_shares(conn) do
    rows = Sharing.list_stored()

    # One membership lookup per DISTINCT workspace slug, not per row.
    allowed =
      rows
      |> Enum.map(& &1.workspace_slug)
      |> Enum.uniq()
      |> Enum.filter(&stored_share_visible?(conn, &1))
      |> MapSet.new()

    Enum.filter(rows, &MapSet.member?(allowed, &1.workspace_slug))
  end

  defp stored_share_visible?(conn, workspace_slug) do
    case Tenancy.get_workspace_by_slug(workspace_slug) do
      %Tenancy.Workspace{id: ws_id} -> workspace_admin?(conn, ws_id)
      _ -> false
    end
  end

  @doc """
  `POST /v1/shares` — add (or upsert) a stored share.

  Body/params: `scope` (required, `"ws[/project[/dataset]]"`), `surfaces`
  (required, comma list of `papers,docs,media`), `access` (optional,
  `read|edit`, default `read`). 201 on success, 422 on an invalid scope /
  surface / access; 403 when the caller is not a workspace admin of the
  SCOPE's workspace; 422 when that workspace does not exist at all (see the
  tenancy-confinement note above).

  ORDER: grammar → resolve → AUTHORIZE → write. The tenancy check runs before
  `Sharing.add_share/1` ever touches the store, so no denied request can leave
  a row behind and the decision never depends on whether a share already
  exists (an upsert is indistinguishable from an insert to the caller).
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
        case scope_workspace(scope) do
          {:ok, ws_id} ->
            if workspace_admin?(conn, ws_id),
              do: do_create(conn, scope, surfaces, access),
              else: forbidden(conn)

          :unknown_workspace ->
            # GHOST SHARE, fail-closed. Same vocabulary the token surface
            # already uses for `:unknown_scope` (`describe_token_error/1`), and
            # the same 422 family every other create rejection uses — a new
            # denial CODE is not invented here.
            unprocessable(conn, "could not add share: the workspace/project does not exist")

          :invalid_scope ->
            # Grammar failure (wildcard, empty segment, …). Hand it to
            # `add_share/1` so the EXISTING 422 message is preserved verbatim;
            # a malformed scope names no tenant, so nothing is leaked by
            # answering before the tenancy check.
            do_create(conn, scope, surfaces, access)
        end
    end
  end

  defp do_create(conn, scope, surfaces, access) do
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

  @doc """
  `DELETE /v1/shares` — remove the stored share for a scope.

  Body/params: `scope` (required). Applies the same default project/dataset as
  the parser, so `"gyldendal"` deletes `gyldendal/default/production`. Returns
  the count removed (0 if none / if the scope was env-only). 422 on a malformed
  scope; 403 when the caller is not a workspace admin of the SCOPE's workspace.

  THIS VERB IS DESTRUCTIVE BEYOND THE ROW, and `removed` counts only the row.
  `Sharing.remove_share/3` also stamps `revoked_at` on EVERY live scoped-share
  edit token under the scope (`Auth.revoke_share_tokens/3`) AND on EVERY live
  ITEM SHARE LINK under it (`Sharing.Links.revoke_scope/3`) — the `/s/<token>`
  URLs. Both revocations run whether or not a row was deleted, so `removed: 0`
  does NOT mean nothing was revoked. Unconfined, one request hard-revoked
  another tenant's editing credentials — the cross-tenant DoS this closes.

  THE ITEM-LINK CASCADE IS RULED (lead-security-r, 2026-09-02), not incidental:
  an operator who removes a share believes access is withdrawn, and item links
  derive their authority from the share they were minted under. A link in a
  SIBLING project or dataset is a different scope and survives.

  UNRESOLVABLE WORKSPACE IS NOT A DENIAL HERE (asymmetric with `create/2`, on
  purpose): a scope whose workspace does not exist has no tenant to protect,
  and this is the only surface that can clean up the GHOST rows planted by the
  permissive create that shipped before this change. It can never reach a live
  tenant's share — a live tenant has a resolvable workspace and is therefore
  403-confined above. `:require_admin` still gates the verb.
  """
  def delete(conn, params) do
    scope = params["scope"]

    case scope && Sharing.scope_triple(scope) do
      {:ok, {ws, proj, dataset}} ->
        case Tenancy.get_workspace_by_slug(ws) do
          %Tenancy.Workspace{id: ws_id} ->
            if workspace_admin?(conn, ws_id),
              do: do_delete(conn, ws, proj, dataset),
              else: forbidden(conn)

          nil ->
            do_delete(conn, ws, proj, dataset)
        end

      _ ->
        unprocessable(conn, "scope is required and must be ws[/project[/dataset]]")
    end
  end

  defp do_delete(conn, ws, proj, dataset) do
    {:ok, count} = Sharing.remove_share(ws, proj, dataset)
    json(conn, %{removed: count, scope: "#{ws}/#{proj}/#{dataset}"})
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

  ACCEPTED SIGNAL (reviewed, arpss-w8): that ordering means a caller can tell an
  EXISTING foreign workspace (403) from a nonexistent slug (422). Keeping the
  422 first would be strictly worse — it would answer "is this foreign workspace
  edit-shared, and for which surfaces", i.e. leak the foreign share CONFIG, not
  just the slug's existence. And the signal is not new: `ResolveWorkspace`
  already answers 404 for an unknown `/w/:workspace_slug/...` and 403 for a real
  one the caller cannot reach (resolve_workspace.ex:71-76, 134).
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
  # TOTALITY IS THE CHOKEPOINT'S JOB — it is no longer re-done here. This helper
  # used to hand-roll `case {actor, Repo.uuid_or_nil(workspace_id)}`, written
  # when `Tenancy.Auth` raised FunctionClauseError on a nil id and
  # Ecto.Query.CastError on any non-UUID binary. It does not any more:
  # `Tenancy.Auth.membership/3` runs BOTH ids through `Repo.uuid_or_nil/1`
  # (`@canonical capability:uuid-guarded-fetch`, repo.ex) and each arity carries
  # a terminal `-> nil` clause, so a nil actor, a non-`%ApiToken{}` principal, a
  # nil workspace id and an uncastable one all reach the SAME `false` they
  # reached through the wrapper — a DENIAL, never a 500. Made total by #12616
  # (c8cb3e35e9, the membership/2 fail-closed seam) and #12710 (7a42b45576,
  # which moved the `Repo.uuid_or_nil/1` pair INTO membership/3 and gave that
  # arity its own terminal denial); pinned by
  # `test/barkpark_web/live/studio/caps_non_uuid_workspace_denies_test.exs` and,
  # for this seam specifically, by the "the chokepoint denies a malformed
  # workspace id" test in this controller's own suite. Re-adding a local uuid
  # dance here would teach the next reader that every caller must remember it.
  defp workspace_admin?(conn, workspace_id),
    do: TenancyAuth.workspace_admin?(conn.assigns[:api_token], workspace_id)

  # A token id is revocable when its row exists AND the caller is a workspace
  # admin of the ROW's workspace. A row with no workspace_id is not revocable
  # through this surface (nil is a denial, never a pass).
  #
  # THE `Repo.uuid_or_nil/1` BELOW STAYS — it is NOT the redundant wrapper the
  # sibling helper just shed, and it does not guard `Tenancy.Auth` at all. It
  # guards the bare `Repo.get(ApiToken, id)` on the next line: that is Ecto's
  # own fetch, NOT a Barkpark chokepoint, and binding a non-UUID string to a
  # `:binary_id` column raises `Ecto.Query.CastError` → 500. There is no total
  # by-id accessor for an `ApiToken` in `Barkpark.Auth` today, so this guard is
  # the only thing standing between `DELETE /v1/shares/tokens/not-a-uuid` and a
  # crash oracle. Delete it and `share_controller_test.exs`'s "a malformed
  # (non-UUID) token id is a clean 404" test goes RED with a CastError.
  defp revocable_by?(conn, token_id) do
    with id when is_binary(id) <- Repo.uuid_or_nil(token_id),
         %ApiToken{workspace_id: ws_id} <- Repo.get(ApiToken, id) do
      workspace_admin?(conn, ws_id)
    else
      _ -> false
    end
  end

  # Resolve a caller-supplied scope STRING to the id of the workspace it names.
  #   {:ok, ws_id}        the workspace exists — authorize against it
  #   :unknown_workspace  well-formed scope, no such workspace (ghost share)
  #   :invalid_scope      the scope does not parse at all (wildcard, empty, …)
  defp scope_workspace(scope) do
    case Sharing.scope_triple(scope) do
      {:ok, {ws, _proj, _dataset}} ->
        case Tenancy.get_workspace_by_slug(ws) do
          %Tenancy.Workspace{id: id} -> {:ok, id}
          nil -> :unknown_workspace
        end

      _ ->
        :invalid_scope
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
