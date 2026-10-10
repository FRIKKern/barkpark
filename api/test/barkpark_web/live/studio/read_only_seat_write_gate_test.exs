defmodule BarkparkWeb.Studio.ReadOnlySeatWriteGateTest do
  @moduledoc """
  task-409b3ba56ca96471 (P1): a Studio seat whose role grants `read` but not
  `write` must be refused every LiveView write, as the API refuses it.

  The gate is `BarkparkWeb.Studio.Caps.attach/1`: one `handle_event` hook,
  armed in StudioLive's mount, that classifies each event (`Caps.classify/1`)
  and asks the seat's actions (`Caps.write_capable?/2` over
  `Tenancy.Auth.seat_capabilities/3`). The debounced autosave door asks the
  same predicate. Each write event is fired by a read-only CUSTOM role
  (refused, nothing changes) and by a `member` (the change lands), so no
  negative here passes for want of a write.

  Mutation (run by hand): with the `:write` arm of `Caps.gate/3` forced to
  `:cont`, the publish, unpublish, delete, discard and duplicate negatives
  fail; autosave/save stay refused by the same predicate at the debounced
  write door.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Accounts, Content, Repo, TenancyFixtures}
  alias Barkpark.Tenancy.{Role, RolePermission}

  @dataset "production"
  @type_name "rosnotice"

  setup do
    ws_id = TenancyFixtures.default_workspace_id!()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "RO notice",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    role_name = "reader-#{System.unique_integer([:positive])}"
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: role_name, workspace_id: ws_id}))

    {:ok, _} =
      Repo.insert(
        RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: "read"})
      )

    %{ws_id: ws_id, reader_role: role_name}
  end

  defp user_conn(conn, ws_id, role) do
    email = "ro-gate-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(conn, %{"user_session" => raw})
  end

  # `false`: a draft only. `true`: published. `:edited`: published with a
  # newer draft on top (what discard throws away).
  defp new_doc!(shape \\ false) do
    id = "ro-gate-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(@type_name, %{"doc_id" => id, "title" => "Before"}, @dataset)

    if shape in [true, :edited] do
      {:ok, _} = Content.publish_document(id, @type_name, @dataset)
    end

    if shape == :edited do
      {:ok, _} =
        Content.upsert_document(@type_name, %{"doc_id" => id, "title" => "Edit"}, @dataset)
    end

    id
  end

  defp open(conn, id),
    do: live(conn, scoped_studio("/d/#{@dataset}/studio/#{@type_name}/#{id}"))

  # Draft row, published row and the number of documents of the type, so a
  # write that creates a NEW document (duplicate) moves it too.
  defp snapshot(id) do
    %{
      draft: Content.get_document("drafts." <> id, @type_name, @dataset),
      published: Content.get_document(id, @type_name, @dataset),
      count: count_type()
    }
  end

  defp count_type do
    import Ecto.Query

    Repo.aggregate(from(d in Barkpark.Content.Document, where: d.type == @type_name), :count)
  end

  # "save" after an edit: the edit itself is the write a reader cannot make.
  defp fire(view, "save") do
    render_change(view, "autosave", %{"doc" => %{"title" => "After"}})
    render_click(view, "save")
  end

  defp fire(view, "autosave"),
    do: render_change(view, "autosave", %{"doc" => %{"title" => "After"}})

  defp fire(view, event), do: render_click(view, event)

  # Every write event, fired by a read-only custom role (refused, nothing
  # changes) and by a `member` (the change lands). The member half is what
  # makes each negative non-vacuous: the same click DOES write for a writer.
  @cases [
    {"autosave", false},
    {"save", false},
    {"publish", false},
    {"confirm-discard", :edited},
    {"duplicate-doc", false},
    {"confirm-unpublish", true},
    {"confirm-delete", true}
  ]

  for {event, published?} <- @cases do
    test "read-only custom role: #{event} is refused and writes nothing",
         %{conn: conn, ws_id: ws_id, reader_role: role} do
      id = new_doc!(unquote(published?))
      before = snapshot(id)
      {:ok, view, _} = open(user_conn(conn, ws_id, role), id)

      fire(view, unquote(event))

      assert snapshot(id) == before
    end

    test "member (control): #{event} writes", %{conn: conn, ws_id: ws_id} do
      id = new_doc!(unquote(published?))
      before = snapshot(id)
      {:ok, view, _} = open(user_conn(conn, ws_id, "member"), id)

      fire(view, unquote(event))

      refute snapshot(id) == before
    end
  end
end
