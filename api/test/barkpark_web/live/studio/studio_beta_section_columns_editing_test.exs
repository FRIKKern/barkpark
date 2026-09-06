defmodule BarkparkWeb.Studio.StudioBetaSectionColumnsEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content, Repo}
  alias Barkpark.Content.Document

  @dataset "production"
  @doc_type "beta_section_columns_editing"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta Section and Columns editing",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    raw = "beta-section-columns-writer-#{System.unique_integer([:positive])}"

    {:ok, _token} =
      Auth.create_token(raw, "Beta Section and Columns editing", @dataset, ["read", "write"])

    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  test "generic Beta edits nested grid Card fields without replacing sibling slots", %{conn: conn} do
    cards =
      for index <- 1..3 do
        %{
          "id" => "card:#{index}",
          "type" => "card",
          "span" => 1,
          "order" => 3 - index,
          "unknown" => index,
          "slots" => %{
            "title" => [
              %{"type" => "heading", "level" => 3, "text" => "Original", "unknown" => "title"}
            ],
            "body" => [%{"type" => "paragraph", "content" => text("Body"), "unknown" => "body"}],
            "action" => [
              %{
                "type" => "action",
                "label" => "Read",
                "href" => "/papers/original",
                "unknown" => "action"
              }
            ],
            "custom" => [%{"opaque" => [1, 2]}]
          }
        }
      end

    section = %{
      "id" => "card-grid",
      "type" => "section",
      "layout" => %{"mode" => "grid", "tracks" => 3},
      "blocks" => cards
    }

    doc = legacy_document!("cards", [section])
    before = stored_document(doc.doc_id)
    {view, path} = mount_beta(conn, doc.doc_id)
    assert has_element?(view, "[data-test-id='paper-card-editor']")
    refute render(view) =~ "card blocks are not editable yet"
    assert stored_document(doc.doc_id) == before

    request = Ecto.UUID.generate()

    params = %{
      "block_id" => "card:2",
      "card-title" => "Beta edited card",
      "card-tone" => "info",
      "card-action-label" => "Read evidence",
      "card-action-href" => "/papers/evidence",
      "request_id" => request,
      "if_rev" => socket_of(view).assigns.editor_doc.rev
    }

    render_hook(view, "paper-block-autosave", params)
    assert_reply(view, %{saved: true, replayed: false, request_id: ^request})
    saved = stored_document(doc.doc_id)
    [saved_section] = saved.content["blocks"]
    [first, edited, third] = saved_section["blocks"]
    assert first == Enum.at(cards, 0)
    assert third == Enum.at(cards, 2)
    original = Enum.at(cards, 1)
    assert Map.drop(edited, ["tone", "slots"]) == Map.drop(original, ["tone", "slots"])
    assert edited["slots"]["body"] == original["slots"]["body"]
    assert edited["slots"]["custom"] == original["slots"]["custom"]

    assert edited["slots"]["title"] == [
             Map.put(hd(original["slots"]["title"]), "text", "Beta edited card")
           ]

    assert edited["slots"]["action"] == [
             Map.merge(hd(original["slots"]["action"]), %{
               "label" => "Read evidence",
               "href" => "/papers/evidence"
             })
           ]

    assert Map.drop(saved_section, ["blocks"]) == Map.drop(section, ["blocks"])
    render_hook(view, "paper-block-autosave", params)
    assert_reply(view, %{saved: true, replayed: true, request_id: ^request})
    assert stored_document(doc.doc_id) == saved

    body_request = Ecto.UUID.generate()

    body_params = %{
      "op" => "patch-card-body",
      "id" => "card:2",
      "content" => text("Beta body preserves newer card fields"),
      "request_id" => body_request,
      "if_rev" => socket_of(view).assigns.editor_doc.rev
    }

    render_hook(view, "paper-op", body_params)
    assert_reply(view, %{saved: true, replayed: false, request_id: ^body_request})
    body_saved = stored_document(doc.doc_id)

    expected_blocks =
      update_in(
        saved.content["blocks"],
        [Access.at(0), "blocks", Access.at(1), "slots", "body", Access.at(0), "content"],
        fn _ -> body_params["content"] end
      )

    assert body_saved.content["blocks"] == expected_blocks
    assert body_saved.rev != saved.rev
    render_hook(view, "paper-op", body_params)
    assert_reply(view, %{saved: true, replayed: true, request_id: ^body_request})
    assert stored_document(doc.doc_id) == body_saved
    {:ok, reloaded, _} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(reloaded, "[data-test-id='paper-card-editor']")
    assert stored_document(doc.doc_id) == body_saved
  end

  test "generic Beta appends to empty containers with replay and stale-source protection", %{
    conn: conn
  } do
    doc =
      legacy_document!("empty", [
        %{"id" => "section", "type" => "section", "blocks" => [], "unknown" => "keep"},
        %{"id" => "columns", "type" => "columns", "columns" => [[], []], "unknown" => [1, 2]}
      ])

    {view, path} = mount_beta(conn, doc.doc_id)
    request = Ecto.UUID.generate()

    first = %{
      "block_id" => "section",
      "section-child-count" => "0",
      "section-new-child-id" => "child:one",
      "section-action" => "add",
      "request_id" => request,
      "if_rev" => socket_of(view).assigns.editor_doc.rev
    }

    render_hook(view, "paper-edit-block", first)
    assert_reply(view, %{saved: true, replayed: false, request_id: ^request})
    after_first = stored_document(doc.doc_id)
    render_hook(view, "paper-edit-block", first)
    assert_reply(view, %{saved: true, replayed: true, request_id: ^request})
    assert stored_document(doc.doc_id) == after_first

    second_request = Ecto.UUID.generate()

    second = %{
      "block_id" => "section",
      "section-child-count" => "1",
      "section-child-0-id" => "child:one",
      "section-new-child-id" => "child:two",
      "section-action" => "add",
      "request_id" => second_request,
      "if_rev" => socket_of(view).assigns.editor_doc.rev
    }

    render_hook(view, "paper-edit-block", second)
    assert_reply(view, %{saved: true, request_id: ^second_request})
    after_second = stored_document(doc.doc_id)

    stale_request = Ecto.UUID.generate()

    stale =
      first
      |> Map.put("request_id", stale_request)
      |> Map.put("if_rev", socket_of(view).assigns.editor_doc.rev)

    render_hook(view, "paper-edit-block", stale)
    assert_reply(view, %{saved: false, request_id: ^stale_request})
    assert stored_document(doc.doc_id) == after_second

    column_request = Ecto.UUID.generate()

    render_hook(view, "paper-edit-block", %{
      "block_id" => "columns",
      "column-count" => "2",
      "column-0-child-count" => "0",
      "column-1-child-count" => "0",
      "column-new-child-id" => "column:child",
      "column-action" => "add:1",
      "request_id" => column_request,
      "if_rev" => socket_of(view).assigns.editor_doc.rev
    })

    assert_reply(view, %{saved: true, request_id: ^column_request})
    final = stored_document(doc.doc_id)
    [section, columns] = final.content["blocks"]
    assert Enum.map(section["blocks"], & &1["id"]) == ["child:one", "child:two"]
    assert section["unknown"] == "keep"
    assert columns["unknown"] == [1, 2]
    assert hd(columns["columns"]) == []
    assert get_in(columns, ["columns", Access.at(1), Access.at(0), "id"]) == "column:child"
    {:ok, reloaded, _} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert stored_document(doc.doc_id) == final
  end

  test "generic Beta recursively edits Section and Columns while preserving layout metadata",
       %{conn: conn} do
    original = nested_blocks()
    doc = legacy_document!("nested", original)
    before = stored_document(doc.doc_id)
    path = studio_path(doc.doc_id)
    {:ok, view, _html} = live(conn, path)
    ids = projected_ids(socket_of(view).assigns.editor_blocks)

    assert stored_document(doc.doc_id) == before

    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert_nested_editors(view, ids)
    assert stored_document(doc.doc_id) == before

    view |> element(~s([data-test-id="editor-mode-classic"])) |> render_click()
    {:ok, view, _html} = live(conn, path)
    assert stored_document(doc.doc_id) == before

    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert_nested_editors(view, ids)
    assert stored_document(doc.doc_id) == before

    title_request = Ecto.UUID.generate()

    render_hook(view, "paper-block-autosave", %{
      "block_id" => ids.outer_section,
      "title" => "Edited outer section",
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => title_request
    })

    assert_reply(view, %{saved: true, replayed: false, request_id: ^title_request})
    after_title = stored_blocks(doc.doc_id)
    assert nested_block(after_title, ids.outer_section)["title"] == "Edited outer section"
    assert_metadata_preserved(after_title)

    child_request = Ecto.UUID.generate()

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => ids.grid_paragraph,
      "patch" => %{"content" => text("Edited grid cell")},
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => child_request
    })

    assert_reply(view, %{saved: true, replayed: false, request_id: ^child_request})
    after_child = stored_blocks(doc.doc_id)
    grid_paragraph = nested_block(after_child, ids.grid_paragraph)

    assert grid_paragraph["content"] == text("Edited grid cell")

    assert Map.take(grid_paragraph, ["span", "order", "unknown"]) == %{
             "span" => 2,
             "order" => 1,
             "unknown" => %{"keep" => true}
           }

    assert nested_block(after_child, ids.column_paragraph)["content"] == text("Column prose")
    assert nested_block(after_child, ids.left_paragraph)["content"] == text("Left column")
    assert_metadata_preserved(after_child)

    clear_title_request = Ecto.UUID.generate()

    render_hook(view, "paper-block-autosave", %{
      "block_id" => ids.outer_section,
      "title" => "",
      "if_rev" => socket_of(view).assigns.editor_doc.rev,
      "request_id" => clear_title_request
    })

    assert_reply(view, %{saved: true, replayed: false, request_id: ^clear_title_request})
    after_clear = stored_blocks(doc.doc_id)
    assert nested_block(after_clear, ids.outer_section)["title"] == nil
    assert after_clear == put_in(after_child, [Access.at(0), "title"], nil)
    assert_metadata_preserved(after_clear)

    {:ok, reloaded, _html} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    assert_nested_editors(reloaded, ids, nil)

    assert has_element?(reloaded, "#paper-ed-#{ids.grid_paragraph}")
    assert stored_blocks(doc.doc_id) == after_clear
  end

  test "generic Beta keeps a malformed Columns parent wholly read-only", %{conn: conn} do
    original = [
      %{
        "type" => "columns",
        "columns" => [[paragraph("Valid-looking sibling")], "opaque column"],
        "unknown" => %{"keep" => true}
      }
    ]

    doc = legacy_document!("malformed", original)
    before = stored_document(doc.doc_id)
    {view, path} = mount_beta(conn, doc.doc_id)

    assert has_element?(view, "[data-test-id='paper-columns-editor']")
    assert has_element?(view, "[data-test-id='paper-columns-editor'] .bp-paper-edit-readonly")
    refute has_element?(view, "[data-paper-columns-editor-frame]")
    refute has_element?(view, "[data-test-id='paper-columns-editor'] [id^='paper-ed-']")
    assert stored_document(doc.doc_id) == before

    {:ok, reloaded, _html} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    assert has_element?(reloaded, "[data-test-id='paper-columns-editor'] .bp-paper-edit-readonly")
    refute has_element?(reloaded, "[data-paper-columns-editor-frame]")
    assert stored_document(doc.doc_id) == before
  end

  defp assert_nested_editors(view, ids, outer_title \\ "Outer section") do
    assert has_element?(view, "[data-test-id='paper-section-editor']")
    assert has_element?(view, "[data-test-id='paper-columns-editor']")

    if is_binary(outer_title) do
      assert has_element?(view, "#section-title-#{ids.outer_section}[value='#{outer_title}']")
    else
      assert has_element?(view, "#section-title-#{ids.outer_section}")

      refute has_element?(
               view,
               "#section-title-#{ids.outer_section}[value='Edited outer section']"
             )
    end

    assert has_element?(view, "#section-title-#{ids.inner_section}[value='Inner section']")
    assert has_element?(view, "#section-title-#{ids.grid_section}[value='Grid section']")

    for id <- [
          ids.outer_paragraph,
          ids.left_paragraph,
          ids.column_paragraph,
          ids.inner_paragraph,
          ids.grid_paragraph
        ] do
      assert has_element?(view, "#paper-ed-#{id}")
    end

    assert has_element?(view, "[data-test-id='paper-form-contextual-editor']")

    refute has_element?(
             view,
             "[data-paper-container-kind='section'][data-paper-container-id='#{ids.grid_section}']"
           )

    assert has_element?(
             view,
             ".bp-section__cell[style='grid-column:span 2;order:1'] #paper-ed-#{ids.grid_paragraph}"
           )
  end

  defp nested_blocks do
    [
      %{
        "type" => "section",
        "title" => "Outer section",
        "outer-meta" => %{"keep" => true},
        "blocks" => [
          paragraph("Outer prose"),
          %{
            "type" => "columns",
            "gap" => "wide",
            "columns-meta" => [1, 2],
            "columns" => [
              [paragraph("Left column")],
              [
                paragraph("Column prose"),
                %{
                  "type" => "section",
                  "title" => "Inner section",
                  "inner-meta" => "preserve",
                  "blocks" => [
                    paragraph("Inner prose"),
                    %{
                      "type" => "form",
                      "kind" => "questionnaire",
                      "questions" => [],
                      "form-meta" => %{"keep" => true}
                    },
                    %{
                      "type" => "section",
                      "title" => "Grid section",
                      "layout" => %{"mode" => "grid", "tracks" => 2},
                      "grid-meta" => %{"keep" => true},
                      "blocks" => [
                        paragraph("Grid cell")
                        |> Map.merge(%{
                          "span" => 2,
                          "order" => 1,
                          "unknown" => %{"keep" => true}
                        })
                      ]
                    }
                  ]
                }
              ]
            ]
          }
        ]
      }
    ]
  end

  defp projected_ids([outer]) do
    [outer_paragraph, columns] = outer["blocks"]
    [left_column, second_column] = columns["columns"]
    [column_paragraph, inner] = second_column
    [inner_paragraph, form, grid_section] = inner["blocks"]
    [grid_paragraph] = grid_section["blocks"]

    %{
      outer_section: outer["id"],
      outer_paragraph: outer_paragraph["id"],
      columns: columns["id"],
      left_paragraph: hd(left_column)["id"],
      column_paragraph: column_paragraph["id"],
      inner_section: inner["id"],
      inner_paragraph: inner_paragraph["id"],
      form: form["id"],
      grid_section: grid_section["id"],
      grid_paragraph: grid_paragraph["id"]
    }
  end

  defp nested_block(blocks, id) when is_list(blocks) do
    Enum.find_value(blocks, fn
      %{"id" => ^id} = block ->
        block

      %{"type" => "section", "blocks" => children} when is_list(children) ->
        nested_block(children, id)

      %{"type" => "columns", "columns" => columns} when is_list(columns) ->
        Enum.find_value(columns, fn
          children when is_list(children) -> nested_block(children, id)
          _opaque -> nil
        end)

      _block ->
        nil
    end)
  end

  defp assert_metadata_preserved(blocks) do
    [outer] = blocks
    [_outer_paragraph, columns] = outer["blocks"]
    [_left, second] = columns["columns"]
    [_column_paragraph, inner] = second
    [_inner_paragraph, form, grid_section] = inner["blocks"]
    [grid_paragraph] = grid_section["blocks"]

    assert outer["outer-meta"] == %{"keep" => true}
    assert columns["gap"] == "wide"
    assert columns["columns-meta"] == [1, 2]
    assert inner["inner-meta"] == "preserve"
    assert form["form-meta"] == %{"keep" => true}
    assert grid_section["layout"] == %{"mode" => "grid", "tracks" => 2}
    assert grid_section["grid-meta"] == %{"keep" => true}
    assert grid_paragraph["span"] == 2
    assert grid_paragraph["order"] == 1
    assert grid_paragraph["unknown"] == %{"keep" => true}
  end

  defp mount_beta(conn, doc_id) do
    path = studio_path(doc_id)
    {:ok, view, _html} = live(conn, path)
    beta_html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert beta_html =~ ~s(data-test-id="studio-doc-beta-editor")
    {view, path}
  end

  defp legacy_document!(label, blocks) do
    id = "beta-section-columns-#{label}-#{System.unique_integer([:positive])}"
    {:ok, doc} = Content.create_document(@doc_type, %{"doc_id" => id, "title" => label}, @dataset)

    Repo.update_all(from(d in Document, where: d.id == ^doc.id),
      set: [content: %{"blocks" => blocks}]
    )

    stored_document(doc.doc_id)
  end

  defp paragraph(value), do: %{"type" => "paragraph", "content" => text(value)}
  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp stored_blocks(doc_id), do: stored_document(doc_id).content["blocks"]

  defp stored_document(doc_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    doc
  end

  defp studio_path(doc_id) do
    scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{Content.published_id(doc_id)}")
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
