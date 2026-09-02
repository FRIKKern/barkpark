defmodule BarkparkWeb.Studio.CapsNonUuidWorkspaceDeniesTest do
  @moduledoc """
  task-cd491bf64265ba6b + arpss-w8 — the RUN-PROOF behind two corrected doc
  claims, in the one file because they are two halves of the same fact.

  THE CLAIM UNDER TEST. `BarkparkWeb.Studio.Caps.load_memberships/2` is guarded
  by `is_binary(ws_id)` — a SHAPE guard, not a UUID guard. Its comment used to
  say it "Mirrors `authorize/3`'s own totality", a property inherited rather
  than proved. A non-UUID BINARY workspace id (`""`, `"not-a-uuid"`) therefore
  passes that guard and reaches `Tenancy.Auth.membership/2` for real.

  WHAT ACTUALLY HAPPENS, AND WHOSE GUARANTEE IT IS. It DENIES rather than
  raising — but the guarantee belongs to the CHOKEPOINT, not to the caps
  clause. `Tenancy.Auth.membership/3` runs BOTH ids through
  `Barkpark.Repo.uuid_or_nil/1` and answers `nil` on a cast failure, so nothing
  malformed is ever bound to a `:binary_id` column. This file proves BOTH
  directions, because a denial on its own does not say why:

    * `denies` — the public `Caps.derive/1` path, on every non-UUID binary
      shape, for a USER and for an API-TOKEN principal, answers all-false and
      does not raise.
    * `would raise without it` — the SAME bad value bound directly into a
      `Repo.one` over the SAME column raises `%Ecto.Query.CastError{}`. That is
      the raise the chokepoint prevents, and it is the struct
      `Barkpark.Repo.uuid_or_nil/1`'s docstring names (arpss-w8 corrected it
      from `Ecto.CastError`, a DIFFERENT struct — an `assert_raise
      Ecto.CastError` written from the old wording could never match, which is
      why the name is load-bearing and not cosmetic).

  Without the second test the first is a denial that could equally mean "the
  bad id never reached the DB at all", which is exactly the unproved totality
  the comment used to assert.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Tenancy.Membership
  alias Barkpark.{Accounts, Auth, Repo, Tenancy}
  alias BarkparkWeb.Studio.Caps

  @dataset "production"

  # Every binary that passes `is_binary/1` and fails `Ecto.UUID.cast/1`. The
  # empty string is listed FIRST because it is the shape a nil-ish assign
  # degrades into, and the one the old comment's "unresolved workspace" wording
  # implicitly claimed was handled by the `[]` clause. It is not — it is
  # handled downstream.
  @non_uuid_ws_ids ["", "not-a-uuid", "  ", "0", "11111111-1111-1111-1111-11111111111", "null"]

  setup do
    {ws, proj} = ensure_default_scope!()
    {:ok, ws: ws, proj: proj}
  end

  defp socket(bad_ws_id, proj, assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            # A workspace MAP whose id is a malformed binary — `derive/1` reads
            # `ws && Map.get(ws, :id)`, so this is exactly what a stale or
            # hand-forged mount hands it.
            current_workspace: %{id: bad_ws_id},
            current_project: proj,
            dataset: @dataset,
            api_token: nil,
            current_user: nil
          },
          assigns
        )
    }
  end

  defp real_user(ws) do
    email = "caps-nonuuid-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    # An OWNER membership in the REAL workspace: the principal is maximally
    # privileged somewhere, so an all-false answer below is the malformed
    # workspace id denying, not a principal with nothing to lose.
    {:ok, m} = Tenancy.Auth.create_membership(ws.id, user.id, "owner", "user")
    assert m.role == "owner"
    assert m.principal_type == "user"
    user
  end

  defp real_token(ws) do
    raw = "caps-nonuuid-token-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "caps non-uuid", @dataset, ["read", "write", "admin"])

    # `Auth.create_token/4` ALREADY mints the workspace membership, so a second
    # `Tenancy.Auth.create_membership/4` here trips
    # `workspace_memberships_principal_unique_idx`. Read the row back rather
    # than assume it: an absent or mis-typed membership would make every
    # denial below vacuously green.
    m = Tenancy.Auth.membership(token, ws.id)
    assert m.role in ["owner", "admin"]
    assert m.principal_type == "api_token"
    token
  end

  # ── NON-VACUITY: the same principals answer TRUE on the real workspace ──────

  test "CONTROL — both principals are genuinely privileged on the REAL workspace id",
       %{ws: ws, proj: proj} do
    user = real_user(ws)
    token = real_token(ws)

    assert Caps.derive(socket(ws.id, proj, %{current_user: user})) ==
             %{read: true, write: true, admin: true}

    assert Caps.derive(socket(ws.id, proj, %{api_token: token})) ==
             %{read: true, write: true, admin: true}
  end

  # ── THE DENIAL ──────────────────────────────────────────────────────────────

  test "a non-UUID binary ws_id DENIES (never raises) — USER principal",
       %{ws: ws, proj: proj} do
    user = real_user(ws)

    for bad <- @non_uuid_ws_ids do
      assert Caps.derive(socket(bad, proj, %{current_user: user})) ==
               %{read: false, write: false, admin: false},
             "Caps.derive/1 did not deny for ws_id #{inspect(bad)}"
    end
  end

  test "a non-UUID binary ws_id DENIES (never raises) — API-TOKEN principal",
       %{ws: ws, proj: proj} do
    token = real_token(ws)

    for bad <- @non_uuid_ws_ids do
      assert Caps.derive(socket(bad, proj, %{api_token: token})) ==
               %{read: false, write: false, admin: false},
             "Caps.derive/1 did not deny for ws_id #{inspect(bad)}"
    end
  end

  test "the bad id REACHES the chokepoint and is denied THERE, not filtered out earlier",
       %{ws: ws, proj: proj} do
    user = real_user(ws)

    # Same seam `load_memberships/2` calls, called directly: a real principal
    # struct + a malformed workspace id answers nil rather than raising. This
    # is the sentence the caps.ex comment now makes — the guarantee is
    # `membership/3`'s `Repo.uuid_or_nil/1` pair, not the `is_binary/1` guard.
    for bad <- @non_uuid_ws_ids do
      assert Tenancy.Auth.membership(user, bad) == nil
    end

    # And the caps clause's own `[]` arm still covers the NON-binary shapes.
    assert Caps.derive(socket(nil, proj, %{current_user: user})) ==
             %{read: false, write: false, admin: false}
  end

  # ── THE RAISE THE CHOKEPOINT PREVENTS (arpss-w8: the struct's NAME) ─────────

  test "an UNGUARDED bind of the same value raises Ecto.Query.CastError, NOT Ecto.CastError" do
    bad = "not-a-uuid"

    # `Repo.uuid_or_nil/1` returns nil for this value, which is why the guarded
    # path above never gets here.
    assert Repo.uuid_or_nil(bad) == nil

    # Bind it anyway, to the same `:binary_id` column `Tenancy.Auth.membership/3`
    # binds, and name the struct that comes back.
    err =
      assert_raise Ecto.Query.CastError, fn ->
        Repo.one(from m in Membership, where: m.workspace_id == ^bad)
      end

    assert err.__struct__ == Ecto.Query.CastError
    # `:binary_id` is the COLUMN type Ecto could not cast into — measured, not
    # assumed (a first draft of this line guessed `Ecto.UUID` and was wrong).
    assert err.type == :binary_id

    # THE PART THAT MADE THE DOC DEFECT MATTER: the struct the old docstring
    # named is a DIFFERENT module, so an assertion written from it could never
    # have matched the raise above.
    refute err.__struct__ == Ecto.CastError
    refute Ecto.Query.CastError == Ecto.CastError

    IO.puts("\n  arpss-w8 RUN-PROOF — struct raised: #{inspect(err.__struct__)}")
  end
end
