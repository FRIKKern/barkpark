defmodule BarkparkWeb.PaperSectionColumnsEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Barkpark.{Auth, Content, Repo}

  @dataset "production"

  setup %{conn: conn} do
    previous = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    raw = "section-columns-writer-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "Section and Columns editing", @dataset, ["read", "write"])
    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  for host <- [:public, :studio] do
    for collision <- [:cross_column, :outside_container] do
      test "#{host}: #{collision} duplicate identities cannot expose nested editors or mutate storage",
           %{conn: conn} do
        {slug, original} = create_duplicate_columns_paper(unquote(collision))
        assert_duplicate_source_readonly(conn, unquote(host), slug, original)
        assert stored(slug).content == original
      end
    end

    test "#{host}: nested Section and Columns contexts patch exact children and survive reload",
         %{
           conn: conn
         } do
      host = unquote(host)
      {slug, original} = create_legacy_nested_paper()
      {view, path} = mount_editor(conn, host, slug)
      ids = projected_ids(original)

      assert_nested_contexts(view, ids)
      assert has_element?(view, "[data-test-id='paper-form-contextual-editor']")

      refute has_element?(
               view,
               "[data-paper-container-kind='section'][data-paper-container-id='#{ids.grid_section}']"
             )

      assert_grid_cell_editor(view, ids.grid_paragraph)
      assert stored(slug).content == original

      request = Ecto.UUID.generate()

      inner_patch = %{
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => ids.inner_paragraph,
            "patch" => %{
              "content" => [%{"type" => "text", "value" => "Edited inner paragraph"}]
            }
          }
        ],
        "container_kind" => "section",
        "container_id" => ids.inner_section,
        "container_run_ids" => [ids.inner_paragraph],
        "request_id" => request,
        "if_rev" => socket_of(view).assigns.paper_rev
      }

      render_hook(view, "paper-ops", inner_patch)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: false, rev: revision})
      after_inner = stored(slug).content

      assert nested_block(after_inner, ids.inner_paragraph)["content"] == [
               %{"type" => "text", "value" => "Edited inner paragraph"}
             ]

      render_hook(view, "paper-ops", inner_patch)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: true, rev: ^revision})
      assert stored(slug).content == after_inner

      changed_retry =
        put_in(
          inner_patch,
          ["ops", Access.at(0), "patch", "content"],
          [%{"type" => "text", "value" => "Different retry"}]
        )

      render_hook(view, "paper-ops", changed_retry)
      assert_reply(view, %{saved: false, request_id: ^request})
      assert stored(slug).content == after_inner

      column_request = Ecto.UUID.generate()

      column_patch = %{
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => ids.column_paragraph,
            "patch" => %{
              "content" => [%{"type" => "text", "value" => "Edited column paragraph"}]
            }
          }
        ],
        "container_kind" => "columns",
        "container_id" => ids.columns,
        "container_column_index" => 1,
        "container_run_ids" => [ids.column_paragraph],
        "request_id" => column_request,
        "if_rev" => socket_of(view).assigns.paper_rev
      }

      render_hook(view, "paper-ops", column_patch)
      assert_reply(view, %{saved: true, request_id: ^column_request})
      after_column = stored(slug).content

      assert nested_block(after_column, ids.column_paragraph)["content"] == [
               %{"type" => "text", "value" => "Edited column paragraph"}
             ]

      grid_request = Ecto.UUID.generate()

      render_hook(view, "paper-edit-block", %{
        "block_id" => ids.grid_paragraph,
        "text" => "Edited grid cell",
        "request_id" => grid_request,
        "if_rev" => socket_of(view).assigns.paper_rev
      })

      assert_reply(view, %{saved: true, request_id: ^grid_request})
      after_grid = stored(slug).content
      grid_paragraph = nested_block(after_grid, ids.grid_paragraph)
      assert grid_paragraph["content"] == [%{"type" => "text", "value" => "Edited grid cell"}]

      assert Map.take(grid_paragraph, ["span", "order", "unknown"]) == %{
               "span" => 2,
               "order" => 1,
               "unknown" => %{"keep" => true}
             }

      collision_request = Ecto.UUID.generate()

      collision =
        column_patch
        |> Map.put("ops", [
          %{
            "op" => "append-block",
            "block" => %{"id" => ids.left_paragraph, "type" => "paragraph", "content" => []}
          }
        ])
        |> Map.put("request_id", collision_request)
        |> Map.put("if_rev", socket_of(view).assigns.paper_rev)

      render_hook(view, "paper-ops", collision)
      assert_reply(view, %{saved: false, request_id: ^collision_request})
      assert stored(slug).content == after_grid

      wrong_column_request = Ecto.UUID.generate()

      wrong_column =
        column_patch
        |> Map.put("container_column_index", 0)
        |> Map.put("request_id", wrong_column_request)
        |> Map.put("if_rev", socket_of(view).assigns.paper_rev)

      render_hook(view, "paper-ops", wrong_column)
      assert_reply(view, %{saved: false, request_id: ^wrong_column_request})
      assert stored(slug).content == after_grid

      assert_metadata_preserved(after_grid)

      {:ok, reloaded, _} = live(conn, path)
      toggle_public_editor(reloaded, host)
      assert_nested_contexts(reloaded, ids)
      assert has_element?(reloaded, "[data-test-id='paper-form-contextual-editor']")

      refute has_element?(
               reloaded,
               "[data-paper-container-kind='section'][data-paper-container-id='#{ids.grid_section}']"
             )

      assert_grid_cell_editor(reloaded, ids.grid_paragraph)
      assert stored(slug).content == after_grid
    end

    test "#{host}: clearing a Section title preserves its children and metadata", %{conn: conn} do
      host = unquote(host)
      {slug, original} = create_legacy_nested_paper()
      {view, path} = mount_editor(conn, host, slug)
      [projected] = Content.ensure_block_ids(original["blocks"])
      request = Ecto.UUID.generate()

      render_hook(view, "paper-edit-block", %{
        "block_id" => projected["id"],
        "title" => "",
        "request_id" => request,
        "if_rev" => socket_of(view).assigns.paper_rev
      })

      assert_reply(view, %{saved: true, request_id: ^request})
      cleared = stored(slug).content
      assert cleared["blocks"] == [Map.put(projected, "title", nil)]
      derived_keys = ~w(blocks body body_html body_html_sv preview rev)
      assert Map.drop(cleared, derived_keys) == Map.drop(original, derived_keys)

      invalid_request = Ecto.UUID.generate()

      render_hook(view, "paper-edit-block", %{
        "block_id" => projected["id"],
        "title" => %{"unexpected" => "object"},
        "request_id" => invalid_request,
        "if_rev" => socket_of(view).assigns.paper_rev
      })

      assert_reply(view, %{saved: false, request_id: ^invalid_request})
      assert stored(slug).content == cleared

      {:ok, reloaded, _} = live(conn, path)
      toggle_public_editor(reloaded, host)
      assert stored(slug).content == cleared
    end

    test "#{host}: mounting and closing nested legacy editors does not persist projected IDs", %{
      conn: conn
    } do
      host = unquote(host)
      {slug, original} = create_legacy_nested_paper()
      {view, path} = mount_editor(conn, host, slug)
      ids = projected_ids(original)
      assert_nested_contexts(view, ids)
      toggle_public_editor(view, host)
      {:ok, _, _} = live(conn, path)
      assert stored(slug).content == original
    end

    test "#{host}: malformed Columns remain read-only and never expose a partial column canvas",
         %{
           conn: conn
         } do
      host = unquote(host)
      {slug, original} = create_malformed_columns_paper()
      {view, path} = mount_editor(conn, host, slug)
      [columns] = Content.ensure_block_ids(original["blocks"])

      refute has_element?(
               view,
               "[data-paper-container-kind='columns'][data-paper-container-id='#{columns["id"]}']"
             )

      toggle_public_editor(view, host)
      {:ok, _, _} = live(conn, path)
      assert stored(slug).content == original
    end
  end

  defp assert_duplicate_source_readonly(conn, :public, slug, _original) do
    assert_raise BarkparkWeb.BulldocsLive.InvalidSource, ~r/ambiguous_source/, fn ->
      mount_editor(conn, :public, slug)
    end
  end

  defp assert_duplicate_source_readonly(conn, :studio, slug, original) do
    {view, path} = mount_editor(conn, :studio, slug)
    assert has_element?(view, "[data-test-id='paper-identity-readonly']")
    refute has_element?(view, "[data-test-id='paper-add-block']")
    refute has_element?(view, "[data-edit-block-id]")
    refute has_element?(view, "[data-paper-container-kind='columns']")
    refute has_element?(view, "[data-paper-container-kind='section']")
    refute has_element?(view, "[data-test-id='paper-form-contextual-editor']")
    assert stored(slug).content == original
    request = Ecto.UUID.generate()

    render_hook(view, "paper-edit-block", %{
      "block_id" => "duplicate-form",
      "kind" => "grill",
      "request_id" => request,
      "if_rev" => socket_of(view).assigns.paper_rev
    })

    assert_reply(view, %{saved: false, request_id: ^request})
    assert stored(slug).content == original
    {:ok, _, _} = live(conn, path)
  end

  defp assert_nested_contexts(view, ids) do
    assert has_element?(
             view,
             "[data-paper-container-kind='section'][data-paper-container-id='#{ids.outer_section}']"
           )

    assert has_element?(
             view,
             "[data-paper-container-kind='columns'][data-paper-container-id='#{ids.columns}']" <>
               "[data-paper-container-column-index='1']"
           )

    assert has_element?(
             view,
             "[data-paper-container-kind='section'][data-paper-container-id='#{ids.inner_section}']"
           )
  end

  defp assert_grid_cell_editor(view, grid_paragraph_id) do
    assert has_element?(
             view,
             ".bp-section__cell[style='grid-column:span 2;order:1'] #paper-ed-#{grid_paragraph_id}"
           )
  end

  defp create_legacy_nested_paper do
    slug = "section-columns-editing-#{System.unique_integer([:positive])}"

    blocks = [
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

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Section and Columns editing",
          blocks: blocks
        })
      )

    original = Map.put(paper.content, "blocks", blocks)
    paper |> Ecto.Changeset.change(content: original) |> Repo.update!()
    {slug, original}
  end

  defp create_malformed_columns_paper do
    slug = "malformed-columns-editing-#{System.unique_integer([:positive])}"

    blocks = [
      %{
        "type" => "columns",
        "columns" => [[paragraph("Valid-looking sibling")], "opaque column"],
        "unknown" => %{"keep" => true}
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Malformed Columns editing",
          blocks: blocks
        })
      )

    original = Map.put(paper.content, "blocks", blocks)
    paper |> Ecto.Changeset.change(content: original) |> Repo.update!()
    {slug, original}
  end

  defp create_duplicate_columns_paper(collision) do
    slug = "duplicate-columns-editing-#{System.unique_integer([:positive])}"

    form = %{
      "id" => "duplicate-form",
      "type" => "form",
      "kind" => "questionnaire",
      "questions" => [],
      "unknown" => %{"keep" => true}
    }

    inner = %{
      "id" => "inner-section",
      "type" => "section",
      "title" => "Nested",
      "blocks" => [form]
    }

    columns = %{
      "id" => "columns-parent",
      "type" => "columns",
      "columns" => [[inner], if(collision == :cross_column, do: [form], else: [])]
    }

    blocks = if collision == :outside_container, do: [columns, form], else: [columns]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Duplicate identity fixture",
          blocks: [paragraph("Fixture seed")]
        })
      )

    original = Map.put(paper.content, "blocks", blocks)
    paper |> Ecto.Changeset.change(content: original) |> Repo.update!()
    {slug, original}
  end

  defp projected_ids(original) do
    [outer] = Content.ensure_block_ids(original["blocks"])
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

  defp nested_block(content, id) do
    content["blocks"]
    |> Content.ensure_block_ids()
    |> find_block(id)
  end

  defp find_block(blocks, id) when is_list(blocks) do
    Enum.find_value(blocks, fn
      %{"id" => ^id} = block ->
        block

      %{"type" => "section", "blocks" => children} when is_list(children) ->
        find_block(children, id)

      %{"type" => "columns", "columns" => columns} when is_list(columns) ->
        Enum.find_value(columns, fn
          children when is_list(children) -> find_block(children, id)
          _opaque -> nil
        end)

      _block ->
        nil
    end)
  end

  defp assert_metadata_preserved(content) do
    [outer] = content["blocks"]
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

  defp paragraph(value) do
    %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => value}]}
  end

  defp mount_editor(conn, host, slug) do
    path =
      if host == :public,
        do: "/papers/#{slug}",
        else: scoped_studio("/d/#{@dataset}/studio/paper/#{slug}")

    {:ok, view, _} = live(conn, path)
    toggle_public_editor(view, host)
    {view, path}
  end

  defp toggle_public_editor(view, :public), do: render_click(view, "paper-toggle-edit", %{})
  defp toggle_public_editor(_view, :studio), do: :ok

  defp stored(slug), do: Content.get_paper(slug, @dataset)
  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
