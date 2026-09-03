defmodule Barkpark.Auth do
  @moduledoc "Context for API token authentication."

  import Ecto.Query
  alias Barkpark.Audit
  alias Barkpark.Repo
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Auth.LoginTicket
  alias Barkpark.Sharing
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # dwb-7 login-ticket TTL: 60s. A one-time handoff URL is used immediately
  # (control plane mints it, browser opens it), so the window is deliberately
  # tiny — single-use + short TTL are the two mitigations for consuming on GET.
  @login_ticket_ttl_seconds 60

  # P5 share-edit token TTL policy (owner decision 2026-06-09): default 7 days,
  # hard cap 1 year. Write access is higher-risk than the anonymous read share,
  # so an edit token always expires.
  @share_token_default_ttl 7 * 24 * 3600
  @share_token_max_ttl 365 * 24 * 3600

  # The ONLY surfaces an edit token may cover. Papers-edit is out of scope (it
  # rides the Bulldocs shared-secret ingest API, a different auth model).
  @editable_surfaces ~w(docs media)

  def verify_token(raw_token) do
    hash = ApiToken.hash_token(raw_token)
    now = DateTime.utc_now()

    # Revocation + expiry are enforced in the WHERE clause, not post-filter:
    # a revoked or expired token must look identical to a missing one
    # (`{:error, :unauthorized}`), with no opportunity to leak its existence.
    #
    # `kind == "api"` is the fail-closed ticket-key boundary (Barkpark Tickets,
    # charter Decision 1): a low-trust `kind == "ticket"` key is filtered out
    # HERE, at the single choke point, so EVERY consumer of verify_token/1 —
    # RequireToken, OptionalToken, RequireBearerOrSessionToken, the login-ticket
    # mint, session auth, share-edit resolution — rejects a ticket key with zero
    # further edits. Revocation-style (WHERE, not post-filter) so a ticket key is
    # indistinguishable from a missing token. `Tickets.Keys.verify/1`
    # (kind == "ticket") is the ONLY resolver that accepts one.
    ApiToken
    |> where([t], t.token_hash == ^hash)
    |> where([t], t.kind == "api")
    |> where([t], is_nil(t.revoked_at))
    |> where([t], is_nil(t.expires_at) or t.expires_at > ^now)
    |> Repo.one()
    |> case do
      nil -> {:error, :unauthorized}
      token -> {:ok, token}
    end
  end

  @doc """
  Resolve a raw bearer to its `ApiToken` id, or nil.

  The IDENTITY half of `verify_token/1` — same WHERE clause, same fail-closed
  `kind == "api"` boundary, no `%ApiToken{}` handed to the caller. Exists for
  `BarkparkWeb.Plugs.RateLimit`, which needs a stable per-credential key and
  nothing else, and which registers this alongside `Scim.resolve_token_id/1`
  as one entry in its resolver list.
  """
  @spec verify_token_id(binary()) :: binary() | nil
  def verify_token_id(raw_token) when is_binary(raw_token) do
    case verify_token(raw_token) do
      {:ok, %ApiToken{id: id}} -> id
      _ -> nil
    end
  end

  def verify_token_id(_), do: nil

  # ── dwb-7: single-use login handoff tickets ─────────────────────────────

  @doc """
  Mint a single-use, 60s login ticket bound to `raw_api_token` (dwb-7).

  The caller must prove possession of a LIVE api_token — this re-verifies it
  (`verify_token/1`), so a revoked/expired token cannot mint. The opaque ticket
  is stored only as its SHA-256 hash; the raw api_token is held encrypted at
  rest (`Barkpark.EncryptedBinary`) so `consume_login_ticket/1` can later drop
  the RAW token into the session (what LiveAuth verifies). Returns
  `{:ok, raw_ticket}` — the raw ticket is returned ONCE and never recoverable —
  or `{:error, :unauthorized}` for a bad/expired/revoked token.

  Never log the returned ticket or the api_token; never place the api_token in a
  URL. Only the ticket travels in the handoff URL.

  A USER-shaped ticket (cloud-identity-studio-handoff) carries `opts[:user_email]`
  — consuming it JIT-provisions that account and mints a `user_session` (the
  Barkpark Cloud "same account on your instance" handoff). Because consuming
  grants a Default-workspace OWNER, minting one requires the bearer to hold the
  `admin` permission (the control plane's stored per-instance admin token) —
  a read-only token minting a user ticket would be privilege escalation.
  """
  @spec mint_login_ticket(binary(), keyword()) :: {:ok, binary()} | {:error, :unauthorized}
  def mint_login_ticket(raw_api_token, opts \\ [])

  def mint_login_ticket(raw_api_token, opts) when is_binary(raw_api_token) do
    user_email = presence(opts[:user_email])

    case verify_token(raw_api_token) do
      {:ok, token} ->
        if user_email != nil and not has_permission?(token, "admin") do
          {:error, :unauthorized}
        else
          raw_ticket =
            "bplt_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

          now = DateTime.utc_now()

          attrs = %{
            ticket_hash: hash_ticket(raw_ticket),
            api_token: raw_api_token,
            user_email: user_email,
            expires_at: DateTime.add(now, @login_ticket_ttl_seconds)
          }

          case %LoginTicket{} |> LoginTicket.changeset(attrs) |> Repo.insert() do
            {:ok, _ticket} -> {:ok, raw_ticket}
            {:error, _changeset} -> {:error, :unauthorized}
          end
        end

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  def mint_login_ticket(_, _), do: {:error, :unauthorized}

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  @doc """
  Atomically consume a login ticket, returning the bound RAW api_token (dwb-7).

  Single-use is enforced by a race-safe `UPDATE ... WHERE used_at IS NULL AND
  not-expired` that stamps `used_at` and returns the row: under Postgres READ
  COMMITTED two concurrent consumes serialize on the row lock and the second
  re-evaluates the WHERE against the now-spent row, so EXACTLY ONE wins (count
  == 1). An unknown, already-used, or expired ticket all return the SAME
  `{:error, :invalid}` — no oracle distinguishes the failure kinds.
  """
  @spec consume_login_ticket(binary()) :: {:ok, binary()} | {:error, :invalid}
  def consume_login_ticket(raw_ticket) when is_binary(raw_ticket) do
    hash = hash_ticket(raw_ticket)
    now = DateTime.utc_now()

    # `select:` (NOT the `:returning` opt — update_all silently ignores it and
    # yields `{count, nil}`) both returns the winner's payload and routes it
    # through the schema type, so the EncryptedBinary ciphertext comes back
    # DECRYPTED as the raw api_token.
    query =
      from t in LoginTicket,
        where: t.ticket_hash == ^hash and is_nil(t.used_at) and t.expires_at > ^now,
        select: {t.api_token, t.user_email}

    case Repo.update_all(query, set: [used_at: now]) do
      # user-shaped (cloud-identity handoff): the consumer mints a
      # user_session for this email instead of dropping the token in.
      {1, [{raw_api_token, user_email}]} when is_binary(user_email) ->
        {:ok, {:user, user_email, raw_api_token}}

      {1, [{raw_api_token, nil}]} ->
        {:ok, raw_api_token}

      _ ->
        {:error, :invalid}
    end
  end

  def consume_login_ticket(_), do: {:error, :invalid}

  @doc """
  Delete expired or spent login tickets. Best-effort GC — returns the count
  removed. A spent/expired row carries no live secret (its api_token is only
  reachable by a WINNING consume, which never happens again), so retention is a
  hygiene concern, not a security one.
  """
  @spec sweep_login_tickets() :: non_neg_integer()
  def sweep_login_tickets do
    now = DateTime.utc_now()

    {count, _} =
      LoginTicket
      |> where([t], not is_nil(t.used_at) or t.expires_at <= ^now)
      |> Repo.delete_all()

    count
  end

  @doc false
  @spec hash_ticket(binary()) :: binary()
  def hash_ticket(raw_ticket) do
    :crypto.hash(:sha256, raw_ticket) |> Base.encode16(case: :lower)
  end

  @doc "The login-ticket TTL in seconds (the mint response's `expires_in`)."
  @spec login_ticket_ttl_seconds() :: pos_integer()
  def login_ticket_ttl_seconds, do: @login_ticket_ttl_seconds

  @doc """
  Revoke an API token — sets `revoked_at` to now so `verify_token/1` rejects
  it without a DB delete. Accepts an `ApiToken` struct or a token id. Idempotent
  on an already-revoked token (re-stamps `revoked_at`). The revocation primitive
  — no HTTP route is wired yet.
  """
  @spec revoke_token(ApiToken.t() | binary()) ::
          {:ok, ApiToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke_token(%ApiToken{} = token) do
    token
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
    |> case do
      {:ok, revoked} = ok ->
        # A revoke is a standing-credential lifecycle event — audit it. `subject`
        # is the token id; `owner_user_id` distinguishes a user PAT from a
        # machine/share token for the audit reader.
        Audit.emit(%{
          category: "token",
          action: "token_revoked",
          subject: revoked.id,
          actor_type: "system",
          metadata: %{
            "owner_user_id" => revoked.owner_user_id,
            "share_scope" => revoked.share_scope
          }
        })

        broadcast_socket_teardown(revoked)

        ok

      err ->
        err
    end
  end

  def revoke_token(token_id) when is_binary(token_id) do
    # Guard the UUID cast: the id column is :binary_id, so a non-UUID token_id
    # (e.g. from `DELETE /v1/shares/tokens/garbage`) would raise Ecto.CastError
    # → 500. A malformed id can't identify any row, so it's a clean not_found.
    case Repo.uuid_or_nil(token_id) do
      nil ->
        {:error, :not_found}

      uuid ->
        case Repo.get(ApiToken, uuid) do
          nil -> {:error, :not_found}
          token -> revoke_token(token)
        end
    end
  end

  # Revocation has to reach ALREADY-OPEN sockets, not just the next HTTP
  # request. `verify_token/1`'s WHERE clause is re-run per request, so the HTTP
  # door closes on its own; `BarkparkWeb.UserSocket.connect/3` runs it EXACTLY
  # ONCE and then never again, so a revoked credential kept answering search
  # frames and streaming live document pushes for as long as the holder stayed
  # connected. `UserSocket.id/1` now returns a token-derived topic — the handle
  # Phoenix's own disconnect mechanism needs — and this is the broadcast
  # against it, so teardown is caused by the revoke itself with no action
  # required from the client. Both other revoke entry points
  # (`revoke_app_tokens_for_email/2`, `revoke_app_token_by_id/2`) funnel through
  # `revoke_token/1`, so this one hook covers every revoke in the tree.
  #
  # BEST-EFFORT ON PURPOSE: a pubsub or endpoint hiccup must never make a
  # revoke fail. The DB row is the source of truth for every other consumer,
  # and a revoke that rolled back because a socket could not be notified would
  # be strictly worse than one whose notification was missed.
  defp broadcast_socket_teardown(%ApiToken{id: id}) when is_binary(id) do
    BarkparkWeb.Endpoint.broadcast(BarkparkWeb.UserSocket.disconnect_topic(id), "disconnect", %{})
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp broadcast_socket_teardown(_token), do: :ok

  @doc """
  Resolve a RAW bearer to its `%ApiToken{}` row regardless of revocation or
  expiry — `verify_token/1`'s administrative sibling (mob-w2-app-token-revoke).
  `verify_token/1` is the fail-closed auth choke point and filters
  revoked/expired rows in its WHERE clause; this lookup exists so a lifecycle
  surface (the app-token revoke route) can act on an already-dead row — an
  idempotent re-revoke must find the row it already killed. Same
  `kind == "api"` boundary: a low-trust ticket key stays invisible here too.
  """
  @spec get_api_token_by_raw(binary()) :: ApiToken.t() | nil
  def get_api_token_by_raw(raw_token) when is_binary(raw_token) do
    hash = ApiToken.hash_token(raw_token)

    ApiToken
    |> where([t], t.token_hash == ^hash)
    |> where([t], t.kind == "api")
    |> Repo.one()
  end

  @doc """
  Revoke every LIVE `app:<email>`-labelled api token THE ACTOR MAY ADMINISTER —
  the "logout everywhere" half of the app-token revoke path
  (mob-w2-app-token-revoke). Tokens carrying `admin` are excluded fail-safe: a
  label collision must never let a member-reachable proxy revoke the stored
  custody credential. Returns the revoke count (0 is a fine, idempotent
  answer); each revoke goes through `revoke_token/1`, so every one is
  individually audited.

  ## `actor` IS REQUIRED, AND THE ARITY IS THE POINT (task-ea8cae3258ea4bd3)

  This used to be `revoke_app_tokens_for_email/1` and its selection set was
  "every live app token for this email, ON THE INSTANCE". Three predicates —
  label, `kind`, not-already-revoked — and none of them tenancy. The only gate
  above it is `has_permission?(bearer, "admin")`, a flat membership test over
  `token.permissions` that reads no workspace at all, so an admin token in
  workspace A, knowing nothing but an email address, logged workspace B's users
  out of every phone session they held. Repeatable, and the route's rate
  limiter slows that without scoping it.

  The constraint lives HERE, in the query layer, and `actor` has no default —
  the unscoped form is no longer spellable. A controller-side narrowing would
  have left the next caller of this function holding the same instance-wide
  weapon, and this module is exactly where a "revoke tokens by label" helper
  gets reached for again.

  The predicate is `Tenancy.Auth.workspace_admin?/2`, never
  `Tenancy.Auth.authorize/3`: authorize/3's api_token arm is `member? AND the
  token's GLOBAL permissions[]`, so a global-admin token holding a plain
  `member` row in workspace B would PASS `authorize(tok, B, :admin)` while
  `workspace_admin?(tok, B)` denies. It is also NOT `actor.workspace_id ==
  token.workspace_id` — the predicate #12404 proposed and arpss-w8 rejected,
  because that denies an admin who legitimately holds admin seats in several
  workspaces. Same predicate, same reasoning, as `ShareLinkController`.

  A row with a NULL `workspace_id` is administrable by nobody and is skipped.
  That is fail-closed rather than a fallback, and it strands nothing in
  practice: `AppTokenController.resolve_workspace/1` 422s a mint that cannot
  resolve a workspace, so an app token with no workspace cannot be minted
  through this surface in the first place.

  Denial SHAPE, per the law in `BarkparkWeb.ShareLinkController`: the caller
  named an email, not a workspace, so there is no target to 403 about. Foreign
  rows are simply absent from the set and the count reports what actually
  happened — a 403 here would confirm that the address holds a live token
  somewhere on the instance, which is the disclosure the route already refuses
  to make.
  """
  @spec revoke_app_tokens_for_email(String.t(), ApiToken.t()) :: non_neg_integer()
  def revoke_app_tokens_for_email(email, %ApiToken{} = actor) when is_binary(email) do
    label = "app:" <> email

    ApiToken
    |> where([t], t.label == ^label)
    |> where([t], t.kind == "api")
    |> where([t], is_nil(t.revoked_at))
    |> Repo.all()
    |> Enum.reject(&("admin" in (&1.permissions || [])))
    |> Enum.filter(&administrable_by?(&1, actor))
    |> Enum.reduce(0, fn token, acc ->
      case revoke_token(token) do
        {:ok, _} -> acc + 1
        _ -> acc
      end
    end)
  end

  # The ONE tenancy predicate both app-token revoke selectors share, so the
  # by-email and by-id arms cannot drift apart. A NULL workspace_id denies:
  # `workspace_admin?/2` reaches `membership/3`, whose `is_binary(workspace_id)`
  # guard fails, and lands on that function's terminal `nil` — a deny, never a
  # raise.
  defp administrable_by?(%ApiToken{workspace_id: ws_id}, %ApiToken{} = actor) do
    TenancyAuth.workspace_admin?(actor, ws_id)
  end

  @doc """
  Every app token (`kind == "api"`) IN THE WORKSPACES `actor` ADMINISTERS,
  newest first, for the admin enumerate route. Optionally narrowed further to
  one `email` by the SAME label convention the mint uses. The workspace
  confinement is UNCONDITIONAL — it is not a property of the `:email` arm.

  ## Why enumeration had to exist (jf-backlog-apptoken-revoke-upstream)

  `revoke_app_tokens_for_email/2` matches `label == "app:" <> email` EXACTLY,
  and the mint's optional `label` REPLACES that default
  (`AppTokenController.fetch_label/2`). So a custom-labelled app token was
  unreachable by email — and with no list route and no revoke-by-id ROUTE, it
  could not be revoked at all unless the operator still held the raw string.
  A credential nobody can enumerate is a credential nobody can retire.

  Returns rows, never raw secrets: `token_hash` is the only stored form and the
  caller renders a redacted view.

  ## `actor` IS REQUIRED — the LIST door is where authorization looks like
  configuration (task-71787769f1d03e51)

  This was `list_app_tokens/1`, taking `opts` and no actor at all, while BOTH
  of its siblings on this controller — `revoke_app_tokens_for_email/2` and
  `revoke_app_token_by_id/2` — already took one. That asymmetry is the shape of
  the class, not an accident of this module: a BY-ID lookup naturally has the
  id AND the caller in hand, so scoping it reads as authorization. A LIST takes
  FILTERS, and "which filters" reads as a query question. So the missing
  argument here was the caller, and it did not look missing.

  What the unscoped form granted, over HTTP:
  `GET /v1/auth/app-tokens?email=<addr>` answered, for an ARBITRARY address,
  whether it holds a live app token anywhere on the instance — and because
  `AppTokenController.index/2` treats a supplied filter as licence to skip
  redaction, it answered with the UNREDACTED `label`, plus `workspace_id`
  (which tenants that address belongs to), `permissions`, `dataset`, `id` and
  the dates. `revoke_app_tokens_for_email/2` returns a bare count, and its
  docstring says why in as many words: "a 403 here would confirm that the
  address holds a live token somewhere on the instance, which is the disclosure
  the route already refuses to make." The route did not refuse it — one HTTP
  GET away on the same controller, this function granted exactly the
  confirmation its sibling withholds. A refusal a neighbour grants is not a
  refusal.

  Same predicate as both revoke arms — the private `administrable_by?/2` ->
  `Tenancy.Auth.workspace_admin?/2` — so the THREE selectors cannot drift
  again, and a NULL `workspace_id` row is administrable by nobody and absent
  (fail-closed, exactly as the write arms document).

  ## THE SCOPE IS BOTH ARMS NOW — THE RULING (task-aa07355fa8a53355)

  This section used to read "THE SCOPE IS THE `?email=` ARM ONLY", and said
  "the unfiltered sweep is left exactly as it was, label redaction and all",
  because the question of who may see an instance-wide inventory was open. It
  was decided, verbatim:

  > orchestrator, delegated; owner informed 2026-09-01 — RULED option 1: GET
  > /v1/auth/app-tokens is scoped to the bearer's ADMIN workspaces
  > (Tenancy.Auth.workspace_admin?/2, the same predicate both revoke arms use)
  > with labels UN-REDACTED there; an instance-wide view belongs to the
  > operator tier only, not to any `admin` permission bit.

  So the filter moved OUT of the `by_email?` branch and now runs on every
  return path. The two arms differ in WHAT they select, never in WHO may see
  it — which is the property that let the old split rot: a reader had to hold
  both branches in mind to know whether the caller was confined.

  This is not a tightening of the `?email=` arm's justification, it is the
  removal of an exception. The GATE on this route is
  `has_permission?(token, "admin")` — the same permission-only test
  `BarkparkWeb.Plugs.RequireAdmin` applies, a flat read of the token's global
  `permissions[]` with NO membership requirement at all. `workspace_admin?/2`
  is membership-and-role. So an `admin`-permissioned token holding zero
  memberships passes the gate, reaches this function, and is administrator of
  nothing: it now gets `[]` on BOTH arms, matching the write twin, which hands
  such a caller `revoked_count: 0`.

  The cost the ruling accepted, stated plainly: an operator whose admin token
  is seated in one workspace can no longer inventory the whole instance from
  this route. That reach was never earned by the `admin` permission bit — it
  was an artifact of a selector that read no workspace. An instance-wide view
  is an OPERATOR-tier question, and this module has no operator predicate to
  gate one with (see `BarkparkWeb.AppTokenController.index/2`, which names the
  row that would have to build it).

  (Do not restate this as a bypass in `Tenancy.Auth.authorize/3`. `authorize/3`
  IS membership-gated — `member?/2 and permits?/2`. Its documented, load-bearing
  divergence from `workspace_admin?/2` is a different thing: both read
  membership, and they differ on whether the GRANT comes from the token's
  global `permissions[]` or from the membership ROLE, which is why a
  global-admin token seated in workspace B as a plain `member` passes
  `authorize(tok, B, :admin)` and correctly fails `workspace_admin?(tok, B)`.
  The permission-only reach on this route comes from the ROUTE'S OWN gate, not
  from `authorize/3`.)

  Denial SHAPE, per the law in `BarkparkWeb.ShareLinkController`: the caller
  named an email, not a workspace, so there is no target to 403 about. Foreign
  rows are simply ABSENT, and the 200 response for a provisioned foreign
  address is byte-identical to the 200 for an address that exists nowhere — a
  status-code difference would rebuild the oracle this closes.

  WHAT THAT GUARANTEE IS NOT, stated so nobody reads it as more than it is: the
  denial is byte-identical in the RESPONSE, not in the WORK. Because the
  predicate runs after `Repo.all`, a provisioned foreign address loads one row
  and costs one `workspace_admin?/2` membership query before dropping it, while
  an address that exists nowhere costs none. Same bytes, different timing — a
  noisy residue, and the SAME shape `revoke_app_tokens_for_email/2` already
  has, inherited from the twin rather than introduced here. Closing it means
  joining the workspace set into the WHERE clause, which is the same change a
  paginator would force (see the comment on the filter below); until someone
  needs constant time, this is where it lives.
  """
  @spec list_app_tokens(ApiToken.t(), keyword()) :: [ApiToken.t()]
  def list_app_tokens(%ApiToken{} = actor, opts) when is_list(opts) do
    query =
      ApiToken
      |> where([t], t.kind == "api")

    # `:email` is a FILTER and nothing more. It used to double as the scope
    # trigger — a `by_email?` boolean that decided both what was selected and
    # whether the caller was confined — and that coupling was the defect
    # `task-aa07355fa8a53355` closed: the unfiltered branch fell through
    # unscoped. There is now ONE return path and it is filtered on it, so no
    # later edit can add a third arm that forgets.
    query =
      case Keyword.get(opts, :email) do
        email when is_binary(email) and email != "" ->
          where(query, [t], t.label == ^("app:" <> email))

        _ ->
          query
      end

    query
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
    # Post-`Repo.all` filtering, matching `revoke_app_tokens_for_email/2`
    # exactly so the twin selectors read the same. IF A LIMIT IS EVER ADDED,
    # IT MUST NOT GO IN THE QUERY ABOVE: the database would take 50 rows
    # instance-wide and this filter would then hand back the 3 of them the
    # caller administers, so a full page of the caller's own tokens would look
    # like a near-empty account. A paginator has to push the workspace set
    # into the WHERE clause first, which also removes this hop.
    |> Enum.filter(&administrable_by?(&1, actor))
  end

  @doc """
  Revoke ONE app token by its row id — the escape hatch for a token whose label
  no longer matches the email convention.

  Scoped to `kind == "api"`, the same boundary `get_api_token_by_raw/1` keeps: a
  non-app row answers `{:error, :not_found}` rather than being revoked through
  this door, so the app-token surface cannot reach a share/ticket credential.

  ## Admin-permissioned tokens ARE revocable here, unlike the email path

  `revoke_app_tokens_for_email/2` rejects `admin` rows, and the controller's
  by-raw arm 422s them. That rule exists for a stated reason — a custody
  credential "cannot be killed by a label collision or a smuggled body". An
  explicit row id is neither: it names one row, chosen by an admin bearer, with
  no collision surface. Carrying the rejection over would leave the WORST case
  of this gap — a custom-labelled admin app token — permanently unrevocable,
  which is the defect, not a protection against it.

  ## `actor` IS REQUIRED — this arm is the by-email hole's twin
  (task-ea8cae3258ea4bd3)

  This was `revoke_app_token_by_id/1`: a bare `Repo.get/2` under the same
  permission-only `has_permission?(bearer, "admin")` gate, i.e. any admin token
  in any workspace could revoke ANY app token on the instance — and unlike the
  email arm it does not even exclude `admin`-permissioned rows, by the
  deliberate reasoning above. `GET /v1/auth/app-tokens` enumerates every id
  instance-wide, so scoping only the email arm would have left a two-request
  bypass through this same controller. Both selectors take the constraint, from
  the same private predicate, so neither can be tightened without the other.

  Denial SHAPE, per the law in `BarkparkWeb.ShareLinkController`: an opaque row
  id belonging to a foreign tenant answers `{:error, :not_found}` — the SAME
  return value, reaching the SAME emitter, as a missing row and a non-castable
  id. Not a 403: distinguishing "exists but not yours" from "does not exist"
  turns a revoke route into an existence oracle over every credential on the
  instance.
  """
  @spec revoke_app_token_by_id(binary(), ApiToken.t()) :: {:ok, ApiToken.t()} | {:error, atom()}
  def revoke_app_token_by_id(token_id, %ApiToken{} = actor) when is_binary(token_id) do
    # Same UUID cast guard as revoke_token/1: the id column is :binary_id, so a
    # non-UUID would raise Ecto.CastError -> 500 instead of a clean not_found.
    case Repo.uuid_or_nil(token_id) do
      nil ->
        {:error, :not_found}

      uuid ->
        case Repo.get(ApiToken, uuid) do
          %ApiToken{kind: "api"} = token ->
            if administrable_by?(token, actor),
              do: revoke_token(token),
              else: {:error, :not_found}

          _ ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Mint an API token. When `workspace_id` is given (the tenancy-aware path),
  the token is bound to that workspace AND a `Barkpark.Tenancy.Membership`
  row is created in the same transaction — role derived from permissions
  ("admin" perm → "admin", else "member"). The token + membership commit
  atomically, so a failed membership insert rolls the token back.

  When `workspace_id` is `nil` the token falls back to the seeded Default
  Workspace if one exists (the backfill's target); when no Default Workspace
  exists the token is created un-bound (no membership) for back-compat with
  pre-tenancy callers and the existing test suite.
  """
  def create_token(raw_token, label, dataset, permissions, workspace_id \\ nil) do
    ws_id = workspace_id || default_workspace_id()

    token_attrs = %{
      token_hash: ApiToken.hash_token(raw_token),
      label: label,
      dataset: dataset,
      permissions: permissions,
      workspace_id: ws_id
    }

    if is_nil(ws_id) do
      %ApiToken{}
      |> ApiToken.changeset(token_attrs)
      |> Repo.insert()
    else
      insert_token_with_membership(token_attrs, ws_id, permissions)
    end
  end

  # ── Connectors: the per-install chat token (D36/D48) ───────────────────────

  # THE ONLY PLACE the connector chat permission set is written. HARDCODED, in
  # ONE place, on purpose.
  #
  # `create_token/5` above does NOT hardcode anything — it mints whatever
  # permission list it is handed. Before this extraction the `["chat"]` literal
  # lived in `ChatTokenController`, which made the HTTP endpoint safe and left
  # every IN-PROCESS caller (a LiveView, a Mix task, a plugin) one keystroke from
  # `["admin"]` — and `TenancyAuth.role_for_permissions/1` would then escalate the
  # minted token's own membership row to `admin`: a token that can mint more
  # tokens. Studio's Connect button is exactly such an in-process caller.
  #
  # Consequences of ANY change to this list, both proven in
  # `chat_token_controller_test.exs`:
  #   * adding "admin" → `RequireChatAccess.chat_scope/1` checks `admin` FIRST →
  #     `:global` → `StudioChat` stamps `owner_workspace_id = NULL` → every bridge
  #     session becomes TENANT-LESS and any other `:global` caller reads them all.
  #   * that suite reds with `expected owner_workspace_id=…, got nil` and a
  #     literal `CROSS-TENANT LEAK` assertion. It now protects BOTH callers.
  @chat_permissions ["chat"]

  @doc """
  The permission set every connector chat token carries — `#{inspect(["chat"])}`,
  and nothing else. Exposed so callers (the controller's 201 body, the LiveView)
  can ECHO it without re-declaring it.
  """
  @spec chat_permissions() :: [String.t()]
  def chat_permissions, do: @chat_permissions

  @doc """
  Mint a workspace-bound `chat` API token (Connectors D36/D48) — the ONE mint
  path for a connector install's credential, shared by the HTTP endpoint
  (`ChatTokenController`) and the in-process Studio connect loop.

  The raw token is returned ONCE (only its SHA-256 hash is persisted) and must
  never be logged, never assigned to a LiveView socket, and never put in a URL.
  It rides the connect POST body over loopback to the bridge, which seals it into
  `connector_installs.chat_token_ref`.

  `label` is load-bearing for CONNECTORS: `Barkpark.Connectors.Catalog.token_label/2`
  produces `connector:<provider>:<install_key>`, and that label is the ONLY handle
  DISCONNECT has on the token — the bridge holds no token id and the sealed
  `chat_token_ref` is never opened by Elixir.

  Fail-closed on a missing workspace: a `chat` token with a NULL `workspace_id`
  is precisely the tenant-less operator credential this whole wave exists to
  delete, so it is an error, never a Default-workspace fallback.
  """
  @spec create_chat_token(String.t(), String.t(), binary()) ::
          {:ok, binary(), ApiToken.t()} | {:error, :workspace_required | term()}
  def create_chat_token(label, dataset, workspace_id)
      when is_binary(label) and is_binary(dataset) and is_binary(workspace_id) and
             workspace_id != "" do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    case create_token(raw, label, dataset, @chat_permissions, workspace_id) do
      {:ok, %ApiToken{} = token} -> {:ok, raw, token}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_chat_token(_label, _dataset, _workspace_id), do: {:error, :workspace_required}

  @doc """
  Every LIVE (non-revoked) api_token in `workspace_id` carrying `label` — the
  disconnect side of `create_chat_token/3`.

  Scoped to the workspace on purpose: two workspaces could each connect a bot and
  (pathologically) land the same `install_key`, and one tenant must never revoke
  another's credential.
  """
  @spec live_tokens_by_label(binary(), String.t()) :: [ApiToken.t()]
  def live_tokens_by_label(workspace_id, label)
      when is_binary(workspace_id) and is_binary(label) do
    case Repo.uuid_or_nil(workspace_id) do
      nil ->
        []

      uuid ->
        ApiToken
        |> where([t], t.workspace_id == ^uuid)
        |> where([t], t.label == ^label)
        |> where([t], is_nil(t.revoked_at))
        |> Repo.all()
    end
  end

  def live_tokens_by_label(_workspace_id, _label), do: []

  @doc """
  Relabel an api_token in place (Connectors D179) — a plain changeset update on
  the `label` column, nothing else touched.

  The Add-to-Slack flow (D62/D63) mints its workspace chat token BEFORE the OAuth
  callback learns the team_id, so it is labelled `connector:slack:oauth`. Once the
  callback lands the install, `Barkpark.Connectors.Catalog.token_label/2` gives the
  canonical `connector:slack:<install_key>`, and this reconciles the token to it so
  DISCONNECT can revoke it by the same single label as every other provider.

  A RELABEL, never a revoke: the credential the live install is authenticating
  with must keep working. `label` has no uniqueness constraint, so there is no
  conflict path; relabelling to the current label is a clean no-op update.
  """
  @spec relabel_token(ApiToken.t(), String.t()) ::
          {:ok, ApiToken.t()} | {:error, Ecto.Changeset.t()}
  def relabel_token(%ApiToken{} = token, new_label) when is_binary(new_label) do
    token
    |> Ecto.Changeset.change(label: new_label)
    |> Repo.update()
  end

  defp insert_token_with_membership(token_attrs, ws_id, permissions) do
    role = TenancyAuth.role_for_permissions(permissions)

    Repo.transaction(fn ->
      with {:ok, token} <- %ApiToken{} |> ApiToken.changeset(token_attrs) |> Repo.insert(),
           {:ok, _membership} <- TenancyAuth.create_membership(ws_id, token.id, role) do
        token
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp default_workspace_id do
    case Tenancy.get_default_workspace() do
      nil -> nil
      ws -> ws.id
    end
  end

  def list_tokens(dataset) do
    ApiToken
    |> where([t], t.dataset == ^dataset)
    |> Repo.all()
  end

  # ── PAT fast-follow: self-service Personal Access Tokens ───────────────

  # PAT TTL policy: default 30 days, hard-capped at 1 year. A PAT is a
  # longer-lived self-service credential than the dev token, so it always
  # carries a finite horizon (mirrors cloud/'s bounded expiry).
  @pat_default_ttl 30 * 24 * 3600
  @pat_max_ttl 365 * 24 * 3600
  @pat_token_prefix "bppat_"

  # Roles that may mint an ELEVATED (write-tier) token. A `member` may only
  # mint a read token (Coolify's ApiTokenPolicy: only admin/owner mint elevated
  # tokens — app/Policies/ApiTokenPolicy.php).
  #
  # THE CEILING IS `write`, NEVER `admin` (ruling 2026-09-02; orchestrator
  # ruling A, delegated, owner informed 2026-09-01). WHY: a token's `"admin"`
  # permission is the FLAT, INSTANCE-WIDE bit `BarkparkWeb.Plugs.RequireAdmin`
  # reads — `Auth.has_permission?(token, "admin")`, with no workspace anywhere
  # in the check. It is not, and never was, a workspace-role artefact. Deriving
  # it from a workspace role (which the HTTP self-mint began doing in #14245)
  # handed it to whoever happened to be `owner` of SOME workspace — and a
  # workspace creator is always the owner of the one they just created. Such a
  # token cleared every `[:api, :require_admin]` route on the INSTANCE: run
  # secrets in cleartext (`GET /v1/secrets/:name`), `POST /v1/admin/self-update`,
  # `/v1/admin/rollback`, secrets write/delete, `/v1/plugins/settings` CRUD,
  # `POST /v1/shares`, bundle import.
  #
  # Workspace-scoped administrative authority lives on the MEMBERSHIP ROLE and
  # is read by `Tenancy.Auth.workspace_admin?/2` — that axis is untouched by
  # this cap, and so is `RequireAdmin`, which stays the flat instance tier by
  # design (docs/auth.md, "Hierarchy — permission ⟂ membership"). The cap is at
  # MINT, not at CHECK: pre-existing `["read", "write", "admin"]` rows (the
  # instance operator's own credential, the `demo` seed's dev token) keep
  # working untouched — no migration, no revoke, no backfill.
  @pat_admin_roles ~w(owner admin)
  @pat_allowed_member_permissions ~w(read)
  @pat_allowed_elevated_permissions ~w(read write)

  @doc """
  Mint a self-service Personal Access Token, ROLE-GATED on the minting admin's
  workspace role. The `:role` opt is the minter's workspace role (the Studio
  pane passes the current admin's role); a `member` may mint only `["read"]`,
  an `owner`/`admin` may mint up to `["read", "write"]` — never `"admin"`. A
  request to mint above the role returns `{:error, :forbidden}` (the server is
  the authority — never trust a client-supplied permission set).

  `"admin"` is UNMINTABLE here at every role (ruling 2026-09-02): it is the
  flat, instance-wide permission `BarkparkWeb.Plugs.RequireAdmin` reads with no
  workspace in the check, so it can never be legitimately derived from a
  workspace membership role. `create_personal_access_token(_, ["admin"],
  role: "owner")` is `{:error, :forbidden}`. See
  `@pat_allowed_elevated_permissions` for the full rationale.

  Unlike `create_token/5`, this sets `name` (user-facing) + `created_by` (audit)
  + a bounded `expires_at`, and prefixes the raw token with `#{@pat_token_prefix}`
  for leak-scanner recognisability. Returns `{:ok, {raw_token, %ApiToken{}}}` —
  the raw token is shown ONCE and never recoverable after.

  `opts`: `:role` (default `"member"`), `:workspace_id`, `:dataset`
  (default `"production"`), `:created_by`, `:ttl` (seconds; `nil` = never;
  default 30 days; capped at 1 year), `:owner_user_id` (bind the token to a
  USER identity — set ONLY by the session-gated self-mint, hard-bound to the
  authenticated caller; never a client-supplied value).

  ## `:workspace_id` — NO implicit Default-Workspace fallback (SECURITY)

  When `:workspace_id` is omitted (or `nil`), the token is minted
  WORKSPACE-LESS — `insert_token_with_membership/3` is skipped entirely and no
  `Tenancy.Membership` row is ever created. There used to be an unconditional
  `|| default_workspace_id()` fallback here; it let any caller that forgot to
  resolve a real workspace (the self-service mint was the one that did) hand
  the minted token a membership in the seeded Default Workspace with ZERO
  relationship check. The caller MUST resolve and pass its own real
  `:workspace_id` to get a workspace-bound token — there is no default to fall
  into. (Every other caller already passes `:workspace_id` explicitly; grep
  `create_personal_access_token` before relying on this.)
  """
  @spec create_personal_access_token(binary(), [binary()], keyword()) ::
          {:ok, {binary(), ApiToken.t()}} | {:error, :forbidden | Ecto.Changeset.t()}
  def create_personal_access_token(name, permissions, opts \\ [])
      when is_binary(name) and is_list(permissions) do
    role = Keyword.get(opts, :role, "member")

    with :ok <- authorize_pat_permissions(role, permissions) do
      raw = @pat_token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      ws_id = Keyword.get(opts, :workspace_id)

      expires_at =
        case Keyword.get(opts, :ttl, @pat_default_ttl) do
          nil ->
            nil

          ttl ->
            DateTime.utc_now()
            |> DateTime.add(clamp_pat_ttl(ttl))
            |> DateTime.truncate(:second)
        end

      token_attrs = %{
        token_hash: ApiToken.hash_token(raw),
        name: name,
        label: name,
        dataset: Keyword.get(opts, :dataset, "production"),
        permissions: permissions,
        workspace_id: ws_id,
        created_by: Keyword.get(opts, :created_by),
        expires_at: expires_at,
        # ag-bp-user-identity-auth: optional owner USER binding. NULL for a
        # machine PAT; set only by the session-gated self-mint, which HARD-BINDS
        # it to current_user.id (never a caller-supplied param).
        owner_user_id: Keyword.get(opts, :owner_user_id)
      }

      result =
        if is_nil(ws_id) do
          %ApiToken{} |> ApiToken.changeset(token_attrs) |> Repo.insert()
        else
          insert_token_with_membership(token_attrs, ws_id, permissions)
        end

      case result do
        {:ok, token} -> {:ok, {raw, token}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  # Best-effort, throttled `last_used_at` stamp for a verified token. Called from
  # RequireToken so operators can spot dead tokens. Once/minute resolution — a
  # chatty token does not trigger a write per request. Errors are swallowed:
  # stamping liveness must never break auth.
  @pat_last_used_throttle_seconds 60

  @doc false
  @spec touch_last_used(ApiToken.t()) :: :ok
  def touch_last_used(%ApiToken{id: id, last_used_at: prev}) do
    now = DateTime.utc_now()

    stale? =
      is_nil(prev) or DateTime.diff(now, prev, :second) > @pat_last_used_throttle_seconds

    if stale? do
      stamp = DateTime.truncate(now, :microsecond)

      try do
        ApiToken
        |> where([t], t.id == ^id)
        |> Repo.update_all(set: [last_used_at: stamp])
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  def touch_last_used(_), do: :ok

  @doc """
  The MAXIMUM PAT permission tier `role` may mint — the same
  `@pat_admin_roles` / allowed-permissions split `authorize_pat_permissions/2`
  gates on, exposed so a caller (the session-gated self-mint) can DERIVE the
  permission set from the caller's REAL workspace role instead of a hardcoded
  literal, without duplicating the role/permission mapping. `owner`/`admin`
  get `#{inspect(@pat_allowed_elevated_permissions)}`; every other role
  (including `nil` — no membership resolved) gets
  `#{inspect(@pat_allowed_member_permissions)}`, mirroring
  `@pat_allowed_member_permissions`'s deliberate member cap.

  NO ROLE REACHES `"admin"` (ruling 2026-09-02). A workspace role is a
  WORKSPACE fact; the `"admin"` permission is the INSTANCE-wide bit
  `RequireAdmin` reads workspace-blind. Mapping one onto the other is the
  escalation this cap closes — an owner of any workspace, including one they
  created a second ago, otherwise walked out of this function holding the
  instance. Workspace-admin authority is `Tenancy.Auth.workspace_admin?/2`
  (the membership role), not a token permission.
  """
  @spec max_pat_permissions_for_role(String.t() | nil) :: [String.t()]
  def max_pat_permissions_for_role(role) when role in @pat_admin_roles,
    do: @pat_allowed_elevated_permissions

  def max_pat_permissions_for_role(_role), do: @pat_allowed_member_permissions

  # Gate the requested permission set against the minter's workspace role. The
  # elevated set tops out at `write`, so an explicitly-requested `["admin"]` is
  # `{:error, :forbidden}` at EVERY role — this is the same allowed set
  # `max_pat_permissions_for_role/1` publishes, never a second opinion.
  defp authorize_pat_permissions(role, permissions) do
    allowed =
      if role in @pat_admin_roles,
        do: @pat_allowed_elevated_permissions,
        else: @pat_allowed_member_permissions

    if Enum.all?(permissions, &(&1 in allowed)) and permissions != [] do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp clamp_pat_ttl(ttl) when is_integer(ttl) and ttl > 0, do: min(ttl, @pat_max_ttl)
  defp clamp_pat_ttl(_), do: @pat_default_ttl

  # ── P5: scoped-share EDIT tokens ───────────────────────────────────────

  @doc """
  Mint a SCOPED, REVOCABLE edit token for a `(workspace, project, dataset)`
  scope that is currently `:edit`-shared for the requested `surfaces`
  (subset of `#{inspect(@editable_surfaces)}`).

  The token is deliberately INERT everywhere except that exact shared scope:

    * its permissions are OPAQUE (`"share-edit-<surface>"`) — NOT `"write"` /
      `"admin"` — so it satisfies no global perm tier and cannot drive the flat
      mutate route or any membership-gated route;
    * it gets NO `Membership` row (a plain `Repo.insert`, not
      `insert_token_with_membership/3`), so every normal scoped route denies it;
    * `share_scope` byte-binds it to one `"ws/proj/dataset"`.

  Defense-in-depth: refuses to mint unless the scope is live-`:edit`-shared for
  every requested surface RIGHT NOW. `opts`: `:ttl` (seconds, default 7 days,
  capped at 1 year), `:label`. Returns `{:ok, {raw_token, %ApiToken{}}}` — the
  raw token is shown ONCE and never recoverable after.
  """
  @spec create_share_token(binary(), binary(), binary(), [binary() | atom()], keyword()) ::
          {:ok, {binary(), ApiToken.t()}} | {:error, term()}
  def create_share_token(ws_slug, proj_slug, dataset, surfaces, opts \\ [])

  def create_share_token(ws_slug, proj_slug, dataset, surfaces, opts)
      when is_binary(ws_slug) and is_binary(proj_slug) and is_binary(dataset) and
             is_list(surfaces) do
    surfaces = surfaces |> Enum.map(&to_string/1) |> Enum.uniq()

    with :ok <- validate_edit_share(ws_slug, proj_slug, dataset, surfaces),
         %Tenancy.Workspace{} = ws <-
           Tenancy.get_workspace_by_slug(ws_slug) || {:error, :unknown_scope},
         %Tenancy.Project{} <-
           Tenancy.get_project(ws_slug, proj_slug) || {:error, :unknown_scope} do
      raw = "bpshare_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        token_hash: ApiToken.hash_token(raw),
        label: opts[:label] || "share-edit #{ws_slug}/#{proj_slug}/#{dataset}",
        dataset: dataset,
        # permissions are NON-OVERRIDABLE — derived only from validated surfaces,
        # never caller-supplied (a caller could otherwise inject "admin").
        permissions: Enum.map(surfaces, &"share-edit-#{&1}"),
        workspace_id: ws.id,
        share_scope: "#{ws_slug}/#{proj_slug}/#{dataset}",
        expires_at: DateTime.add(now, clamp_ttl(opts[:ttl]))
      }

      case %ApiToken{} |> ApiToken.changeset(attrs) |> Repo.insert() do
        {:ok, token} -> {:ok, {raw, token}}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def create_share_token(_ws, _proj, _ds, _surfaces, _opts), do: {:error, :invalid_args}

  @doc """
  Hard-revoke (stamp `revoked_at`) every share token bound to the exact
  `(ws, proj, dataset)` scope. Called from `Sharing.remove_share/3` so deleting
  a share also kills its edit tokens. Returns `{:ok, count_revoked}`.
  """
  @spec revoke_share_tokens(binary(), binary(), binary()) :: {:ok, non_neg_integer()}
  def revoke_share_tokens(ws_slug, proj_slug, dataset)
      when is_binary(ws_slug) and is_binary(proj_slug) and is_binary(dataset) do
    scope = "#{ws_slug}/#{proj_slug}/#{dataset}"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      ApiToken
      |> where([t], t.share_scope == ^scope and is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: now])

    {:ok, count}
  end

  @doc """
  List share tokens (those carrying a `share_scope`), newest first, optionally
  filtered to one scope. Returns the rows — callers MUST NOT expose `token_hash`.
  """
  @spec list_share_tokens(binary() | nil) :: [ApiToken.t()]
  def list_share_tokens(scope \\ nil) do
    query =
      ApiToken
      |> where([t], not is_nil(t.share_scope))
      |> order_by([t], desc: t.inserted_at)

    query = if scope, do: where(query, [t], t.share_scope == ^scope), else: query
    Repo.all(query)
  end

  defp validate_edit_share(ws, proj, dataset, surfaces) do
    cond do
      surfaces == [] ->
        {:error, :no_surfaces}

      Enum.any?(surfaces, &(&1 not in @editable_surfaces)) ->
        {:error, :unsupported_surface}

      Sharing.access_for(ws, proj, dataset) != :edit ->
        {:error, :not_edit_shared}

      not Enum.all?(surfaces, &Sharing.shared?(ws, proj, dataset, &1)) ->
        {:error, :surface_not_shared}

      true ->
        :ok
    end
  end

  defp clamp_ttl(nil), do: @share_token_default_ttl
  defp clamp_ttl(ttl) when is_integer(ttl) and ttl > 0, do: min(ttl, @share_token_max_ttl)
  defp clamp_ttl(_), do: @share_token_default_ttl

  # ── scc-w12: Claude-chat loopback session tokens (charter D63) ──────────

  # D63 session-credential TTL policy: this token exists only to give ONE
  # Studio Claude-chat subprocess hands over Barkpark (`bp mcp serve`), so its
  # horizon is HOURS, never days — deliberately a NEW constant pair
  # (`clamp_ttl/1`'s share floor is 7 DAYS; reusing it would leave a crashed
  # session's credential live for a week). Revocation in the chat Session's
  # terminate clauses is the primary teardown; this expiry is the crash
  # backstop.
  @claude_session_default_ttl 4 * 3600
  @claude_session_max_ttl 24 * 3600
  # Curated REAL permissions — the task/doc/search verbs the loopback needs
  # ride the ordinary `read`/`write` tiers; `chat` lets the loopback reach
  # `/v1/chat` (herd-s4). The mint is workspace-bound (below), so
  # `RequireChatAccess` resolves it to `{:workspace, ws}` — fail-closed tenant
  # inheritance by construction, never instance-global. NEVER `share-edit-*`
  # (opaque share perms), NEVER `admin`, NEVER caller-supplied.
  @claude_session_permissions ~w(read write chat)
  @claude_session_token_prefix "bpcs_"

  @doc """
  Mint the SHORT-LIVED ApiToken a Studio Claude-chat session injects into its
  loopback `bp mcp serve` subprocess (charter D63, scc-w12-mcp-loopback).

  Modeled on `create_share_token/5`'s insert block: `kind` stays `"api"` (so
  `verify_token/1` accepts it — an `Access.mint/2` grant token is PROVEN
  rejected there), permissions are the curated
  `#{inspect(@claude_session_permissions)}` (never `admin`, never
  `share-edit-*`, never caller-supplied — `opts` deliberately has no
  `:permissions` key), the label names the session (`claude-session <sid>`),
  and the row is workspace-scoped with a plain `Repo.insert` — NO membership
  row, mirroring the share token's deliberately inert posture on
  membership-gated routes.

  AUTHORIZED UP FRONT: `minter` — the chat admin's `%ApiToken{}` / `%User{}`
  principal — must pass `Tenancy.Auth.authorize/3` for `:write` on the target
  workspace, so the minted token can never exceed the human's own rights. A
  nil, unknown, or under-privileged minter refuses (`{:error, :forbidden}`),
  fail-closed.

  TTL: `opts[:ttl]` seconds, default #{div(@claude_session_default_ttl, 3600)}h,
  hard-capped at #{div(@claude_session_max_ttl, 3600)}h. Expiry is the crash
  backstop; `revoke_token/1` (idempotent) in the Session's terminate clauses
  is the primary teardown.

  `opts`: `:ttl`, `:workspace_id` (default: the minter token's workspace,
  then the Default workspace), `:dataset` (default `"production"`). Returns
  `{:ok, {raw_token, %ApiToken{}}}` — the raw token is written ONLY into the
  session's temp mcp-config env block, never logged, never recoverable.
  """
  @spec create_claude_session_token(term(), binary(), keyword()) ::
          {:ok, {binary(), ApiToken.t()}} | {:error, term()}
  def create_claude_session_token(minter, session_id, opts \\ [])

  def create_claude_session_token(minter, session_id, opts) when is_binary(session_id) do
    ws_id =
      Keyword.get(opts, :workspace_id) || minter_workspace_id(minter) || default_workspace_id()

    with ws_id when is_binary(ws_id) <- ws_id || {:error, :no_workspace},
         :ok <- TenancyAuth.authorize(minter, ws_id, :write) do
      raw =
        @claude_session_token_prefix <>
          Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        token_hash: ApiToken.hash_token(raw),
        label: "claude-session #{session_id}",
        dataset: Keyword.get(opts, :dataset, "production"),
        # NON-OVERRIDABLE curated permissions — a caller can never inject
        # "admin" (or anything else) here.
        permissions: @claude_session_permissions,
        workspace_id: ws_id,
        expires_at: DateTime.add(now, clamp_claude_session_ttl(opts[:ttl]))
      }

      case %ApiToken{} |> ApiToken.changeset(attrs) |> Repo.insert() do
        {:ok, token} -> {:ok, {raw, token}}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def create_claude_session_token(_minter, _session_id, _opts), do: {:error, :invalid_args}

  defp minter_workspace_id(%ApiToken{workspace_id: ws_id}), do: ws_id
  defp minter_workspace_id(_), do: nil

  defp clamp_claude_session_ttl(ttl) when is_integer(ttl) and ttl > 0,
    do: min(ttl, @claude_session_max_ttl)

  defp clamp_claude_session_ttl(_), do: @claude_session_default_ttl

  # `token.permissions || []` keeps this total: a nil permissions array (e.g. a
  # NULL DB column) denies (false) instead of raising `ArgumentError` on
  # `permission in nil`. nil permissions → deny, never raise.
  def has_permission?(token, permission) do
    permission in (token.permissions || [])
  end
end
