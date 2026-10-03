defmodule BarkparkWeb.Studio.WriteGateGrantRefreshTest do
  @moduledoc """
  LiveScope's grant write-narrowing gate checked each mutating event against
  the grant set captured when the socket mounted. A revoke refreshes the
  socket's `:caller_context`, but the gate kept the old set, so a grantee whose
  broad write grant was revoked could still write anywhere that grant reached
  while a narrower write grant kept the socket write-capable
  (task-28649621c8cb03ae).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Access, Accounts, Content, Repo}
  alias Barkpark.Access.Grant

  @dataset "production"

  setup %{conn: conn} do
    ws = create_workspace!("wg-refresh-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "wg-refresh-proj")
    Barkpark.SharingFixtures.clear_shares!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp grantee_session(conn) do
    email = "wg-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  defp grant_authority!(ws) do
    {:ok, token} =
      %Barkpark.Auth.ApiToken{}
      |> Barkpark.Auth.ApiToken.changeset(%{
        token_hash: Barkpark.Auth.ApiToken.hash_token("wg-grantor-" <> Ecto.UUID.generate()),
        label: "wg-grantor",
        dataset: "test",
        permissions: ["read", "write", "admin"]
      })
      |> Repo.insert()

    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, token.id, "admin")
    token
  end

  defp bind_grant!(ws, user, grantor, overrides) do
    attrs =
      %{
        grantor_id: grantor.id,
        grantee_email: user.email,
        grantee_user_id: user.id,
        claimed_at: DateTime.utc_now(),
        workspace_id: ws.id,
        capabilities: ["read"],
        link_token_hash: "hash-" <> Ecto.UUID.generate()
      }
      |> Map.merge(overrides)

    {:ok, grant} = %Grant{} |> Grant.changeset(attrs) |> Repo.insert()
    grant
  end

  defp desk_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  test "a revoked project write grant no longer admits a create; a doc grant left behind cannot create",
       %{conn: conn, ws: ws, proj: proj} do
    {user, conn} = grantee_session(conn)
    grantor = grant_authority!(ws)

    # Mount admission: workspace-wide read.
    bind_grant!(ws, user, grantor, %{capabilities: ["read"]})
    # The broad write grant that will be revoked: project-wide write.
    broad =
      bind_grant!(ws, user, grantor, %{project_id: proj.id, capabilities: ["read", "write"]})

    # A narrow write grant that stays: one document. It keeps the socket
    # write-capable, but a doc grant can never create a new document.
    bind_grant!(ws, user, grantor, %{
      project_id: proj.id,
      dataset: @dataset,
      type: "post",
      doc_id: "kept-doc",
      capabilities: ["read", "write"]
    })

    {:ok, view, _html} = live(conn, desk_url(ws, proj))

    assert {:ok, _} = Access.revoke(broad.id, grantor)
    # The revoke broadcast is processed before the next event.
    _ = :sys.get_state(view.pid)

    before_count = Repo.aggregate(Content.Document, :count)
    _html = render_click(view, "new-document", %{"type" => "post"})

    assert Repo.aggregate(Content.Document, :count) == before_count
  end

  test "an unrevoked project write grant still creates (control)", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    {user, conn} = grantee_session(conn)
    grantor = grant_authority!(ws)

    bind_grant!(ws, user, grantor, %{capabilities: ["read"]})
    bind_grant!(ws, user, grantor, %{project_id: proj.id, capabilities: ["read", "write"]})

    {:ok, view, _html} = live(conn, desk_url(ws, proj))

    before_count = Repo.aggregate(Content.Document, :count)
    _html = render_click(view, "new-document", %{"type" => "post"})

    assert Repo.aggregate(Content.Document, :count) > before_count
  end
end
