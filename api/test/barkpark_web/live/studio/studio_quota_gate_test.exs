defmodule BarkparkWeb.Studio.StudioQuotaGateTest do
  @moduledoc """
  task-72437f78ef0d3184: Studio LiveView writes meet workspace suspension and
  the document quota, as the HTTP doors do (`RequireWithinQuota`). The gate is
  `BarkparkWeb.Studio.QuotaGate`, a `handle_event` hook attached after Caps.

  A `member` seat throughout, so Caps passes every write and only the quota
  gate can refuse; the last test swaps in a read-only seat to show an event
  Caps refuses never reaches the quota gate.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Accounts, Content, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Tenancy.{Quota, Role, RolePermission}

  @dataset "production"
  @type_name "quotanotice"
  @suspended "This workspace is suspended"
  @full "reached its document quota"

  setup do
    ws_id = TenancyFixtures.default_workspace_id!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Quota notice",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    %{ws_id: ws_id}
  end

  defp user_conn(conn, ws_id, role) do
    email = "quota-gate-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(conn, %{"user_session" => raw})
  end

  defp new_doc! do
    id = "quota-gate-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(@type_name, %{"doc_id" => id, "title" => "Before"}, @dataset)

    id
  end

  defp open(conn, id), do: live(conn, scoped_studio("/d/#{@dataset}/studio/#{@type_name}/#{id}"))

  defp snapshot(id) do
    %{
      draft: Content.get_document("drafts." <> id, @type_name, @dataset),
      published: Content.get_document(id, @type_name, @dataset),
      count: count(Barkpark.Content.Document),
      media: count(Barkpark.Media.Storage.MediaFile)
    }
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp fire(view, "save") do
    render_change(view, "autosave", %{"doc" => %{"title" => "After"}})
    render_click(view, "save")
  end

  defp fire(view, "new-document"), do: render_click(view, "new-document", %{"type" => @type_name})
  defp fire(view, "upload-image"), do: render_click(view, "upload-image", %{"field" => "image"})
  defp fire(view, event), do: render_click(view, event)

  defp suspend!(ws_id), do: {:ok, _} = Quota.suspend(Tenancy.get_workspace_by_id(ws_id), "test")

  defp fill!(ws_id) do
    ws = Tenancy.get_workspace_by_id(ws_id)
    {:ok, _} = Quota.set_quota(ws, Quota.usage(ws.id))
  end

  test "a normal workspace: save, publish and new-document write", %{conn: conn, ws_id: ws_id} do
    for event <- ~w(save publish new-document) do
      id = new_doc!()
      before = snapshot(id)
      {:ok, view, _} = open(user_conn(conn, ws_id, "member"), id)

      html = fire(view, event)

      refute html =~ @suspended or html =~ @full, event
      refute snapshot(id) == before, "#{event} wrote nothing"
    end
  end

  test "a suspended workspace: every write is refused with a flash and writes nothing",
       %{conn: conn, ws_id: ws_id} do
    ids = for _ <- 1..5, do: new_doc!()
    conn = user_conn(conn, ws_id, "member")
    suspend!(ws_id)

    for {event, id} <- Enum.zip(~w(save publish new-document duplicate-doc upload-image), ids) do
      before = snapshot(id)
      {:ok, view, _} = open(conn, id)

      html = fire(view, event)

      assert html =~ @suspended, event
      assert snapshot(id) == before, "#{event} wrote"
    end
  end

  test "a full workspace: adding is refused, editing and publishing are not",
       %{conn: conn, ws_id: ws_id} do
    ids = for _ <- 1..4, do: new_doc!()
    conn = user_conn(conn, ws_id, "member")
    fill!(ws_id)

    for {event, id} <- Enum.zip(~w(new-document duplicate-doc), ids) do
      before = snapshot(id)
      {:ok, view, _} = open(conn, id)
      assert fire(view, event) =~ @full, event
      assert snapshot(id) == before, "#{event} wrote"
    end

    for {event, id} <- Enum.zip(~w(save publish), Enum.drop(ids, 2)) do
      before = snapshot(id)
      {:ok, view, _} = open(conn, id)
      refute fire(view, event) =~ @full, event
      refute snapshot(id) == before, "#{event} wrote nothing"
    end
  end

  test "a suspension after mount refuses the next save", %{conn: conn, ws_id: ws_id} do
    id = new_doc!()
    {:ok, view, _} = open(user_conn(conn, ws_id, "member"), id)
    before = snapshot(id)

    suspend!(ws_id)

    assert fire(view, "save") =~ @suspended
    assert snapshot(id) == before
  end

  test "an event Caps refuses never reaches the quota gate", %{conn: conn, ws_id: ws_id} do
    role_name = "reader-#{System.unique_integer([:positive])}"
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: role_name, workspace_id: ws_id}))

    {:ok, _} =
      Repo.insert(
        RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: "read"})
      )

    id = new_doc!()
    conn = user_conn(conn, ws_id, role_name)
    suspend!(ws_id)
    {:ok, view, _} = open(conn, id)

    html = fire(view, "publish")

    assert html =~ "You don&#39;t have access to do that." or
             html =~ "You don't have access to do that."

    refute html =~ @suspended
  end
end
