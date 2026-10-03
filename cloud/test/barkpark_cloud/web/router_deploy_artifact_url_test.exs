defmodule BarkparkCloud.Web.RouterDeployArtifactUrlTest do
  @moduledoc """
  task-a21cac2c018f852e: `POST /v1/sites/:id/deploy` copied a client-supplied
  `artifact_url` into the deployment unchecked, and the builder on the team's
  box reads a `file://` URL as a local directory and builds it. Any team member
  could therefore bake `file:///opt/barkpark` or `file:///etc` from the box into
  an image. The route now accepts only an https artifact_url from a client;
  promote copies a stored value through `Registry`, so it keeps working.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  # A container site on a team box, deployed by a caller holding `role`.
  defp site_for(role) do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "X", slug: "x-#{n}"})
    {:ok, token} = Accounts.create_user_session_token(user)
    {site, token}
  end

  defp deploy(site, token, body) do
    conn(:post, "/v1/sites/#{site.id}/deploy", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp rows(site), do: Registry.list_deployments(site, 10, environment: "production")

  describe "a client-supplied artifact_url" do
    for url <- [
          "file:///etc",
          "file:///opt/barkpark",
          "file:///tmp/artifact.tar.gz",
          "http://10.0.0.1/a.tar.gz",
          "ftp://example.com/a.tar.gz",
          "https://",
          "/opt/barkpark"
        ] do
      test "#{url} is refused 422 and mints no row" do
        {site, token} = site_for("member")
        conn = deploy(site, token, %{git_ref: "main", artifact_url: unquote(url)})

        assert conn.status == 422
        body = Jason.decode!(conn.resp_body)
        assert body["error"] == "invalid"
        assert [_message] = body["details"]["artifact_url"]
        assert rows(site) == []
      end
    end

    test "a non-string artifact_url is refused 422" do
      {site, token} = site_for("owner")
      conn = deploy(site, token, %{artifact_url: %{"path" => "/etc"}})

      assert conn.status == 422
      assert rows(site) == []
    end

    test "an owner is refused a file:// artifact too; the rule is not role-gated" do
      {site, token} = site_for("owner")
      conn = deploy(site, token, %{artifact_url: "file:///opt/barkpark"})

      assert conn.status == 422
      assert rows(site) == []
    end

    test "an https artifact_url still queues a deployment" do
      {site, token} = site_for("member")
      url = "https://artifacts.example.com/site.tar.gz"
      conn = deploy(site, token, %{git_ref: "main", artifact_url: url})

      assert conn.status == 201
      assert Jason.decode!(conn.resp_body)["deployment"]["artifact_url"] == url
    end
  end

  describe "promote of a stored artifact" do
    test "still copies a stored file:// artifact_url (the refusal guards only the client door)" do
      {site, token} = site_for("owner")

      {:ok, source} =
        Registry.create_deployment(site, %{git_ref: "v1", artifact_url: "file:///tmp/v1.tar.gz"})

      {:ok, source} = Registry.transition_deployment(source, %{status: "live"})

      conn =
        conn(:post, "/v1/sites/#{site.id}/deployments/#{source.id}/promote", "{}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Router.call(@opts)

      assert conn.status == 201

      assert Jason.decode!(conn.resp_body)["deployment"]["artifact_url"] ==
               "file:///tmp/v1.tar.gz"
    end
  end
end
