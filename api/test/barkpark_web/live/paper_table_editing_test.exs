defmodule BarkparkWeb.PaperTableEditingTest do
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Barkpark.{Auth, Content, Repo}
  alias Barkpark.PortableDoc.TableEditing

  @dataset "production"
  @beta_type "table_editing_beta"

  setup %{conn: conn} do
    for type <- ["paper", @beta_type] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Table editing",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "type" => "string"},
              %{"name" => "body", "type" => "richText"}
            ]
          },
          @dataset
        )
    end

    raw = "table-writer-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "Table editing", @dataset, ["read", "write"])
    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  for host <- [:public, :studio, :beta] do
    test "#{host}: unsupported external Table echoes explicitly refuse a lossy editor projection",
         %{conn: conn} do
      host = unquote(host)
      {id, _} = seed(host, [table()])
      {view, _} = mount(conn, host, id)
      assert has_element?(view, "#paper-ed-table bp-paper-editor[data-editor-mode='table']")
      ragged = [[text("One")], [text("Two"), text("Three")]]
      op = %{"op" => "patch-block", "id" => "table", "patch" => %{"rows" => ragged}}

      assert {:ok, _} = apply_external(host, id, op, revision(view, host))

      assert_push_event(
        view,
        "bp:block-update",
        %{block_id: "table", table_projection: nil},
        1000
      )

      assert stored(host, id).content["blocks"] |> hd() |> Map.get("rows") == ragged
    end

    test "#{host}: nested Table cell, structural action, replay, no-op and reload preserve carriers",
         %{conn: conn} do
      host = unquote(host)
      source = table()

      blocks = [
        %{
          "id" => "grid",
          "type" => "section",
          "layout" => %{"mode" => "grid", "tracks" => 2},
          "blocks" => [
            %{
              "id" => "columns",
              "type" => "columns",
              "columns" => [[source]],
              "unknown" => "container"
            }
          ]
        }
      ]

      {id, before} = seed(host, blocks)
      {view, path} = mount(conn, host, id)
      assert has_element?(view, "#paper-ed-table bp-paper-editor[data-editor-mode='table']")
      assert stored(host, id).content == before
      {:ok, projection} = TableEditing.project(source)

      no_op =
        request(view, host, %{
          "op" => "patch-table-cells",
          "id" => "table",
          "shape" => projection.shape,
          "cells" => []
        })

      assert_reply(view, %{saved: true, request_id: ^no_op})
      assert stored(host, id).content == before

      op = %{
        "op" => "patch-table-cells",
        "id" => "table",
        "shape" => projection.shape,
        "cells" => [
          %{"area" => "body", "row" => 0, "column" => 0, "content" => text("Edited rich cell")}
        ],
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => revision(view, host)
      }

      render_hook(view, "paper-op", op)
      request_id = op["request_id"]

      assert_reply(view, %{
        saved: true,
        request_id: ^request_id,
        table_projection: reply_projection,
        table_projection_rev: reply_rev
      })

      assert reply_projection.rows == [[text("Edited rich cell")]]
      assert reply_projection.shape == projection.shape
      assert reply_rev == revision(view, host)

      assert_push_event(view, "bp:block-update", %{
        block_id: "table",
        request_id: ^request_id,
        table_projection: echo
      })

      assert echo.rows == [[text("Edited rich cell")]]
      assert echo.shape == projection.shape

      expected =
        put_in(
          source,
          ["rows", Access.at(0), "cells", Access.at(0), "content"],
          text("Edited rich cell")
        )

      expected_blocks =
        put_in(
          blocks,
          [Access.at(0), "blocks", Access.at(0), "columns", Access.at(0), Access.at(0)],
          expected
        )

      saved = stored(host, id)
      assert saved.content["blocks"] == expected_blocks

      render_hook(view, "paper-op", op)

      assert_reply(view, %{
        saved: true,
        request_id: ^request_id,
        replayed: true,
        table_projection: ^reply_projection,
        table_projection_rev: ^reply_rev
      })

      assert stored(host, id).rev == saved.rev

      structure_id =
        request(view, host, %{
          "op" => "patch-table-structure",
          "id" => "table",
          "shape" => projection.shape,
          "action" => "add-column"
        })

      assert_reply(view, %{
        saved: true,
        request_id: ^structure_id,
        table_projection: structure_reply,
        table_projection_rev: structure_rev
      })

      assert structure_reply.rows == [[text("Edited rich cell"), []]]
      assert structure_rev == revision(view, host)

      assert_push_event(view, "bp:block-update", %{
        block_id: "table",
        request_id: ^structure_id,
        table_projection: structure_echo
      })

      assert structure_echo.rows == [[text("Edited rich cell"), []]]
      {:ok, expected} = TableEditing.apply_action(expected, projection.shape, "add-column")

      final_blocks =
        put_in(
          expected_blocks,
          [Access.at(0), "blocks", Access.at(0), "columns", Access.at(0), Access.at(0)],
          expected
        )

      assert stored(host, id).content["blocks"] == final_blocks

      render_hook(view, "paper-op", op)

      assert_reply(view, %{
        saved: true,
        request_id: ^request_id,
        replayed: true,
        table_projection: ^structure_reply,
        table_projection_rev: ^structure_rev
      })

      assert stored(host, id).content["blocks"] == final_blocks
      assert revision(view, host) == structure_rev

      stale_shape =
        request(view, host, %{
          "op" => "patch-table-structure",
          "id" => "table",
          "shape" => projection.shape,
          "action" => "add-row"
        })

      assert_reply(view, %{saved: false, request_id: ^stale_shape})
      assert stored(host, id).content["blocks"] == final_blocks
      {:ok, reloaded, _} = live(conn, path)
      enter(reloaded, host)
      assert has_element?(reloaded, "#paper-ed-table bp-paper-editor[data-editor-mode='table']")
      assert stored(host, id).content["blocks"] == final_blocks
    end

    test "#{host}: idless legacy Table is visible but cannot acquire an editing identity", %{
      conn: conn
    } do
      host = unquote(host)
      {id, before} = seed(host, [Map.delete(table(), "id")])
      {view, _} = mount(conn, host, id)
      assert has_element?(view, "[data-test-id='paper-table-readonly'] .bp-table")
      refute has_element?(view, "bp-paper-editor[data-editor-mode='table']")
      assert stored(host, id).content == before
      {:ok, shape} = TableEditing.project(table())

      request_id =
        request(view, host, %{
          "op" => "patch-table-cells",
          "id" => "block-0",
          "shape" => shape.shape,
          "cells" => []
        })

      assert_reply(view, %{saved: false, request_id: ^request_id})
      assert stored(host, id).content == before
    end
  end

  defp seed(host, blocks) do
    id = "table-lab-#{System.unique_integer([:positive])}"

    doc =
      if host == :beta do
        {:ok, doc} =
          Content.create_document(@beta_type, %{"doc_id" => id, "title" => "Table lab"}, @dataset)

        doc
      else
        {:ok, doc} =
          Content.upsert_paper(
            Barkpark.LabelFixtures.paper_attrs(%{
              slug: id,
              dataset: @dataset,
              title: "Table lab",
              blocks: blocks
            })
          )

        doc
      end

    content = Map.put(doc.content, "blocks", blocks)
    Repo.update!(Ecto.Changeset.change(doc, content: content))
    {doc.doc_id, content}
  end

  defp stored(:beta, id) do
    {:ok, doc} = Content.get_document(id, @beta_type, @dataset)
    doc
  end

  defp stored(_, id), do: Content.get_paper(id, @dataset)

  defp apply_external(:beta, id, op, rev),
    do: Content.apply_document_block_op(id, @beta_type, op, @dataset, if_rev: rev)

  defp apply_external(_, id, op, rev),
    do: Content.apply_paper_block_op(id, op, @dataset, if_rev: rev)

  defp revision(view, :beta), do: :sys.get_state(view.pid).socket.assigns.editor_doc.rev
  defp revision(view, _), do: :sys.get_state(view.pid).socket.assigns.paper_rev

  defp request(view, host, op) do
    id = Ecto.UUID.generate()

    render_hook(
      view,
      "paper-op",
      Map.merge(op, %{"request_id" => id, "if_rev" => revision(view, host)})
    )

    id
  end

  defp mount(conn, host, id) do
    path =
      case host do
        :public -> "/papers/#{id}"
        :studio -> scoped_studio("/d/#{@dataset}/studio/paper/#{id}")
        :beta -> scoped_studio("/d/#{@dataset}/studio/#{@beta_type}/#{Content.published_id(id)}")
      end

    {:ok, view, _} = live(conn, path)
    enter(view, host)
    {view, path}
  end

  defp enter(view, :public), do: render_click(view, "paper-toggle-edit", %{})

  defp enter(view, :beta),
    do: view |> element("[data-test-id='editor-mode-beta']") |> render_click()

  defp enter(view, :studio) do
    if has_element?(view, "[data-test-id='paper-edit-toggle']"),
      do: view |> element("[data-test-id='paper-edit-toggle']") |> render_click(),
      else: :ok
  end

  defp text(value), do: [%{"type" => "text", "value" => value}]

  defp table do
    %{
      "id" => "table",
      "type" => "table",
      "unknown" => %{"keep" => true},
      "rows" => [
        %{
          "row-note" => "preserve",
          "cells" => [%{"cell-note" => "preserve", "content" => text("Original cell")}]
        }
      ]
    }
  end
end
