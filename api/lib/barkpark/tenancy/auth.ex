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
    * `role_permits?/3` and `granted_actions/2` take NO id guard. A built-in
      role name is workspace-id-INDEPENDENT by design — it resolves from the
      compiled-in `@builtin_role_actions` map BEFORE any DB read, so a tenant
      can never redefine `admin` to escalate. `role_permits?("admin", "",
      :admin)` is `true` today and MUST stay true; a guard above that lookup
      would silently TIGHTEN authorization. The cast guard therefore sits on
      the DB read inside `db_actions/2` alone — the only branch a CUSTOM
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
      the two predicates must never be "unified".
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
  alias Barkpark.Tenancy.{Membership, Role, RolePermission}

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
  def authorize(%ApiToken{} = token, workspace_id, action)
      when is_binary(workspace_id) and action in [:read, :write, :admin] do
    if member?(token, workspace_id) and permits?(token, action) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  # User principal: the GRANT is the membership ROLE (users carry no
  # permissions[] array). A non-member is denied; a member is allowed when its
  # role satisfies the action. Same chokepoint, same total contract as tokens.
  def authorize(%User{} = user, workspace_id, action)
      when is_binary(workspace_id) and action in [:read, :write, :admin] do
    case membership(user, workspace_id) do
      %Membership{role: role} ->
        if role_permits?(role, workspace_id, action), do: :ok, else: {:error, :forbidden}

      nil ->
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
  def authorize(%Barkpark.Content.CallerContext{} = ctx, workspace_id, action)
      when is_binary(workspace_id) and action in [:read, :write, :admin] do
    cond do
      membership_authorizes?(ctx, workspace_id, action) == :ok -> :ok
      grants_authorize?(ctx, workspace_id, action) -> :ok
      true -> {:error, :forbidden}
    end
  end

  def authorize(_token, _workspace_id, _action), do: {:error, :forbidden}

  # Reconstruct the bare principal from the ctx and run the EXISTING authorize
  # arms, so a folded member's decision is byte-identical to today.
  defp membership_authorizes?(%{principal_type: :user, user_id: uid}, workspace_id, action)
       when is_binary(uid),
       do: authorize(%User{id: uid}, workspace_id, action)

  defp membership_authorizes?(
         %{principal_type: :api_token, token_id: tid, roles: roles},
         workspace_id,
         action
       )
       when is_binary(tid) and is_list(roles),
       do: authorize(%ApiToken{id: tid, permissions: roles}, workspace_id, action)

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
  defp granted_actions(role, workspace_id) do
    case Map.get(@builtin_role_actions, role) do
      nil -> db_actions(role, workspace_id)
      builtin -> builtin
    end
  end

  # The ONLY id guard on the role path. `granted_actions/2` above answers for a
  # built-in role WITHOUT consulting the workspace id at all, so the guard
  # cannot sit any higher without flipping `role_permits?("admin", "", :admin)`
  # from true to false — a silent authorization TIGHTENING. Here, a malformed
  # workspace id yields no permission rows, i.e. a denial for a custom role.
  defp db_actions(role, workspace_id) do
    case Repo.uuid_or_nil(workspace_id) do
      nil ->
        []

      ws_uuid ->
        Repo.all(
          from rp in RolePermission,
            join: r in Role,
            on: rp.role_id == r.id,
            where:
              r.name == ^role and
                (r.workspace_id == ^ws_uuid or is_nil(r.workspace_id)),
            select: rp.action
        )
    end
  end

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

  # Roles that confer workspace-admin authority on a scoped surface.
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
  True when the token's membership ROLE in `workspace_id` confers admin
  authority (`owner` or `admin`). This is the per-membership admin gate: a
  `member` of B — even one holding global `admin` perms — is NOT a workspace
  admin of B. A non-member is never an admin.
  """
  # @canonical capability:workspace-admin-authority aka:is_admin,workspace_admin,mount_gate,scoped_admin doc:docs/contracts/tenancy.md
  @spec workspace_admin?(principal(), binary()) :: boolean()
  def workspace_admin?(token_or_principal_id, workspace_id) do
    membership_role(token_or_principal_id, workspace_id) in @admin_roles
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
    membership_role(principal_id, workspace_id, principal_kind) in @admin_roles
  end

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
end
