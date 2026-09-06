defmodule Barkpark.Tenancy.AuthTotalityTest do
  @moduledoc """
  TOTALITY of the tenant-authority chokepoint: `Barkpark.Tenancy.Auth`'s READ
  predicates must DENY on malformed or absent input, never raise.

  Before the `membership/2` normalisation seam, a `nil` or non-binary in either
  id position raised `FunctionClauseError` (HTTP 500 via Plug's `Any` fallback)
  and ANY non-castable binary — the empty string included — raised
  `Ecto.Query.CastError` (HTTP 400 via `phoenix_ecto`). Never `Ecto.CastError`:
  that module fires ZERO times on this path, so a test asserting it would be
  vacuous. Every rescue below therefore names `Ecto.Query.CastError`.

  Each malformed row is its OWN test so it reds INDIVIDUALLY under mutation
  (restore `auth.ex` to origin/main, keep this file). The CONTROL rows are
  green in BOTH runs — a matrix where every row reds is a blanket deny, not a
  totality proof.

  This file asserts NO new authorization semantics. Semantics-preserved lives
  in `test/barkpark/tenancy_auth_test.exs`, which this wave leaves BYTE-UNTOUCHED.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.CallerContext
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth
  alias Barkpark.Tenancy.Role
  alias Barkpark.Tenancy.RolePermission

  # ---------------------------------------------------------------------------
  # The public surface, pinned as {name, arity} TUPLES.
  #
  # Names alone would collapse this to 9 entries and silently accept an arity
  # change on `workspace_admin?` or a new `create_membership/5`:
  # `create_membership` is one 4-arity head with inline `\\` defaults, so it
  # exports arities 2, 3 AND 4. The module has no `use` macro (only
  # `import Ecto.Query, warn: false`), declares no behaviours and defines no
  # macros, so this literal is exactly the hand-written public set.
  # ---------------------------------------------------------------------------
  #
  # The four 3-arity entries are the EXPLICIT-KIND forms added by
  # `arpss-w10-bl-workspace-admin-bare-user-id-silent-false`: a raw id binary
  # cannot carry the `principal_type` discriminator, so the 2-arity raw-binary
  # path has to guess (it reads "api_token"), and these let a caller SAY which
  # kind it holds. This pin RED is what a new public arity is supposed to
  # produce — it was red on 15-vs-11 before this list was updated.
  #
  # `tier_of/1` is the GLOBAL AUTH TIER, moved here from
  # `Barkpark.Plugins.Capabilities.tier_for_token/1` (task-0cdfc8ce6e8d17c3):
  # the /v1/capabilities manifest used to carry its OWN `cond` over
  # `permits?/2`, so the tier advertised to every bp/MCP client and the tier the
  # request pipelines enforce were two hand-written ladders. It is a fold over
  # `permits?/2` and lives next to it; `tier_for_token/1` is now a one-line
  # `defdelegate`. It is NOT in `driven/2` and deliberately so — like
  # `role_permits?/3`, its argument is not a (principal id, workspace id) pair:
  # it takes a resolved `%ApiToken{}` or `nil`, produced ONLY by
  # `Barkpark.Auth.verify_token/1` via RequireToken/OptionalToken, so the
  # malformed-workspace-id matrix has nothing to say about it. `nil` is its own
  # first clause and answers the existence-hiding floor `"none"`. Its
  # manifest==pipeline equality is pinned by
  # `BarkparkWeb.Contract.CapabilitiesTierParityTest`.
  #
  # `seat_capabilities/3` is the SEAT DECISION off a PRELOADED `%Membership{}`
  # row, added by `arpss-w10-bl-collapse-the-caps-fork-into-tenancy-auth` so the
  # Studio capability gate stops recomposing the decision from `permits?/2` and
  # `role_permits?/3` while keeping its PDS-D634 one-load property. It is NOT in
  # `driven/2`, for `role_permits?/3`'s reason carried through the row: its
  # decision folds `permits?/2` (which takes no id) and the built-in role
  # resolver (workspace-id-INDEPENDENT by design), so a blanket
  # "malformed -> denial" row here would force the same authorization TIGHTENING
  # this file's anti-tightening lock forbids. Its own totality is pinned twice:
  # `seat_capabilities_test.exs` in this directory drives the malformed / nil /
  # foreign-row shapes directly, and the wave-10 parity table drives it
  # end-to-end through `Caps.derive/1` on the same shapes.
  #
  # `workspace_owner?/2` is the OWNER-ONLY SEAT added by
  # `arpss-w10-bl-chat-hosts-owner-literal-seat-fork`: chat-host enrollment
  # spelled its rule as a literal `membership_role(p, ws) == "owner"` in a
  # controller AND a LiveView, one rule in two places with nothing tying them
  # together. It is strictly narrower than `workspace_admin?/2` and can only
  # DENY where that admits. It is DRIVEN below — it takes a client-reachable
  # principal and workspace id, so the totality guarantee has to cover it.
  @public_surface [
    authorize: 3,
    authorize_with_reason: 3,
    create_membership: 2,
    create_membership: 3,
    create_membership: 4,
    list_workspaces_for: 1,
    member?: 2,
    member?: 3,
    membership: 2,
    membership: 3,
    membership_role: 2,
    membership_role: 3,
    permits?: 2,
    role_for_permissions: 1,
    role_permits?: 3,
    seat_capabilities: 3,
    tier_of: 1,
    valid_role_names: 1,
    workspace_admin?: 2,
    workspace_admin?: 3,
    workspace_owner?: 2
  ]

  # The DRIVEN subset — every entry point reachable from a request path with a
  # client-supplied id. Everything else is excluded ON PURPOSE:
  #
  #   * create_membership/2,3,4 and role_for_permissions/1 — WRITE constructors,
  #     deliberately LOUD. Three create_membership callers discard the return
  #     value, so a silent denial would provision a principal with no seat and
  #     report success; every caller derives its ids from a loaded row, so the
  #     crash is unreachable from client input.
  #   * permits?/2 — already total via its catch-all in auth.ex; it takes no id.
  #     Pinned as a control below rather than driven through the matrix.
  #   * valid_role_names/1 — the valid-role SET for a membership write, made
  #     public so `Barkpark.Scim` validates group role grants against the
  #     IDENTICAL set `create_membership/4` enforces
  #     (arpss-w10-bl-scim-set-member-role-unvalidated). A write-path helper
  #     like the constructors above, not a request-path predicate: every
  #     caller passes a workspace id derived from a loaded row, never client
  #     input, so LOUD on malformed input is the correct posture.
  #   * list_workspaces_for/1 — the INVERSE index (relocated here from
  #     Barkpark.Tenancy by task-e7571b83f9a101fd). It takes NO workspace id, so
  #     the malformed-workspace-id matrix below has no argument position to
  #     drive; its own totality (malformed PRINCIPAL id -> []) is pinned by
  #     test/barkpark/tenancy/list_workspaces_for_totality_test.exs, which also
  #     counts queries so the fail-open filter rewrite reds.
  #   * role_permits?/3 — SPLIT expectation, own dedicated test at the bottom.
  #     Its first argument is a ROLE NAME, not a principal id, and built-in
  #     roles are workspace-id-INDEPENDENT by design, so a blanket
  #     "malformed -> denial" row here would FORCE the exact authorization
  #     tightening this wave forbids.

  defp valid_uuid, do: Ecto.UUID.generate()

  # Every driven entry point paired with the denial value its own @spec declares.
  defp driven(principal, workspace_id) do
    [
      {"membership/2", fn -> Auth.membership(principal, workspace_id) end, nil},
      {"membership_role/2", fn -> Auth.membership_role(principal, workspace_id) end, nil},
      {"member?/2", fn -> Auth.member?(principal, workspace_id) end, false},
      {"workspace_admin?/2", fn -> Auth.workspace_admin?(principal, workspace_id) end, false},
      {"workspace_owner?/2", fn -> Auth.workspace_owner?(principal, workspace_id) end, false},
      {"authorize/3 :read", fn -> Auth.authorize(principal, workspace_id, :read) end,
       {:error, :forbidden}},
      {"authorize/3 :admin", fn -> Auth.authorize(principal, workspace_id, :admin) end,
       {:error, :forbidden}},
      # authorize_with_reason/3 is the arm-naming variant authorize/3 collapses.
      # It is driven here too: a reason-bearing denial must still be TOTAL, and
      # on malformed input NO arm applies — a malformed workspace id is not
      # evidence of non-membership, so the bare `:forbidden` is the honest
      # answer and the reason atoms must NOT leak into this matrix.
      {"authorize_with_reason/3 :read",
       fn -> Auth.authorize_with_reason(principal, workspace_id, :read) end,
       {:error, :forbidden}},
      {"authorize_with_reason/3 :admin",
       fn -> Auth.authorize_with_reason(principal, workspace_id, :admin) end,
       {:error, :forbidden}}
    ]
  end

  # Drives every entry point and asserts the spec'd denial value with NO raise.
  # A raise is converted into `{:raised, Module}` so the failure message NAMES
  # the exception module the mutation run reported.
  defp assert_denies(principal, workspace_id) do
    for {label, fun, expected} <- driven(principal, workspace_id) do
      actual =
        try do
          fun.()
        rescue
          e in FunctionClauseError -> {:raised, e.__struct__}
          e in Ecto.Query.CastError -> {:raised, e.__struct__}
        end

      assert actual == expected,
             "#{label} returned #{inspect(actual)} — expected the denial value #{inspect(expected)}"
    end
  end

  describe "public surface pin" do
    test "Auth exports exactly the 21 pinned {name, arity} tuples" do
      assert Enum.sort(Auth.__info__(:functions)) == Enum.sort(@public_surface)
    end
  end

  describe "malformed workspace id denies at every driven entry point" do
    test "nil workspace id" do
      assert_denies(valid_uuid(), nil)
    end

    test "non-binary workspace id" do
      assert_denies(valid_uuid(), 123)
    end

    test "empty-string workspace id" do
      assert_denies(valid_uuid(), "")
    end

    test "non-UUID workspace id" do
      assert_denies(valid_uuid(), "zzz")
    end

    test "16-byte non-UUID workspace id is a synthetic UUID that matches no row" do
      # Run-measured: on origin/main this RAISED Ecto.Query.CastError like any
      # other non-UUID string. After the seam, Ecto.UUID.cast/1 accepts any
      # 16-byte binary as raw UUID bytes, so it normalises to a well-formed
      # synthetic UUID, DOES reach the query, and denies by matching no row.
      # That is the one real WIDENING this seam admits — the raw 16 bytes of a
      # LIVE workspace id now resolve instead of crashing. No privilege is
      # gained (producing those bytes requires already holding the id); the
      # auth.ex moduledoc records it explicitly rather than smuggling it.
      assert_denies(valid_uuid(), "0123456789abcdef")
    end
  end

  describe "malformed principal denies at every driven entry point" do
    test "nil principal" do
      assert_denies(nil, valid_uuid())
    end

    test "non-binary principal" do
      assert_denies(:not_a_principal, valid_uuid())
    end

    test "non-UUID principal id" do
      assert_denies("zzz", valid_uuid())
    end

    test "%ApiToken{id: nil}" do
      assert_denies(%ApiToken{id: nil, permissions: ["admin"]}, valid_uuid())
    end

    test "%User{id: nil}" do
      assert_denies(%User{id: nil}, valid_uuid())
    end

    test "unrecognised principal struct (%CallerContext{}) denies at membership/2" do
      # The near-miss two prior share waves routed around. It must DENY at
      # membership/2 — never be unwrapped there. (authorize/3 has its own
      # CallerContext arm; that arm re-enters membership/2 with a reconstructed
      # bare principal and is unaffected by this row.)
      assert_denies(%CallerContext{}, valid_uuid())
    end
  end

  describe "controls — green BEFORE and AFTER the seam" do
    test "a valid UUID naming an unknown workspace denies without raising" do
      assert_denies(valid_uuid(), valid_uuid())
    end

    test "permits?/2 was already total and stays so" do
      refute Auth.permits?(nil, :admin)
      refute Auth.permits?(%ApiToken{permissions: nil}, :read)
      assert Auth.permits?(%ApiToken{permissions: ["admin"]}, :admin)
    end
  end

  describe "role_permits?/3 — SPLIT expectation, the anti-tightening lock" do
    test "a built-in role with an empty workspace id still permits (UNCHANGED)" do
      # A NEW PIN on EXISTING behaviour: green on origin/main too, and that is
      # correct. Built-in roles resolve from the compiled-in map BEFORE any DB
      # read, so a tenant cannot redefine `admin` to escalate. A cast guard
      # placed above that lookup would flip this true -> false — the silent
      # authorization TIGHTENING this wave forbids.
      assert Auth.role_permits?("admin", "", :admin)
      assert Auth.role_permits?("admin", "not-a-uuid", :admin)
      assert Auth.role_permits?("member", "", :read)
      assert Auth.role_permits?("owner", "", :write)
    end

    test "a CUSTOM role with a malformed workspace id denies instead of raising" do
      # The RED row: only a non-built-in name reaches db_actions/2, which is
      # where the cast guard sits. Before the guard this raised
      # Ecto.Query.CastError.
      actual =
        try do
          Auth.role_permits?("custom-x", "zzz", :admin)
        rescue
          e in Ecto.Query.CastError -> {:raised, e.__struct__}
        end

      assert actual == false, "expected a denial, got #{inspect(actual)}"
    end

    test "a CUSTOM role with a valid workspace id still resolves from the DB (UNCHANGED)" do
      # NOT a vacuous refute. `db_actions/2` is the one function the seam
      # rewrote on the role path: it now binds the CAST id (`^ws_uuid`) into
      # the query instead of the raw argument. A control that only asserts
      # `false` for a random UUID stays green even if that rebind broke the
      # match and the custom-role branch silently returned `[]` forever — a
      # SILENT AUTHORIZATION TIGHTENING with no red anywhere in this file.
      # So pin the POSITIVE direction: a real workspace-scoped role with real
      # `role_permissions` rows must still resolve THROUGH the rebound query.
      {:ok, ws} =
        Tenancy.create_workspace(%{
          slug: "auth-totality-#{System.unique_integer([:positive])}",
          name: "WS"
        })

      {:ok, role} =
        Repo.insert(Role.changeset(%Role{}, %{name: "totality-editor", workspace_id: ws.id}))

      for action <- ["read", "write"] do
        {:ok, _} =
          Repo.insert(
            RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: action})
          )
      end

      assert Auth.role_permits?("totality-editor", ws.id, :read)
      assert Auth.role_permits?("totality-editor", ws.id, :write)
      refute Auth.role_permits?("totality-editor", ws.id, :admin)

      # And the workspace scoping the rebind must not blur: the SAME custom
      # role name grants nothing in a workspace that did not define it.
      refute Auth.role_permits?("totality-editor", valid_uuid(), :read)

      # An unknown custom name still resolves to no rows.
      refute Auth.role_permits?("custom-x", ws.id, :admin)
    end
  end
end
