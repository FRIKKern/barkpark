defmodule BarkparkCloud.Web.RouterTokenMintAuditTest do
  @moduledoc """
  ssw10-bl-token-mint-audit-requested-abilities — the `token.minted` audit row
  must record what was ISSUED, not what was ASKED FOR.

  `UserToken.normalize_abilities/1` is the server-side authority on ability
  EXCLUSIVITY: a mint requesting `["write", "deploy"]` stores `["deploy"]`. The
  route built its audit metadata from the raw request map a few lines BEFORE the
  changeset ran, so the issuance log — the one surface an incident review reads
  to answer "what was this credential allowed to do" — claimed a grant the
  credential never held.

  Two arms, and they fail for different reasons:

    * the COLLAPSING mint records the persisted list, and names the drop rather
      than absorbing it silently;
    * the ORDINARY mint is unchanged — no `requested_abilities` /
      `dropped_abilities` noise on a row where nothing was dropped.

  MUTATION (run before trusting the green): revert the `target_fun` metadata to
  `attrs.abilities` in `POST /v1/tokens` and the first test reds by name on the
  `["deploy"]` assertion; drop the `dropped == []` branch in
  `mint_audit_metadata/2` and the second reds by name on `refute Map.has_key?`.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp logged_in do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "mint-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, session} = Accounts.create_user_session_token(user)
    {user, team, session}
  end

  defp mint(session, body) do
    conn(:post, "/v1/tokens", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{session}")
    |> Router.call(@opts)
  end

  # The one `token.minted` row this team has.
  defp mint_event(team) do
    assert [event] =
             team
             |> Accounts.list_audit_events()
             |> Enum.filter(&(&1.action == "token.minted"))

    event
  end

  describe "token.minted metadata" do
    test "records the GRANTED abilities off the persisted row, not the requested ones" do
      {_user, team, session} = logged_in()

      conn = mint(session, %{name: "deploy-key", abilities: ["write", "deploy"]})
      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)

      # The credential itself: `deploy` is exclusive, so `write` never existed.
      assert body["pat"]["abilities"] == ["deploy"]

      event = mint_event(team)
      assert event.target_id == body["pat"]["id"]

      # THE ROW UNDER TEST. Before this slice it read ["write", "deploy"] — an
      # issuance record for a grant that was never made.
      assert event.metadata["abilities"] == ["deploy"]

      # And the collapse is NAMED, not silently absorbed.
      assert event.metadata["requested_abilities"] == ["write", "deploy"]
      assert event.metadata["dropped_abilities"] == ["write"]
    end

    test "`root` collapses the same way and the row says so" do
      {_user, team, session} = logged_in()

      conn = mint(session, %{name: "root-key", abilities: ["read", "root"]})
      assert conn.status == 201
      assert Jason.decode!(conn.resp_body)["pat"]["abilities"] == ["root"]

      event = mint_event(team)
      assert event.metadata["abilities"] == ["root"]
      assert event.metadata["dropped_abilities"] == ["read"]
    end

    test "an ordinary mint drops nothing and carries no drop keys" do
      {_user, team, session} = logged_in()

      conn = mint(session, %{name: "ro-key", abilities: ["read"]})
      assert conn.status == 201

      event = mint_event(team)
      assert event.metadata["name"] == "ro-key"
      assert event.metadata["abilities"] == ["read"]
      refute Map.has_key?(event.metadata, "requested_abilities")
      refute Map.has_key?(event.metadata, "dropped_abilities")
    end
  end
end
