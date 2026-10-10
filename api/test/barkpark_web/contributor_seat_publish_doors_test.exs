defmodule BarkparkWeb.ContributorSeatPublishDoorsTest do
  @moduledoc """
  A `contributor` seat writes drafts and cannot publish (owner decision
  2026-10-10, task-348a4fbe24feede6).

  Each publish-side door is tried twice: once with a contributor seat, which
  must be refused and leave the published side unchanged, and once with a
  `member` seat holding the SAME token permissions, which must succeed. The
  member run is the control: it proves the refusal comes from the seat role
  and not from the fixture.

  Doors: the HTTP mutate batch (`publish`, `unpublish`, `delete` of a published
  document; the bp CLI's `doc publish`/`unpublish`/`delete` send exactly these
  ops), a PAT whose owner holds the contributor seat, the Studio Publish
  button, and `GET /v1/auth/token`'s `seat.can.publish`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, Repo, TenancyFixtures}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @dataset "production"
  @type_name "notice"

  setup do
    ws_id = TenancyFixtures.default_workspace_id!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Notice",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    %{ws_id: ws_id}
  end

  # A write token whose seat in the Default workspace holds `role`.
  defp seated_token(ws_id, role) do
    raw = "contrib-#{role}-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "seat #{role}", @dataset, ["read", "write"], ws_id)
    set_role!(token.id, "api_token", ws_id, role)
    {raw, token}
  end

  defp set_role!(principal_id, type, ws_id, role) do
    Membership
    |> Repo.get_by!(principal_id: principal_id, principal_type: type, workspace_id: ws_id)
    |> Ecto.Changeset.change(role: role)
    |> Repo.update!()
  end

  defp mutate(raw, mutations) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp new_id, do: "contrib-doc-#{System.unique_integer([:positive])}"

  defp create_draft!(id) do
    {:ok, _} =
      Content.create_document(@type_name, %{"doc_id" => id, "title" => "Draft"}, @dataset)
  end

  defp create_published!(id) do
    create_draft!(id)
    {:ok, _} = Content.publish_document(id, @type_name, @dataset)
  end

  defp published?(id), do: match?({:ok, _}, Content.get_document(id, @type_name, @dataset))

  defp assert_refused(conn) do
    body = json_response(conn, 403)
    assert body["error"]["code"] == "forbidden"
    assert body["error"]["reason"] == "publish_not_permitted"
  end

  describe "HTTP mutate batch" do
    test "a contributor creates and edits a draft", %{ws_id: ws_id} do
      {raw, _} = seated_token(ws_id, "contributor")
      id = new_id()

      conn =
        mutate(raw, [
          %{"create" => %{"_id" => id, "_type" => @type_name, "title" => "One"}},
          %{"patch" => %{"id" => id, "type" => @type_name, "set" => %{"title" => "Two"}}}
        ])

      assert json_response(conn, 200)
      assert {:ok, draft} = Content.get_document("drafts." <> id, @type_name, @dataset)
      assert draft.title == "Two"
      refute published?(id)
    end

    test "publish: refused for a contributor, allowed for a member", %{ws_id: ws_id} do
      {contrib, _} = seated_token(ws_id, "contributor")
      {member, _} = seated_token(ws_id, "member")
      id = new_id()
      create_draft!(id)

      op = [%{"publish" => %{"id" => id, "type" => @type_name}}]

      assert_refused(mutate(contrib, op))
      refute published?(id)
      assert {:ok, _} = Content.get_document("drafts." <> id, @type_name, @dataset)

      assert json_response(mutate(member, op), 200)
      assert published?(id)
    end

    test "a publish op inside a batch with draft writes rolls the whole batch back",
         %{ws_id: ws_id} do
      {contrib, _} = seated_token(ws_id, "contributor")
      id = new_id()

      conn =
        mutate(contrib, [
          %{"create" => %{"_id" => id, "_type" => @type_name, "title" => "One"}},
          %{"publish" => %{"id" => id, "type" => @type_name}}
        ])

      assert_refused(conn)
      refute published?(id)
    end

    test "unpublish: refused for a contributor, allowed for a member", %{ws_id: ws_id} do
      {contrib, _} = seated_token(ws_id, "contributor")
      {member, _} = seated_token(ws_id, "member")
      id = new_id()
      create_published!(id)

      op = [%{"unpublish" => %{"id" => id, "type" => @type_name}}]

      assert_refused(mutate(contrib, op))
      assert published?(id)

      assert json_response(mutate(member, op), 200)
      refute published?(id)
    end

    test "delete of a published document: refused for a contributor, allowed for a member",
         %{ws_id: ws_id} do
      {contrib, _} = seated_token(ws_id, "contributor")
      {member, _} = seated_token(ws_id, "member")
      id = new_id()
      create_published!(id)

      op = [%{"delete" => %{"id" => id, "type" => @type_name}}]

      assert_refused(mutate(contrib, op))
      assert published?(id)

      assert json_response(mutate(member, op), 200)
      refute published?(id)
    end

    test "delete of a draft-only document is allowed for a contributor", %{ws_id: ws_id} do
      {contrib, _} = seated_token(ws_id, "contributor")
      id = new_id()
      create_draft!(id)

      assert json_response(
               mutate(contrib, [%{"delete" => %{"id" => id, "type" => @type_name}}]),
               200
             )

      assert {:error, :not_found} = Content.get_document("drafts." <> id, @type_name, @dataset)
    end

    test "a PAT whose owner holds a contributor seat cannot publish", %{ws_id: ws_id} do
      user =
        Barkpark.AccountsFixtures.register_user(
          "contrib-#{System.unique_integer([:positive])}@example.com"
        )

      {:ok, _} = TenancyAuth.create_membership(ws_id, user.id, "contributor", "user")

      raw = "contrib-pat-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "pat", @dataset, ["read", "write"], ws_id)

      token
      |> Ecto.Changeset.change(owner_user_id: user.id)
      |> Repo.update!()

      id = new_id()
      create_draft!(id)

      assert_refused(mutate(raw, [%{"publish" => %{"id" => id, "type" => @type_name}}]))
      refute published?(id)
    end
  end

  describe "Studio" do
    test "the Publish button is refused for a contributor", %{conn: conn, ws_id: ws_id} do
      {raw, _} = seated_token(ws_id, "contributor")
      id = new_id()
      create_draft!(id)

      conn = init_test_session(conn, %{"api_token" => raw})
      {:ok, view, _} = live(conn, scoped_studio("/d/#{@dataset}/studio/#{@type_name}/#{id}"))

      html = render_click(view, "publish")

      assert html =~ "cannot publish"
      refute published?(id)
    end

    test "the Publish button works for a member (control)", %{conn: conn, ws_id: ws_id} do
      {raw, _} = seated_token(ws_id, "member")
      id = new_id()
      create_draft!(id)

      conn = init_test_session(conn, %{"api_token" => raw})
      {:ok, view, _} = live(conn, scoped_studio("/d/#{@dataset}/studio/#{@type_name}/#{id}"))

      render_click(view, "publish")
      assert published?(id)
    end
  end

  describe "GET /v1/auth/token" do
    test "reports seat.can.publish false for a contributor, true for a member",
         %{ws_id: ws_id} do
      for {role, can_publish} <- [{"contributor", false}, {"member", true}] do
        {raw, _} = seated_token(ws_id, role)

        body =
          scoped_conn()
          |> put_req_header("authorization", "Bearer " <> raw)
          |> get("/v1/auth/token")
          |> json_response(200)

        assert body["seat"]["role"] == role
        assert body["seat"]["can"]["write"] == true
        assert body["seat"]["can"]["publish"] == can_publish
      end
    end
  end
end
