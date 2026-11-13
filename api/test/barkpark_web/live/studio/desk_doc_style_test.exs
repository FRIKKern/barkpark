defmodule BarkparkWeb.Studio.DeskDocStyleTest do
  @moduledoc """
  LOOKS PR 1: the desk's document form as the TanStack Studio draws it
  (`Desk.DocStyle`): the type's name and a large title over a centred
  column, field labels as written, pill group tabs, and no "<Type> · N
  fields" line. The old Studio's editor keeps its own line and look.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @pane "[data-pane-editing]"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "doc_look_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Look #{n}",
          "visibility" => "public",
          "fields" => [
            %{
              "name" => "title",
              "title" => "Title",
              "type" => "string",
              "validation" => %{"required" => true}
            },
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "text"}
          ]
        },
        @dataset
      )

    id = "dl-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Looked at"}, @dataset)
    {:ok, _} = Content.publish_document(id, type, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-doc-look-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-doc-look", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     n: n,
     type: type,
     id: id,
     desk: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{type};#{id}",
     studio: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{type}/#{id}"}
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  test "the desk: the type's name and the title over the form, no field count", c do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)

    assert has_element?(view, "#{@pane} .editor-meta .dk-kind", "Look #{c.n}")
    assert has_element?(view, "#{@pane} .editor-meta .dk-big-title", "Looked at")
    refute view |> element("#{@pane} .editor-body") |> render() =~ "2 fields"
  end

  test "the desk's sheet: TanStack's column, labels and tabs, under the edit pane only", c do
    {:ok, view, _html} = live(c.conn, c.desk)
    html = render(view)

    # The form column (TanStack `.doc-form`: 640 px less 20 px each side, 28 px from the top).
    assert html =~
             ".dk .dk-edit .editor-body.editor-panel-main { max-width: none; padding: 28px max(20px, calc(50% - 300px)) 161px;"

    # A label as written (`.field > label`: 13 px, 500, 15 px over the input), 59 px under a field.
    assert html =~
             "font-size: 13px; line-height: 19px; font-weight: 500; letter-spacing: 0; text-transform: none;"

    assert html =~
             ".dk .dk-edit .editor-field, .dk .dk-edit .editor-field-self-titled { margin-bottom: 59px; }"

    # Pills (`.group-tabs [role=tab]`), not an underline.
    assert html =~ ".dk .dk-edit .bp-tab.is-active { background: var(--dk-selected-fill);"
    # Dark values follow the page's theme.
    assert html =~ ~s(html[data-theme="dark"] .dk .dk-edit {)
  end

  # LOOKS PR 4. TanStack steps the title by its `.doc-column` (the pane), not by
  # the 600 px form inside it (barkpark-studio's stylesheet, the `.doc-column`
  # title rules): at 1440 it is 33 px.
  test "the title steps by the pane, not by the 600 px column", c do
    {:ok, view, _html} = live(c.conn, c.desk)
    html = render(view)

    assert html =~
             "@container panel (max-width: 600px) { .dk .dk-edit .dk-big-title { font-size: 27px;"

    assert html =~
             "@container panel (max-width: 464px) { .dk .dk-edit .dk-big-title { font-size: 21px;"

    refute html =~ "dk-doc-column"
  end

  # TanStack `.input` (:672-675, :692-693) and `.btn-create.btn-generate` (:793-795).
  test "inputs are ringed, not bordered; Generate is TanStack's secondary button", c do
    {:ok, view, _html} = live(c.conn, c.desk)
    html = render(view)

    assert html =~ "border: 0; border-radius: 3px; box-shadow: inset 0 0 0 1px var(--dk-line); }"

    assert html =~
             ".dk .dk-edit .form-input:hover:not(:focus, :disabled, [readonly]) { box-shadow: inset 0 0 0 1px var(--dk-input-hover-ring); }"

    assert html =~
             ".dk .dk-edit .form-input:focus { outline: none; box-shadow: inset 0 0 0 1px var(--dk-focus-ring); }"

    assert html =~
             ~S|.dk .dk-edit button[phx-click="slug-generate"] { box-sizing: border-box; flex: none; height: 35px; padding: 0 12px; border: 0; border-radius: 3px; background: var(--dk-bg-soft);|

    # Light and dark values, TanStack's tokens.
    assert html =~ "--dk-btn2-fg: rgb(78 85 109); --dk-btn2-ring: rgb(230 230 234);"
    assert html =~ "--dk-btn2-fg: rgb(153 158 179); --dk-btn2-ring: rgb(38 40 55);"
    # The pane is TanStack's page colour, and focus is its blue, not the Studio's green.
    assert html =~ "--bg: var(--dk-bg); background: var(--bg);"

    assert html =~
             ".dk .dk-edit :where(button, a, [role=tab], [tabindex]):focus-visible { outline: 1px solid var(--dk-focus-ring);"
  end

  test "control: the old Studio's editor keeps its type line and field count", c do
    {:ok, view, _html} = live(c.conn, c.studio)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)

    assert has_element?(view, ".editor-meta", "2 fields")
    refute has_element?(view, ".dk-big-title")
  end
end
