defmodule BarkparkWeb.AppTokenController do
  @moduledoc """
  Admin-gated mint of a member-shaped, workspace-bound app token (mobile
  charter D4) — the instance half of the two-endpoint app-token exchange.

  `POST /v1/auth/app-tokens` — bearer-authed (`:require_token` verified the
  token and assigned `:api_token`), then gated on the bearer holding `admin`
  (the `mint_login_ticket` idiom: a lesser token gets the same generic
  unauthorized, no privilege oracle). The expected caller is the Barkpark Cloud
  control plane using the STORED per-instance admin token server-side — the
  member never sees an admin credential, only the minted member-shaped token.

  What one mint does, in order:

    1. JIT-provisions the cloud identity: `Sso.find_or_create_user/1` (race-safe,
       charter D5) plus an idempotent `member` workspace membership for the USER
       principal — the "your cloud account is a member on your instance" seat.
    2. Mints via the EXISTING `Auth.create_token/5` — atomic token +
       `role=member` membership for the TOKEN principal (D9: member-shaped
       row-level; `role_for_permissions/1` only grants `admin` when the list
       carries `admin`, which this endpoint can never mint).

  SECURITY — the permission set is capped by a hard allowlist
  (`read`/`write`/`chat`, ratified R2). A body asking for `admin` (or anything
  else) is a 422, never a policy decision: `RequireChatAccess` checks `admin`
  FIRST and resolves such a token to `:global`, so a single smuggled `admin`
  entry would mint a tenant-less operator credential through a member-reachable
  proxy. Deliberately NOT delegated to `Auth.create_chat_token/3` — that is the
  connector mint and its `["chat"]` set is D48-frozen; this endpoint mints the
  app-token set and nothing else.

  The plaintext token is returned ONCE in the 201 body and is never recoverable
  after (only its SHA256 hash is persisted). The raw token is NEVER logged and
  never audited — the audit event records THAT a mint happened.

  Wave 2 (mob-w2-app-token-revoke) adds the lifecycle twin: `delete/2`
  (admin-bearer revoke by presented token or logout-everywhere by email) and
  `delete_current/2` (self-revoke — the bearer kills itself). Both only ever
  SET `revoked_at`; `Auth.verify_token/1` already rejects revoked rows in its
  WHERE clause, so revocation is fail-closed with zero read-path changes.
  """
  use BarkparkWeb, :controller

  alias Barkpark.{Audit, Auth, RateLimiter, Sso, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.ErrorResponse

  @app_token_permissions ~w(read write chat)
  @app_token_prefix "bpapp_"

  # D7 sibling bucket on the instance side: `{:app_token_revoke, ip}`, 10/min —
  # the same budget as the Cloud proxy's `app_token_revoke:<ip>` window, so a
  # runaway logout loop is braked at both layers.
  @revoke_bucket_capacity 10

  @doc """
  Mint an app token bound to a workspace, as `email`'s JIT-provisioned identity.

  Body: `{"email": string, "workspace": slug-or-id?, "permissions": list?,
  "label": string?, "dataset": string?}`.

    * `email` is required — the cloud account the token is minted FOR.
    * `workspace` (slug or id) defaults to the Default Workspace; fail-closed
      422 when neither resolves (a workspace-less `chat`-carrying token is the
      tenant-less credential this surface must never mint).
    * `permissions` defaults to `#{inspect(@app_token_permissions)}` and must be
      a non-empty subset of it — `admin` is unmintable here by construction.
    * `dataset` defaults to `"production"`; `label` to `"app:" <> email`.

  201 → `{"token": raw, "workspace_id": ..., "permissions": [...],
  "expires_at": null}` — exactly the payload the Cloud proxy relays.
  """
  def create(conn, params) do
    token = conn.assigns.api_token

    if Auth.has_permission?(token, "admin") do
      mint(conn, params)
    else
      # mint_login_ticket idiom: a non-admin bearer gets the same generic
      # unauthorized as a bad token — this route never confirms tiers.
      ErrorResponse.emit(conn, {:error, :unauthorized})
    end
  end

  @doc """
  DELETE /v1/auth/app-tokens — admin-bearer-gated revoke, the mint's lifecycle
  twin (mob-w2-app-token-revoke). Sets `revoked_at` only; `Auth.verify_token/1`
  already filters revoked rows in its WHERE clause, so a revoked token fails
  closed on its next use with ZERO read-path changes.

  Body, EXACTLY one of (enforced: both keys → 422; an empty `"token"` → 422
  naming the field, never a silent logout-everywhere):

    * `{"token": raw}` — revoke exactly that token. Unknown raw → the same
      canonical 404 whatever the reason (nonexistent and foreign join one
      not-found oracle). Idempotent: re-revoking an already-revoked token is
      another 200.
    * `{"email": email}` — logout-everywhere WITHIN THE WORKSPACES THE BEARER
      ADMINISTERS: revoke every LIVE `app:<email>`-labelled token bound to one
      of them. 200 `{"revoked_count": n}` (0 included).

  Tokens carrying `admin` are never revocable through this path (422) — the
  stored custody credential cannot be killed by a label collision or a smuggled
  body. Rate-bucketed per IP (D7 idiom). Non-admin bearers get the same generic
  unauthorized as an invalid token (the mint's oracle discipline).

  ## "logout-everywhere" MEANS EVERYWHERE THE CALLER GOVERNS
  (task-ea8cae3258ea4bd3)

  The email arm used to select instance-wide, and the gate above it —
  `Auth.has_permission?(bearer, "admin")` — reads `token.permissions` and no
  workspace at all. An admin of workspace A therefore logged workspace B's
  users out of every phone session, knowing only an email address. The
  narrowing lives in `Auth.revoke_app_tokens_for_email/2`, which now takes the
  bearer and keeps only rows in workspaces where it is an ADMIN MEMBER.

  The BY-RAW arm above is deliberately NOT narrowed, and the asymmetry is the
  point: possession of the plaintext secret is itself the authorization there,
  exactly as in `delete_current/2`, and the Cloud control plane's relayed
  single-device logout (`Registry.revoke_app_token/3` with `{:token, raw}`)
  depends on it. A selector the caller can guess (an email) and a selector the
  caller must already hold (the secret) are different powers.
  """
  def delete(conn, params) do
    bearer = conn.assigns.api_token

    cond do
      revoke_rate_limited?(conn) ->
        ErrorResponse.emit(conn, {:error, :rate_limited})

      not Auth.has_permission?(bearer, "admin") ->
        ErrorResponse.emit(conn, {:error, :unauthorized})

      true ->
        revoke(conn, params)
    end
  end

  @doc """
  GET /v1/auth/app-tokens — admin-bearer-gated enumerate
  (jf-backlog-apptoken-revoke-upstream).

  Never returns a raw secret: only `token_hash` is stored, and it is not
  returned either. Mirrors `ShareController.list_tokens/2`'s posture rather than
  inventing a second shape.

  ## BOTH ARMS ARE SCOPED TO THE BEARER'S ADMIN WORKSPACES
  (task-71787769f1d03e51, then task-aa07355fa8a53355)

  The admin gate here is `Auth.has_permission?/2` — PERMISSION-only, with no
  tenancy predicate (the same property `Plugs.RequireAdmin` has). So any
  admin-permissioned token, in any workspace or none, reaches this route. What
  it then READS is confined by `Auth.list_app_tokens/2`, which takes the bearer
  and keeps only rows in workspaces where it is an ADMIN MEMBER — the same
  `Tenancy.Auth.workspace_admin?/2` predicate both revoke selectors on this
  controller use, so all THREE selectors answer the same way. `?email=` narrows
  WHAT is selected; it no longer decides WHO may see it.

  ## THE RULING ON THE UNFILTERED SWEEP (task-aa07355fa8a53355)

  This section used to be headed "WHAT THIS READ PATH STILL DOES NOT DO" and
  said the unfiltered sweep was "still unscoped, deliberately" — an admin of
  workspace A running `GET /app-tokens` with no filter saw every app token row
  on the instance, label withheld — with `task-aa07355fa8a53355` named as the
  open owner of the question. That row was decided, verbatim:

  > orchestrator, delegated; owner informed 2026-09-01 — RULED option 1: GET
  > /v1/auth/app-tokens is scoped to the bearer's ADMIN workspaces
  > (Tenancy.Auth.workspace_admin?/2, the same predicate both revoke arms use)
  > with labels UN-REDACTED there; an instance-wide view belongs to the
  > operator tier only, not to any `admin` permission bit.

  THERE IS NO INSTANCE-WIDE ARM TO BUILD HERE, and that is a fact about this
  tree rather than a deferral of work: `api/` has no operator predicate at all
  today — `Barkpark.Tenancy.Auth` exposes `member?/2`, `workspace_admin?/2` and
  `authorize/3`, all membership-derived, and nothing above them. The operator
  tier lives in `cloud/`. Building `?scope=instance` (the ruling's option 3)
  would mean first minting an operator predicate on the instance side, which is
  `task-c7e2b87f1bbca815`'s subject, not this route's. Until that exists, the
  honest shape of this endpoint is the scoped one, and an operator who wants an
  instance-wide inventory reads the database.

  ## THE LABEL IS NO LONGER REDACTED — THE GATE CARRIES IT NOW

  `label_redacted` is on the envelope and is now ALWAYS `false`. The key is
  KEPT rather than dropped: it is a published response field, a client keying
  on it must keep parsing, and a disappearing key reads as "unknown" where a
  literal `false` reads as "nothing was withheld". (Nothing in `internal/`,
  `js/`, `web/` or `docs/` reads it — only this repo's own tests do — so the
  key is retained for wire compatibility with clients outside the tree, not to
  serve a known reader.)

  The redaction existed for ONE stated reason, quoted from the paragraph it
  replaces: "the admin gate here is permission-only, with no tenancy
  predicate", so an unfiltered list that returned labels "would hand one
  workspace's admin EVERY USER'S EMAIL ADDRESS on the instance — a DIRECTORY,
  not a lifecycle verb." That premise is now false. The rows a caller can see
  are the rows in workspaces it already administers, whose members' addresses
  it can already read from the membership tables; withholding the label there
  hides nothing and costs the operator the one field that says WHOSE token a
  row is. A directory of the instance is no longer reachable from this route at
  all — not because the label is hidden, but because the ROWS are.

  What a caller gets is therefore everything the enumerate route exists for:
  `id` (revoke by it), `label`, `workspace_id`, `permissions`, `dataset` and
  the dates — for its own workspaces. An operator can still find and retire a
  custom-labelled token, including one the `?email=` filter can never match,
  which was the whole defect this route was built for.

  Non-admin bearers get the same generic unauthorized as an invalid token, the
  mint's oracle discipline.
  """
  def index(conn, params) do
    if Auth.has_permission?(conn.assigns.api_token, "admin") do
      case list_email_filter(params) do
        {:ok, opts} ->
          # The bearer is the SELECTOR's first argument, not a post-filter here:
          # `Auth.list_app_tokens/2` confines to workspaces it administers from
          # the same predicate both revoke arms use, on EVERY arm. Narrowing in
          # the controller would have left the next caller of that function
          # holding the instance-wide read (task-71787769f1d03e51).
          rows =
            conn.assigns.api_token
            |> Auth.list_app_tokens(opts)
            |> Enum.map(&app_token_json/1)

          # Always `false`, never computed from the filter. The flag used to be
          # `not filtered?` — the posture that redacted the sweep's labels
          # because its gate was permission-only. The gate is membership-scoped
          # now (task-aa07355fa8a53355), so there is nothing to withhold and no
          # branch to get wrong. The KEY stays for wire compatibility: a client
          # keying on it keeps parsing, and a literal `false` states "nothing
          # withheld" where an absent key would read as "unknown".
          json(conn, %{tokens: rows, label_redacted: false})

        {:error, message} ->
          unprocessable(conn, message)
      end
    else
      ErrorResponse.emit(conn, {:error, :unauthorized})
    end
  end

  @doc """
  DELETE /v1/auth/app-tokens/:id — admin-bearer-gated revoke by row id, the
  escape hatch for a token whose label no longer matches the email convention.

  A malformed or unknown id is a clean 404 (no existence oracle). Idempotent:
  re-revoking an already-revoked row is another 200, matching the by-raw arm.

  Unlike the by-raw and by-email arms this does NOT 422 an `admin`-permissioned
  token — see `Auth.revoke_app_token_by_id/2` for why an explicit row id is not
  the collision this rule was written against.

  ## The id must name a row the bearer administers (task-ea8cae3258ea4bd3)

  A FOREIGN row id joins the same not-found oracle as a missing one and a
  non-castable one: all three reach the single `ErrorResponse.emit(conn,
  {:error, :not_found})` call site below, byte-identical. Without that, this
  arm was the shorter path to the same cross-tenant harm as the email arm: at
  the time `index/2` handed an admin every id on the instance, and this route
  does not even spare `admin`-permissioned rows. `index/2` is scoped now too
  (task-aa07355fa8a53355), so that supply is gone — but the guard here is what
  makes an id from ANY source (a log line, a support ticket, an older client)
  useless, and it does not lean on the list route being narrow.
  """
  def delete_by_id(conn, %{"id" => id}) do
    cond do
      revoke_rate_limited?(conn) ->
        ErrorResponse.emit(conn, {:error, :rate_limited})

      not Auth.has_permission?(conn.assigns.api_token, "admin") ->
        ErrorResponse.emit(conn, {:error, :unauthorized})

      true ->
        case Auth.revoke_app_token_by_id(id, conn.assigns.api_token) do
          # THE RECEIPT, and it describes the STORE rather than the request
          # (jf-backlog-apptoken-revoke-upstream). `revoke_token/1` returns the
          # UPDATED row, so `revoked_at` is the timestamp the write actually
          # produced — not a literal echoed back from the caller's own params.
          # The success marker is the house one (auth_controller.ex:179/:218,
          # bulldocs_intents_controller.ex:50) and is what makes this routed
          # write JUDGED by the receipt census instead of an undisposed arrival.
          # Spelled only in the code below, never in this comment: the census
          # counts textual occurrences, and a mention here would register as a
          # PHANTOM site that names no emitter.
          # A revoke route that could not be audited would be the one thing this
          # endpoint exists to prevent.
          {:ok, token} ->
            json(conn, %{
              ok: true,
              revoked: not is_nil(token.revoked_at),
              id: token.id,
              revoked_at: token.revoked_at
            })

          {:error, :not_found} ->
            ErrorResponse.emit(conn, {:error, :not_found})

          {:error, _} ->
            ErrorResponse.emit(conn, {:error, :not_found})
        end
    end
  end

  @doc """
  DELETE /v1/auth/app-tokens/current — self-revoke: the bearer kills ITSELF
  (possession is the authorization; no admin required). The phone's
  cloud-independent logout. Admin bearers are refused (422) so the stored
  custody credential can never self-destruct through a member-shaped path.
  After the 200, the same bearer is rejected by `:require_token` — a repeat
  call is the HTTP-level proof of fail-closed.
  """
  def delete_current(conn, _params) do
    token = conn.assigns.api_token

    cond do
      revoke_rate_limited?(conn) ->
        ErrorResponse.emit(conn, {:error, :rate_limited})

      Auth.has_permission?(token, "admin") ->
        unprocessable(conn, "admin tokens cannot self-revoke through the app-token path")

      true ->
        case Auth.revoke_token(token) do
          # RECEIPT LAW (pds w40): `Auth.revoke_token/1` returns the UPDATED row
          # (auth.ex:200-225) — its own audit block already dereferences
          # `revoked.id`. The old body was a literal `true` that stayed true even
          # if the stamp never landed; `revoked` now descends from the persisted
          # `revoked_at` and stays truthy, so the wire contract is unchanged.
          {:ok, revoked} ->
            json(conn, %{
              revoked: not is_nil(revoked.revoked_at),
              id: revoked.id,
              revoked_at: revoked.revoked_at
            })

          _ ->
            unprocessable(conn, "could not revoke token")
        end
    end
  end

  # EXACTLY-ONE-OF, enforced rather than documented: with both keys present the
  # token clause below used to match first and silently win, so a body naming two
  # different victims killed one of them without saying which.
  defp revoke(conn, %{"token" => _, "email" => _}) do
    unprocessable(conn, ~s(body must carry exactly one of "token" or "email", not both))
  end

  defp revoke(conn, %{"token" => raw}) when is_binary(raw) and raw != "" do
    case Auth.get_api_token_by_raw(raw) do
      nil ->
        ErrorResponse.emit(conn, {:error, :not_found})

      %{permissions: perms} = token ->
        if "admin" in (perms || []) do
          unprocessable(conn, "admin tokens cannot be revoked through the app-token path")
        else
          case Auth.revoke_token(token) do
            # RECEIPT LAW (pds w40): same callee, same repair as
            # `delete_current/2` above — the admin revoke-by-raw path answered
            # with a literal `true` that could not distinguish a landed stamp
            # from an unobserved one (auth.ex:200-225).
            {:ok, revoked} ->
              json(conn, %{
                revoked: not is_nil(revoked.revoked_at),
                id: revoked.id,
                revoked_at: revoked.revoked_at
              })

            _ ->
              unprocessable(conn, "could not revoke token")
          end
        end
    end
  end

  # A present-but-empty (or non-string) "token" is a caller bug, not a request to
  # revoke nothing: name the field instead of falling through to the generic
  # "token or email" message.
  defp revoke(conn, %{"token" => raw}) when not (is_binary(raw) and raw != "") do
    unprocessable(conn, ~s("token" must be a non-empty string))
  end

  defp revoke(conn, %{"email" => email}) when is_binary(email) do
    case String.trim(email) do
      "" ->
        unprocessable(conn, "email must be a non-empty string")

      trimmed ->
        json(conn, %{
          revoked_count: Auth.revoke_app_tokens_for_email(trimmed, conn.assigns.api_token)
        })
    end
  end

  defp revoke(conn, _params) do
    unprocessable(conn, ~s(body must carry "token" or "email"))
  end

  # The bucket key comes from RateLimiter.client_ip/1 — the ONE trust boundary
  # for x-forwarded-for (it was the limiter's to draw, not this controller's).
  # The earlier first-hop read here was inherited from the pulse limiter and was
  # not a limit at all: Caddy APPENDS, so a caller reaching this endpoint
  # directly could send its own header and rotate its bucket key per request.
  # The resolver believes the chain only from a trusted front and takes the
  # rightmost non-proxy hop. The Cloud control plane's relayed address
  # (Registry.revoke_app_token/3) still wins — a whole team does not share one
  # bucket keyed on the single Cloud egress IP — provided that egress address is
  # listed in BARKPARK_TRUSTED_PROXIES; unlisted, it is correctly disbelieved.
  #
  # The key goes through `RateLimiter.scope_key/2` (the per-test isolation
  # scope `Plugs.RateLimit` always honoured; a no-op in production). Without it
  # this bucket was the ONE unscoped meter on the app-token routes: every test
  # conn is the loopback peer, so every revoking suite spent the same
  # `127.0.0.1` allowance of 10/min, and which file saw the 429 was a function
  # of the seed (main run 33681637129, seed 210993, reddened
  # RequireTokenWriteGateTest; the next sha was green).
  defp revoke_rate_limited?(conn) do
    RateLimiter.check(
      revoke_bucket_key(conn),
      capacity: @revoke_bucket_capacity,
      refill_per_sec: @revoke_bucket_capacity / 60
    ) == :rate_limited
  end

  defp revoke_bucket_key(conn) do
    RateLimiter.scope_key(conn, {:app_token_revoke, RateLimiter.client_ip(conn)})
  end

  defp mint(conn, params) do
    with {:ok, email} <- fetch_email(params),
         {:ok, permissions} <- fetch_permissions(params),
         {:ok, workspace} <- resolve_workspace(params) do
      # JIT MEMBER (charter D5): the identity first, then its member seat.
      # `create_membership` is idempotent-by-constraint — an existing seat hits
      # the unique index and is left as-is (the `Sso.jit_provision/3` pattern).
      user = Sso.find_or_create_user(email)
      _ = TenancyAuth.create_membership(workspace.id, user.id, "member", "user")

      raw = @app_token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      label = fetch_label(params, email)
      dataset = fetch_dataset(params)

      case Auth.create_token(raw, label, dataset, permissions, workspace.id) do
        {:ok, minted} ->
          # Credential lifecycle event (the `revoke_token` twin): THAT a mint
          # happened, for whom, into which workspace — never the token value.
          Audit.emit(%{
            category: "token",
            action: "app_token_minted",
            subject: minted.id,
            actor_type: "user",
            actor_id: user.id,
            workspace_id: workspace.id,
            metadata: %{"email" => email, "label" => label, "permissions" => permissions}
          })

          conn
          |> put_status(:created)
          |> json(%{
            token: raw,
            workspace_id: workspace.id,
            permissions: permissions,
            expires_at: nil
          })

        {:error, _changeset} ->
          unprocessable(conn, "could not mint token")
      end
    else
      {:error, :email_required} ->
        unprocessable(conn, "email is required and must be a non-empty string")

      {:error, :invalid_permissions} ->
        unprocessable(
          conn,
          "permissions must be a non-empty subset of #{inspect(@app_token_permissions)}"
        )

      {:error, :workspace_not_found} ->
        unprocessable(conn, "workspace could not be resolved")
    end
  end

  defp fetch_email(%{"email" => email}) when is_binary(email) do
    case String.trim(email) do
      "" -> {:error, :email_required}
      trimmed -> if trimmed =~ "@", do: {:ok, trimmed}, else: {:error, :email_required}
    end
  end

  defp fetch_email(_), do: {:error, :email_required}

  defp fetch_permissions(%{"permissions" => perms}) when is_list(perms) do
    if perms != [] and Enum.all?(perms, &(is_binary(&1) and &1 in @app_token_permissions)) do
      # Keep the canonical order (and dedupe) so the minted list is stable
      # whatever order the caller sent.
      {:ok, Enum.filter(@app_token_permissions, &(&1 in perms))}
    else
      {:error, :invalid_permissions}
    end
  end

  defp fetch_permissions(%{"permissions" => _}), do: {:error, :invalid_permissions}
  defp fetch_permissions(_), do: {:ok, @app_token_permissions}

  # `workspace` accepts a slug (the Cloud proxy sends its stored bootstrap
  # workspace slug) or an id; absent/null falls back to the Default Workspace.
  # No resolvable workspace → fail closed (422), never an unbound token.
  defp resolve_workspace(params) do
    case params["workspace"] do
      slug_or_id when is_binary(slug_or_id) and slug_or_id != "" ->
        case Tenancy.get_workspace_by_slug(slug_or_id) || Tenancy.get_workspace_by_id(slug_or_id) do
          nil -> {:error, :workspace_not_found}
          workspace -> {:ok, workspace}
        end

      _ ->
        case Tenancy.get_default_workspace() do
          nil -> {:error, :workspace_not_found}
          workspace -> {:ok, workspace}
        end
    end
  end

  defp fetch_label(%{"label" => label}, _email) when is_binary(label) and label != "" do
    label
  end

  defp fetch_label(_, email), do: "app:" <> email

  defp fetch_dataset(%{"dataset" => dataset}) when is_binary(dataset) and dataset != "",
    do: dataset

  defp fetch_dataset(_), do: "production"

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "unprocessable", message: message}})
  end

  # The list filter reuses the mint's OWN email discipline (trim, non-empty,
  # must contain "@") so a caller cannot narrow by a shape the mint would never
  # have produced — one convention, not two.
  defp list_email_filter(%{"email" => email}) when is_binary(email) do
    case String.trim(email) do
      "" ->
        {:error, "email must be a non-empty string"}

      trimmed ->
        if trimmed =~ "@",
          do: {:ok, [email: trimmed]},
          else: {:error, ~s(email must look like an address)}
    end
  end

  defp list_email_filter(%{"email" => _}), do: {:error, ~s("email" must be a string)}
  defp list_email_filter(_), do: {:ok, []}

  # One row. The raw secret is never stored (only `token_hash`) and the hash is
  # not returned either — an enumerate route must not hand out anything
  # replayable.
  #
  # This took a `filtered?` second argument and nil-ed `label` unless the caller
  # had supplied the address. That branch is gone with the redaction it served
  # (task-aa07355fa8a53355): every row reaching here is in a workspace the
  # bearer administers, so `label` is the real one. A `nil` label now means the
  # ROW has none, which is the statement the old shape could not make.
  defp app_token_json(token) do
    %{
      id: token.id,
      label: token.label,
      permissions: token.permissions || [],
      dataset: token.dataset,
      workspace_id: token.workspace_id,
      revoked_at: token.revoked_at,
      inserted_at: token.inserted_at
    }
  end
end
