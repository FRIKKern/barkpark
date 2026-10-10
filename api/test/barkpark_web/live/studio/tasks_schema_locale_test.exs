defmodule BarkparkWeb.Studio.TasksSchemaLocaleTest do
  @moduledoc """
  task-228e90e341223f82: in an nb Studio the task board read English. The row
  badge said "open", the editor tabs Brief/Work/Close/System and the field
  labels TITLE, LIFECYCLE…, all raw from `Barkpark.Tasks` schema data. Studio
  now shows them in the workspace's language (`PluginSchemaCopy`). The stored
  lifecycle token is unchanged, and an English workspace reads as before.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Tenancy, TenancyFixtures}
  alias BarkparkWeb.Studio.PluginSchemaCopy

  @dataset "production"

  defp nb(fun), do: Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fun)

  test "every Tasks schema title and shown token has a translation marker" do
    schema = Barkpark.Tasks.task_schema(@dataset)

    titles =
      [schema.title] ++
        Enum.map(schema.groups, & &1["title"]) ++ Enum.map(schema.fields, & &1["title"])

    assert titles -- PluginSchemaCopy.task_markers() == []

    for name <- ~w(lifecycle_status disposition) do
      opts = Enum.find(schema.fields, &(&1["name"] == name))["options"]
      assert opts -- PluginSchemaCopy.task_option_markers() == [], name
    end
  end

  test "an nb Studio reads the Tasks schema in Norwegian and keeps the stored tokens" do
    schema = nb(fn -> PluginSchemaCopy.localize(Barkpark.Tasks.task_schema(@dataset)) end)

    assert schema.title == "Oppgave"
    assert Enum.map(schema.groups, & &1["title"]) == ~w(Oppdrag Arbeid Avslutning System)

    lifecycle = Enum.find(schema.fields, &(&1["name"] == "lifecycle_status"))
    assert lifecycle["title"] == "Livsløp"
    assert %{"value" => "open", "title" => "åpen"} in lifecycle["options"]

    raw =
      Enum.find(Barkpark.Tasks.task_schema(@dataset).fields, &(&1["name"] == "lifecycle_status"))

    assert Barkpark.Content.SelectOptions.values(lifecycle["options"]) == raw["options"]

    assert nb(fn -> PluginSchemaCopy.option_label("task", "lifecycle_status", "in_progress") end) ==
             "pågår"

    assert PluginSchemaCopy.option_label("author", "lifecycle_status", "open") == "open"
  end

  test "an English Studio reads the Tasks schema exactly as before" do
    raw = Barkpark.Tasks.task_schema(@dataset)
    schema = PluginSchemaCopy.localize(raw)

    assert schema.title == raw.title
    assert Enum.map(schema.groups, & &1["title"]) == Enum.map(raw.groups, & &1["title"])
    assert Enum.map(schema.fields, & &1["title"]) == Enum.map(raw.fields, & &1["title"])

    lifecycle = Enum.find(schema.fields, &(&1["name"] == "lifecycle_status"))

    assert Barkpark.Content.SelectOptions.normalize(lifecycle["options"]) ==
             Enum.find(raw.fields, &(&1["name"] == "lifecycle_status"))["options"]
             |> Barkpark.Content.SelectOptions.normalize()
  end

  describe "the task board" do
    setup %{conn: conn} do
      {ws, _proj} = TenancyFixtures.ensure_default_scope!()
      schema = Barkpark.Tasks.task_schema(@dataset)

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => schema.name,
            "title" => schema.title,
            "icon" => schema.icon,
            "visibility" => "public",
            "groups" => schema.groups,
            "list_preview" => schema.list_preview,
            "fields" => schema.fields
          },
          @dataset
        )

      {:ok, _} =
        Content.create_document(
          "task",
          %{
            "doc_id" => "tsk-loc",
            "title" => "Wire the bridge",
            "content" => %{"kind" => "task", "lifecycle_status" => "open"}
          },
          @dataset
        )

      {:ok, conn: conn, ws: ws}
    end

    @tag :requires_plugins
    test "an nb workspace shows the badge, tabs and labels in Norwegian", %{conn: conn, ws: ws} do
      {:ok, _} = Tenancy.set_workspace_locale(ws, "nb-NO")
      {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/task/tsk-loc"))

      doc = LazyHTML.from_document(html)
      badge = LazyHTML.query(doc, ".pane-doc-badge")
      assert LazyHTML.text(badge) == "åpen"
      assert LazyHTML.attribute(badge, "class") == ["pane-doc-badge pane-doc-badge--open"]

      tabs =
        doc
        |> LazyHTML.query(~s(.bp-tab-bar [role="tab"]))
        |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert tabs == ~w(Oppdrag Arbeid Avslutning System)

      work =
        view
        |> element(~s(.bp-tab-bar button[phx-value-group="work"]))
        |> render_click()

      assert work =~ "Livsløp"
      assert work =~ ~r{<option value="open"[^>]*>åpen</option>}
    end

    @tag :requires_plugins
    test "an English workspace shows the stored words as before", %{conn: conn} do
      {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/task/tsk-loc"))

      badge = html |> LazyHTML.from_document() |> LazyHTML.query(".pane-doc-badge")
      assert LazyHTML.text(badge) == "open"

      work =
        view
        |> element(~s(.bp-tab-bar button[phx-value-group="work"]))
        |> render_click()

      assert work =~ "Lifecycle"
      assert work =~ ~r{<option value="open"[^>]*>open</option>}
    end
  end
end
