defmodule BarkparkWeb.Studio.DeskValidationPanelTest do
  @moduledoc """
  WP3: Sanity's Validation inspector on the desk's edit pane
  (`Desk.ValidationPanel`), by the names barkpark-studio's
  `e2e/journeys/nested-validation.spec.ts` (J13) finds it by: a header button
  named "Validation", a `complementary` named "Validation" that lists each
  problem as a button, and a jump that picks the field's group. Publish is
  greyed out while an error blocks it.

  Every type and document a test reads is made in this setup.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.ValidationPanel

  @dataset "production"
  @pane "[data-pane-editing]"
  @button ~s(#{@pane} .pane-header button.validation-btn[aria-label="Validation"])
  @panel ~s(#{@pane} aside.inspector.validation[aria-label="Validation"])
  @publish ~s(#{@pane} .doc-footer button[data-desk-publish])
  @inspect_param "inspect=sanity%2Fstructure%2Fvalidation"
  @blocked "There are validation errors that need to be fixed before this document can be published"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "vp_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Validated #{n}",
          "visibility" => "public",
          "groups" => [
            %{"name" => "content", "title" => "Content", "default" => true},
            %{"name" => "meta", "title" => "Meta"}
          ],
          "fieldsets" => [
            %{
              "name" => "more",
              "title" => "More",
              "options" => %{"collapsible" => true, "collapsed" => true}
            }
          ],
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string", "group" => "content"},
            %{
              "name" => "excerpt",
              "title" => "Excerpt",
              "type" => "string",
              "group" => "content",
              "validation" => %{"max" => 10, "level" => "warning"}
            },
            %{
              "name" => "rating",
              "title" => "Rating",
              "type" => "number",
              "group" => "meta",
              "validation" => %{"min" => 0, "max" => 5}
            },
            %{
              "name" => "limit",
              "title" => "Limit",
              "type" => "number",
              "fieldset" => "more",
              "validation" => %{"max" => 10}
            },
            %{
              "name" => "links",
              "title" => "Links",
              "type" => "arrayOf",
              "group" => "meta",
              "of" => %{
                "type" => "composite",
                "options" => %{"typeField" => "kind"},
                "fields" => [
                  %{
                    "name" => "kind",
                    "title" => "Kind",
                    "type" => "select",
                    "options" => [%{"value" => "externalLink", "title" => "External link"}]
                  },
                  %{
                    "name" => "url",
                    "title" => "URL",
                    "type" => "string",
                    "validation" => %{"required" => true}
                  }
                ]
              }
            }
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-validation-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-validation", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: base, type: type, n: n}
  end

  # A draft of the setup's type holding `content`.
  defp draft(c, name, content) do
    id = "vp-#{name}-#{c.n}"

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> id, "title" => "Probe #{name}", "content" => content},
        @dataset
      )

    id
  end

  defp open(c, id, params \\ "") do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};#{id}#{params}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp text(html),
    do: html |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  test "a document with an error: the button, the panel, the problem in TanStack's words", c do
    id = draft(c, "rating", %{"rating" => 9})
    view = open(c, id)

    assert has_element?(view, ~s(#{@button}[aria-pressed="false"][data-level="error"]))
    refute has_element?(view, @panel)

    view |> element(@button) |> render_click()
    assert_patch(view)

    assert has_element?(view, ~s(#{@button}[aria-pressed="true"]))
    assert has_element?(view, ~s(#{@panel} h2), "Validation")
    assert has_element?(view, ~s(#{@panel} button[aria-label="Close validation"]))

    problem =
      ~s(#{@panel} ul.problems button.problem[data-level="error"][data-desk-problem="rating"])

    assert view |> element(problem) |> render() |> text() ==
             "Rating Must be lower than or equal to 5"

    # No note says the inspector is not shown.
    refute has_element?(view, "#{@pane} [data-desk-left-out]")
  end

  test "the panel is open from the URL, and its close button takes it out", c do
    id = draft(c, "url", %{"rating" => 9})
    view = open(c, id, ",#{@inspect_param}")

    assert has_element?(view, @panel)

    view |> element(~s(#{@panel} button[aria-label="Close validation"])) |> render_click()
    path = assert_patch(view)

    refute path =~ "inspect"
    refute has_element?(view, @panel)
    assert has_element?(view, ~s(#{@button}[aria-pressed="false"]))
  end

  test "picking a problem in another group selects that field's group", c do
    id = draft(c, "group", %{"rating" => 9})
    view = open(c, id, ",#{@inspect_param}")

    assert has_element?(view, ~s(#{@pane} [role="tab"][aria-selected="true"]), "Content")
    refute has_element?(view, ~s(#{@pane} [id="rating"]))

    problem = ~s(#{@panel} button.problem[data-desk-problem="rating"])
    # The jump itself is the browser's: the press says which field.
    assert view |> element(problem) |> render() =~ "desk:goto-field"

    view |> element(problem) |> render_click()

    assert has_element?(view, ~s(#{@pane} [role="tab"][aria-selected="true"]), "Meta")
    assert has_element?(view, ~s(#{@pane} [id="rating"]))
    assert has_element?(view, @panel)
  end

  test "a field in a folded fieldset is listed by its path", c do
    id = draft(c, "fold", %{"limit" => 50})
    view = open(c, id, ",#{@inspect_param}")

    problem = ~s(#{@panel} button.problem[data-desk-problem="limit"])

    assert view |> element(problem) |> render() |> text() ==
             "Limit Must be lower than or equal to 10"

    # Limit is in no group, so the Content tab does not draw it.
    refute has_element?(view, ~s(#{@pane} fieldset[data-fieldset="more"]))

    view |> element(problem) |> render_click()

    # All fields now, and the fieldset still folded: the browser opens it.
    assert has_element?(view, ~s(#{@pane} [role="tab"][aria-selected="true"]), "All fields")

    assert has_element?(
             view,
             ~s(#{@pane} fieldset[data-fieldset="more"] .object-toggle[aria-expanded="false"])
           )
  end

  test "an array item's field: its parents' titles and the item's key in the path", c do
    links = [%{"_key" => "l1", "kind" => "externalLink"}]
    id = draft(c, "nested", %{"links" => links})
    view = open(c, id, ",#{@inspect_param}")

    problem = ~s|#{@panel} button.problem[data-desk-problem='links[_key=="l1"].url']|

    assert view |> element(problem) |> render() |> text() ==
             "Links / External link / URL Required"
  end

  test "an error greys Publish out and says why; a warning does not", c do
    blocked = open(c, draft(c, "blocked", %{"rating" => 9}))
    assert has_element?(blocked, ~s(#{@publish}[disabled][title="#{@blocked}"]))

    warned = open(c, draft(c, "warned", %{"excerpt" => "longer than ten"}))
    assert has_element?(warned, ~s(#{@button}[data-level="warning"]))
    refute has_element?(warned, ~s(#{@publish}[disabled]))
    refute has_element?(warned, ~s(#{@publish}[title]))

    warned |> element(@button) |> render_click()
    assert has_element?(warned, ~s(#{@panel} button.problem[data-level="warning"]))
  end

  test "a document with no problem has no button; its open panel says so", c do
    id = draft(c, "clean", %{"rating" => 3})
    view = open(c, id)

    refute has_element?(view, @button)
    refute has_element?(view, @panel)
    refute has_element?(view, ~s(#{@publish}[disabled]))

    opened = open(c, id, ",#{@inspect_param}")
    assert has_element?(opened, ~s(#{@button}[aria-pressed="true"]))
    assert has_element?(opened, ~s(#{@panel} p), "No validation errors")
  end

  test "the published perspective draws neither the button nor the panel", c do
    id = draft(c, "published", %{"rating" => 9})
    view = open(c, id, ",#{@inspect_param}?perspective=published")

    refute has_element?(view, @button)
    refute has_element?(view, @panel)
  end

  test "the page gives the jump's script its address, and the script hears the press", c do
    id = draft(c, "script", %{"rating" => 9})
    {:ok, _view, html} = live(c.conn, "#{c.base}/#{c.type};#{id}")

    path = BarkparkWeb.StaticAssets.path("bp-desk-validation.js")
    assert path =~ ~r|^/assets/v/[\w-]{16}/bp-desk-validation\.js$|
    assert html =~ ~s(data-desk-validation="#{path}")
    refute html =~ ~r/<script[^>]*bp-desk-validation/

    js = File.read!(Application.app_dir(:barkpark, "priv/static/assets/bp-desk-validation.js"))
    assert js =~ ~s("desk:goto-field")
    desk = File.read!(Application.app_dir(:barkpark, "priv/static/assets/bp-desk.js"))
    assert desk =~ ~s|deskScript("data-desk-validation"|
  end

  test "problems/1: none without a document or a schema; errors are what block" do
    assert ValidationPanel.problems(%{}) == []
    assert ValidationPanel.problems(%{editor_doc: %{title: "x", content: %{}}}) == []

    assert ValidationPanel.blocking([%{level: "error"}, %{level: "warning"}, %{level: "error"}]) ==
             2
  end
end
