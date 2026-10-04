defmodule BarkparkWeb.SchemaReservedStatusTest do
  @moduledoc """
  Owner ruling #45 (task-e427940a663dc687): rename the demo `status` field and
  guard schemas against the reserved name.

  `status` is the document's draft/published state. A project select named
  `status` (planning/active/completed) was written to the row status and lost
  on publish, and the desk's status lists stayed empty.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, Structure}
  alias Barkpark.Content.ShapeMigrations.StatusToPhase

  @dataset "production"
  @token "barkpark-test-reserved-status"

  setup do
    {:ok, _} =
      Auth.create_token(
        @token,
        "reserved-status",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    :ok
  end

  defp apply_schema(conn, name, options) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/schemas/#{@dataset}",
      Jason.encode!(%{
        "name" => name,
        "title" => "Thing",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "status", "type" => "select", "options" => options}
        ]
      })
    )
  end

  test "schema apply refuses a status select whose options are not lifecycle states",
       %{conn: conn} do
    resp = apply_schema(conn, "rs_project", ["planning", "active", "completed", "archived"])

    assert resp.status == 422, resp.resp_body
    message = Jason.decode!(resp.resp_body)["error"]["message"]
    assert message =~ "status"
    assert message =~ "planning, active, completed"
    assert message =~ "phase"
    assert {:error, :not_found} = Content.get_schema("rs_project", @dataset)
  end

  test "a status select limited to draft/published/archived is still accepted", %{conn: conn} do
    assert apply_schema(conn, "rs_post", ["draft", "published", "archived"]).status == 201
  end

  test "the demo project declares `phase`, not `status`" do
    source = File.read!(Path.join(File.cwd!(), "lib/barkpark/seeds/demo.ex"))
    [project] = Regex.run(~r/name: "project",.*?name: "siteSettings"/s, source)

    assert project =~ ~s(name: "phase")
    refute project =~ ~s(name: "status")
  end

  describe "the desk lists filter on a `phase` content field" do
    setup do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "project",
            "title" => "Project",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{
                "name" => "phase",
                "title" => "Phase",
                "type" => "select",
                "options" => ["planning", "active", "completed", "archived"]
              }
            ]
          },
          @dataset
        )

      for {id, phase} <- [{"rs-a", "active"}, {"rs-p", "planning"}] do
        {:ok, _} =
          Content.create_document(
            "project",
            %{"doc_id" => id, "title" => "Project #{phase}", "content" => %{"phase" => phase}},
            @dataset
          )

        {:ok, _} = Content.publish_document(id, "project", @dataset)
      end

      :ok
    end

    test "the structure carries one list per phase, filtering the content field" do
      nodes = @dataset |> Structure.build() |> flatten()

      active = Enum.find(nodes, &(Map.get(&1, :id) == "project-active"))
      assert active, inspect(Enum.map(nodes, &Map.get(&1, :id)))
      assert active.filter == "phase=active"
    end

    test "the Active list opens and lists only published active projects", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/project/project-active"))

      refute html =~ "Studio could not open this document"
      assert html =~ "Project active"
      refute html =~ "Project planning"
    end
  end

  test "the dry-run backfill reports and writes nothing; --apply moves status into phase" do
    {:ok, doc} =
      Content.create_document(
        "project",
        %{"doc_id" => "rs-legacy", "title" => "Legacy"},
        @dataset
      )

    doc |> Ecto.Changeset.change(status: "active") |> Barkpark.Repo.update!()

    assert Enum.any?(StatusToPhase.census(), &(&1.type == "project" and &1.status == "active"))

    dry = StatusToPhase.run()
    assert dry.applied? == false
    assert Enum.any?(dry.rows, &(&1.doc_id == "drafts.rs-legacy" and &1.new_status == "draft"))

    assert {:ok, %{status: "active"}} =
             Content.get_document("drafts.rs-legacy", "project", @dataset)

    StatusToPhase.run(apply: true)
    assert {:ok, after_apply} = Content.get_document("drafts.rs-legacy", "project", @dataset)
    assert after_apply.status == "draft"
    assert after_apply.content["phase"] == "active"
  end

  defp flatten(%{items: items} = node) when is_list(items),
    do: [node | Enum.flat_map(items, &flatten/1)]

  defp flatten(list) when is_list(list), do: Enum.flat_map(list, &flatten/1)
  defp flatten(node), do: [node]
end
