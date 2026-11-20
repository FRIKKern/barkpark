defmodule Barkpark.Tasks.FieldVisibilityWorkspaceTest do
  @moduledoc """
  task-c626f2be5264f61a (review of #27767): a workspace's own `task` schema
  decides which task fields its board, the Tasks plugin's list and the desk's
  Tasks sidebar show. `Board.field_visibility_gate` read the schema with no
  scope, which resolves `production` to the Default workspace's dataset, so
  every workspace was judged by Default's schema.

  Three schemas, each hiding another field: Default hides `priority`, A hides
  `description`, B hides `due_at`. Each workspace hides exactly its own field.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Board
  alias BarkparkWeb.Studio.Desk.TasksRead

  @dataset "production"

  setup do
    Repo.delete_all(from(d in Document, where: d.type == "task"))

    {default_ws, default_proj} = TenancyFixtures.ensure_default_scope!()
    default = [workspace_id: default_ws.id, project_id: default_proj.id]
    a = scope!()
    b = scope!()

    seal!(default, ["priority"])
    seal!(a, ["description"])
    seal!(b, ["due_at"])

    for {name, scope} <- [default: default, a: a, b: b], do: task!("fv-#{name}", scope)

    %{default: default, a: a, b: b}
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

  defp task!(doc_id, scope) do
    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "task",
      dataset: @dataset,
      status: "published",
      title: doc_id,
      rev: "rev-#{doc_id}",
      workspace_id: scope[:workspace_id],
      project_id: scope[:project_id],
      content: %{
        "lifecycle_status" => "open",
        "description" => "the description",
        "due_at" => "2026-12-01T09:00:00Z",
        "priority" => 1
      }
    })
  end

  defp hidden(readable?), do: for(f <- ~w(description due_at priority), not readable?.(f), do: f)

  test "the gate judges each workspace by its own task schema", c do
    assert hidden(Board.field_visibility_gate(@dataset, c.default)) == ["priority"]
    assert hidden(Board.field_visibility_gate(@dataset, c.a)) == ["description"]
    assert hidden(Board.field_visibility_gate(@dataset, c.b)) == ["due_at"]

    # The plugin list's scoped mount knows only its workspace.
    assert hidden(Board.field_visibility_gate(@dataset, workspace_id: c.b[:workspace_id])) ==
             ["due_at"]
  end

  test "the desk's Tasks sidebar shows each workspace's task by its own schema", c do
    a = TasksRead.get("fv-a", Keyword.put(c.a, :dataset, @dataset))
    b = TasksRead.get("fv-b", Keyword.put(c.b, :dataset, @dataset))

    assert {a.description, a.due_at, a.priority} == {nil, "2026-12-01T09:00:00Z", 1}
    assert {b.description, b.due_at, b.priority} == {"the description", nil, 1}

    [row] = TasksRead.list("all", Keyword.put(c.b, :dataset, @dataset)).todo
    assert row.doc_id == "fv-b"
  end

  test "the board's snapshot of a workspace seals its cards by that workspace's schema", c do
    card = fn scope, id ->
      Board.snapshot(dataset: @dataset, workspace_id: scope[:workspace_id]).cards_by_id[id]
    end

    a = card.(c.a, "fv-a")
    b = card.(c.b, "fv-b")
    d = card.(c.default, "fv-default")

    assert {a.description_excerpt, a.priority} == {nil, 1}
    assert {is_binary(b.description_excerpt), b.priority} == {true, 1}
    assert {is_binary(d.description_excerpt), d.priority} == {true, nil}
  end
end
