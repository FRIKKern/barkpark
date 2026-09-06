defmodule Barkpark.Tenancy.SeatCapabilitiesTest do
  @moduledoc """
  `Barkpark.Tenancy.Auth.seat_capabilities/3` — the arity
  `arpss-w10-bl-collapse-the-caps-fork-into-tenancy-auth` added so the Studio
  capability gate could stop recomposing the workspace-authorization decision
  out of `permits?/2` and `role_permits?/3`.

  ## What this file owns, and what it deliberately does not

  The DECISION-EQUIVALENCE oracle for this arity is the wave-10 parity table
  (`test/barkpark_web/live/studio/caps_authorization_parity_test.exs`): it drives
  every cell through `Caps.derive/1` and `Caps.admin?/1`, which is where this
  function is actually reached, and re-derives a DECLARED verdict against
  `authorize/3` and `workspace_admin?/2`. Repeating those cells here would be a
  second, weaker copy of a stronger test.

  What this file owns is the property that is NEW because the arity takes a
  PRELOADED ROW rather than loading one itself: **a row can only answer for the
  workspace it belongs to, AND for the principal it belongs to.** Every other
  predicate in `Tenancy.Auth` loads its own row from the (principal, workspace)
  pair and cannot be handed a foreign one; this one can, so it owes TWO
  bindings and each is a pattern rather than a sentence:

    * `%Membership{workspace_id: workspace_id}` bound to the `workspace_id`
      ARGUMENT — delete it and `a row loaded for ANOTHER workspace confers
      nothing` reds with an admit;
    * `principal_type` / `principal_id` bound to the PRINCIPAL argument —
      delete it and `a row belonging to ANOTHER PRINCIPAL confers nothing` reds
      with the other principal's seat.

  The second binding closes a hazard with NO reachable instance today: both
  live call sites zip correctly (`Caps.load_memberships/2` pairs each row with
  its principal, `admin?/1` loads per principal). It is here because the
  introducing caller holds a LIST of two principals' rows, and a transposition
  there would return the WRONG SEAT with no raise, no red and no log. Added on
  lead-studio-10's review of #16586. A test is the only thing that keeps a
  guarded-against-nothing binding alive through the next refactor.

  It also pins the D9/D22 conjunct that makes the `:admin` column neither
  canonical verbatim, and the fail-closed catch-all.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Accounts
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TAuth
  alias Barkpark.Tenancy.{Membership, Role, RolePermission}

  @dataset "production"
  @none %{read: false, write: false, admin: false}

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp workspace!(slug) do
    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: "#{slug}-#{System.unique_integer([:positive])}",
        name: slug
      })

    ws
  end

  defp user! do
    {:ok, user} =
      Accounts.register_user(%{
        email: "seat-caps-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp mint_token(perms),
    do:
      Barkpark.Auth.create_token(
        "seat-caps-token-#{System.unique_integer([:positive])}",
        "seat caps",
        @dataset,
        perms
      )

  # A CUSTOM role is only attachable when a `Tenancy.Role` row exists for the
  # workspace — `create_membership/4` validates against `valid_role_names/1`.
  defp custom_role!(ws_id, name, actions) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: name, workspace_id: ws_id}))

    Enum.each(actions, fn action ->
      {:ok, _} =
        Repo.insert(
          RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: action})
        )
    end)

    role
  end

  # `principal_type` is passed EXPLICITLY on every row: create_membership/4
  # defaults it to "api_token", and a mis-typed row makes a user assertion
  # vacuously green (no membership ever matches a %User{} principal).
  defp seat!(ws, %Accounts.User{} = user, role) do
    {:ok, membership} = TAuth.create_membership(ws.id, user.id, role, "user")
    assert membership.principal_type == "user"
    membership
  end

  defp seat!(ws, %Barkpark.Auth.ApiToken{} = token, role) do
    {:ok, membership} = TAuth.create_membership(ws.id, token.id, role, "api_token")
    membership
  end

  # ── THE PROPERTY THIS ARITY OWNS: the row must belong to THIS workspace ─────

  describe "a preloaded row answers only for its own workspace" do
    test "a row loaded for ANOTHER workspace confers nothing" do
      ws_a = workspace!("seat-a")
      ws_b = workspace!("seat-b")
      user = user!()

      # An OWNER seat in A. No row at all in B.
      row_a = seat!(ws_a, user, "owner")
      assert TAuth.seat_capabilities(user, row_a, ws_a.id).admin

      # The same row, asked about B. This is the misuse an arity that accepts a
      # caller-supplied row must refuse: without the workspace binding in the
      # clause heads it would answer with A's seat, i.e. hand an owner of A
      # every capability in B.
      assert TAuth.seat_capabilities(user, row_a, ws_b.id) == @none

      # And the canonical agrees about B, which is what makes the refusal
      # CORRECT rather than merely conservative.
      assert TAuth.authorize(user, ws_b.id, :read) == {:error, :forbidden}
      refute TAuth.workspace_admin?(user, ws_b.id)
    end

    test "a row belonging to ANOTHER PRINCIPAL confers nothing — both kinds, and crossed kinds" do
      ws = workspace!("seat-principal")
      owner = user!()
      bystander = user!()

      # OWNER seat for `owner`; `bystander` holds the weakest built-in seat in
      # the SAME workspace ("member" — the role enum is owner|admin|member), so
      # the two rows differ ONLY in whom they belong to.
      owner_row = seat!(ws, owner, "owner")
      bystander_row = seat!(ws, bystander, "member")

      # The control: each principal WITH ITS OWN ROW answers as itself, so a
      # denial below cannot be "this fixture confers nothing anyway".
      assert TAuth.seat_capabilities(owner, owner_row, ws.id).admin
      refute TAuth.seat_capabilities(bystander, bystander_row, ws.id).admin

      # THE TRANSPOSITION. Same workspace, right shapes, wrong pairing — the
      # exact slip a caller holding a LIST of principals and a LIST of rows can
      # make. Without the principal binding this answers with the OWNER's seat.
      assert TAuth.seat_capabilities(bystander, owner_row, ws.id) == @none
      assert TAuth.seat_capabilities(owner, bystander_row, ws.id) == @none

      # CROSSED KINDS: a token holding a USER's row, and a user holding a
      # TOKEN's row. `principal_type` refuses these even when the ids collide,
      # which is the reason the type is in the pattern and not just the id.
      {:ok, token} = mint_token(~w(read write admin))
      token_row = seat!(ws, token, "owner")

      assert TAuth.seat_capabilities(token, token_row, ws.id).admin
      assert TAuth.seat_capabilities(token, owner_row, ws.id) == @none
      assert TAuth.seat_capabilities(owner, token_row, ws.id) == @none
    end

    test "a HAND-BUILT %Membership{} naming ANOTHER principal confers nothing" do
      ws = workspace!("seat-fabricated-principal")
      user = user!()
      other = user!()

      # The workspace is real and matches, the role is real, the principal_type
      # is right — only the principal_id is somebody else's. This is the arm the
      # workspace binding alone cannot catch.
      row = %Membership{
        role: "owner",
        workspace_id: ws.id,
        principal_type: "user",
        principal_id: other.id
      }

      assert TAuth.seat_capabilities(user, row, ws.id) == @none

      # Positive control on the SAME struct shape: hand it its own principal and
      # it answers, so the denial above is the principal binding and not the
      # hand-built provenance.
      assert TAuth.seat_capabilities(other, row, ws.id).admin
    end

    test "a HAND-BUILT %Membership{} that names no workspace confers nothing" do
      ws = workspace!("seat-fabricated")
      user = user!()

      # The provenance hazard the role_permits?/3 call-site census exists to
      # police, in struct form: a built-in role name resolves TRUE
      # workspace-blind, so a fabricated row is the one way to reach that answer
      # without a membership load. The workspace binding refuses it.
      fabricated = %Membership{role: "admin", principal_type: "user", principal_id: user.id}

      assert TAuth.seat_capabilities(user, fabricated, ws.id) == @none

      assert TAuth.seat_capabilities(user, %Membership{fabricated | workspace_id: nil}, ws.id) ==
               @none
    end
  end

  # ── fail closed ─────────────────────────────────────────────────────────────

  describe "fail closed" do
    test "a nil membership (non-member) is nothing, for both principal kinds" do
      ws = workspace!("seat-nil")
      user = user!()
      {:ok, token} = mint_token(["admin"])

      assert TAuth.seat_capabilities(user, nil, ws.id) == @none
      assert TAuth.seat_capabilities(token, nil, ws.id) == @none
    end

    test "an unrecognised principal shape is nothing, even holding a real row" do
      ws = workspace!("seat-shape")
      user = user!()
      row = seat!(ws, user, "owner")

      for principal <- [%{foo: :bar}, nil, "a-bare-id", %Barkpark.Content.CallerContext{}] do
        assert TAuth.seat_capabilities(principal, row, ws.id) == @none
      end
    end

    test "a nil / malformed / non-binary workspace id is nothing, and never raises" do
      ws = workspace!("seat-malformed")
      user = user!()
      row = seat!(ws, user, "owner")

      for bad <- [nil, "", "not-a-uuid", 123, :atom] do
        assert TAuth.seat_capabilities(user, row, bad) == @none
      end
    end
  end

  # ── the :admin conjunct — charter D9 / D22 ──────────────────────────────────

  describe "the :admin column is the SEAT, for both principal kinds (D22)" do
    test "USER: the membership role's admin action, custom roles included" do
      ws = workspace!("seat-user-admin")

      member = user!()
      assert %{read: true, write: true, admin: false} = caps(member, ws, "member")

      admin = user!()
      assert %{read: true, write: true, admin: true} = caps(admin, ws, "admin")

      custom_role!(ws.id, "superviewer", ["read", "admin"])
      custom = user!()
      assert %{read: true, write: false, admin: true} = caps(custom, ws, "superviewer")
    end

    test "TOKEN: admin needs the PERMISSION and the SEAT — the D9 cell stays denied" do
      ws = workspace!("seat-token-admin")

      # A global-admin token holding a plain `member` row here. authorize/3
      # ADMITS (`member? AND permits?`); the seat rule DENIES. That divergence
      # is charter D9 and this arity must preserve it — it is cell
      # `token/foreign-member+perms[admin]` of the wave-10 parity table.
      {:ok, foreign} = mint_token(["admin"])
      foreign_row = seat!(ws, foreign, "member")

      assert TAuth.authorize(foreign, ws.id, :admin) == :ok
      assert TAuth.seat_capabilities(foreign, foreign_row, ws.id).admin == false

      # The mirror cell: an `admin` ROLE with read-only permissions. The token's
      # own permissions are the FIRST conjunct, so this denies too — and
      # workspace_admin?/2, which reads the role column only, admits.
      {:ok, readonly} = mint_token(["read"])
      readonly_row = seat!(ws, readonly, "admin")

      assert TAuth.workspace_admin?(readonly, ws.id)
      assert TAuth.seat_capabilities(readonly, readonly_row, ws.id).admin == false

      # The legitimate operator: admin perms AND an owner seat.
      {:ok, legit} = mint_token(["admin"])
      legit_row = seat!(ws, legit, "owner")
      assert TAuth.seat_capabilities(legit, legit_row, ws.id).admin
    end

    test "TOKEN read/write is the token's permissions, exactly as authorize/3 reads them" do
      ws = workspace!("seat-token-rw")
      {:ok, token} = mint_token(["read", "write"])
      row = seat!(ws, token, "member")

      assert TAuth.seat_capabilities(token, row, ws.id) == %{
               read: true,
               write: true,
               admin: false
             }

      for action <- [:read, :write] do
        assert TAuth.authorize(token, ws.id, action) == :ok
      end
    end
  end

  # ── the collapse's own claim: ONE resolution, three answers ─────────────────

  test "a CUSTOM role resolves ONCE — one Repo.all answers all three columns" do
    ws = workspace!("seat-one-resolution")
    custom_role!(ws.id, "tri", ["read", "write", "admin"])
    user = user!()
    row = seat!(ws, user, "tri")

    assert TAuth.seat_capabilities(user, row, ws.id) == %{read: true, write: true, admin: true}

    # THE COST HALF OF THE COLLAPSE. Three `role_permits?/3` calls over the same
    # row cost three `Repo.all`s; this arity costs one. The per-derive figures
    # this buys (custom-role derive 5 -> 3, event path 10 -> 6) are asserted in
    # test/barkpark_web/live/studio/pds_w43_caps_derive_cost_test.exs; the
    # decomposition is asserted HERE, at the arity that owns it.
    assert count_queries(fn -> TAuth.seat_capabilities(user, row, ws.id) end) == 1

    assert count_queries(fn ->
             for action <- [:read, :write, :admin],
                 do: TAuth.role_permits?(row.role, ws.id, action)
           end) == 3

    # A BUILT-IN role costs nothing either way — the compiled-in map answers
    # before any DB read, which is why only the custom rows moved.
    builtin = user!()
    builtin_row = seat!(ws, builtin, "member")
    assert count_queries(fn -> TAuth.seat_capabilities(builtin, builtin_row, ws.id) end) == 0
  end

  # Process-scoped Repo query counter. `:telemetry.attach/4` is NODE-global, so
  # the handler filters on `self() == owner` — an unscoped counter reads other
  # processes' queries (measured: 800 counted as 806).
  defp count_queries(fun) do
    counter = :counters.new(1, [:atomics])
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:barkpark, :repo, :query],
        fn _event, _measure, _meta, %{owner: owner, counter: counter} ->
          if self() == owner, do: :counters.add(counter, 1, 1)
        end,
        %{owner: owner, counter: counter}
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    :counters.get(counter, 1)
  end

  defp caps(user, ws, role) do
    row = seat!(ws, user, role)
    TAuth.seat_capabilities(user, row, ws.id)
  end
end
