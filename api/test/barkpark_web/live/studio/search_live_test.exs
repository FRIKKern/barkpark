defmodule BarkparkWeb.Studio.SearchLiveTest do
  @moduledoc """
  The Studio Search page: an admin sees the dataset's searches and manages its
  synonyms; a member who is not an admin is refused; one workspace never sees
  another's searches or synonyms, even on a shared dataset name.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Repo, Tenancy}
  alias Barkpark.Search.{Crystallizer, Event, Synonyms}

  # Both workspaces use this dataset name on purpose: the workspace must keep
  # them apart, not the name.
  @dataset "production"

  setup %{conn: conn} do
    ws = workspace!("search-a")
    other = workspace!("search-b")

    record!(ws, "red sofa", false)
    record!(ws, "divan", true)
    record!(other, "secret roadmap", true)

    {:ok, _} =
      Synonyms.create(
        "documents",
        @dataset,
        %{"from" => "zebrafrom", "to" => "zebrato"},
        other.id
      )

    for w <- [ws, other],
        do: Crystallizer.crystallize_period("documents", @dataset, :day, yesterday(), w.id)

    {:ok, conn: conn, ws: ws, other: other}
  end

  test "an admin sees the searches, then adds and deletes a synonym", ctx do
    {:ok, view, html} = live(sign_in(ctx.conn, ctx.ws, "admin"), path(ctx.ws) <> "?period=day")

    assert html =~ "red sofa"
    assert view |> element("[data-test-id=search-zero-hits]") |> render() =~ "divan"

    # The row's button starts a synonym from the search that found nothing.
    view |> element("[data-test-id=search-zero-hits] button") |> render_click()
    assert view |> element("#search-rule-from") |> render() =~ ~s(value="divan")

    view |> form("#search-rule-form", rule: %{from: "divan", to: "sofa"}) |> render_submit()

    assert [%{from: "divan", to: "sofa", id: id}] =
             Synonyms.list("documents", @dataset, ctx.ws.id)

    assert view |> element("[data-test-id=search-synonym-row]") |> render() =~ "sofa"

    # Delete takes two clicks; a lone delete event deletes nothing.
    render_click(view, "rule_delete", %{"id" => id})
    assert [_] = Synonyms.list("documents", @dataset, ctx.ws.id)

    view |> element("[data-test-id=search-synonym-row] button", "Delete") |> render_click()
    assert view |> element("[data-test-id=search-synonym-confirm]") |> render() =~ "Delete?"

    view
    |> element("[data-test-id=search-synonym-confirm] button", "Yes, delete")
    |> render_click()

    assert Synonyms.list("documents", @dataset, ctx.ws.id) == []
    refute render(view) =~ id
  end

  test "a shared synonym says so, and a NUL in a synonym is a form error", ctx do
    {:ok, shared} =
      Synonyms.create("documents", @dataset, %{"from" => "tv", "to" => "telly"}, nil)

    {:ok, view, html} = live(sign_in(ctx.conn, ctx.ws, "admin"), path(ctx.ws))

    assert html =~ "every workspace"
    render_click(view, "rule_delete_ask", %{"id" => shared.id})
    assert render(view) =~ "Delete for every workspace?"

    html = render_submit(view, "rule_save", %{"rule" => %{"from" => "di\0van", "to" => "sofa"}})
    assert html =~ "cannot hold that character"
    assert [%{from: "tv"}] = Synonyms.list("documents", @dataset, ctx.ws.id)
  end

  test "a document type named search still opens in the desk", ctx do
    conn = sign_in(ctx.conn, ctx.ws, "admin")
    base = String.replace_suffix(path(ctx.ws), "/_search", "")

    proj = Tenancy.get_project(ctx.ws.slug, "default")

    {:ok, _} =
      Barkpark.Content.upsert_schema(
        %{
          "name" => "search",
          "title" => "Saved lookups",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset,
        workspace_id: ctx.ws.id,
        project_id: proj.id
      )

    {:ok, view, html} = live(conn, base <> "/search")
    assert view.module == BarkparkWeb.Studio.StudioLive
    assert html =~ "Saved lookups"

    assert redirected_to(get(conn, "/studio/#{@dataset}/_search"), 302) =~ "/studio/_search"
  end

  test "a member who is not an admin is refused", ctx do
    assert {:error, {:redirect, %{to: "/studio", flash: flash}}} =
             live(sign_in(ctx.conn, ctx.ws, "member"), path(ctx.ws))

    assert flash["error"] == "Admin access required"
  end

  test "an admin demoted after opening the page can no longer save a synonym", ctx do
    conn = sign_in(ctx.conn, ctx.ws, "admin")
    {:ok, view, _html} = live(conn, path(ctx.ws))

    {:ok, _} =
      Tenancy.Members.update_role(ctx.ws.id, %{type: :user, id: conn.assigns.user.id}, "member")

    render_submit(view, "rule_save", %{"rule" => %{"from" => "divan", "to" => "sofa"}})
    assert Synonyms.list("documents", @dataset, ctx.ws.id) == []
  end

  test "an admin of one workspace sees nothing of another", ctx do
    conn = sign_in(ctx.conn, ctx.ws, "admin")
    {:ok, _view, html} = live(conn, path(ctx.ws) <> "?period=day")

    refute html =~ "secret roadmap"
    refute html =~ "zebrafrom"

    # The other workspace's page does not open at all.
    refused = get(conn, path(ctx.other) <> "?period=day")
    assert refused.status in [403, 404]
    refute refused.resp_body =~ "secret roadmap"
  end

  defp path(ws), do: "/w/#{ws.slug}/p/default/d/#{@dataset}/studio/_search"

  defp workspace!(name) do
    ws = create_workspace!("#{name}-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, @dataset)
    ws
  end

  defp sign_in(conn, ws, role) do
    email = "search-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)

    conn |> Plug.Test.init_test_session(%{"user_session" => raw}) |> Plug.Conn.assign(:user, user)
  end

  defp yesterday, do: Date.add(Date.utc_today(), -1)

  defp record!(ws, query, zero_hits?) do
    %Event{}
    |> Ecto.Changeset.change(%{
      surface: "documents",
      scope: @dataset,
      workspace_id: ws.id,
      query: query,
      query_normalized: query,
      filters: %{},
      result_count: if(zero_hits?, do: 0, else: 3),
      zero_hits: zero_hits?,
      actor_key: "reader",
      quality: "accepted",
      inserted_at: DateTime.new!(yesterday(), ~T[10:00:00.000000], "Etc/UTC")
    })
    |> Repo.insert!()
  end
end
