defmodule Barkpark.Plugins.Tasks.Web.FlatFieldGatesTest do
  @moduledoc """
  Each task on the Tasks board, its peek and its list is shown by its own
  workspace and project's task schema, never by another's. A filter or a
  sort is offered only when every one of those schemas allows its field.

  task-b3d338cd0745b310, the operator's flat mounts (`/admin/projects`, its
  peek, `/admin/projects/list`), which show every workspace's tasks: three
  schemas, each hiding another field. Default hides `priority`, A hides
  `labels`, B hides `parent_id`.

  task-2c4baa77701785b3, a workspace's own mounts: two projects of one
  workspace, P1 hiding `labels`, P2 hiding nothing.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Board, FieldGates}

  @dataset "production"
  @token "flat-field-gates-operator"

  setup do
    Repo.delete_all(from(d in Document, where: d.type == "task"))

    {default_ws, default_proj} = TenancyFixtures.ensure_default_scope!()
    default = [workspace_id: default_ws.id, project_id: default_proj.id]
    a = scope!()
    b = scope!()

    seal!(default, ["priority"])
    seal!(a, ["labels"])
    seal!(b, ["parent_id"])

    for {name, scope} <- [default: default, a: a, b: b], do: task!(name, scope)

    {:ok, _} = Auth.create_token(@token, "operator", @dataset, ["read", "write", "admin"])
    conn = scoped_conn() |> init_test_session(%{"api_token" => @token})

    %{conn: conn, default: default, a: a, b: b}
  end

  defp scope! do
    ws = TenancyFixtures.create_workspace!()
    [workspace_id: ws.id, project_id: TenancyFixtures.create_project!(ws).id]
  end

  # The real task schema in `scope`, with `private` fields sealed.
  defp seal!(scope, private) do
    attrs =
      @dataset
      |> Tasks.schema_definitions()
      |> Enum.find(&(&1.name == "task"))
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    fields =
      Enum.map(attrs["fields"], fn field ->
        if field["name"] in private, do: Map.put(field, "visibility", "private"), else: field
      end)

    {:ok, _} = Content.upsert_schema(Map.put(attrs, "fields", fields), @dataset, scope)
  end

  # Each value names its workspace, so a page can be searched for it.
  defp task!(name, scope) do
    Repo.insert!(%Document{
      doc_id: "fg-#{name}",
      type: "task",
      dataset: @dataset,
      status: "published",
      title: "Gate zebra #{name}",
      rev: "rev-fg-#{name}",
      workspace_id: scope[:workspace_id],
      project_id: scope[:project_id],
      content: %{
        "lifecycle_status" => "open",
        "priority" => 1,
        "labels" => ["lab-#{name}"],
        "parent_id" => "par-#{name}"
      }
    })
  end

  defp shown(card), do: {card.priority, card.labels, card.parent_id}

  test "the instance-wide snapshot seals each card by its own workspace's schema" do
    cards = Board.snapshot(dataset: @dataset).cards_by_id

    assert shown(cards["fg-default"]) == {nil, ["lab-default"], "par-default"}
    assert shown(cards["fg-a"]) == {1, [], "par-a"}
    assert shown(cards["fg-b"]) == {1, ["lab-b"], nil}
  end

  test "the flat board and its peek show each task by its own workspace's schema", c do
    {:ok, _view, html} = live(c.conn, "/admin/projects")
    assert html =~ "Gate zebra a"
    refute html =~ "lab-a"
    assert html =~ "lab-b"
    assert html =~ "lab-default"

    {:ok, _view, a} = live(c.conn, "/admin/projects?task=fg-a")
    assert a =~ ~s(data-role="peek")
    refute a =~ "lab-a"
    assert a =~ "par-a"

    {:ok, _view, b} = live(c.conn, "/admin/projects?task=fg-b")
    assert b =~ "lab-b"
    refute b =~ "par-b"
  end

  test "the flat list shows each row by its own workspace's schema", c do
    {:ok, view, _html} = live(c.conn, "/admin/projects/list?q=zebra")

    row = fn name ->
      view |> element(~s([data-role="task-row"][data-doc-id="fg-#{name}"])) |> render()
    end

    assert row.("a") =~ "Gate zebra a"
    refute row.("a") =~ "lab-a"
    assert row.("b") =~ "lab-b"
    assert row.("default") =~ "lab-default"
    assert row.("a") =~ "par-a"
    refute row.("b") =~ "par-b"
  end

  test "the flat list offers a filter or sort only when every workspace's schema allows it", c do
    {:ok, _view, html} = live(c.conn, "/admin/projects/list?q=zebra")
    refute html =~ ~s(data-sort="priority")

    # Each filter names a field one workspace hides, so it is dropped and the
    # count stays at all three.
    for query <- ["label=lab-b", "priority=1", "parent=par-a"] do
      {:ok, view, _html} = live(c.conn, "/admin/projects/list?q=zebra&" <> query)
      assert has_element?(view, ~s([data-role="match-count"][data-total="3"])), query
    end
  end

  test "a row of a workspace the gate set does not hold shows no gated field" do
    gates = FieldGates.for_keys(@dataset, [{nil, nil}])

    refute FieldGates.pick(gates, %{workspace_id: Ecto.UUID.generate(), project_id: nil}).(
             "labels"
           )

    assert FieldGates.pick(gates, %{workspace_id: nil, project_id: nil}).("labels")
  end

  describe "one workspace, two projects" do
    setup c do
      ws = TenancyFixtures.create_workspace!()
      p1 = TenancyFixtures.create_project!(ws)
      p2 = TenancyFixtures.create_project!(ws)
      seal!([workspace_id: ws.id, project_id: p1.id], ["labels"])
      seal!([workspace_id: ws.id, project_id: p2.id], [])
      task!("p1", workspace_id: ws.id, project_id: p1.id)
      task!("p2", workspace_id: ws.id, project_id: p2.id)

      raw = "flat-field-gates-member-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "member", @dataset, ["read", "write", "admin"])
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, token.id, "admin", "api_token")
      conn = scoped_conn() |> init_test_session(%{"api_token" => raw})

      Map.merge(c, %{ws: ws, member: conn, base: "/w/#{ws.slug}/p/#{p1.slug}/admin/projects"})
    end

    test "the workspace's snapshot seals each card by its own project's schema", c do
      cards = Board.snapshot(dataset: @dataset, workspace_id: c.ws.id).cards_by_id

      assert shown(cards["fg-p1"]) == {1, [], "par-p1"}
      assert shown(cards["fg-p2"]) == {1, ["lab-p2"], "par-p2"}
    end

    test "the scoped board, its peek and its list show each task by its own project's schema",
         c do
      {:ok, _view, html} = live(c.member, c.base)
      assert html =~ "Gate zebra p1"
      refute html =~ "lab-p1"
      assert html =~ "lab-p2"

      {:ok, _view, peek} = live(c.member, c.base <> "?task=fg-p1")
      assert peek =~ ~s(data-role="peek")
      refute peek =~ "lab-p1"

      {:ok, view, _html} = live(c.member, c.base <> "/list?q=zebra")
      p1 = view |> element(~s([data-role="task-row"][data-doc-id="fg-p1"])) |> render()
      p2 = view |> element(~s([data-role="task-row"][data-doc-id="fg-p2"])) |> render()
      refute p1 =~ "lab-p1"
      assert p2 =~ "lab-p2"

      # P1 hides labels, so the label filter is dropped for the whole list.
      {:ok, view, _html} = live(c.member, c.base <> "/list?q=zebra&label=lab-p2")
      assert has_element?(view, ~s([data-role="match-count"][data-total="2"]))
    end
  end
end
