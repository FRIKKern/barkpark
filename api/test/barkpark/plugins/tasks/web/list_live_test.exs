defmodule Barkpark.Plugins.Tasks.Web.ListLiveTest do
  @moduledoc """
  The Tasks list at `/admin/projects/list`: search, filters, sorting and
  paging over every task, under the board's access rules.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @admin_token "task-list-admin-test-token"

  setup do
    # The list reads the whole task corpus of the production dataset, like the
    # board. Stray committed rows would poison the counts; this delete rolls
    # back with the test's sandbox transaction.
    Repo.delete_all(from(d in Document, where: d.type == "task"))

    {:ok, _} =
      Auth.create_token(@admin_token, "task list admin", "production", ["read", "write", "admin"])

    conn = scoped_conn() |> init_test_session(%{"api_token" => @admin_token})
    {:ok, conn: conn}
  end

  test "a done task the board's done window hides is found by search, and its row opens it",
       %{conn: conn} do
    # 14 done tasks. The board shows the newest 12, so the oldest is off it.
    for n <- 1..14 do
      task("done-#{n}", "Shipped piece #{n}",
        lifecycle: "done",
        updated_at: DateTime.add(~U[2026-01-01 00:00:00Z], n, :hour)
      )
    end

    task("done-old", "Migrate the Quokka importer",
      lifecycle: "done",
      updated_at: ~U[2025-06-01 00:00:00Z]
    )

    {:ok, _board, board_html} = live(conn, "/admin/projects")
    refute board_html =~ "Migrate the Quokka importer"
    assert board_html =~ ~s(data-role="list-link")

    {:ok, view, _html} = live(conn, "/admin/projects/list?q=quokka")

    assert has_element?(view, ~s([data-role="match-count"][data-total="1"]))

    assert has_element?(
             view,
             ~s([data-doc-id="done-old"] a[data-role="task-link"][href="/admin/projects?task=done-old"]),
             "Migrate the Quokka importer"
           )

    # The doc id is searched too, and the search box patches the URL.
    view |> form(~s([data-role="filter-form"]), %{"q" => "DONE-OLD"}) |> render_change()
    assert_patch(view, "/admin/projects/list?q=DONE-OLD")
    assert has_element?(view, ~s([data-role="match-count"][data-total="1"]))

    # The row's link lands on the board with that task's detail open.
    {:ok, _board, peek_html} = live(conn, "/admin/projects?task=done-old")
    assert peek_html =~ ~s(data-role="peek")
    assert peek_html =~ "Migrate the Quokka importer"
  end

  test "status filter, sort and page 2 all ride the URL", %{conn: conn} do
    for n <- 1..55 do
      task("c-#{pad(n)}", "Cancelled #{pad(n)}", lifecycle: "cancelled", priority: rem(n, 3))
    end

    task("o-1", "Open one", lifecycle: "open", parent_id: "c-01", labels: ["area:list"])

    {:ok, view, _html} = live(conn, "/admin/projects/list?status=cancelled&sort=title")

    assert has_element?(view, ~s([data-role="match-count"][data-total="55"]))
    assert ids(view) == for(n <- 1..50, do: "c-#{pad(n)}")
    refute has_element?(view, ~s([data-doc-id="o-1"]))

    view |> element(~s([data-role="page-next"])) |> render_click()
    assert_patch(view, "/admin/projects/list?status=cancelled&sort=title&page=2")
    assert ids(view) == for(n <- 51..55, do: "c-#{pad(n)}")
    assert has_element?(view, ~s([data-role="page-now"]), "Page 2 of 2")

    # A second click on the header flips the order and returns to page 1.
    view |> element(~s([data-sort="title"])) |> render_click()
    assert_patch(view, "/admin/projects/list?status=cancelled&sort=title&dir=desc")
    assert hd(ids(view)) == "c-55"

    # Priority sort puts P0 first; a status chip adds a second status.
    {:ok, view, _html} = live(conn, "/admin/projects/list?status=cancelled&sort=priority")
    assert view |> element(~s([data-doc-id="#{hd(ids(view))}"] .bp-pip)) |> render() =~ "P0"

    view |> element(~s([data-role="status-chip"][data-status="open"])) |> render_click()
    assert_patch(view, "/admin/projects/list?sort=priority&status=cancelled%2Copen")
    assert has_element?(view, ~s([data-role="match-count"][data-total="56"]))

    # One query names the parent title for the row; "No parent" hides the child.
    {:ok, view, html} = live(conn, "/admin/projects/list?label=area%3Alist")
    assert ids(view) == ["o-1"]
    assert html =~ "Cancelled 01"

    {:ok, view, _html} = live(conn, "/admin/projects/list?parent=none&status=open")
    assert has_element?(view, ~s([data-role="list-no-match"]))

    view |> element(~s([data-role="clear-filters"])) |> render_click()
    assert_patch(view, "/admin/projects/list")
    assert has_element?(view, ~s([data-role="match-count"][data-total="56"]))
  end

  describe "scope and field visibility" do
    setup do
      n = System.unique_integer([:positive])
      default_ws = Barkpark.Tenancy.get_default_workspace()
      {:ok, ws_b} = Barkpark.Tenancy.create_workspace(%{slug: "list-b-#{n}", name: "B"})
      {:ok, proj_b} = Barkpark.Tenancy.create_project(ws_b, %{slug: "list-p-#{n}", name: "P"})

      raw = "list-scoped-member-#{n}"
      {:ok, token} = Auth.create_token(raw, "member", "production", ["read", "write", "admin"])
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_b.id, token.id, "admin", "api_token")

      task("ws-b-row", "Workspace B zebra", lifecycle: "done", workspace_id: ws_b.id)

      task("ws-default-row", "Default zebra",
        lifecycle: "done",
        workspace_id: default_ws.id,
        priority: 0,
        assignee: "studio:secret-worker",
        labels: ["secret-label"]
      )

      # The same doc id in another dataset is not a row on this board or list.
      Repo.insert!(%Document{
        doc_id: "other-ds-row",
        type: "task",
        dataset: "staging",
        status: "published",
        title: "Staging zebra",
        rev: "rev-other",
        workspace_id: ws_b.id,
        content: %{"lifecycle_status" => "done"}
      })

      scoped = scoped_conn() |> init_test_session(%{"api_token" => raw})
      {:ok, scoped: scoped, ws_b: ws_b, base: "/w/#{ws_b.slug}/p/#{proj_b.slug}/admin/projects"}
    end

    test "a scoped list shows and counts its own workspace's tasks only",
         %{scoped: scoped, base: base} do
      {:ok, view, html} = live(scoped, base <> "/list?q=zebra")

      assert ids(view) == ["ws-b-row"]
      assert has_element?(view, ~s([data-role="match-count"][data-total="1"]))
      refute html =~ "Default zebra"
      refute html =~ "Staging zebra"

      # Links stay inside the scoped mount.
      assert has_element?(view, ~s(a[data-role="task-link"][href="#{base}?task=ws-b-row"]))
      assert has_element?(view, ~s(a[data-role="board-link"][href="#{base}"]))

      # Naming the other workspace's id, label or assignee finds nothing.
      for query <- ["q=ws-default-row", "label=secret-label", "assignee=studio%3Asecret-worker"] do
        {:ok, view, _html} = live(scoped, base <> "/list?" <> query)
        assert has_element?(view, ~s([data-role="match-count"][data-total="0"])), query
      end
    end

    test "the board's refusals hold: a tenant-bound token on the flat list, another dataset's token anywhere",
         %{base: base, ws_b: ws_b} do
      n = System.unique_integer([:positive])
      perms = ["read", "write", "ops"]

      {:ok, _} = Auth.create_token("list-tenant-#{n}", "tenant", "production", perms, ws_b.id, [])
      tenant = scoped_conn() |> init_test_session(%{"api_token" => "list-tenant-#{n}"})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(tenant, "/admin/projects/list")
      assert {:ok, _view, _html} = live(tenant, base <> "/list")

      {:ok, _} =
        Auth.create_token("list-bound-#{n}", "bound", "staging", perms, ws_b.id,
          dataset_bound: true
        )

      bound = scoped_conn() |> init_test_session(%{"api_token" => "list-bound-#{n}"})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(bound, base <> "/list")
    end

    test "a field the schema hides is not shown, filterable or sortable", %{conn: conn} do
      {:ok, _schema} =
        Barkpark.Content.upsert_schema(
          %{
            "name" => "task",
            "title" => "Task",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "priority", "type" => "number", "visibility" => "private"},
              %{"name" => "labels", "type" => "array", "visibility" => "private"},
              %{"name" => "assignee", "type" => "string", "visibility" => "private"}
            ]
          },
          "production"
        )

      {:ok, view, html} = live(conn, "/admin/projects/list?q=zebra")
      assert "ws-default-row" in ids(view)
      refute html =~ "secret-label"
      refute html =~ "secret-worker"
      refute html =~ ~s(class="bp-pip")
      refute html =~ ~s(data-role="priority-chip")
      refute html =~ ~s(data-sort="priority")

      # A filter on a hidden field is dropped, so it cannot narrow the count
      # to the tasks that hold a hidden value.
      for query <- ["label=secret-label", "assignee=studio%3Asecret-worker", "priority=0"] do
        {:ok, view, _html} = live(conn, "/admin/projects/list?q=zebra&" <> query)
        assert has_element?(view, ~s([data-role="match-count"][data-total="2"])), query
      end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp ids(view) do
    view
    |> render()
    |> then(&Regex.scan(~r/data-role="task-row" data-doc-id="([^"]+)"/, &1))
    |> Enum.map(fn [_, id] -> id end)
  end

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp task(doc_id, title, opts) do
    content =
      %{"lifecycle_status" => Keyword.fetch!(opts, :lifecycle)}
      |> put_some("priority", opts[:priority])
      |> put_some("parent_id", opts[:parent_id])
      |> put_some("labels", opts[:labels])
      |> put_some("assignee", opts[:assignee])

    doc =
      Repo.insert!(%Document{
        doc_id: doc_id,
        type: "task",
        dataset: "production",
        status: "published",
        title: title,
        rev: "rev-#{doc_id}",
        workspace_id: opts[:workspace_id],
        content: content
      })

    if at = opts[:updated_at] do
      Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [updated_at: at])
    end

    doc
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)
end
