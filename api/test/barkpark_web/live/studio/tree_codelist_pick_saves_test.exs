defmodule BarkparkWeb.Studio.TreeCodelistPickSavesTest do
  @moduledoc """
  task-0f806691db0e06dd (B05, codelist.spec:6): in the document editor, a
  pick in a tree codelist saves the code to the document.

  A codelist with more than 100 hierarchical entries renders as
  `TreeCodelistField`. A row select only set the component's own
  `:selected`; the hidden input it re-renders fires no `phx-change`, and the
  classic editor mounted the tree with no `notify_id`. So the pick reached the
  document only if another field's change submitted the form later. These
  tests click a tree row in the old Studio editor and in the desk's editing
  pane, and read the stored draft.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy

  @dataset "production"
  @plugin "onixedit"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list_id = "onixedit:tree-pick-#{n}"
    type = "tp_volume_#{n}"
    doc_id = "tp-volume-#{n}"

    # One parent with 101 children: over the 100-entry tree threshold.
    children =
      for i <- 1..101 do
        code = "FB" <> String.pad_leading(Integer.to_string(i), 3, "0")
        %{code: code, translations: [%{language: "eng", label: "Fiction #{i}"}]}
      end

    {:ok, _} =
      Codelists.register(@plugin, list_id, %{
        issue: "1",
        name: "Tree pick proof",
        values: [
          %{code: "FB", translations: [%{language: "eng", label: "Fiction"}], children: children}
        ]
      })

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "TP volumes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "subject",
              "title" => "Subject",
              "type" => "codelist",
              "codelistId" => list_id
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => "Volume one", "content" => %{}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "tree-pick-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "tree-pick", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     studio: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type,
     doc_id: doc_id}
  end

  defp stored_subject(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    doc && (doc.content || %{})["subject"]
  end

  defp pick(view, scope, code) do
    field = scope <> ~s( [data-field-name="subject"])
    row = field <> ~s( [phx-click="tree_node_select"][phx-value-code="#{code}"])

    # The parent opens once; after a pick the tree keeps it open.
    unless has_element?(view, row) do
      view
      |> element(field <> ~s( [phx-click="tree_node_toggle"][phx-value-code="FB"]))
      |> render_click()
    end

    view |> element(row) |> render_click()

    # The save rides a message the LiveView handles after the click.
    render(view)
  end

  test "old Studio: a picked tree row is saved to the document", c do
    {:ok, view, _html} = live(c.conn, "#{c.studio}/#{c.type}/#{c.doc_id}")
    assert has_element?(view, ~s([data-field-name="subject"] [phx-click="tree_node_select"]))
    assert stored_subject(c) in [nil, ""]

    pick(view, "#editor-form", "FB042")

    assert stored_subject(c) == "FB042"
  end

  test "desk: a picked tree row in the editing pane is saved to the document", c do
    {:ok, view, _html} = live(c.conn, "#{c.studio}/_desk/#{c.type};#{c.doc_id}")
    assert has_element?(view, ~s([data-pane-editing] [data-field-name="subject"]))

    pick(view, "[data-pane-editing]", "FB007")

    assert stored_subject(c) == "FB007"
  end

  test "a second pick replaces the first, and the title typed before is kept", c do
    {:ok, view, _html} = live(c.conn, "#{c.studio}/#{c.type}/#{c.doc_id}")

    view
    |> element("#editor-form")
    |> render_change(%{"doc" => %{"title" => "Volume one, retitled"}})

    pick(view, "#editor-form", "FB001")
    pick(view, "#editor-form", "FB101")

    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    assert doc.content["subject"] == "FB101"
    assert doc.title == "Volume one, retitled"
  end

  test "a hand-made pick of a code the codelist does not hold is refused", c do
    {:ok, view, _html} = live(c.conn, "#{c.studio}/#{c.type}/#{c.doc_id}")
    pick(view, "#editor-form", "FB042")

    row =
      ~s(#editor-form [data-field-name="subject"] [phx-click="tree_node_select"][phx-value-code="FB042"])

    view |> element(row) |> render_click(%{"code" => "NOPE"})
    render(view)

    assert stored_subject(c) == "FB042"
    refute render(view) =~ ~s(value="NOPE")
  end

  # task-03d337bc001f0a5b: once a code was picked, the tree offered no way
  # back to no code; the flat select has its empty option.
  for {surface, path, scope} <- [
        {"old Studio", :studio, "#editor-form"},
        {"desk", :desk, "[data-pane-editing]"}
      ] do
    test "#{surface}: Remove takes the picked code off the document", c do
      url =
        if unquote(path) == :desk,
          do: "#{c.studio}/_desk/#{c.type};#{c.doc_id}",
          else: "#{c.studio}/#{c.type}/#{c.doc_id}"

      {:ok, view, _html} = live(c.conn, url)
      field = unquote(scope) <> ~s( [data-field-name="subject"])
      refute has_element?(view, field <> ~s( [data-test-id="tree-codelist-remove"]))

      pick(view, unquote(scope), "FB042")
      assert stored_subject(c) == "FB042"

      view |> element(field <> ~s( [data-test-id="tree-codelist-remove"])) |> render_click()
      render(view)

      assert stored_subject(c) in [nil, ""]
      refute has_element?(view, field <> ~s( [data-test-id="tree-codelist-remove"]))
    end
  end

  # Remove takes itself off the page, so the focus fell to <body>. Its click
  # also focuses the tree's search box. LiveViewTest runs no JS.focus, so the
  # command is read from the button (the browser check is in the PR).
  test "Remove sends the focus to the tree's search box", c do
    {:ok, view, _html} = live(c.conn, "#{c.studio}/#{c.type}/#{c.doc_id}")
    pick(view, "#editor-form", "FB042")
    field = ~s(#editor-form [data-field-name="subject"])

    [search_id] =
      view
      |> element(field <> " input.bp-tree-search")
      |> render()
      |> then(&Regex.run(~r/id="([^"]+)"/, &1, capture: :all_but_first))

    click =
      view
      |> element(field <> ~s( [data-test-id="tree-codelist-remove"]))
      |> render()
      |> then(&Regex.run(~r/phx-click="([^"]+)"/, &1, capture: :all_but_first))
      |> hd()
      |> String.replace("&quot;", ~s("))

    assert click =~ ~s("focus")
    assert click =~ ~s("to":"##{search_id}")
  end
end
