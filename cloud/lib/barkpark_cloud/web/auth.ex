defmodule BarkparkCloud.Web.Auth do
  @moduledoc """
  Bearer-token authentication for the control-plane HTTP API (cloud-12a).

  Three principals share one `Authorization: Bearer <token>` header but resolve
  through different stores:

    * a USER session token (`Accounts.verify_user_session_token/1`) → the human
      behind "one login for all your Barkparks". Assigned as
      `conn.assigns.current_user` + `conn.assigns.current_team` (the user's
      primary team — a logged-in user acts within one team at a time).
    * an AGENT token (`Registry.verify_agent_token/1`) → an on-box agent
      reporting for one Barkpark. Assigned as `conn.assigns.current_barkpark`.
    * the WORKER token — a single shared secret (`:worker_token` config / the
      `WORKER_TOKEN` env) the off-box Go warm-pool provisioner presents to the
      `/v1/internal/*` job-queue endpoints. NOT a user session and NOT an agent
      token — a separate, unrelated principal, checked by constant-time compare.

  The user/agent token namespaces do not overlap (random 32-byte tokens,
  separate hashed tables), so a token is at most one of those principals. The
  worker token is a flat shared secret, so a user/agent token can never be it
  and the worker token resolves no user/agent (each pipeline does its OWN lookup
  against only its store). Three pipeline plugs gate routes:

    * `require_user/2`   — 401 unless a valid USER session token resolved.
    * `require_agent/2`  — 401 unless a valid AGENT token resolved.
    * `require_worker/2` — 401 unless the bearer equals the configured worker
      token. When no worker token is configured (e.g. dev with `WORKER_TOKEN`
      unset), it fails CLOSED — every request 401s rather than opening the
      internal endpoints to all.

  One DISJUNCTION composes over them: `require_user_or_pat_or_worker/2`, for a
  PLATFORM-scoped read whose writer is the worker itself. It admits the worker
  FACELESSLY (no `:current_user`, no `:current_team`) and clamps it to
  `["read"]`, so it can never be a back door to a write. Read its own @doc
  before putting a second route behind it.
  """
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.Authz
  alias BarkparkCloud.Accounts.TeamMembership
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Registry

  @doc """
  Require a valid USER session token. On success assigns `:current_user` and
  `:current_team`; otherwise halts the conn with a 401 JSON body.

  The session's `last_used_at` stamp is DEFERRED (`defer_session_touch/2`), not
  written here — see that function for why authentication is the wrong place to
  make a liveness claim.
  """
  def require_user(conn, _opts) do
    with token when is_binary(token) <- bearer_token(conn),
         %{} = user <- Accounts.verify_user_session_token(token, touch: false) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_team, resolve_team(conn, user))
      |> defer_session_touch(token)
    else
      _ -> unauthorized(conn)
    end
  end

  # THE LIVENESS STAMP BELONGS DOWNSTREAM OF THE RESPONSE DECISION.
  #
  # `last_used_at` is what the sessions card renders as "Active just now", so it
  # is a claim that the platform SERVED this device — but authentication runs
  # strictly before authorization. `require_platform_operator/2` resolves the
  # user, THEN checks the allowlist and answers `forbidden/2`; there are seven
  # `forbidden/2` sites in this module and every one of them is downstream
  # of the verify. An eager stamp therefore made a REFUSED device print as
  # active, and a throttle at the write site could not touch it: an idle device
  # satisfies any staleness guard (measured — idle 3600s, one request, 403, and
  # the stamp still jumped a full hour).
  #
  # `register_before_send/2` is the first point where the status is known, and
  # it runs for every terminal path (`send_resp`, `send_file`, `send_chunked`),
  # including the halts above. `status < 400` is the gate: served ⇒ claim
  # activity, refused (401/403/404/422) ⇒ claim nothing. A request that never
  # sends (an unhandled crash) stamps nothing either, which is the honest answer.
  #
  # Registered ONCE per conn: `require_team_role/3` and friends re-enter
  # `require_user/2`, and a second callback would be a redundant (throttled, but
  # pointless) statement.
  defp defer_session_touch(conn, token) do
    defer_credential_touch(conn, fn -> Accounts.touch_session_last_used(token) end)
  end

  # The PAT twin. A PAT is the SAME liveness claim on the tokens card, and it
  # runs through the same authentication-before-authorization ordering: the
  # branch below resolves the credential, and `require_ability/2` answers
  # `forbidden/2` only afterwards — so an eager stamp made a read-only PAT
  # that was just 403'd print as freshly used. Measured: backdate 3600s, fire
  # ONE refused request, and the stamp jumped a full hour past any throttle.
  defp defer_pat_touch(conn, token) do
    defer_credential_touch(conn, fn -> Accounts.touch_pat_last_used(token) end)
  end

  # Registered ONCE per conn under a SHARED private key. Safe because session
  # and PAT are mutually exclusive branches of one `cond` in
  # `require_user_or_pat/2` — a single conn can only ever carry one of them, so
  # the two deferrals can never contend for the key. (Should a conn ever be
  # able to hold both, this needs one key per credential kind.)
  defp defer_credential_touch(conn, stamp_fun) do
    if conn.private[:barkpark_session_touch_deferred] do
      conn
    else
      conn
      |> put_private(:barkpark_session_touch_deferred, true)
      |> register_before_send(fn sent ->
        if is_integer(sent.status) and sent.status < 400 do
          stamp_fun.()
        end

        sent
      end)
    end
  end

  # Team resolution honors an explicit `x-barkpark-team` header when the caller
  # is a MEMBER of that team (the SPA's team switcher — a user can belong to
  # several teams but every route reads one `current_team`). Anything else —
  # absent header, malformed id, a team the user was removed from — falls back
  # to the primary (oldest) membership rather than hard-failing, so a stale
  # switcher value degrades to a working dashboard instead of bricking it.
  defp resolve_team(conn, user) do
    with [team_id | _] <- Plug.Conn.get_req_header(conn, "x-barkpark-team"),
         %{} = team <- Accounts.get_team(team_id),
         %{} <- Accounts.get_membership(team.id, user.id) do
      team
    else
      _ -> Accounts.primary_team(user)
    end
  end

  @doc """
  Require a USER whose grant on `current_team` is `owner` or `admin`.

  Runs `require_user/2` first (idempotent if `current_user` is already assigned),
  then enforces the role via `Authz.team_admin?/2`. A drop-in replacement for the
  `require_user` line in a mutating route: 401 when unauthenticated, 403 when
  authenticated but under-privileged (or holding no team grant). Mirrors api/'s
  `BarkparkWeb.Plugs.RequireWorkspaceRole` (fail-closed on a missing assign → 403)
  in this `Plug.Router`'s inline style.
  """
  def require_team_admin(conn, opts), do: gate_role(conn, opts, &Authz.team_admin?/2, "admin")

  @doc """
  Require a USER who is the OWNER of `current_team` (the billing / delete-team
  gate). Same shape as `require_team_admin/2`, narrower check.
  """
  def require_team_owner(conn, opts), do: gate_role(conn, opts, &Authz.team_owner?/2, "owner")

  @doc """
  Require a valid USER credential — either a session token OR a Personal Access
  Token (PAT). The programmatic-API counterpart of `require_user/2`: external
  integrations authenticate with a PAT, the browser dashboard with a session.

  On success assigns `:current_user`, `:current_team`, and `:current_abilities`:

    * a SESSION credential implies the full user (a logged-in human is not
      ability-limited), so it carries `["root"]` — the browser dashboard is
      never gated by `require_ability/2`.
    * a PAT carries `:current_token` (the `%UserToken{}`) + its own
      `:current_abilities` array, and resolves `:current_team` from the team it
      was minted under (falling back to the user's primary team).

  Halts with a 401 JSON body when neither resolves.
  """
  def require_user_or_pat(conn, _opts) do
    case bearer_token(conn) do
      token when is_binary(token) ->
        cond do
          user = Accounts.verify_user_session_token(token, touch: false) ->
            conn
            |> assign(:current_user, user)
            |> assign(:current_team, resolve_team(conn, user))
            |> assign(:current_abilities, ["root"])
            |> defer_session_touch(token)

          result = Accounts.verify_personal_access_token(token, touch: false) ->
            {user, pat} = result

            conn
            |> assign(:current_user, user)
            |> assign(
              :current_team,
              Accounts.get_team(pat.team_id) || Accounts.primary_team(user)
            )
            |> assign(:current_token, pat)
            |> assign(:current_abilities, pat.abilities)
            |> defer_pat_touch(token)

          true ->
            unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  # THE ABILITY IMPLICATION TABLE (site-spawner wave 10).
  #
  # The ability strings on a PAT are a FLAT set on the wire and the mint is
  # EXCLUSIVE, not hierarchical (`UserToken.normalize_abilities/1` collapses
  # `root` → ["root"] and `deploy` → ["deploy"], mirroring Coolify's
  # ApiTokens.updatedPermissions). So a `write` PAT holds literally ["write"] and
  # a `deploy` PAT literally ["deploy"] — neither carries `read`.
  #
  # Honouring only the literal string made the programmatic surface unusable: a
  # write PAT could POST /v1/sites/:id/deploy but was 403'd on GET /v1/sites, so
  # `bp cloud site deploy` — which resolves the site handle via ListSites and then
  # POLLS GET /v1/sites/:id/deployments/:dep_id — could not complete a deploy it
  # was allowed to START. Same for a deploy PAT and go-live.
  #
  # The fix is an EXPLICIT table, spelled out rather than derived, so widening it
  # is an edit to this map and nothing else. Implication runs in the READ
  # direction ONLY:
  #
  #   root   ⊇ read, write, deploy   — the session/superset credential
  #   write  ⊇ read                  — "may change it" implies "may look at it"
  #   deploy ⊇ read                  — "may launch it" implies "may resolve it"
  #   deploy ⊉ write                  — DELIBERATE. The mint sells `deploy` as
  #     "Launch / go-live only (exclusive)"; implying `write` would hand a
  #     launch-only credential all seven write-gated site routes, DELETE
  #     /v1/sites/:id included.
  #   write  ⊉ deploy                 — DELIBERATE. A CI key must not be able to
  #     provision a paid box.
  #
  # The bound that makes the read direction safe is that EVERY route gated on
  # `read` is a GET. That is not a convention to remember — it is machine-checked
  # each run by RouterAbilityMatrixTest, which scans router.ex and fails naming
  # the offending route.
  @ability_implies %{
    "root" => ~w(root read write deploy),
    "write" => ~w(write read),
    "deploy" => ~w(deploy read),
    "read" => ~w(read)
  }

  @doc """
  The ability implication table: `held ability => every ability it satisfies`.
  Exposed so tests (and the ability-matrix invariant) can assert against the
  table itself rather than restating it.
  """
  def ability_implies, do: @ability_implies

  # Does a HELD ability satisfy the REQUIRED one? An unknown held string
  # satisfies only itself — an unrecognised ability never widens anything.
  defp implies?(held, required) when is_binary(held) and is_binary(required) do
    required in Map.get(@ability_implies, held, [held])
  end

  @doc """
  Require `ability` on the resolved credential. Run AFTER
  `require_user_or_pat/2`. A session credential carries `["root"]` so the browser
  dashboard always passes; a PAT is gated by its `abilities` array, widened only
  by the READ-direction implication table above (`write`/`deploy` satisfy
  `read`; neither satisfies the other). Halts with a 403 JSON body on a miss
  (and is a no-op pass-through if the conn is already halted, so it composes
  cleanly after the require step).
  """
  def require_ability(conn, ability) when is_binary(ability) do
    if conn.halted do
      conn
    else
      abilities = conn.assigns[:current_abilities] || []

      if Enum.any?(abilities, &implies?(&1, ability)) do
        conn
      else
        forbidden(conn, required: ability, scope: "token")
      end
    end
  end

  @doc """
  Require a valid AGENT token. On success assigns `:current_barkpark`; otherwise
  halts the conn with a 401 JSON body.
  """
  def require_agent(conn, _opts) do
    with token when is_binary(token) <- bearer_token(conn),
         %{} = barkpark <- Registry.verify_agent_token(token) do
      assign(conn, :current_barkpark, barkpark)
    else
      _ -> unauthorized(conn)
    end
  end

  @doc """
  Require the shared WORKER token (the off-box Go warm-pool provisioner). On a
  match the conn passes through unchanged (the worker is a faceless principal —
  there is no team/barkpark to assign); otherwise halts with a 401 JSON body.

  Fails CLOSED when no worker token is configured: an unset / blank
  `:worker_token` 401s every request, so the internal endpoints are never open
  by omission. The compare is constant-time to avoid leaking the secret by
  timing.
  """
  def require_worker(conn, _opts) do
    if worker_bearer?(conn), do: conn, else: unauthorized(conn)
  end

  # ONE definition of "this bearer IS the worker". `require_worker/2` halts on a
  # miss; `require_user_or_pat_or_worker/2` needs the same question answered
  # WITHOUT halting, because a non-worker there is not a refusal — it is the
  # next credential to try. A second copy of the compare is how one of them
  # would eventually stop failing closed on a blank `:worker_token`.
  @spec worker_bearer?(Plug.Conn.t()) :: boolean()
  defp worker_bearer?(conn) do
    configured = worker_token()

    with token when is_binary(token) <- bearer_token(conn),
         true <- is_binary(configured) and configured != "" do
      Plug.Crypto.secure_compare(token, configured)
    else
      _ -> false
    end
  end

  @doc """
  Require a USER credential (session or PAT) **or** the shared WORKER token —
  the gate for a PLATFORM-SCOPED read whose WRITER is the worker itself
  (`GET /v1/deliveries`, task-e2acb66e9ed0da09).

  ## Why this exists

  The platform delivery record is WRITTEN by `POST /v1/internal/platform-
  deliveries` under `require_worker/2` — deploy.yml's crown step carries
  `WORKER_TOKEN` and nothing else. Under `require_user_or_pat/2` alone the read
  half answered that same principal **401**: the record had no working API read
  path for the credential that writes it, and crown-reconcile survived only by
  SSH-ing into the control plane and reading `platform_deliveries` out of its
  postgres container — 22 times in run 31311887504. A fallback that always fires
  is a broken door with a working window.

  ## Why widening to the worker grants nothing new

  The worker token is not a tenant credential and never becomes one here. It is
  a faceless off-box shared secret that ALREADY reaches `/v1/internal/*` — the
  cross-team `GET /v1/internal/barkparks` list, every team's provision-job
  queue, and the writer of these very rows. Admitting it to a read of the
  platform's own per-sha deploy record is STRICTLY SUBSUMED by what it holds
  already. What it must not do is inherit a USER's reach, so:

    * NO `:current_user` and NO `:current_team` are assigned. The worker stays
      faceless, exactly as under `require_worker/2`. A route that reads
      `conn.assigns.current_user` MUST NOT use this plug — it would match on
      nil.
    * `:current_abilities` is `["read"]`, never `["root"]`. The worker satisfies
      `require_ability("read")` and is 403'd by `write`, `deploy` and `root`, so
      composing this plug onto a mutating route cannot silently hand the worker
      a write.
    * `:current_principal` is `:worker`, so a handler can tell the three apart
      without re-deriving them from the bearer.

  ## Order

  The worker compare runs FIRST: it is a constant-time compare against a flat
  shared secret and needs no database round-trip, and (per this module's
  moduledoc) a user/agent token can never equal it — the namespaces do not
  overlap. So trying it first cannot shadow a human credential.

  Fails CLOSED on every axis: an unset/blank `:worker_token` matches nothing,
  and a bearer that is neither the worker nor a valid session/PAT falls through
  to `require_user_or_pat/2`'s 401.
  """
  @spec require_user_or_pat_or_worker(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_user_or_pat_or_worker(conn, opts) do
    if worker_bearer?(conn) do
      conn
      |> assign(:current_principal, :worker)
      |> assign(:current_abilities, ["read"])
    else
      require_user_or_pat(conn, opts)
    end
  end

  @doc """
  Require a USER SESSION whose email is on the platform-operator allowlist — the
  gate for the read-mostly Operator console (`/v1/operator/*`, GR39). Runs
  `require_user/2` first (idempotent if `current_user` is already assigned), then
  checks the resolved email against `Notifications.platform_admin_emails/0` — the
  SAME allowlist that feeds `/v1/me`'s `platform_operator` boolean, so operator-
  ness has ONE definition and `isu-backlog-operator-principal` inherits both.

  Fails CLOSED:

    * 401 when no/invalid session token (delegated to `require_user/2`).
    * 403 when authenticated but NOT on the allowlist — and, because the
      allowlist resolves config emails against REGISTERED users and reads `[]`
      when unset, an unconfigured platform 403s every user rather than opening
      the operator surface by omission.

  Distinct from `require_worker/2` (the faceless off-box provisioner secret
  behind `/v1/internal/*` + `/v1/admin/*`): this gates the human operator's
  browser SESSION, which is 401-dead against the worker surface. Never a team
  role (owner/admin is a different axis: authority reads from the membership
  row, not a global allowlist — Authz law).

  THE RULING (`isu-backlog-operator-principal`, closing charter GR9/GR39's open
  question): this is THE human principal for the fleet self-update controls, not
  an interim placeholder, and it is reachable from BOTH shipped human surfaces —
  the console SPA and `bp cloud rollout`, which now calls
  `/v1/operator/autoupdate[/halt|/resume]` with the caller's session instead of
  aiming it at the worker-gated `/v1/admin/autoupdate*` trio no `bp login` token
  could ever open. The worker routes were NOT widened to accept a session: the
  two doors are disjoint in both directions, and
  `test/barkpark_cloud/web/router_operator_test.exs` §2b asserts that as a
  full-equality matrix (worker 401/200 · operator 200/401 · plain 403/401).
  """
  @spec require_platform_operator(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_platform_operator(conn, opts) do
    conn = if conn.assigns[:current_user], do: conn, else: require_user(conn, opts)

    cond do
      conn.halted -> conn
      conn.assigns.current_user.email in Notifications.platform_admin_emails() -> conn
      true -> forbidden(conn, required: "platform_operator", scope: "platform")
    end
  end

  @doc """
  The configured shared worker token (`config :barkpark_cloud, :worker_token`,
  fed from `WORKER_TOKEN` in runtime.exs). `nil` when unset — `require_worker`
  treats that as "no worker may authenticate" (fail closed).
  """
  @spec worker_token() :: binary() | nil
  def worker_token, do: Application.get_env(:barkpark_cloud, :worker_token)

  @doc """
  Require that the authed user holds at least `min_role` ("member"|"admin") in
  the team named by `team_id`. The Cloud twin of api/'s `RequireWorkspaceRole`
  (copied, NOT reused — the api/ plug lives in another OTP app). On success
  assigns `:current_team_scoped` (the path team) and `:current_team_role`; on
  failure halts:

    * 401 if no/invalid user token (delegates to `require_user/2`).
    * 404 if the user is NOT a member of that team (no existence leak — a
      non-member learns nothing about whether the team exists).
    * 403 if a member but below `min_role`.
  """
  @spec require_team_role(Plug.Conn.t(), binary() | nil, String.t()) :: Plug.Conn.t()
  def require_team_role(conn, team_id, min_role) do
    conn = require_user(conn, [])

    if conn.halted do
      conn
    else
      user = conn.assigns.current_user

      case team_id && Accounts.get_team(team_id) do
        nil ->
          # No id, or no such team → 404 (same shape a non-member gets).
          not_found(conn)

        team ->
          role = Accounts.team_role(user, team)

          cond do
            # Not a member → 404, never a 403 (do not confirm the team exists).
            is_nil(role) ->
              not_found(conn)

            TeamMembership.rank(role) < TeamMembership.rank(min_role) ->
              forbidden(conn, required: min_role, scope: "team")

            true ->
              conn
              |> assign(:current_team_scoped, team)
              |> assign(:current_team_role, role)
          end
      end
    end
  end

  @doc """
  Require that the authed user is owner|admin of the CURRENTLY SELECTED team —
  the gate for privileged actions on routes that resolve the team implicitly
  (billing/checkout, go-live, DELETE barkpark) rather than from a path `:id`.

  The team read is `conn.assigns[:current_team]`, which `require_user/2` fills
  via `resolve_team/2`: the `x-barkpark-team` header wins whenever the caller is
  a member of that team (the SPA's team switcher), and only an absent/unusable
  header falls back to the primary membership. So this gate is NOT primary-team
  scoped — it judges whichever team the caller currently has selected, and EVERY
  refusal it emits says `scope: "team"` for that reason.

  401 if unauthenticated; 403 `{forbidden, reason: "no_team", scope: "team"}` if
  the user has no team; 403 `{forbidden, required: "admin", scope: "team"}` if a
  member but not admin. Holding no grant is an AUTHORITY answer, not a malformed
  body — one condition, one status. On success the conn passes through with
  `:current_team` already assigned by `require_user/2`.
  """
  @spec require_primary_team_admin(Plug.Conn.t()) :: Plug.Conn.t()
  def require_primary_team_admin(conn) do
    conn = require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns[:current_team]) ->
        forbidden(conn, reason: "no_team", scope: "team")

      Accounts.team_admin?(conn.assigns.current_user, conn.assigns.current_team) ->
        conn

      true ->
        forbidden(conn, required: "admin", scope: "team")
    end
  end

  @doc """
  Require that the authed user is the OWNER of the CURRENTLY SELECTED team — the
  billing gate (checkout / portal / cancel). The narrower twin of
  `require_primary_team_admin/1`, and it answers the same three conditions the
  same way: 401 if unauthenticated; 403 `{forbidden, reason: "no_team", scope:
  "team"}` if the user has no team; 403 `{forbidden, required: "owner", scope:
  "team"}` if a member/admin but not the owner — a missing grant is an authority
  answer, never a bad body. Reads `Authz.team_owner?/2` against
  `conn.assigns[:current_team]` — filled by `resolve_team/2` from the
  `x-barkpark-team` header when the caller is a member of that team, primary
  membership only as the fallback. Not primary-team scoped, hence
  `scope: "team"` on every refusal. On success the conn passes through with
  `:current_team` already assigned by `require_user/2`.
  """
  @spec require_primary_team_owner(Plug.Conn.t()) :: Plug.Conn.t()
  def require_primary_team_owner(conn) do
    conn = require_user(conn, [])

    cond do
      conn.halted ->
        conn

      is_nil(conn.assigns[:current_team]) ->
        forbidden(conn, reason: "no_team", scope: "team")

      Authz.team_owner?(conn.assigns.current_user, conn.assigns.current_team) ->
        conn

      true ->
        forbidden(conn, required: "owner", scope: "team")
    end
  end

  @doc """
  Extract the bearer token from the `Authorization` header, or `nil` when it is
  absent or not a `Bearer <token>` form. Public so the router can reuse it.
  """
  @spec bearer_token(Plug.Conn.t()) :: binary() | nil
  def bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      ["bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  # Ensure a user, then enforce `check.(user, team)`. A no-team authenticated
  # user is 403 (not 401) — they ARE authenticated, they simply hold no grant.
  #
  # `check` arrives as an opaque capture (`&Authz.team_admin?/2` vs
  # `&Authz.team_owner?/2`), so this function cannot introspect WHICH authority
  # it is enforcing — `required` is the caller's own label for it, and it is the
  # only reason the two arms are distinguishable in a refusal.
  defp gate_role(conn, opts, check, required) do
    conn = if conn.assigns[:current_user], do: conn, else: require_user(conn, opts)

    cond do
      # require_user already sent 401 — leave it.
      conn.halted ->
        conn

      # NO AUTHORITY HERE. A user who holds no team at all cannot be repaired by
      # any role grant, so naming one would be a second confidently-wrong
      # sentence. State the actual cause instead; the status stays 403 (they are
      # authenticated, they simply hold no grant).
      is_nil(conn.assigns[:current_team]) ->
        forbidden(conn, reason: "no_team", scope: "team")

      check.(conn.assigns.current_user, conn.assigns.current_team) ->
        conn

      true ->
        forbidden(conn, required: required, scope: "team")
    end
  end

  defp unauthorized(conn), do: json_halt(conn, 401, %{error: "unauthorized"})

  @doc """
  Send a 403 whose body carries the AUTHORITY that was missing, and halt.

  ADDITIVE ONLY. `error: "forbidden"` is the slug 21 assertions across 10 test
  files already pin — evidence is merged AROUND it, never over it, so a client
  that reads only `error` is unaffected while one that can render a cause has
  something to render.

  PUBLIC (cch-w36-s1) because the ONE refusal on the launch→checkout chain is
  not gated by this module at all: `go_live` gates the session branch INLINE in
  the router (it must not re-run `require_user/2` and discard the resolved
  PAT/session assigns), and it used to ship a bare `%{error: "forbidden"}` — the
  console could not tell that refusal apart from the owner-only billing one. The
  router now emits its evidence through this seam instead of reaching a private
  function or growing a second copy of the shape.

  NO DEFAULT ARGUMENT, on purpose: `evidence \\\\ []` reds the Cloud gate, which
  compiles with `--warnings-as-errors` (charter D396(2)).
  """
  @spec forbidden(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def forbidden(conn, evidence),
    do: json_halt(conn, 403, Enum.into(evidence, %{error: "forbidden"}))

  defp not_found(conn), do: json_halt(conn, 404, %{error: "not_found"})

  defp json_halt(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
