defmodule BarkparkWeb.Studio.DeskEditorPanelsTest do
  @moduledoc """
  The Studio editor's side panels and secondary views, hosted by the desk's
  editor pane (`DeskLive`, the last document of the chain).

  Measured in a browser first (editing-w4 probe): "Open another" (secondary
  picker and card) and the Classic/Beta toggle work inside the pane; these
  tests pin that. Three panel actions are broken in the desk (Network shares
  leaves the desk, View blast radius drops the chain, a document view's rows
  link to the plain Studio); their red tests stay on branch `editing/probe`
  for the rows that own them.
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
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
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

  # Poll the view for a condition instead of asserting right after a send.
  defp poll(view, fun, tries \\ 25) do
    settle(view)

    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(100) && poll(view, fun, tries - 1)
    end
  end

  defp open(ctx, splat) do
    {:ok, view, _} = live(ctx.conn, "#{ctx.base}/#{splat}")
    settle(view)
    assert has_element?(view, "[data-pane-editing] #editor-form")
    view
  end

  test "Open another shows the second document read-only inside the editor pane", ctx do
    view = open(ctx, "#{ctx.post_type};#{ctx.a}")

    view
    |> element(~s([data-pane-editing] button[phx-click="open-secondary-picker"]))
    |> render_click()

    assert poll(view, fn ->
             has_element?(
               view,
               ~s([data-pane-editing] [phx-click="select-secondary"][phx-value-id="#{ctx.b}"])
             )
           end),
           "the secondary picker does not offer the second document"

    render_click(view, "select-secondary", %{"id" => ctx.b})

    assert poll(view, fn ->
             has_element?(
               view,
               ~s([data-pane-editing] [data-test-id="secondary-pane"]),
               "Panel post B"
             )
           end),
           "the second document never showed in the editor pane"

    render_click(view, "close-secondary", %{})

    assert poll(view, fn -> not has_element?(view, ~s([data-test-id="secondary-pane"])) end),
           "Close left the secondary pane open"
  end

  test "the Classic/Beta toggle switches the editor in place", ctx do
    view = open(ctx, "#{ctx.post_type};#{ctx.a}")

    assert has_element?(view, ~s([data-pane-editing] [data-test-id="editor-mode-classic"]))

    render_click(view, "editor-set-mode", %{"mode" => "beta"})

    assert poll(view, fn ->
             has_element?(view, ~s([data-pane-editing] [data-test-id="studio-doc-beta-shell"]))
           end),
           "Beta did not replace the Classic editor in the pane"

    assert has_element?(view, ~s(#editor-focus-mirror[data-editor-mode="beta"]))
    # The desk's own panes stay.
    assert has_element?(view, ~s([data-pane-index="1"][data-pane-kind="list"]))

    render_click(view, "editor-set-mode", %{"mode" => "classic"})

    assert poll(view, fn -> has_element?(view, "[data-pane-editing] #editor-form") end),
           "Classic did not come back in the pane"
  end
end
