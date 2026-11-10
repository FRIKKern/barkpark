defmodule BarkparkWeb.Studio.DeskEditorPanelsTest do
  @moduledoc """
  The Studio editor's side panels and secondary views, hosted by the desk's
  editor pane (`DeskLive`, the last document of the chain).

  Measured in a browser first (editing-w4 probe):

    * the top bar's "Network shares" leaves the desk for the plain Studio
      (`StudioChrome` intercepts `shares-open` on any view that is not
      `StudioLive`);
    * "View blast radius" patches to `<desk>/graph;<id>`, which the desk reads
      as a type list named "graph", so the chain to the left is gone;
    * a document view's rows (`desk.views`) link to the plain Studio;
    * "Open another" (secondary picker and card) and the Classic/Beta toggle
      work inside the pane.

  Run both ways: `--only desk_editor_red` / `--exclude desk_editor_red`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author_type = "w4_pa_#{n}"
    post_type = "w4_pp_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author_type,
          "title" => "W4 panel authors #{n}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}],
          "desk" => %{
            "views" => [
              %{
                "id" => "posts",
                "title" => "Posts by author",
                "type" => post_type,
                "by" => "content.author._ref"
              }
            ]
          }
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => post_type,
          "title" => "W4 panel posts #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "author",
              "title" => "Author",
              "type" => "reference",
              "to" => [author_type]
            }
          ]
        },
        @dataset
      )

    author = "w4pa-#{n}"

    {:ok, _} =
      Content.create_document(
        author_type,
        %{"doc_id" => author, "title" => "Panel Ada"},
        @dataset
      )

    ref = %{"_ref" => author, "_type" => "reference"}

    for {id, title} <- [{"w4pp-a-#{n}", "Panel post A"}, {"w4pp-b-#{n}", "Panel post B"}] do
      {:ok, _} =
        Content.create_document(
          post_type,
          %{"doc_id" => id, "title" => title, "content" => %{"author" => ref}},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok,
     conn: admin(conn),
     base: base,
     post_type: post_type,
     author_type: author_type,
     author: author,
     a: "w4pp-a-#{n}",
     b: "w4pp-b-#{n}"}
  end

  defp admin(conn) do
    raw = "w4-desk-panels-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()

    {:ok, _} =
      Auth.create_token(raw, "w4-desk-panels", @dataset, ["read", "write", "admin"], ws.id)

    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp settle(view), do: render_async(view, 5_000)

  defp open(ctx, splat) do
    {:ok, view, _} = live(ctx.conn, "#{ctx.base}/#{splat}")
    settle(view)
    assert has_element?(view, "[data-pane-editing] #editor-form")
    view
  end

  # BROKEN in the desk: `StudioChrome` halts `shares-open` on every view that
  # is not StudioLive and push_navigates to `/studio?shares=open`, so the
  # desk is left for the plain Studio (studio_chrome.ex, @per_view_events).
  @tag :desk_editor_red
  test "Network shares opens its dialog on the desk page", ctx do
    view = open(ctx, "#{ctx.post_type};#{ctx.a}")

    result = render_click(view, "shares-open", %{})

    assert is_binary(result),
           "shares-open left the desk: #{inspect(result)}"

    assert has_element?(view, "#shares-modal-dialog[role=dialog]")
  end

  # BROKEN in the desk: `Secondary.view_graph/1` patches to
  # `Shared.studio_path(socket, ["graph", id])`, printed as `<desk>/graph;<id>`;
  # the desk reads "graph" as a type list ("There is no document type named
  # graph") and the panes to the left of the document are gone.
  @tag :desk_editor_red
  test "View blast radius keeps the pane chain", ctx do
    view = open(ctx, "#{ctx.post_type};#{ctx.a}")

    view |> element(~s([data-pane-editing] button[phx-click="view-graph"])) |> render_click()
    to = view |> assert_patch() |> URI.decode()

    assert String.starts_with?(to, "#{ctx.base}/#{ctx.post_type};"),
           "view-graph patched to #{to}: the list pane is gone"
  end

  # BROKEN in the desk: the view's rows are linked with `Paths.studio_path/3`
  # (studio_components/editor.ex, document-view-list), the plain Studio URL,
  # not the desk-aware `Shared.studio_path/4`.
  @tag :desk_editor_red
  test "a document view's rows open inside the desk", ctx do
    view = open(ctx, "#{ctx.author_type};#{ctx.author}")

    view
    |> element(~s([data-pane-editing] [data-test-id="document-view-tab"][data-view-id="posts"]))
    |> render_click()

    assert has_element?(view, ~s([data-test-id="document-view-list"] a), "Panel post A")

    refute has_element?(
             view,
             ~s{[data-test-id="document-view-list"] a[href^="/w/"]:not([href*="/studio/_desk/"])}
           ),
           "a document view row links out of the desk to the plain Studio"
  end

  test "Open another shows the second document read-only inside the editor pane", ctx do
    view = open(ctx, "#{ctx.post_type};#{ctx.a}")

    view
    |> element(~s([data-pane-editing] button[phx-click="open-secondary-picker"]))
    |> render_click()

    assert has_element?(
             view,
             ~s([data-pane-editing] [phx-click="select-secondary"][phx-value-id="#{ctx.b}"])
           )

    render_click(view, "select-secondary", %{"id" => ctx.b})

    assert has_element?(
             view,
             ~s([data-pane-editing] [data-test-id="secondary-pane"]),
             "Panel post B"
           )

    render_click(view, "close-secondary", %{})
    refute has_element?(view, ~s([data-test-id="secondary-pane"]))
  end

  test "the Classic/Beta toggle switches the editor in place", ctx do
    view = open(ctx, "#{ctx.post_type};#{ctx.a}")

    assert has_element?(view, ~s([data-pane-editing] [data-test-id="editor-mode-classic"]))

    render_click(view, "editor-set-mode", %{"mode" => "beta"})
    assert has_element?(view, ~s([data-pane-editing] [data-test-id="studio-doc-beta-shell"]))
    assert has_element?(view, ~s(#editor-focus-mirror[data-editor-mode="beta"]))
    # The desk's own panes stay.
    assert has_element?(view, ~s([data-pane-index="1"][data-pane-kind="list"]))

    render_click(view, "editor-set-mode", %{"mode" => "classic"})
    assert has_element?(view, "[data-pane-editing] #editor-form")
  end
end
