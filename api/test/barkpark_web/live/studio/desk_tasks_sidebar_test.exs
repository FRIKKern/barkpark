defmodule BarkparkWeb.Studio.DeskTasksSidebarTest do
  @moduledoc """
  The desk's Tasks sidebar (`Desk.TasksPanel`), as the TanStack Studio's
  (`Navbar.tsx` `TasksButton`, `TasksPanel.tsx`; rig `navbar.spec.ts` J46 at
  :127): a Tasks button in the navbar and in the phone drawer opens a
  sidebar of the workspace's tasks, with a read-only view of each.

  Admins only, with the desk; nothing while the Tasks plugin is off; and
  never a task from another workspace.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.TasksRead

  @dataset "production"
  @bar ~s(#studio-bar .studio-bar-right > button#dk-tasks-btn.tasks-btn[aria-label="Tasks"])
  @drawer_tasks ~s(#dk-drawer .drawer-foot button.drawer-tasks[data-desk-drawer-tasks][data-desk-drawer-pick])
  @panel ~s(.dk-tasks-host aside#dk-tasks.tasks-panel[aria-label="Tasks"])

  setup %{conn: conn} do
    # Stray committed task rows would show in the lists; this rolls back.
    Repo.delete_all(from(d in Document, where: d.type == "task"))

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    ws_id = Tenancy.get_default_workspace().id
    raw = "desk-tasks-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "desk-tasks", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     ws_id: ws_id,
     n: System.unique_integer([:positive])}
  end

  defp task(doc_id, title, ws_id, content) do
    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "task",
      dataset: @dataset,
      status: "published",
      title: title,
      rev: "rev-#{doc_id}",
      workspace_id: ws_id,
      content: content
    })
  end

  defp other_workspace_task(c) do
    other = Barkpark.TenancyFixtures.create_workspace!()
    task("dts-other-#{c.n}", "Other workspace's task", other.id, %{"lifecycle_status" => "open"})
    other
  end

  defp open_sidebar(view) do
    view |> element(@bar) |> render_click()
    assert has_element?(view, @panel)
  end

  test "the bar and the drawer carry Tasks; it opens the sidebar on All, To Do and Done", c do
    task("dts-open-#{c.n}", "Write the brief", c.ws_id, %{
      "lifecycle_status" => "in_progress",
      "assignee" => "tasks-builder",
      "due_at" => "2026-12-01T09:00:00Z"
    })

    task("dts-done-#{c.n}", "Ship the brief", c.ws_id, %{"lifecycle_status" => "done"})
    task("dts-gone-#{c.n}", "Dropped idea", c.ws_id, %{"lifecycle_status" => "cancelled"})
    other_workspace_task(c)

    {:ok, view, _html} = live(c.conn, c.base)

    assert has_element?(view, @bar <> ~s([aria-pressed="false"][phx-click="desk-tasks-toggle"]))
    assert has_element?(view, @drawer_tasks <> ~s([phx-click="desk-tasks-toggle"]), "Tasks")
    refute has_element?(view, @panel)

    open_sidebar(view)
    assert has_element?(view, @bar <> ~s([aria-pressed="true"]))
    assert has_element?(view, ~s(.dk-tasks-host[data-tasks-open]))
    assert has_element?(view, "#{@panel} .tasks-head h2", "Tasks")
    assert has_element?(view, ~s(#{@panel} [role="tab"][aria-selected="true"]), "All")

    assert has_element?(
             view,
             ~s(#{@panel} [role="tab"][aria-selected="false"]),
             "Active Document"
           )

    todo = ~s(#{@panel} details.tasks-group[open] ul[aria-label="To Do"])
    assert has_element?(view, "#{todo} button.task-title", "Write the brief")
    assert has_element?(view, "#{todo} .task-meta", "In progress")
    assert has_element?(view, "#{todo} .task-meta", "2026-12-01")
    assert has_element?(view, ~s(#{todo} .task-assignee[title="tasks-builder"]), "TB")

    done = ~s|#{@panel} details.tasks-done:not([open]) ul[aria-label="Done"]|

    assert has_element?(
             view,
             ~s(#{done} li.task-row[data-done] button.task-title),
             "Ship the brief"
           )

    # Cancelled is in neither group, and another workspace's task is nowhere.
    refute render(view) =~ "Dropped idea"
    refute render(view) =~ "Other workspace&#39;s task"

    # The drawer's button toggles it too.
    view |> element(@drawer_tasks) |> render_click()
    refute has_element?(view, @panel)
    assert has_element?(view, @bar <> ~s([aria-pressed="false"]))
    view |> element(@drawer_tasks) |> render_click()
    assert has_element?(view, @panel)
  end

  test "a task's view reads its fields, walks the list, and goes back to its row", c do
    task("dts-a-#{c.n}", "First task", c.ws_id, %{
      "lifecycle_status" => "blocked",
      "description" => "Why it waits",
      "priority" => 1,
      "acceptance_criteria" => [
        %{"criterion" => "It works", "met" => true},
        %{"criterion" => "It is fast"}
      ]
    })

    Repo.update_all(from(d in Document, where: d.doc_id == ^"dts-a-#{c.n}"),
      set: [updated_at: ~U[2026-01-02 00:00:00Z]]
    )

    task("dts-b-#{c.n}", "Second task", c.ws_id, %{"lifecycle_status" => "open"})

    Repo.update_all(from(d in Document, where: d.doc_id == ^"dts-b-#{c.n}"),
      set: [updated_at: ~U[2026-01-01 00:00:00Z]]
    )

    task("dts-c-#{c.n}", "Done task", c.ws_id, %{"lifecycle_status" => "done"})

    {:ok, view, _html} = live(c.conn, c.base)
    open_sidebar(view)

    view |> element("#dk-task-dts-a-#{c.n}") |> render_click()

    crumbs = ~s(#{@panel} nav.tasks-crumbs[aria-label="Tasks"])
    assert has_element?(view, ~s(#{crumbs} button[phx-click="back"][phx-mounted]), "Tasks")
    assert has_element?(view, "#{crumbs} h2", "First task")
    assert has_element?(view, "#{@panel} .task-description", "Why it waits")
    assert has_element?(view, "#{@panel} .task-facts dd", "Blocked")
    assert has_element?(view, "#{@panel} .task-facts dd", "1 of 2 met")
    assert has_element?(view, "#{@panel} .task-facts dd code", "dts-a-#{c.n}")

    assert has_element?(
             view,
             ~s(#{@panel} a.task-open[data-phx-link="patch"][href$=";dts-a-#{c.n}"]),
             "Open the task to edit it"
           )

    # The newest is first: previous is at its end, next goes to the second.
    prev = ~s(#{@panel} button[aria-label="Go to previous task"])
    assert has_element?(view, prev <> ~s([aria-disabled="true"]))
    view |> element(~s(#{@panel} button[aria-label="Go to next task"])) |> render_click()
    assert has_element?(view, "#{crumbs} h2", "Second task")
    assert has_element?(view, prev <> ~s([aria-disabled="false"]))

    # Back on the list, the focus goes to the row of the task it left.
    view |> element(~s(#{crumbs} button[phx-click="back"])) |> render_click()
    assert has_element?(view, ~s(#dk-task-dts-b-#{c.n}[phx-mounted]))
    refute has_element?(view, ~s(#dk-task-dts-a-#{c.n}[phx-mounted]))
    refute has_element?(view, ~s(details.tasks-done[open]))

    # A done task's row is in Done, which unfolds so the focus can land there.
    view |> element("#dk-task-dts-c-#{c.n}") |> render_click()
    view |> element(~s(#{crumbs} button[phx-click="back"])) |> render_click()
    assert has_element?(view, ~s(details.tasks-done[open] #dk-task-dts-c-#{c.n}[phx-mounted]))
  end

  test "Active Document lists the tasks that link to the open document", c do
    type = "dts_post_#{c.n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Task posts",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "dts-doc-#{c.n}"

    {:ok, _} =
      Content.create_document(type, %{"doc_id" => id, "title" => "Linked post"}, @dataset)

    {:ok, _} = Content.publish_document(id, type, @dataset)

    task("dts-paper-#{c.n}", "Linked by papers", c.ws_id, %{
      "lifecycle_status" => "open",
      "papers" => [id]
    })

    task("dts-child-#{c.n}", "Linked by parent", c.ws_id, %{
      "lifecycle_status" => "open",
      "parent_id" => "drafts." <> id
    })

    task("dts-loose-#{c.n}", "Not linked", c.ws_id, %{"lifecycle_status" => "open"})

    other = Barkpark.TenancyFixtures.create_workspace!()

    task("dts-far-#{c.n}", "Linked elsewhere", other.id, %{
      "lifecycle_status" => "open",
      "papers" => [id]
    })

    # With no document open, the tab says to open one.
    {:ok, view, _html} = live(c.conn, c.base)
    open_sidebar(view)
    view |> element("#dk-tasks-tab-document") |> render_click()
    assert has_element?(view, "#{@panel} .tasks-empty h3", "Open a document to see its task")

    {:ok, view, _html} = live(c.conn, "#{c.base}/#{type};#{id}")
    render_async(view, 5_000)
    open_sidebar(view)
    view |> element("#dk-tasks-tab-document") |> render_click()
    assert has_element?(view, ~s(#dk-tasks-tab-document[aria-selected="true"]))

    html = view |> element(@panel) |> render()
    assert html =~ "Linked by papers"
    assert html =~ "Linked by parent"
    refute html =~ "Not linked"
    refute html =~ "Linked elsewhere"
  end

  test "with the Tasks plugin off there is no button, no drawer item and no sidebar", c do
    {:ok, _} = Tenancy.set_workspace_plugin_settings(c.ws_id, %{"tasks" => %{"enabled" => false}})
    task("dts-off-#{c.n}", "Hidden while off", c.ws_id, %{"lifecycle_status" => "open"})

    {:ok, view, html} = live(c.conn, c.base)
    refute has_element?(view, "#dk-tasks-btn")
    refute has_element?(view, "#dk-drawer [data-desk-drawer-tasks]")

    # A forged press does nothing.
    render_click(view, "desk-tasks-toggle", %{})
    refute has_element?(view, "#dk-tasks")
    refute html =~ "Hidden while off"
  end

  test "a workspace member who is not an admin gets no desk, so no Tasks", c do
    raw = "desk-tasks-member-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "desk-tasks-member", @dataset, ~w(read write), c.ws_id)
    conn = Plug.Test.init_test_session(build_conn(), %{"api_token" => raw})

    assert {:error, {:live_redirect, %{to: to}}} = live(conn, c.base)
    refute to =~ "_desk"
    {:ok, studio, _html} = live(conn, to)
    refute has_element?(studio, "#dk-tasks-btn")
    refute has_element?(studio, "[data-desk-drawer-tasks]")
  end

  test "the reads are held to one workspace, and refuse a read without one", c do
    other = other_workspace_task(c)
    task("dts-mine-#{c.n}", "Mine", c.ws_id, %{"lifecycle_status" => "open"})

    opts = [dataset: @dataset, workspace_id: c.ws_id]
    assert TasksRead.get("dts-other-#{c.n}", opts) == nil
    assert %{title: "Mine"} = TasksRead.get("dts-mine-#{c.n}", opts)

    assert %{title: "Other workspace's task"} =
             TasksRead.get("dts-other-#{c.n}", workspace_id: other.id, dataset: @dataset)

    %{todo: todo} = TasksRead.list("all", opts)
    assert Enum.map(todo, & &1.doc_id) == ["dts-mine-#{c.n}"]

    assert_raise ArgumentError, fn ->
      TasksRead.list("all", dataset: @dataset, workspace_id: nil)
    end

    assert_raise ArgumentError, fn ->
      TasksRead.get("dts-mine-#{c.n}", dataset: @dataset, workspace_id: nil)
    end
  end
end
