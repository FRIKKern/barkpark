defmodule BarkparkWeb.Plugs.OptionalToken do
  @moduledoc """
  Soft-auth plug. Assigns `:api_token` when a valid `Authorization: Bearer …`
  header is present; otherwise passes the conn through untouched.

  Never halts on a missing or invalid credential. TWO exceptions, both opt-in
  or narrowly predicated:

  1. (wave-2 seal, foreign-scope-share-token-flat-read) a scope-bound SHARE
     token (`share_scope` set) presented on a FLAT route is refused 403 —
     soft-passing it through as authed is exactly the escape that let a
     foreign-scoped share-edit token read Default-scoped drafts on
     `GET /v1/data/doc/...` (authed? true → the anonymous drafts clamp was
     skipped, while the flat route's scope came from `AssignDefaultScope`, not
     the token's binding). Predicate + rationale live in
     `BarkparkWeb.Plugs.RequireToken.share_token_off_surface?/2` — the share
     token keeps working on its own scoped share routes.

  2. `strict_on_presented: true` (opt-in, see below).

  ## `strict_on_presented: true` — refuse a PRESENTED-but-unverifiable bearer

  Default (`strict_on_presented: false`, i.e. every mount that does not pass
  the opt) is unchanged: a bearer that fails `Auth.verify_token/1` is dropped
  and the conn continues as anonymous. `test/barkpark_web/plugs/optional_token_test.exs`
  pins that default contract.

  With the opt, ONE input changes shape: a request that PRESENTS
  `Authorization: Bearer <x>` where `<x>` does not verify is refused with the
  same indistinguishable 401 `RequireToken` emits. Nothing else moves:

    * NO `Authorization` header at all → untouched, anonymous. The public /
      browser read tier is a supported product surface and sends no header, so
      it cannot be reached by this arm. This is NOT a blanket 401.
    * a non-`Bearer` scheme (`Preview …`) → untouched, as before.
    * a VALID bearer → assigned, as before. A public-read token is a VALID
      token — `verify_token/1` succeeds on it — so the four public-read
      credentials baked into shipped site JS keep working byte-for-byte. The
      arm is scoped to *unverifiable* bearers, which is precisely the
      distinction that separates it from the blanket-401 overreach.

  Why it exists (task-46872cadcfc50c5f): on the flat `/v1/data` read pipeline,
  `Auth.verify_token/1` folds revoked/expired/unknown into one
  `{:error, :unauthorized}`; the default soft-pass then swallowed it, so
  `DeriveWorkspaceFromToken` never fired and `AssignDefaultScope` stamped the
  seeded **Default** workspace. A caller holding a decayed workspace-B token
  got a 200 carrying ANOTHER TENANT's published rows with no signal — a tenant
  swap by credential decay. Integrity/mislead, not confidentiality: the
  downgrade only ever NARROWS scope to the anonymous published tier, it never
  widens it. `test/barkpark_web/optional_token_silent_downgrade_test.exs`
  is the regression.

  The refusal deliberately does NOT differentiate revoked from expired from
  unknown — existence-hiding in `Auth.verify_token/1`'s fold is a documented
  decision and stays untouched. One 401, three causes.

  Mounted with the opt on the flat `/v1/data` READ pipeline only
  (`:api_grant_read` in `BarkparkWeb.Router`). Because `:api` already ran this
  plug for those routes, the strict arm no-ops when `:api_token` is already
  assigned — the extra `verify_token/1` is paid only on the failing path.

  For endpoints that must reject anonymous callers, use
  `BarkparkWeb.Plugs.RequireToken` instead.
  """

  import Plug.Conn
  alias Barkpark.Auth
  alias BarkparkWeb.Plugs.RequireToken

  def init(opts), do: opts

  def call(conn, opts) do
    strict? = strict_on_presented?(opts)

    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw_token] ->
        resolve_bearer(conn, raw_token, strict?)

      # No bearer presented (missing header, or a non-Bearer scheme): anonymous
      # is a supported surface on EVERY mount, strict arm included.
      _ ->
        conn
    end
  end

  defp resolve_bearer(conn, raw_token, strict?) do
    # The strict arm re-mounts on a pipeline where `:api` already resolved this
    # same bearer. Nothing left to decide when it verified.
    if strict? and Map.has_key?(conn.assigns, :api_token) do
      conn
    else
      case Auth.verify_token(raw_token) do
        {:ok, token} ->
          if RequireToken.share_token_off_surface?(conn, token) do
            RequireToken.deny(conn, {:error, :forbidden})
          else
            assign(conn, :api_token, token)
          end

        # Presented but unverifiable — revoked, expired, or never existed. The
        # fold is deliberate; do not differentiate the three in the response.
        _ when strict? ->
          RequireToken.deny(conn, {:error, :unauthorized})

        _ ->
          conn
      end
    end
  end

  defp strict_on_presented?(opts) when is_list(opts),
    do: Keyword.get(opts, :strict_on_presented, false)

  defp strict_on_presented?(%{} = opts), do: Map.get(opts, :strict_on_presented, false)
  defp strict_on_presented?(_), do: false
end
