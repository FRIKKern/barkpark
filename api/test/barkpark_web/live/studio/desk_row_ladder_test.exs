defmodule BarkparkWeb.Studio.DeskRowLadderTest do
  @moduledoc """
  sup-w4 (studio-ui-premium): pins the ONE row-state vocabulary the desk's
  Miller columns speak at every pane depth — so a regression that lets one pane
  paint rows differently from another (the "Projects outshines its siblings"
  bug) reds here.

  The ladder is CSS-rule-level (root.html.heex) — plain=`--fg-muted`,
  hover=`--bg-muted` fill + title→`--fg`, selected=`--bg-accent` + `--primary`
  bar + `--fg`, chevrons hover-revealed. These DOM pins assert the CLASS
  vocabulary each depth renders (the classes the CSS ladder keys on); the AA
  values behind those classes are machine-gated by design/check.mjs Part H, and
  the plugin-link chevron by resolver_outputs_test.exs.

  Isolated ws/proj/dataset with a taxonomy-group type ("author") so walk_path
  resolves `/studio/author`, and one published doc so the type pane shows a
  document row (same harness as StudioLiveEmptyPaneTest).
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ws_slug "desk-ladder-ws"
  @proj_slug "desk-ladder-proj"
  @dataset "desk-ladder-ds"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()

    {:ok, ws} = Tenancy.create_workspace(%{slug: @ws_slug, name: "DeskLadderWS"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: @proj_slug, name: "DeskLadderProj"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "DeskLadder"})

    raw = "desk-ladder-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "desk-ladder", "production", ["read", "write"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "member")

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Authors",
          "icon" => "user",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, _doc} =
      Content.create_document(
        "author",
        %{"title" => "Ada Lovelace", "status" => "published"},
        @dataset,
        scope
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn}
  end

  test "structure pane paints type rows in the shared .pane-item / .pane-item-label vocabulary",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/w/#{@ws_slug}/p/#{@proj_slug}/d/#{@dataset}/studio")

    assert html =~ ~s(class="pane-item)
    assert html =~ ~s(class="pane-item-label")
    # the drill chevron span is in the DOM at rest (CSS hover-reveals it) — the
    # affordance every nav row (incl. plugin links) shares.
    assert html =~ ~s(class="pane-item-chevron")
  end

  test "drilled type row carries .selected; the type pane paints doc rows in the doc vocabulary",
       %{conn: conn} do
    {:ok, _view, html} =
      live(conn, "/w/#{@ws_slug}/p/#{@proj_slug}/d/#{@dataset}/studio/author")

    # Type pane depth: the ancestor 'author' row is the drilled node → .selected
    # (active-trail state; ground differs from the leaf, the state class does not).
    assert html =~ ~s(class="pane-item selected")
    # Doc pane depth: the document row speaks .pane-doc-item + .pane-doc-title —
    # the plain-tier title the ladder now paints at --fg-muted (via root.html.heex).
    assert html =~ ~s(class="pane-doc-item)
    assert html =~ ~s(class="pane-doc-title")
    assert html =~ "Ada Lovelace"
  end
end
