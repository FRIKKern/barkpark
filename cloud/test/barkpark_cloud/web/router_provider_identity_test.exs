defmodule BarkparkCloud.Web.RouterProviderIdentityTest do
  @moduledoc """
  `GET /v1/providers/:kind/identity` — WHICH cloud account a connection points
  at, for the CONNECTABLE kinds rather than the CATALOG kinds (charter D899,
  row `cch-bl-cloudflare-identity-echo-no-surface`).

  The row this closes was filed UNBUILDABLE for two reasons, and this route is
  the answer to the first: `cloudflare` is connectable but is not in
  `@neutral_kinds`, so `with_provider_catalog/3` 404s it before any identity
  clause can run. A second route that gates on `@connectable_kinds` and makes
  ZERO upstream calls makes the cloudflare echo a served fact instead of dead
  code.

  What the arms hold, each stated so it can LOSE:

    * the echo EXISTS — a stored `account_id` comes back on the wire;
    * absence is STATED, never inferred — the `identity` key is ALWAYS present
      and an unknown account is `value: nil` + a reason sentence, never `""`,
      never an omitted key a client would paint as a known blank;
    * the read costs NOTHING upstream — the Cloudflare fake's verify log is
      empty afterwards, with a positive control proving that log can record;
    * the credential never rides along — `api_token` is absent from the body;
    * the kind gate discriminates — a non-connectable kind 404s while
      cloudflare, on the very same route, does not.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Cloudflare, Registry}
  alias BarkparkCloud.Cloudflare.Fake
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @api_token "cf-token-never-echoed"
  @account_id "a1b2c3d4e5f60718293a4b5c6d7e8f90"

  ## Fixtures

  defp user_with_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "ident-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp get(path, token) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp identity_of(conn), do: json_body(conn)["provider"]["identity"]

  defp connect_cloudflare_blob(team, blob),
    do: Registry.connect_provider(team, "cloudflare", Jason.encode!(blob), label: "cf")

  ## The echo

  describe "cloudflare identity echo" do
    test "a stored account_id is named on the wire" do
      {user, team} = user_with_team()

      {:ok, _} =
        connect_cloudflare_blob(team, %{"api_token" => @api_token, "account_id" => @account_id})

      conn = get("/v1/providers/cloudflare/identity", session_token(user))

      assert conn.status == 200

      assert identity_of(conn) == %{
               "label" => "Account",
               "value" => @account_id,
               "source" => "stored",
               "reason" => nil
             }
    end

    test "the echo is marked STORED, never verified — the client must not call it confirmed" do
      {user, team} = user_with_team()

      {:ok, _} =
        connect_cloudflare_blob(team, %{"api_token" => @api_token, "account_id" => @account_id})

      conn = get("/v1/providers/cloudflare/identity", session_token(user))

      assert identity_of(conn)["source"] == "stored"
      refute conn.resp_body =~ "verified"
      refute conn.resp_body =~ "confirmed"
    end

    test "the response never carries the credential" do
      {user, team} = user_with_team()

      {:ok, _} =
        connect_cloudflare_blob(team, %{"api_token" => @api_token, "account_id" => @account_id})

      conn = get("/v1/providers/cloudflare/identity", session_token(user))

      refute conn.resp_body =~ @api_token
      refute conn.resp_body =~ "api_token"
      # CONTROL: the assertion above is not vacuous — the body IS non-empty and
      # DOES carry the thing we asked for.
      assert identity_of(conn)["value"] == @account_id
    end
  end

  ## Absence is STATED, never inferred

  describe "absence" do
    test "a blob with no account_id says so explicitly — key present, value nil, reason given" do
      {user, team} = user_with_team()
      {:ok, _} = connect_cloudflare_blob(team, %{"api_token" => @api_token})

      conn = get("/v1/providers/cloudflare/identity", session_token(user))

      assert conn.status == 200
      identity = identity_of(conn)

      # The KEY is present. An omitted key is the failure this arm exists for.
      assert Map.has_key?(json_body(conn)["provider"], "identity")
      assert identity["label"] == "Account"
      # Explicitly nil — NOT "" and NOT a missing key.
      assert Map.has_key?(identity, "value")
      assert is_nil(identity["value"])
      refute identity["value"] == ""
      assert identity["source"] == "unavailable"
      assert is_binary(identity["reason"]) and String.trim(identity["reason"]) != ""
      assert identity["reason"] =~ "account ID"
    end

    test "a bare API token names no account, and the reason says which shape was stored" do
      {user, team} = user_with_team()
      {:ok, _} = Registry.connect_provider(team, "cloudflare", @api_token, label: "cf-bare")

      conn = get("/v1/providers/cloudflare/identity", session_token(user))

      assert conn.status == 200
      identity = identity_of(conn)
      assert is_nil(identity["value"])
      assert identity["source"] == "unavailable"
      assert identity["reason"] =~ "bare API token"
      # The two absences are DIFFERENT sentences: a bare token and a blob that
      # simply omitted the field are not the same fact.
      refute identity["reason"] =~ "didn't store an account ID"
    end
  end

  ## The read costs nothing upstream

  describe "no upstream call" do
    test "reading the identity does not touch Cloudflare, and the call log CAN record" do
      {user, team} = user_with_team()

      {:ok, _} =
        connect_cloudflare_blob(team, %{"api_token" => @api_token, "account_id" => @account_id})

      # PRECONDITION: the log starts empty in this process.
      assert Fake.verified() == []

      conn = get("/v1/providers/cloudflare/identity", session_token(user))
      assert conn.status == 200

      # The measurement.
      assert Fake.verified() == []
      assert Fake.records() == []

      # POSITIVE CONTROL — a log that is empty because it cannot record proves
      # nothing. One real call through the same fake, in the same process, and
      # the log is no longer empty.
      assert {:ok, %{status: _}} = Cloudflare.verify_token(@api_token)
      assert [%{token: @api_token}] = Fake.verified()
    end
  end

  ## The kind gate

  describe "kind gate" do
    test "a non-connectable kind 404s while cloudflare, on the same route, does not" do
      {user, team} = user_with_team()

      {:ok, _} =
        connect_cloudflare_blob(team, %{"api_token" => @api_token, "account_id" => @account_id})

      token = session_token(user)

      unknown = get("/v1/providers/digitalocean/identity", token)
      assert unknown.status == 404
      assert json_body(unknown) == %{"error" => "unknown_kind"}

      # CONTROL: the gate is not 404ing everything.
      assert get("/v1/providers/cloudflare/identity", token).status == 200
    end

    test "a connectable kind with nothing connected is no_provider, not unknown_kind" do
      {user, _team} = user_with_team()

      conn = get("/v1/providers/cloudflare/identity", session_token(user))

      assert conn.status == 404
      assert json_body(conn) == %{"error" => "no_provider"}
    end

    test "an unauthenticated read is refused" do
      conn = Router.call(conn(:get, "/v1/providers/cloudflare/identity"), @opts)
      assert conn.status == 401
    end
  end

  ## The other two connectable kinds keep their wave-13 contract

  describe "the connectable set, not the catalog set" do
    test "azure echoes its stored subscription id through the new route" do
      {user, team} = user_with_team()

      blob = %{
        "tenant_id" => "11111111-1111-1111-1111-111111111111",
        "client_id" => "22222222-2222-2222-2222-222222222222",
        "client_secret" => "good-secret",
        "subscription_id" => "33333333-3333-3333-3333-333333333333"
      }

      {:ok, _} = Registry.connect_provider(team, "azure", Jason.encode!(blob), label: "az")

      identity = identity_of(get("/v1/providers/azure/identity", session_token(user)))

      assert identity["label"] == "Subscription"
      assert identity["value"] == "33333333-3333-3333-3333-333333333333"
      assert identity["source"] == "stored"
    end

    test "hetzner states its absence rather than guessing a project" do
      {user, team} = user_with_team()
      {:ok, _} = Registry.connect_provider(team, "hetzner", "hz-token", label: "hz")

      identity = identity_of(get("/v1/providers/hetzner/identity", session_token(user)))

      assert identity["label"] == "Project"
      assert is_nil(identity["value"])
      assert identity["source"] == "unavailable"
      assert identity["reason"] =~ "doesn't report which project"
    end
  end
end
