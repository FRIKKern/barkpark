defmodule Barkpark.Tenancy.Auth do
  @moduledoc """
  Authorization primitives for the hard Workspace tenant boundary.

  A principal is bound to a Workspace by a `Barkpark.Tenancy.Membership` row.
  There are TWO kinds of principal, discriminated by the membership's
  `principal_type` column, and BOTH flow through the same `authorize/3`
  chokepoint:

    * **API token** (`principal_type: "api_token"`) — a token bound to a
      workspace. Authorization combines membership AND the token's
      `permissions` array (`:read`/`:write`/`:admin`).
    * **User** (`principal_type: "user"`) — a logged-in account (core-auth:
      accounts/sessions/MFA, and the principal that SSO/SCIM mint). A user
      carries no `permissions` array; its GRANT is its membership ROLE, so
      authorization combines membership AND the role.

  `authorize/3` is the single entry point the router and controllers call.
  Cross-tenant isolation is guaranteed by the membership lookup being keyed on
  `(principal_id, workspace_id, principal_type)` — a principal with no
  membership row in a workspace can never be authorized there.

  ## Fail closed, not fail crash (the READ predicates)

  The read predicates — `membership/2`, `membership_role/2`, `member?/2`,
  `workspace_admin?/2` and `authorize/3` — DENY on malformed or absent input
  instead of raising. Until this seam landed, the prose here claimed a totality
  the module did not have: `membership/2` had no terminal clause, so a `nil` or
  non-binary in EITHER id position raised `FunctionClauseError`, and any
  non-castable binary (the empty string included) raised `Ecto.Query.CastError`
  from the `:binary_id` comparison inside `Repo.one`. Note the module name:
  `Ecto.Query.CastError`, NOT `Ecto.CastError` — the latter fires zero times on
  this path, so a test asserting it would be vacuous.

  The HTTP truth those raises produced, stated plainly because it corrects the
  original finding: `Ecto.Query.CastError` is mapped to **400** by
  `phoenix_ecto`, so the non-castable-STRING class was a 400 `internal_error`;
  only the `nil` / non-binary `FunctionClauseError` class fell through to
  Plug's `Any` fallback and was a **500**. Both are now a clean denial.
  (Comments elsewhere in this repo phrase this class as "CastError -> 500"; on
  this path that phrasing is wrong on both the module and the status.)

  Do NOT read the seam as "a malformed id never reaches the query".
  `Ecto.UUID.cast/1` accepts any 16-byte binary as raw UUID bytes — a 16-byte
  input is normalised into a well-formed synthetic UUID, DOES reach the query,
  and denies by matching no row. That admits one real WIDENING, recorded here
  rather than smuggled: the raw 16 bytes of a live workspace id used to crash
  and now RESOLVE the real membership row. No privilege is gained (producing
  those bytes requires already holding the id), but it is a behaviour change on
  a security path. Normalisation is `Ecto.UUID.cast/1` and nothing else —
  deliberately no `String.trim/1`, because a whitespace-padded id denies today
  and making it resolve would be a widening disguised as a convenience.

  ## What is deliberately NOT totalised

    * The WRITE constructors stay LOUD. `create_membership/2,3,4` and
      `role_for_permissions/1` still raise on malformed input, on purpose:
      three `create_membership` callers DISCARD the return value (the app-token
      controller binds it to `_`; SSO and SCIM call it as a bare expression
      inside a `for`), so a silent denial there would provision a principal
      with NO SEAT and report success. Every caller derives its ids from an
      already-loaded row, so the crash is unreachable from client input anyway.
    * `role_permits?/3` and `granted_actions/2,3` take NO id guard. A built-in
      role name is workspace-id-INDEPENDENT by design — it resolves from the
      compiled-in `@builtin_role_actions` map BEFORE any DB read, so a tenant
      can never redefine `admin` to escalate. `role_permits?("admin", "",
      :admin)` is `true` today and MUST stay true; a guard above that lookup
      would silently TIGHTEN authorization. The cast guard therefore sits on
      the DB read inside `db_actions/3` alone — the only branch a CUSTOM
      (non-built-in) role name reaches.

  ## Two distinctions this module must not blur

    * `authorize/3` is NOT an admin gate; `workspace_admin?/2` is. `authorize/3`
      answers "is this principal a MEMBER here, and does its grant satisfy the
      action" — where the grant is the token's GLOBAL `permissions[]` for an
      `%ApiToken{}` and the membership ROLE for a `%User{}`. It never reads
      `membership.role` for a token, so a global-admin token added to workspace
      B as a plain `member` PASSES `authorize(tok, B, :admin)` and correctly
      FAILS `workspace_admin?(tok, B)`. That divergence IS the cross-tenant
      admin bypass fix (barkpark-23yi / barkpark-fsko); it is load-bearing and
      the two predicates must never be "unified". What the divergence covers is
      the GRANT SHAPE (a token's global `permissions[]` vs a membership role),
      NOT the role vocabulary: since
      `arpss-w10-bl-workspace-admin-denies-custom-role-admin` both predicates
      read a CUSTOM role's action set through the same `granted_actions/3`, so
      a workspace-scoped custom role carrying `admin` is an admin at both. The
      global-permissions denial above is unchanged — it is a `member` ROLE that
      denies there, and `member` grants no `admin` action at either predicate.
    * A scope-bound share-EDIT token (`Barkpark.Auth.create_share_token/5`)
      carries a non-nil `workspace_id` but is inserted with a plain
      `Repo.insert` — never the membership-creating path — so it has NO
      membership row and EVERY predicate here denies it. That is CORRECT: its
      authority comes from `BarkparkWeb.Plugs.RequireShareEditToken`, which
      sets `:share_public` so `ResolveWorkspace` skips the membership gate.
      Routing a share-token-reachable surface through `authorize/3` would deny
      the entire class. What actually refuses such a token on the flat
      `/v1/shares*` admin routes is neither this module nor `RequireAdmin`: the
      `:api` pipeline runs `BarkparkWeb.Plugs.OptionalToken` BEFORE
      `:require_admin`, and `OptionalToken` halts 403 via
      `RequireToken.share_token_off_surface?/2`.

  ## Three entry points, not two — and the third does not merge the other two

  `seat_capabilities/3` (arpss-w10-bl-collapse-the-caps-fork-into-tenancy-auth)
  answers the SEAT decision off a membership row the CALLER already loaded. It
  exists because the Studio capability gate had recomposed that decision out of
  `permits?/2` and `role_permits?/3` in `BarkparkWeb.Studio.Caps`, to keep the
  PDS-D634 one-load property — a second authorization author, with the
  `@canonical` marker pointing at a function its busiest consumer bypassed. The
  recomposition is gone; the one-load property is not. It is a THIRD entry
  point, NOT a unification: `authorize/3` and `workspace_admin?/2` are
  byte-unchanged by it, and charter D9's ban on merging them stands.

  ## A BARE principal id is ambiguous — say which kind it is

  Every predicate here also accepts a raw id binary, and a raw id carries NO
  discriminator: nothing in `"3f2a…"` says whether it names an api_token or a
  user. The 2-arity raw-binary path reads it as an **api_token** — that is the
  historical contract, every in-tree caller that passes a bare id passes a
  TOKEN id, and re-reading it as "whichever row exists" would silently WIDEN a
  user id into a token's grant. The hazard it used to carry is that the wrong
  guess was SILENT: `workspace_admin?(user.id, ws)` answered `false` for a user
  holding a genuine admin seat, indistinguishable from a real denial, and a
  silent FALSE on an admin gate is a lockout nobody reports as a security bug.

  So state the kind. `membership/3`, `member?/3`, `membership_role/3` and
  `workspace_admin?/3` take an explicit `:user | :api_token` and are the ONLY
  correct way to ask about a raw id. The 2-arity raw-binary path keeps its
  api_token reading byte-for-byte, and when that lookup misses while the same
  id names a real USER member of that workspace it LOGS the mis-typed call
  before denying. It still returns `nil` — the fail-closed posture above is not
  traded for a raise on an authorization path — but it is no longer silent.

  Out of scope: denying on a nil workspace ARGUMENT says nothing about a nil
  `workspace_id` COLUMN on a token row. `task-46e7d44068e7185e` is NOT
  answered by this seam.

  Action → satisfying grant:

    * API token permission strings:
      * `:read`  ← "read", "admin", "public-read"
      * `:write` ← "write", "admin"
      * `:admin` ← "admin"
    * User membership roles:
      * `:read`  ← "member", "admin", "owner"
      * `:write` ← "member", "admin", "owner"
      * `:admin` ← "admin", "owner"
  """
  import Ecto.Query, warn: false
  require Logger

  alias Barkpark.Repo
  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.{Membership, Role, RolePermission, Workspace}

  @type action :: :read | :write | :admin
  @type principal :: ApiToken.t() | User.t() | binary()

  # The membership `principal_type` discriminator, as an argument. A raw id
  # binary cannot carry it, so the 3-arity predicates take it explicitly.
  @type principal_kind :: :user | :api_token

  # Which permission strings satisfy each action (API-token principals).
  @read_perms ~w(read admin public-read)
  @write_perms ~w(write admin)
  @admin_perms ~w(admin)

  # Compiled-in action sets for the built-in USER roles — the SOURCE OF TRUTH
  # for byte-identity AND the fail-safe when no DB `role_permissions` row exists.
  # MUST equal the pre-data-driven semantics: read/write ← owner/admin/member,
  # admin ← owner/admin. Because enforcement falls back to this map, a fresh /
  # unseeded DB (or a lost row) can NEVER silently lock out a built-in role.
  @builtin_role_actions %{
    "owner" => ~w(read write admin),
    "admin" => ~w(read write admin),
    "member" => ~w(read write)
  }

  # Default role for a NEW membership when no explicit role is passed. A token
  # ADDED to a workspace it did not create is a `member` — write content, but
  # NOT admin — REGARDLESS of the token's global permissions[]. The role is the
  # GRANT, not a reflection of the token's global perms. The two legitimate
  # exceptions pass an explicit role: the workspace CREATOR ("owner", via
  # `Tenancy.create_workspace_with_owner/2`) and a token's OWN home-workspace
  # binding at mint-time (the perms-derived role, via `Auth.create_token/5`).
  @default_role "member"

  @doc """
  Insert a Membership binding a principal (API token) to a workspace.

  `principal_id` is the token id (a binary_id). `role` must be one of
  `Barkpark.Tenancy.Membership.roles/0`. When omitted it DEFAULTS to
  `"member"` — the core of the per-membership authz model (barkpark-23yi): a
  token added to a workspace gets `member` (write content only), independent of
  its global permissions. Callers that legitimately grant a higher role (the
  workspace creator → `owner`; a token's home-workspace mint binding → its
  perms-derived role) pass `role` EXPLICITLY. Returns the inserted membership
  or a changeset error (e.g. the principal is already a member of the workspace).

  ## HAZARD — `principal_type` DEFAULTS to `"api_token"`

  The fourth argument is the `principal_type` DISCRIMINATOR, and it defaults.
  An implicit default on a discriminator column means a USER grant written as
  `create_membership(ws.id, user.id, "admin")` silently inserts an
  **api_token**-typed row for a user principal. Every user-granting caller in
  `api/lib` passes `"user"` EXPLICITLY (`Barkpark.SSO`, `Barkpark.SCIM`, the
  app-token controller, the session controller), so no shipped row is
  mis-typed — but a TEST that omits it is this repo's proven vacuous-green
  generator, and it fails in the most confusing shape available: the row is
  invisible to `membership(%User{}, ws)`, so `authorize/3` DENIES, while the
  bare-id arm of `workspace_admin?(user.id, ws)` reads TRUE off the mis-typed
  row. A whole user axis can go green while proving nothing — a wave-10
  verifier reproduced exactly that. Pass `"user"` EXPLICITLY for a user grant.
  `test/barkpark/tenancy/auth_principal_kind_test.exs` pins this hazard, and
  the deliberate mis-typed row at `test/barkpark/org_session_policy_test.exs`
  is why the default is documented rather than inferred: inferring the kind
  from the id would rewrite that row's meaning.
  """
  @spec create_membership(binary(), binary(), String.t(), String.t()) ::
          {:ok, Membership.t()} | {:error, Ecto.Changeset.t()}
  def create_membership(
        workspace_id,
        principal_id,
        role \\ @default_role,
        principal_type \\ "api_token"
      )
      when is_binary(workspace_id) and is_binary(principal_id) and is_binary(role) do
    %Membership{}
    |> Membership.changeset(
      %{
        workspace_id: workspace_id,
        principal_id: principal_id,
        role: role,
        principal_type: principal_type
      },
      valid_role_names(workspace_id)
    )
    |> Repo.insert()
  end

  @doc """
  The role names accepted for a membership in this workspace: the built-ins
  (owner/admin/member) plus any custom roles defined for the workspace (or
  global custom roles). A defined custom role is accepted; a typo'd or
  nonexistent role is still rejected by the changeset.

  Public because it is THE valid-role set for a membership write — every
  membership writer must validate against it (`create_membership/4` here,
  `Barkpark.Scim.add_group_member/3` for SCIM group grants), so a role write
  can never land that `Membership.changeset/3` would refuse
  (arpss-w10-bl-scim-set-member-role-unvalidated).
  """
  @spec valid_role_names(binary()) :: [String.t()]
  def valid_role_names(workspace_id) do
    custom =
      Repo.all(
        from r in Role,
          where: r.workspace_id == ^workspace_id or is_nil(r.workspace_id),
          select: r.name
      )

    Enum.uniq(Membership.roles() ++ custom)
  end

  @doc """
  Fetch the Membership for a token (or principal id) in a workspace, or nil.

  A STRUCT argument is unambiguous: `%ApiToken{}` resolves a
  `principal_type: "api_token"` row, `%User{}` a `principal_type: "user"` row.
  The `principal_type` discriminator IS the cross-kind isolation, so a user id
  can never accidentally match a token's grant.

  A RAW id binary is NOT unambiguous — see the moduledoc. This arity reads it
  as an **api_token** id (unchanged, historical contract). If you hold a raw id
  whose kind you know, call `membership/3` and say so; passing a bare USER id
  here answers `nil` and logs the mis-typed call.
  """
  @spec membership(principal(), binary()) :: Membership.t() | nil
  def membership(%ApiToken{id: principal_id}, workspace_id),
    do: membership(principal_id, workspace_id, :api_token)

  # A User principal resolves to a `principal_type: "user"` membership row.
  # Kept SEPARATE from the raw-binary clause below (which reads "api_token") so
  # a user id can never accidentally match a token's grant.
  def membership(%User{id: principal_id}, workspace_id),
    do: membership(principal_id, workspace_id, :user)

  # THE AMBIGUOUS ARM. A bare binary says nothing about its kind, and this arm
  # keeps reading it as an api_token id — byte-identical to before for a real
  # token member, because every in-tree bare-id caller passes a token id and
  # re-reading it as "whichever row exists" would silently WIDEN a user id into
  # a token's grant. What changed is that a WRONG guess is no longer silent:
  # when the api_token lookup misses and the same id names a real USER member
  # of this workspace, the caller asked the wrong question and gets told. The
  # answer stays `nil` — #12616 made this module fail CLOSED rather than crash,
  # and a raise on an authorization path is precisely the hazard that seam
  # removed, so the signal is a LOG, not an exception. The probe costs one
  # extra query only on the bare-id DENIAL path (struct callers delegate
  # straight to `membership/3` and never reach it).
  def membership(principal_id, workspace_id)
      when is_binary(principal_id) and is_binary(workspace_id) do
    case membership(principal_id, workspace_id, :api_token) do
      %Membership{} = membership -> membership
      nil -> deny_bare_id(principal_id, workspace_id)
    end
  end

  # TERMINAL DENIAL — the whole seam. Everything the struct/guarded heads above
  # do not match (a nil, a non-binary, an unrecognised principal struct such as
  # a %CallerContext{}) denies HERE instead of raising FunctionClauseError.
  # It must stay CONTIGUOUS with the clause above: a def of another name
  # between them emits "clauses with the same name and arity should be grouped
  # together", which --warnings-as-errors turns into a failed build.
  # (`%ApiToken{id: nil}` no longer lands here — it delegates as
  # `membership(nil, ws, :api_token)` and denies on membership/3's terminal.)
  def membership(_principal, _workspace_id), do: nil

  @doc """
  Fetch the Membership for a RAW principal id whose kind is stated EXPLICITLY.

  This is the ONLY correct way to ask about a raw id: `principal_kind` is the
  `principal_type` discriminator the id itself cannot carry. `:user` reads the
  user row space, `:api_token` the token row space — never both, so this widens
  nothing.

  Same fail-closed posture as `membership/2`: a nil, a non-binary or an
  unrecognised kind DENIES (returns nil) instead of raising.
  """
  @spec membership(binary(), binary(), principal_kind()) :: Membership.t() | nil
  def membership(principal_id, workspace_id, principal_kind)
      when is_binary(principal_id) and is_binary(workspace_id) and
             principal_kind in [:user, :api_token] do
    case {Repo.uuid_or_nil(principal_id), Repo.uuid_or_nil(workspace_id)} do
      {pid, ws} when is_binary(pid) and is_binary(ws) ->
        principal_type = Atom.to_string(principal_kind)

        Repo.one(
          from m in Membership,
            where:
              m.principal_id == ^pid and
                m.workspace_id == ^ws and
                m.principal_type == ^principal_type
        )

      _ ->
        nil
    end
  end

  # TERMINAL DENIAL for the explicit-kind arity, contiguous for the same
  # grouped-clauses reason as membership/2's.
  def membership(_principal_id, _workspace_id, _principal_kind), do: nil

  # A bare id that matched no api_token membership. Deny either way; when the
  # id names a real USER member here, the call was mis-typed — say so LOUDLY
  # instead of handing back an answer to a question the caller did not ask.
  defp deny_bare_id(principal_id, workspace_id) do
    if membership(principal_id, workspace_id, :user) do
      Logger.error(
        "Tenancy.Auth: a BARE principal id was read as an api_token id but names a USER " <>
          "member of this workspace — DENIED. Pass the %User{} struct, or the 3-arity " <>
          "form with :user. principal_id=#{principal_id} workspace_id=#{workspace_id}"
      )
    end

    nil
  end

  @doc "True when the token (or principal id) is a member of the workspace."
  @spec member?(principal(), binary()) :: boolean()
  def member?(token_or_principal_id, workspace_id) do
    not is_nil(membership(token_or_principal_id, workspace_id))
  end

  @doc """
  True when the RAW principal id of the STATED kind is a member of the
  workspace. The unambiguous form of `member?/2` — see `membership/3`.
  """
  @spec member?(binary(), binary(), principal_kind()) :: boolean()
  def member?(principal_id, workspace_id, principal_kind) do
    not is_nil(membership(principal_id, workspace_id, principal_kind))
  end

  @doc """
  Authorize `token` to perform `action` in `workspace_id`.

  Returns `:ok` when the token is a member of the workspace AND its
  `permissions` satisfy the action; `{:error, :forbidden}` otherwise.

  This is the function the router and controllers call. It denies rather than
  raising: an unknown action, an unrecognised principal shape, a non-member,
  AND — since the `membership/2` seam — a malformed or absent id all return
  `{:error, :forbidden}`.

  That last class is NEW, and the catch-all clause below never covered it. The
  catch-all is a SHAPE catch-all only: the `%ApiToken{}` arm guards just
  `is_binary(workspace_id) and action in [...]`, so `""` and any non-UUID
  string SATISFIED that guard, matched the arm, reached `Repo.one` and raised
  `Ecto.Query.CastError` (HTTP 400) — never `Ecto.CastError`; and
  `%ApiToken{id: nil}` raised `FunctionClauseError` (HTTP 500). Totality for
  malformed input is inherited from `membership/2`, not declared here.

  It is NOT an admin gate — see the module doc: a global-admin token that is a
  plain `member` of workspace B passes `authorize(tok, B, :admin)` and must
  still fail `workspace_admin?(tok, B)`.
  """
  @spec authorize(principal(), binary(), action()) :: :ok | {:error, :forbidden}
  def authorize(principal, workspace_id, action) do
    case authorize_with_reason(principal, workspace_id, action) do
      :ok -> :ok
      {:error, _reason} -> {:error, :forbidden}
    end
  end

  @doc """
  The SAME decision as `authorize/3`, but it names WHICH arm of the conjunction
  refused.

  `authorize/3` answers a two-arm predicate — membership AND capability — with
  one atom, so every caller that renders the refusal has to guess which half
  failed, and the guess is often backwards (a token holding `admin` cannot fail
  the capability half, so what failed was membership). This variant is the ONE
  place that decision is made; `authorize/3` is a thin collapse of it, so the
  two can never drift apart.

    * `{:error, :not_a_member}` — the principal has no membership in the
      workspace. The remedy is a workspace invitation.
    * `{:error, :missing_capability}` — the principal IS a member, but its
      permissions (tokens) or role (users) do not satisfy `action`. The remedy
      is a permission/role change.
    * `{:error, :forbidden}` — the principal shape is unrecognised, or the
      workspace id / action is malformed. No arm applies.

  Grants only ADD access, so a `CallerContext` whose grants authorize is `:ok`;
  when they do not, the membership arm's reason is what the caller hears.
  """
  @spec authorize_with_reason(principal(), binary(), action()) ::
          :ok | {:error, :not_a_member | :missing_capability | :forbidden}
  def authorize_with_reason(%ApiToken{id: id} = token, workspace_id, action)
      when is_binary(workspace_id) and action in [:read, :write, :admin] do
    cond do
      not resolvable?(id, workspace_id) -> {:error, :forbidden}
      not member?(token, workspace_id) -> {:error, :not_a_member}
      not permits?(token, action) -> {:error, :missing_capability}
      true -> :ok
    end
  end

  # User principal: the GRANT is the membership ROLE (users carry no
  # permissions[] array). A non-member is denied; a member is allowed when its
  # role satisfies the action. Same chokepoint, same total contract as tokens.
  def authorize_with_reason(%User{id: id} = user, workspace_id, action)
      when is_binary(workspace_id) and action in [:read, :write, :admin] do
    if resolvable?(id, workspace_id) do
      case membership(user, workspace_id) do
        %Membership{role: role} ->
          if role_permits?(role, workspace_id, action),
            do: :ok,
            else: {:error, :missing_capability}

        nil ->
          {:error, :not_a_member}
      end
    else
      {:error, :forbidden}
    end
  end

  # CallerContext arm (airdrop-grants ag-enforcement). A folded caller is
  # authorized when membership authorizes (existing logic, reconstructed from the
  # ctx's principal so it stays byte-identical) OR any ACTIVE grant the ctx
  # carries authorizes `action` at this workspace. Grants only ADD access — the
  # membership check runs first and unchanged, so a member's decision is never
  # altered. The grant check delegates to `Barkpark.Access.validate/3` (single
  # source of scope/capability/expiry truth — never reimplemented here).
  def authorize_with_reason(%Barkpark.Content.CallerContext{} = ctx, workspace_id, action)
      when is_binary(workspace_id) and action in [:read, :write, :admin] do
    case membership_authorizes?(ctx, workspace_id, action) do
      :ok ->
        :ok

      {:error, reason} ->
        if grants_authorize?(ctx, workspace_id, action), do: :ok, else: {:error, reason}
    end
  end

  def authorize_with_reason(_token, _workspace_id, _action), do: {:error, :forbidden}

  # `membership/2` answers `nil` for BOTH "no such row" and "that id could never
  # name a row" (nil, empty string, non-UUID) — it fails closed rather than
  # raising. `authorize/3` could not tell those apart and did not need to: both
  # are `:forbidden`. A reason-bearing denial DOES need to: calling a malformed
  # principal id "not a member" would state a fact about a workspace seat that
  # was never actually queried. So the ids are cast FIRST, and anything that
  # cannot resolve gets the bare `:forbidden` — no arm applies.
  defp resolvable?(principal_id, workspace_id) do
    is_binary(principal_id) and
      not is_nil(Repo.uuid_or_nil(principal_id)) and
      not is_nil(Repo.uuid_or_nil(workspace_id))
  end

  # Reconstruct the bare principal from the ctx and run the EXISTING authorize
  # arms, so a folded member's decision is byte-identical to today.
  defp membership_authorizes?(%{principal_type: :user, user_id: uid}, workspace_id, action)
       when is_binary(uid),
       do: authorize_with_reason(%User{id: uid}, workspace_id, action)

  defp membership_authorizes?(
         %{principal_type: :api_token, token_id: tid, roles: roles},
         workspace_id,
         action
       )
       when is_binary(tid) and is_list(roles),
       do: authorize_with_reason(%ApiToken{id: tid, permissions: roles}, workspace_id, action)

  defp membership_authorizes?(_ctx, _workspace_id, _action), do: {:error, :forbidden}

  defp grants_authorize?(%{grants: grants}, workspace_id, action) when is_list(grants) do
    Enum.any?(grants, fn grant ->
      Barkpark.Access.validate(grant, action, %{workspace_id: workspace_id}) == :ok
    end)
  end

  defp grants_authorize?(_ctx, _workspace_id, _action), do: false

  @doc """
  True when the membership `role` grants `action` in `workspace_id`, for USER
  principals. The grant is data-driven — a role's action set comes from
  `role_permissions` (`Barkpark.Tenancy.Role`) — with the compiled-in
  `@builtin_role_actions` as the fail-safe for the built-in roles, so
  enforcement never DEPENDS on a seed row and a missing row can't cause a
  silent lockout. A built-in name always resolves as built-in (a tenant can't
  redefine `admin` to escalate); a custom role resolves from its DB rows.
  """
  @spec role_permits?(String.t(), binary(), action()) :: boolean()
  def role_permits?(role, workspace_id, action)
      when is_binary(role) and is_binary(workspace_id) and action in [:read, :write, :admin] do
    Atom.to_string(action) in granted_actions(role, workspace_id)
  end

  def role_permits?(_role, _workspace_id, _action), do: false

  # Resolution: a built-in name ALWAYS resolves from the compiled-in map — the
  # DB row for a built-in is purely for Stage-B CRUD visibility and is IGNORED
  # for enforcement, so a tenant can never redefine `admin`/`member` (via a
  # workspace- or global-scoped row of the same name) to escalate OR to weaken
  # the fail-safe. A custom name resolves purely from its DB rows.
  defp granted_actions(role, workspace_id),
    do: granted_actions(role, workspace_id, :inherit_global)

  # THE ONE ROLE RESOLVER. The `case` ORDER is the shadowing tripwire: the
  # built-in map is consulted BEFORE any DB read, in every scope, so a tenant
  # row named `admin`/`owner`/`member` is inert for enforcement. Flip these two
  # arms and a workspace row named `member` carrying an `admin` action
  # escalates — `test/barkpark/tenancy/workspace_admin_custom_role_test.exs`
  # ("built-in shadowing") reds on exactly that mutation.
  #
  # `scope` says whether a nil-`workspace_id` (global) custom row counts:
  #
  #   * `:inherit_global` — the historical `role_permits?/3` / `authorize/3`
  #     reach, unchanged.
  #   * `:workspace_only` — the ADMIN gate's reach. See `workspace_admin?/2`.
  defp granted_actions(role, workspace_id, scope) do
    case Map.get(@builtin_role_actions, role) do
      nil -> db_actions(role, workspace_id, scope)
      builtin -> builtin
    end
  end

  # The ONLY id guard on the role path. `granted_actions/3` above answers for a
  # built-in role WITHOUT consulting the workspace id at all, so the guard
  # cannot sit any higher without flipping `role_permits?("admin", "", :admin)`
  # from true to false — a silent authorization TIGHTENING. Here, a malformed
  # workspace id yields no permission rows, i.e. a denial for a custom role.
  defp db_actions(role, workspace_id, scope) do
    case Repo.uuid_or_nil(workspace_id) do
      nil ->
        []

      ws_uuid ->
        from(rp in RolePermission,
          join: r in Role,
          on: rp.role_id == r.id,
          where: r.name == ^role,
          select: rp.action
        )
        |> role_scope(ws_uuid, scope)
        |> Repo.all()
    end
  end

  defp role_scope(query, ws_uuid, :inherit_global),
    do: from([_rp, r] in query, where: r.workspace_id == ^ws_uuid or is_nil(r.workspace_id))

  defp role_scope(query, ws_uuid, :workspace_only),
    do: from([_rp, r] in query, where: r.workspace_id == ^ws_uuid)

  @doc """
  True when the token's permissions satisfy `action`, ignoring membership.
  Exposed so the write-gate plug can check permission without a workspace.
  """
  # The `when is_list(perms)` guard keeps these clauses total: a token whose
  # `permissions` is nil (e.g. a NULL DB column) falls THROUGH to the catch-all
  # and is denied, rather than raising `ArgumentError` on `&1 in nil`. nil
  # permissions → deny (false), never raise.
  @spec permits?(ApiToken.t(), action()) :: boolean()
  def permits?(%ApiToken{permissions: perms}, :read) when is_list(perms),
    do: Enum.any?(@read_perms, &(&1 in perms))

  def permits?(%ApiToken{permissions: perms}, :write) when is_list(perms),
    do: Enum.any?(@write_perms, &(&1 in perms))

  def permits?(%ApiToken{permissions: perms}, :admin) when is_list(perms),
    do: Enum.any?(@admin_perms, &(&1 in perms))

  def permits?(_token, _action), do: false

  @no_seat %{read: false, write: false, admin: false}

  @doc """
  THE SEAT DECISION for one principal, read off an **already-loaded**
  `%Membership{}` row: `%{read:, write:, admin:}` for `workspace_id`.

  This is the arity the Studio calls (`BarkparkWeb.Studio.Caps`). It exists so
  that a caller which has ALREADY paid for the membership row does not have to
  recompose the decision out of `permits?/2` + `role_permits?/3` on its own —
  which is exactly what `caps.ex` used to do, and what
  `arpss-w10-bl-collapse-the-caps-fork-into-tenancy-auth` deleted. One decision,
  one owner, zero extra queries: the caller keeps the PDS-D634 one-load
  property, the module keeps the decision.

  ## The contract, column by column

    * `:read` / `:write` — **the same decision `authorize/3` makes**, by shared
      code over the same row: `permits?/2` for a token, the role's action set
      for a user. A `nil` membership is a non-member and denies, exactly as
      `authorize/3` denies it.
    * `:admin` — **WORKSPACE-SCOPED SEAT AUTHORITY** (charter D22), which is
      deliberately NOT `authorize/3`'s answer and NOT `workspace_admin?/2`'s
      answer:
      - for a USER it is the membership role's `admin` action, which IS
        `authorize/3`'s user arm;
      - for an API TOKEN it is `permits?(token, :admin)` **AND** the membership
        role's `admin` action. `authorize/3`'s token arm is `member? AND
        permits?`, which admits a global-admin token holding a plain `member`
        row in a foreign workspace — the barkpark-23yi/fsko shape. This arity
        refuses it.

  ## What this does NOT do — charter D9 stands

  It does not unify `authorize/3` and `workspace_admin?/2`, and it does not
  change either of them. They remain two predicates with two different, RULED
  reaches, and this is a THIRD entry point that composes neither: it reads the
  seat off a row the caller supplies. In particular a SHARE-EDIT token, which
  holds no membership row at all, reaches the `nil` catch-all and gets nothing —
  its read/write access comes from the grant arm at the call site, never from
  here.

  ## The row must belong to THIS workspace AND TO THIS PRINCIPAL

  An arity that ACCEPTS a preloaded row owes its callers TWO guarantees, and
  each is a pattern binding rather than a sentence:

    * the `%Membership{workspace_id: workspace_id}` pattern binds the row's own
      workspace to the `workspace_id` argument, so a row loaded for workspace A
      can never answer a question about workspace B;
    * the `principal_type` / `principal_id` pattern binds the row to the
      PRINCIPAL in the first argument — the same `{id, type}` pairing
      `membership/2` uses to LOAD a row (`%ApiToken{}` -> `"api_token"`,
      `%User{}` -> `"user"`), so a row that belongs to somebody else cannot
      answer for you.

  The second one is why a crossed pair denies instead of answering. This
  function's whole contract is "I trust the row you hand me", and its own
  introducing caller (`Caps.derive_from_assigns/1`) holds a LIST of two
  principals' rows: a transposition there would otherwise return the WRONG
  SEAT — silently, with no raise, no red and no log. Both live call sites zip
  correctly today (`load_memberships/2` pairs each row with its principal, and
  `admin?/1` loads per principal), so this closes a hazard with no reachable
  instance rather than a live defect — added on lead-studio-10's review of
  pds-w42/#16586, on the reasoning that a newly PUBLIC function on the
  authorization chokepoint should not rely on every future caller zipping
  correctly.

  Both bindings together make the workspace-blind built-in role resolution (see
  `role_permits?/3`) unreachable from a hand-built struct: a fabricated
  `%Membership{role: "admin"}` with no matching `workspace_id` — or with no
  matching principal — answers all-false.

  ## Cost

  ZERO queries on a built-in role. ONE `Repo.all` on a custom role — resolved
  ONCE for all three actions, where three separate `role_permits?/3` calls paid
  for it three times. That is the cost half of this collapse, pinned in
  `test/barkpark_web/live/studio/pds_w43_caps_derive_cost_test.exs`.
  """
  @spec seat_capabilities(principal(), Membership.t() | nil, binary()) ::
          %{read: boolean(), write: boolean(), admin: boolean()}
  def seat_capabilities(
        %ApiToken{id: principal_id} = token,
        %Membership{
          role: role,
          workspace_id: workspace_id,
          principal_type: "api_token",
          principal_id: principal_id
        },
        workspace_id
      )
      when is_binary(principal_id) and is_binary(workspace_id) do
    %{
      read: permits?(token, :read),
      write: permits?(token, :write),
      # PERMS FIRST, deliberately: a token without the `admin` permission
      # short-circuits before any role resolution, so a read-only token pays
      # nothing for the seat half.
      admin: permits?(token, :admin) and role_confers_admin?(role, workspace_id)
    }
  end

  def seat_capabilities(
        %User{id: principal_id},
        %Membership{
          role: role,
          workspace_id: workspace_id,
          principal_type: "user",
          principal_id: principal_id
        },
        workspace_id
      )
      when is_binary(principal_id) and is_binary(role) and is_binary(workspace_id) do
    # ONE resolution, three answers. `role_permits?/3` is `action in
    # granted_actions(role, ws)`; asking it three times asks the resolver three
    # times, which on a CUSTOM role is three `Repo.all`s for one row.
    actions = granted_actions(role, workspace_id)

    %{
      read: "read" in actions,
      write: "write" in actions,
      admin: "admin" in actions
    }
  end

  # Non-member (nil row), a row from another WORKSPACE, a row belonging to
  # another PRINCIPAL, an unrecognised principal shape, a non-binary workspace
  # id or principal id: nothing. Fails closed, never raises.
  def seat_capabilities(_principal, _membership, _workspace_id), do: @no_seat

  # The seat half of a TOKEN's `:admin` conjunct. Same resolver, same
  # `:inherit_global` reach as `role_permits?(role, ws, :admin)` — this is the
  # spelling charter D22 ruled for the Studio column, NOT `workspace_admin?/2`'s
  # `:workspace_only` name-list-or-custom-row rule.
  defp role_confers_admin?(role, workspace_id)
       when is_binary(role) and is_binary(workspace_id),
       do: "admin" in granted_actions(role, workspace_id)

  defp role_confers_admin?(_role, _workspace_id), do: false

  @doc """
  The caller's GLOBAL auth tier, as one of the closed strings the
  `/v1/capabilities` manifest speaks: `"none" | "read" | "write" | "admin"`,
  optionally suffixed `"+chat"`.

  THE SINGLE OWNER OF THE LADDER. `Barkpark.Plugins.Capabilities.tier_for_token/1`
  used to carry its own copy of this `cond`, so the tier the manifest ADVERTISES
  and the tier the request pipelines ENFORCE were two hand-written ladders that
  had to agree by review. They live here now, next to `permits?/2` — the very
  predicate every rung consults and the one the write gate already calls — so
  there is one rung to change when a permission is added.

  Each rung is the same judgment its pipeline authority makes, and MUST stay
  equal to it (pinned by
  `BarkparkWeb.Contract.CapabilitiesTierParityTest`):

    * `"admin"` — `BarkparkWeb.Plugs.RequireAdmin` (`pipeline :require_admin`),
      i.e. `Barkpark.Auth.has_permission?(token, "admin")`. Identical to
      `permits?(token, :admin)`, whose `@admin_perms` is exactly `~w(admin)`.
    * `"write"` — `BarkparkWeb.Plugs.RequireWritePermission`
      (`pipeline :require_write`), i.e. `permits?(token, :write)`.
    * `"read"` — the `pipeline :require_token` stack: `RequireToken` admits the
      credential, `PublicRead` clamps the tier below this one, and
      `RequireWriteForMutation` refuses this tier every mutation. A token that
      gets a GET through that stack but is refused a write is `read`.
    * `"+chat"` — `BarkparkWeb.Plugs.RequireChatAccess.chat_scope/1` resolving
      `{:workspace, ws}`: a NON-admin, workspace-bound `chat` token. ORTHOGONAL
      (charter D16/D36) — it rides ALONGSIDE the base rank and lifts nothing,
      which is why it is a suffix and not a rung.

  `nil` (no resolved token) is `"none"`, the existence-hiding floor.

  @canonical capability:global-auth-tier aka:tier_for_token,tier_of,auth tier,caller tier,tier ladder,auth-tier ladder doc:docs/auth.md
  """
  @spec tier_of(ApiToken.t() | nil) :: String.t()
  def tier_of(nil), do: "none"

  def tier_of(token) do
    base =
      cond do
        permits?(token, :admin) -> "admin"
        permits?(token, :write) -> "write"
        permits?(token, :read) -> "read"
        true -> "none"
      end

    # A global-admin caller already discovers `chat` through the rank ladder;
    # the suffix is only for the non-admin, workspace-bound `chat` token —
    # exactly the principal RequireChatAccess authorizes at `{:workspace, ws}`.
    if base != "admin" and Barkpark.Auth.has_permission?(token, "chat") and
         not is_nil(Map.get(token, :workspace_id)) do
      base <> "+chat"
    else
      base
    end
  end

  @doc """
  Derive the workspace role from a permissions array: `"admin"` when the
  permissions include "admin", otherwise `"member"`.

  SCOPE: this is the role for a token's OWN home workspace ONLY — the workspace
  the token is minted into (`Auth.create_token/5`). It is a legitimate
  perms-derived role because the token's home workspace is its own. It is NOT
  used when ADDING a token to ANOTHER workspace — that path defaults to
  `member` (see `create_membership/4`). This is the fix for the cross-tenant
  admin bypass (barkpark-23yi / barkpark-fsko): a global-admin token added to
  workspace B must NOT become admin of B.
  """
  @spec role_for_permissions([String.t()]) :: String.t()
  def role_for_permissions(permissions) when is_list(permissions) do
    if "admin" in permissions, do: "admin", else: "member"
  end

  # The BUILT-IN roles that confer workspace-admin authority on a scoped
  # surface, resolved with no DB read. NOT the whole rule: a workspace-scoped
  # CUSTOM role carrying the `admin` action also confers it — see
  # `admin_role?/2`, the one place both arms are spelled.
  @admin_roles ~w(owner admin)

  @doc """
  The token's MEMBERSHIP ROLE in `workspace_id`, or nil when it is not a member.
  This reads the GRANT (the `workspace_memberships.role` column), NOT the
  token's global permissions[]. Accepts a token struct or a raw principal id.
  """
  @spec membership_role(principal(), binary()) :: String.t() | nil
  def membership_role(token_or_principal_id, workspace_id) do
    case membership(token_or_principal_id, workspace_id) do
      %Membership{role: role} -> role
      nil -> nil
    end
  end

  @doc """
  The membership ROLE of a RAW principal id of the STATED kind. The
  unambiguous form of `membership_role/2` — see `membership/3`.
  """
  @spec membership_role(binary(), binary(), principal_kind()) :: String.t() | nil
  def membership_role(principal_id, workspace_id, principal_kind) do
    case membership(principal_id, workspace_id, principal_kind) do
      %Membership{role: role} -> role
      nil -> nil
    end
  end

  @doc """
  True when the principal's membership ROLE in `workspace_id` confers admin
  authority. This is the per-membership admin gate: a `member` of B — even one
  holding global `admin` perms — is NOT a workspace admin of B. A non-member is
  never an admin.

  Two ways a role confers it, and only two:

    * it IS a built-in admin role (`owner` / `admin`), resolved from the
      compiled-in `@admin_roles` constant with NO DB read — the fail-safe is
      unchanged, an unseeded DB can never lock a built-in admin out; or
    * it is a CUSTOM role DEFINED IN THIS WORKSPACE whose stored
      `role_permissions` rows carry the `admin` action, resolved through the
      same `granted_actions/3` the `authorize/3` chokepoint uses.

  ## Why the second arm exists (arpss-w10-bl-workspace-admin-denies-custom-role-admin)

  Without it this predicate was a role-NAME check while `authorize/3` resolved
  the ACTION SET, so a workspace-scoped custom role carrying the `admin` action
  made `authorize(user, ws, :admin)` `:ok` and `workspace_admin?(user, ws)`
  FALSE. `BarkparkWeb.LiveAuth`'s `:scoped_admin` mount gate bars on THIS
  predicate, so a legitimate custom-role admin was locked out of
  `/w/:ws/…/_plugins` and every other scoped-admin surface. RULED
  (team-lead, 2026-09-02): honour the custom role.

  ## What this deliberately does NOT widen — charter D9 stands

    * A GLOBAL-PERMISSIONS principal is still not an admin. The arm reads the
      membership ROLE only; a global-`admin` token added to workspace B as a
      plain `member` resolves `"member"` → the built-in map → no `admin`
      action → still DENIED. The D9 divergence from `authorize/3` is intact.
    * A SHARE-EDIT token is still not an admin. It has no membership row at
      all, so `membership_role/2` is `nil` and the guardless clause denies.
    * A tenant role NAMED a built-in cannot escalate. `granted_actions/3`
      resolves built-in names from the compiled map BEFORE any DB read, so a
      workspace row named `member` carrying an `admin` action is inert.
    * A GLOBAL custom role (`workspace_id: nil`) cannot confer admin
      EVERYWHERE. This arm resolves `:workspace_only` — strictly rows scoped to
      THIS workspace — while `role_permits?/3` keeps its historical
      `:inherit_global` reach. Nothing in `api/lib` writes a nil-workspace
      CUSTOM role (`Barkpark.Seeds.Shared.ensure_builtin_roles/0` is the sole
      `Role` writer and inserts built-ins only), and the migration declares
      "NULL = global built-in", so honouring one here would have amplified a
      single hand-inserted row into admin of every workspace on the instance.
  """
  # @canonical capability:workspace-admin-authority aka:is_admin,workspace_admin,mount_gate,scoped_admin doc:docs/contracts/tenancy.md
  @spec workspace_admin?(principal(), binary()) :: boolean()
  def workspace_admin?(token_or_principal_id, workspace_id) do
    admin_role?(membership_role(token_or_principal_id, workspace_id), workspace_id)
  end

  @doc """
  True when a RAW principal id of the STATED kind holds admin authority in the
  workspace. The unambiguous form of `workspace_admin?/2`.

  Prefer this (or the struct form) whenever you hold a bare id: `workspace_admin?/2`
  reads a bare binary as an api_token id, so a bare USER id answers `false` for
  a user who genuinely holds an admin seat — a silent DENY on an admin gate.
  """
  @spec workspace_admin?(binary(), binary(), principal_kind()) :: boolean()
  def workspace_admin?(principal_id, workspace_id, principal_kind) do
    admin_role?(membership_role(principal_id, workspace_id, principal_kind), workspace_id)
  end

  # THE admin-authority rule, written ONCE so /2 and /3 can never diverge.
  # Short-circuits on the built-in constant, so the common case still costs no
  # DB read and a built-in admin survives an unseeded `roles` table. The custom
  # arm is `:workspace_only` on purpose — see `workspace_admin?/2`'s doc.
  # `nil` (non-member) and any non-binary role fall to the catch-all: DENY.
  defp admin_role?(role, workspace_id) when is_binary(role) and is_binary(workspace_id) do
    role in @admin_roles or "admin" in granted_actions(role, workspace_id, :workspace_only)
  end

  defp admin_role?(role, _workspace_id) when is_binary(role), do: role in @admin_roles

  defp admin_role?(_role, _workspace_id), do: false

  # The role that confers WORKSPACE-OWNER authority. Deliberately a SEPARATE
  # constant from `@admin_roles` — the point of this predicate is that it is
  # strictly narrower, and sharing a constant would make a future widening of
  # the admin gate silently widen the owner seat too.
  @owner_roles ~w(owner)

  @doc """
  True when the principal's membership ROLE in `workspace_id` is `owner`.

  DELIBERATELY STRICTER than `workspace_admin?/2`: `owner` alone, never
  `admin`. It is the OWNER-ONLY SEAT test — the gate for a ceremony only the
  workspace's owner may perform, today chat-host enrollment (the Studio
  `ChatHostsLive` `:enroll` arm and `ChatHostController.create_enrollment/2`),
  where handing a machine a long-lived credential is an owner decision while
  revoking one is an admin decision. The policy lives HERE, at one named
  predicate, rather than being spelled `membership_role(p, ws) == "owner"` at
  each call site: that literal was written TWICE, in a controller and a
  LiveView, and a loosening applied to one and not the other is a silent
  divergence (`arpss-w10-bl-chat-hosts-owner-literal-seat-fork`).

  Because it is narrower than every other predicate here it can only DENY where
  they admit — it is not, and must not become, a way to ADMIT anyone
  `workspace_admin?/2` refuses. A non-member is never an owner, and the
  fail-closed posture of `membership_role/2` (nil / malformed ids deny rather
  than raise) is inherited unchanged.
  """
  @spec workspace_owner?(principal(), binary()) :: boolean()
  def workspace_owner?(token_or_principal_id, workspace_id) do
    membership_role(token_or_principal_id, workspace_id) in @owner_roles
  end

  @doc """
  List the Workspaces a principal is a MEMBER of, ordered by slug.

  Accepts an `%ApiToken{}` struct, a `%User{}` struct, or a raw principal id
  binary. The hard tenant boundary: the query INNER-JOINs
  `workspace_memberships` on `principal_id == <principal id>` (and a
  `principal_type` pinned per clause), so a workspace the caller has no
  membership row in can never appear — there is no unscoped fallback.

  ## Fail closed, not fail crash

  TOTAL for malformed input: every clause routes its id through
  `Repo.uuid_or_nil/1` and a non-castable id yields the declared denial value,
  the EMPTY LIST — the same posture this module's other read predicates
  hold. Before this seam the bare-binary clause accepted ANY binary (the empty
  string, `"not-a-uuid"`) and reached the query, where the `:binary_id`
  comparison raised **`Ecto.Query.CastError`** — mapped to 400 by
  `phoenix_ecto`. Note the module: `Ecto.Query.CastError`, NOT `Ecto.CastError`
  (which `Repo.uuid_or_nil/1`'s own docstring names); the latter fires zero
  times on this path, so a test asserting it would be vacuous. A
  `%ApiToken{id: nil}` did NOT crash before — it delegated to the raw-binary
  arity, missed the `is_binary` guard and landed on the terminal `[]` by luck
  of clause ORDER. It now denies by RULE, at the normalisation seam.

  As elsewhere in this module, normalisation is `Ecto.UUID.cast/1` and nothing
  else:
  a 16-byte binary is accepted as raw UUID bytes and DOES reach the query,
  where it denies by matching no membership row.

  ## This is the INVERSE index — never rewrite it on top of `membership/2`

  This module's other predicates are POINT lookups: every one of them takes a
  `workspace_id` and answers about ONE workspace. This one takes no workspace
  argument and enumerates them, so it is the inverse index over the SAME
  `(principal_id, workspace_id, principal_type)` keying, not another copy of
  the point lookup. It arrived here by RELOCATION from `Barkpark.Tenancy`
  (`task-e7571b83f9a101fd`), query byte-for-byte, precisely so the enumeration
  sits at the chokepoint without being re-expressed in terms of it.

  The shape this must NOT become:

      list_workspaces() |> Enum.filter(&Auth.member?(principal, &1.id))

  That is N+1 queries over an unbounded workspace scan, and — the reason that
  matters — it is FAIL-OPEN in shape. Starting from every workspace and
  filtering down makes the tenant boundary depend on the filter being right;
  the INNER JOIN below starts from the membership rows, so a workspace with no
  membership row is not merely filtered out, it is UNREACHABLE. That structural
  property is the isolation and it must not be traded for dedup.
  `test/barkpark/tenancy/list_workspaces_for_totality_test.exs` pins the shape
  by COUNTING queries: the enumeration is exactly one, so the filter rewrite
  reds instead of passing silently.
  """
  @spec list_workspaces_for(User.t() | ApiToken.t() | binary() | nil) :: [Workspace.t()]
  def list_workspaces_for(%ApiToken{id: principal_id}),
    do: member_workspaces(principal_id, "api_token")

  # A User principal joins on `principal_type == "user"`. Kept SEPARATE from the
  # raw-binary clause below (pinned to "api_token") so a user id can never match
  # a token's membership grant — the discriminator IS the cross-kind isolation.
  def list_workspaces_for(%User{id: principal_id}),
    do: member_workspaces(principal_id, "user")

  def list_workspaces_for(principal_id) when is_binary(principal_id),
    do: member_workspaces(principal_id, "api_token")

  # TERMINAL DENIAL — a nil, a number, an unrecognised principal struct. Must
  # stay CONTIGUOUS with the clauses above: a def of another name between them
  # emits "clauses with the same name and arity should be grouped together",
  # which --warnings-as-errors turns into a failed build.
  def list_workspaces_for(_), do: []

  # The one membership query behind all three clauses. The `principal_type` is
  # a per-clause LITERAL, never derived from the id, so cross-kind isolation
  # survives the sharing.
  defp member_workspaces(principal_id, principal_type) do
    case Repo.uuid_or_nil(principal_id) do
      nil ->
        []

      pid ->
        Repo.all(
          from w in Workspace,
            join: m in Membership,
            on: m.workspace_id == w.id,
            where: m.principal_id == ^pid and m.principal_type == ^principal_type,
            order_by: w.slug
        )
    end
  end
end
