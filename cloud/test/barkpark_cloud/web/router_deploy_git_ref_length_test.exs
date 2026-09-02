defmodule BarkparkCloud.Web.RouterDeployGitRefLengthTest do
  @moduledoc """
  cch-w34: `deployments.git_ref` is `varchar(255)` and the create changesets
  cast it with no `validate_length`. So a ref longer than 255 characters was
  refused by POSTGRES, not by the changeset — `Postgrex` 22001
  ("value too long for type character varying(255)") RAISED out of the INSERT,
  through `Plug.ErrorHandler`, as a 500 `server_error`. A caller who sent a bad
  string got a server fault instead of "you sent a bad string".

  This file pins the write-path contract on BOTH arms:

    * THE REAL ROUTE — `POST /v1/sites/:id/deploy` with a >255-character
      `git_ref` answers 4xx with the field named in a readable message, and
      mints NO row.
    * THE CHANGESET — `Deployment.changeset/2` and `Deployment.preview_changeset/2`
      (an INDEPENDENT fork, not a delegation) each return the error, 255 exactly
      still passes, and an UPDATE that does not touch `git_ref` is untouched by
      the new validation — the check is on the CHANGE, so no stored row can be
      invalidated by it.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # The column's ceiling, and one character past it. Derived from the schema's
  # own constant so the test cannot drift from what the changeset enforces.
  @max_length Deployment.git_ref_max_length()
  @max_ref String.duplicate("a", @max_length)
  @over_ref String.duplicate("a", @max_length + 1)
  # Comfortably past it too — the filing's own shape (a pathological ref, not an
  # off-by-one).
  @way_over_ref String.duplicate("b", 300)

  ## Fixtures (the router_sites_test.exs pattern)

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # A deployable container site: an uploaded artifact is the build source, so the
  # route reaches `Registry.create_deployment/2` instead of short-circuiting on
  # `no_build_source`.
  defp deployable_site do
    {user, team} = user_with_team()
    bp = barkpark_fixture(team)

    {:ok, site} =
      Registry.create_site(bp, %{name: "X", slug: "x-#{System.unique_integer([:positive])}"})

    {site, login_token(user)}
  end

  ## The real creation route

  describe "POST /v1/sites/:id/deploy with an over-long git_ref" do
    test "answers 422 with a readable git_ref message, never a 500" do
      {site, token} = deployable_site()

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{git_ref: @way_over_ref, artifact_url: "file:///tmp/artifact.tar.gz"},
          token
        )

      assert conn.status == 422,
             "an over-long git_ref must be a client error, got #{conn.status}"

      body = json_body(conn)
      assert body["error"] == "invalid"

      assert ["should be at most 255 character(s)"] = body["details"]["git_ref"],
             "the message must name the ceiling: #{inspect(body["details"])}"

      # Nothing was minted — the refusal is BEFORE the INSERT.
      assert Registry.list_deployments(site, 10, environment: "production") == []
    end

    test "one character over the ceiling is refused too — the boundary, not just the extreme" do
      {site, token} = deployable_site()

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{git_ref: @over_ref, artifact_url: "file:///tmp/artifact.tar.gz"},
          token
        )

      assert conn.status == 422
      assert json_body(conn)["details"]["git_ref"] == ["should be at most 255 character(s)"]
    end

    test "exactly at the ceiling still deploys — only what the column cannot hold is refused" do
      {site, token} = deployable_site()

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{git_ref: @max_ref, artifact_url: "file:///tmp/artifact.tar.gz"},
          token
        )

      assert conn.status == 201
      assert json_body(conn)["deployment"]["git_ref"] == @max_ref
    end
  end

  ## The changesets themselves

  describe "Deployment.changeset/2" do
    test "the enforced ceiling IS the column width" do
      assert @max_length == 255
    end

    test "an over-long git_ref is a changeset error, not a raise" do
      cs =
        Deployment.changeset(%Deployment{}, %{site_id: Ecto.UUID.generate(), git_ref: @over_ref})

      refute cs.valid?
      assert {"should be at most %{count} character(s)", opts} = cs.errors[:git_ref]
      assert opts[:count] == 255
      assert opts[:validation] == :length
    end

    test "255 characters is valid" do
      cs =
        Deployment.changeset(%Deployment{}, %{site_id: Ecto.UUID.generate(), git_ref: @max_ref})

      assert cs.valid?
    end
  end

  describe "Deployment.preview_changeset/2" do
    test "an over-long git_ref is a changeset error on the preview fork too" do
      attrs = %{
        site_id: Ecto.UUID.generate(),
        branch: "feature",
        preview_slug: "slug",
        preview_host: "slug.example.com",
        environment: "preview",
        git_ref: @over_ref
      }

      cs = Deployment.preview_changeset(%Deployment{}, attrs)

      refute cs.valid?
      assert {"should be at most %{count} character(s)", opts} = cs.errors[:git_ref]
      assert opts[:count] == 255
    end

    test "255 characters is valid on the preview fork" do
      attrs = %{
        site_id: Ecto.UUID.generate(),
        branch: "feature",
        preview_slug: "slug",
        preview_host: "slug.example.com",
        environment: "preview",
        git_ref: @max_ref
      }

      assert Deployment.preview_changeset(%Deployment{}, attrs).valid?
    end
  end

  ## Existing rows (criterion 3): the check is on the CHANGE

  describe "stored rows" do
    test "an update that does not touch git_ref is unaffected by the new validation" do
      {site, _token} = deployable_site()
      {:ok, stored} = Registry.create_deployment(site, %{git_ref: @max_ref})

      # The exact shape `Sites.Deploy.store_artifact/3` uses: `changeset/2` on an
      # ALREADY-INSERTED row, stamping one unrelated field. `git_ref` is not in
      # `attrs`, so it is not a change, so `validate_length` never looks at it —
      # a stored row can never be invalidated after the fact.
      cs = Deployment.changeset(stored, %{artifact_sha256: String.duplicate("0", 64)})

      assert cs.valid?
      assert cs.errors[:git_ref] == nil
      assert {:ok, updated} = BarkparkCloud.Repo.update(cs)
      assert updated.git_ref == @max_ref
    end
  end
end
