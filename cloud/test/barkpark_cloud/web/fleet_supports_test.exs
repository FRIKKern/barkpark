defmodule BarkparkCloud.Web.FleetSupportsTest do
  @moduledoc """
  Personal Dev Fleet Wave C (PDF-D61) — the GROUP record. Exercises the three
  additive fleet columns end to end:

    * `Barkpark.fleet_changeset/2` — role inclusion + the parent invariant
      (required iff support, forbidden for main), including the REFUSAL cases.
    * `Registry.register_support_barkpark/2` — the transactional write + the
      self-FK guard.
    * `POST /v1/fleet/supports` — team-scoped create, cross-team parent refused,
      support-as-parent refused, auth gating.
    * `DELETE /v1/fleet/supports/:id` — support-only unbind, main/wrong-team
      refusals.
    * `GET /v1/barkparks` — the fleet fields are serialized.

  Mirrors RouterPatTest's DataCase + Plug.Test harness.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  # A user holding `role` in a fresh team, plus a live session token.
  # Returns {user, team, token}.
  defp user_with_role(role) do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  # A registered MAIN row (fleet_role stamped) — the intended FK target.
  defp main_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "Main #{n}", slug: "main-#{n}"}))

    {:ok, main} = bp |> Barkpark.fleet_changeset(%{fleet_role: "main"}) |> Repo.update()
    main
  end

  ## Request helper

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  ## Changeset invariants

  describe "Barkpark.fleet_changeset/2" do
    test "a support WITH a parent is valid" do
      cs =
        Barkpark.fleet_changeset(%Barkpark{}, %{
          fleet_role: "support",
          fleet_parent_id: Ecto.UUID.generate(),
          fleet_token_id: "tok_abc"
        })

      assert cs.valid?
    end

    test "a main WITHOUT a parent is valid" do
      cs = Barkpark.fleet_changeset(%Barkpark{}, %{fleet_role: "main"})
      assert cs.valid?
    end

    test "an unknown role is refused" do
      cs = Barkpark.fleet_changeset(%Barkpark{}, %{fleet_role: "worker"})
      refute cs.valid?
      assert %{fleet_role: ["is invalid"]} = errors_on(cs)
    end

    test "a support WITHOUT a parent is refused" do
      cs = Barkpark.fleet_changeset(%Barkpark{}, %{fleet_role: "support"})
      refute cs.valid?
      assert %{fleet_parent_id: ["is required for a support"]} = errors_on(cs)
    end

    test "a main WITH a parent is refused" do
      cs =
        Barkpark.fleet_changeset(%Barkpark{}, %{
          fleet_role: "main",
          fleet_parent_id: Ecto.UUID.generate()
        })

      refute cs.valid?
      assert %{fleet_parent_id: ["is forbidden for a main"]} = errors_on(cs)
    end

    test "a nil role (ungrouped) constrains neither parent — valid" do
      assert Barkpark.fleet_changeset(%Barkpark{}, %{}).valid?
      assert Barkpark.fleet_changeset(%Barkpark{}, %{fleet_token_id: "t"}).valid?
    end
  end

  ## Registry write + self-FK guard

  describe "Registry.register_support_barkpark/2" do
    test "creates a support row bound to the parent, carrying all three fleet fields" do
      team = team_fixture()
      main = main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Support A",
          slug: "support-a",
          host: "203.0.113.9",
          parent_id: main.id,
          token_id: "tok_opaque_1"
        })

      assert support.fleet_role == "support"
      assert support.fleet_parent_id == main.id
      assert support.fleet_token_id == "tok_opaque_1"
      assert support.team_id == team.id
      assert support.host == "203.0.113.9"
    end

    test "a parent id that names no row fails the self-FK — no orphan row is left" do
      team = team_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Registry.register_support_barkpark(team, %{
                 name: "Support Bogus",
                 slug: "support-bogus",
                 parent_id: Ecto.UUID.generate(),
                 token_id: "tok_x"
               })

      # The transaction rolled back — the base row was NOT left behind.
      refute Enum.any?(Registry.list_barkparks(team), &(&1.slug == "support-bogus"))
    end
  end

  ## POST /v1/fleet/supports

  describe "POST /v1/fleet/supports" do
    test "201 creates a support bound to an in-team main (session admin)" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      conn =
        call(
          :post,
          "/v1/fleet/supports",
          %{name: "Helper One", parent_id: main.id, host: "203.0.113.20", token_id: "tok_9"},
          token
        )

      assert conn.status == 201
      bp = decode(conn)["barkpark"]
      assert bp["fleet_role"] == "support"
      assert bp["fleet_parent_id"] == main.id
      assert bp["fleet_token_id"] == "tok_9"
      assert bp["team_id"] == team.id

      # The row is really persisted and bound.
      persisted = Registry.get_barkpark(bp["id"])
      assert persisted.fleet_parent_id == main.id
    end

    test "cross-team parent → 404 (no existence leak), nothing created" do
      {_u_a, _team_a, token_a} = user_with_role("owner")
      team_b = team_fixture()
      main_b = main_fixture(team_b)

      conn =
        call(:post, "/v1/fleet/supports", %{name: "Sneaky", parent_id: main_b.id}, token_a)

      assert conn.status == 404
      assert decode(conn)["error"] == "not_found"
    end

    test "a support cannot be a parent → 422 invalid_parent" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Existing Support",
          slug: "existing-support",
          parent_id: main.id,
          token_id: "t"
        })

      conn =
        call(:post, "/v1/fleet/supports", %{name: "Grandchild", parent_id: support.id}, token)

      assert conn.status == 422
      assert decode(conn)["error"] == "invalid_parent"
    end

    test "missing name → 422; missing parent_id → 422" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      no_name = call(:post, "/v1/fleet/supports", %{parent_id: main.id}, token)
      assert no_name.status == 422
      assert decode(no_name)["error"] == "invalid"

      no_parent = call(:post, "/v1/fleet/supports", %{name: "Orphan"}, token)
      assert no_parent.status == 422
      assert decode(no_parent)["error"] == "invalid"
    end

    test "a plain member is 403'd; no token is 401" do
      {_m, team_m, m_token} = user_with_role("member")
      main_m = main_fixture(team_m)

      denied = call(:post, "/v1/fleet/supports", %{name: "X", parent_id: main_m.id}, m_token)
      assert denied.status == 403
      assert decode(denied)["error"] == "forbidden"

      anon = call(:post, "/v1/fleet/supports", %{name: "X", parent_id: main_m.id})
      assert anon.status == 401
    end
  end

  ## DELETE /v1/fleet/supports/:id

  describe "DELETE /v1/fleet/supports/:id" do
    test "removes a support row → 200, the row is gone" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Doomed",
          slug: "doomed",
          parent_id: main.id,
          token_id: "t"
        })

      conn = call(:delete, "/v1/fleet/supports/#{support.id}", nil, token)

      assert conn.status == 200
      assert decode(conn)["status"] == "removed"
      assert Registry.get_barkpark(support.id) == nil
      # The main survives — only the support was unbound.
      assert Registry.get_barkpark(main.id) != nil
    end

    test "a main row is refused → 409 not_a_support, row kept" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      conn = call(:delete, "/v1/fleet/supports/#{main.id}", nil, token)

      assert conn.status == 409
      assert decode(conn)["error"] == "not_a_support"
      assert Registry.get_barkpark(main.id) != nil
    end

    test "wrong-team support → 404 (no existence leak), row untouched" do
      {_u_a, _team_a, token_a} = user_with_role("owner")
      team_b = team_fixture()
      main_b = main_fixture(team_b)

      {:ok, support_b} =
        Registry.register_support_barkpark(team_b, %{
          name: "Theirs",
          slug: "theirs",
          parent_id: main_b.id,
          token_id: "t"
        })

      conn = call(:delete, "/v1/fleet/supports/#{support_b.id}", nil, token_a)

      assert conn.status == 404
      assert Registry.get_barkpark(support_b.id) != nil
    end

    test "nonexistent / malformed id → 404" do
      {_u, _team, token} = user_with_role("owner")
      assert call(:delete, "/v1/fleet/supports/#{Ecto.UUID.generate()}", nil, token).status == 404
      assert call(:delete, "/v1/fleet/supports/not-a-uuid", nil, token).status == 404
    end
  end

  ## GET /v1/barkparks serialization

  describe "GET /v1/barkparks serializes the fleet fields" do
    test "a support row carries fleet_role / fleet_parent_id / fleet_token_id" do
      {_u, team, token} = user_with_role("owner")
      main = main_fixture(team)

      {:ok, support} =
        Registry.register_support_barkpark(team, %{
          name: "Listed Support",
          slug: "listed-support",
          parent_id: main.id,
          token_id: "tok_listed"
        })

      conn = call(:get, "/v1/barkparks", nil, token)
      assert conn.status == 200

      rows = decode(conn)["barkparks"]
      row = Enum.find(rows, &(&1["id"] == support.id))

      assert row["fleet_role"] == "support"
      assert row["fleet_parent_id"] == main.id
      assert row["fleet_token_id"] == "tok_listed"

      # The main serializes its role too, and carries no parent.
      main_row = Enum.find(rows, &(&1["id"] == main.id))
      assert main_row["fleet_role"] == "main"
      assert main_row["fleet_parent_id"] == nil
    end
  end
end
