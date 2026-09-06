defmodule BarkparkWeb.PaperTerminalEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Barkpark.{Auth, Content}

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

    token = "terminal-writer-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "Terminal editing", @dataset, ["read", "write"])
    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => token})}
  end

  for host <- [:public, :studio] do
    test "#{host}: an actual external refetch publishes unsupported Terminal boundary authority",
         %{
           conn: conn
         } do
      {slug, original} = create_paper()
      {view, _path} = mount_editor(conn, unquote(host), slug)
      boundary = "#paper-terminal-boundary-terminal"
      assert has_element?(view, boundary <> "[data-paper-terminal-supported='true']")

      assert {:ok, _} =
               Content.apply_paper_block_op(
                 slug,
                 %{"op" => "patch-block", "id" => "terminal", "patch" => %{"blocks" => []}},
                 @dataset,
                 if_rev: revision(view)
               )

      current_rev = stored(slug).content["rev"]

      if unquote(host) == :public do
        assert_push_event(view, "bp:canvas-update", %{rev: ^current_rev}, 1000)
      else
        assert_push_event(
          view,
          "bp:block-update",
          %{block_id: "terminal", rev: ^current_rev},
          1000
        )
      end

      assert has_element?(view, boundary <> "[data-paper-terminal-supported='false']")

      assert has_element?(
               view,
               boundary <> "[data-paper-terminal-rev='#{current_rev}']"
             )

      assert has_element?(
               view,
               boundary <> "[data-paper-terminal-document-key='#{@dataset}:paper:#{slug}']"
             )

      expected = List.update_at(original["blocks"], 1, &Map.put(&1, "blocks", []))
      assert stored(slug).content["blocks"] == expected
    end

    test "#{host}: Add menu creates an empty Terminal that accepts its first identified child", %{
      conn: conn
    } do
      {slug, original} = create_paper()
      {view, _path} = mount_editor(conn, unquote(host), slug)
      assert has_element?(view, "select[name='block-type'] option[value='terminal']", "Terminal")
      submit(view, "paper-add-block", %{"block-type" => "terminal"})
      created = stored(slug).content["blocks"] |> List.last()
      assert %{"id" => id, "type" => "terminal", "children" => []} = created
      assert is_binary(id) and id != ""
      assert stored(slug).content["blocks"] == original["blocks"] ++ [created]
      assert has_element?(view, "#terminal-structure-form-#{id}")

      submit(view, "paper-edit-block", %{
        "block_id" => id,
        "terminal-child-count" => "0",
        "terminal-new-child-id" => "menu-created-child",
        "terminal-action" => "add"
      })

      assert List.last(stored(slug).content["blocks"]) ==
               Map.put(created, "children", [paragraph("menu-created-child", "")])
    end

    test "#{host}: unsupported initial Terminal stays readonly and refuses forged forms", %{
      conn: conn
    } do
      for extra <- [%{"blocks" => []}, %{"children" => nil}] do
        {slug, original} = create_paper(extra)
        {view, _path} = mount_editor(conn, unquote(host), slug)
        assert has_element?(view, "[data-test-id='paper-terminal-readonly']")
        refute has_element?(view, "#terminal-form-terminal")

        for params <- [
              %{"block_id" => "terminal", "title" => "Forged title"},
              %{
                "block_id" => "terminal",
                "terminal-child-count" => "0",
                "terminal-new-child-id" => "forged-child",
                "terminal-action" => "add"
              }
            ] do
          request = Ecto.UUID.generate()

          render_hook(
            view,
            "paper-edit-block",
            Map.merge(params, %{"request_id" => request, "if_rev" => revision(view)})
          )

          assert_reply(view, %{saved: false, request_id: ^request})
          assert stored(slug).content == original
        end
      end
    end

    test "#{host}: stale coarse Terminal canvas cannot replace identified children", %{conn: conn} do
      {slug, original} = create_paper()
      {view, _path} = mount_editor(conn, unquote(host), slug)
      request = Ecto.UUID.generate()
      current_rev = revision(view)

      render_hook(view, "paper-ops", %{
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "terminal",
            "patch" => %{
              "title" => "7",
              "footer" => nil,
              "live" => true,
              "children" => [
                %{
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "Old canvas draft"}]
                }
              ]
            }
          }
        ],
        "request_id" => request,
        "if_rev" => revision(view)
      })

      assert_reply(view, %{
        saved: false,
        request_id: ^request,
        rejected: "outdated_terminal_canvas",
        current_rev: ^current_rev
      })

      assert stored(slug).content == original

      request = Ecto.UUID.generate()

      render_hook(view, "paper-ops", %{
        "ops" => [
          %{
            "op" => "append-block",
            "block" => %{"id" => "old-slash-terminal", "type" => "terminal", "children" => []}
          }
        ],
        "request_id" => request,
        "if_rev" => current_rev
      })

      assert_reply(view, %{
        saved: false,
        request_id: ^request,
        rejected: "outdated_terminal_canvas",
        current_rev: ^current_rev
      })

      assert stored(slug).content == original
    end

    test "#{host}: chrome no-op preserves raw carriers and edits survive reload", %{conn: conn} do
      {slug, original} = create_paper()
      {view, path} = mount_editor(conn, unquote(host), slug)
      revision = revision(view)

      submit(view, "paper-edit-block", %{
        "block_id" => "terminal",
        "title" => "7",
        "footer" => "",
        "live" => "true"
      })

      assert stored(slug).content == original
      assert revision(view) == revision

      submit(view, "paper-edit-block", %{
        "block_id" => "terminal",
        "title" => "Shell updated",
        "footer" => "q quit",
        "live" => "false"
      })

      expected =
        update_in(
          original,
          ["blocks", Access.at(1)],
          &Map.merge(&1, %{"title" => "Shell updated", "footer" => "q quit", "live" => false})
        )

      assert_authored_content(slug, expected)
      {:ok, _, _} = live(conn, path)
      assert_authored_content(slug, expected)
    end

    test "#{host}: empty add is exact, replayable and rejects stale or colliding identities", %{
      conn: conn
    } do
      {slug, original} = create_paper()
      {view, _path} = mount_editor(conn, unquote(host), slug)

      params = %{
        "block_id" => "empty-terminal",
        "terminal-child-count" => "0",
        "terminal-new-child-id" => "seed",
        "terminal-action" => "add"
      }

      request = Ecto.UUID.generate()

      render_hook(
        view,
        "paper-edit-block",
        Map.merge(params, %{"request_id" => request, "if_rev" => revision(view)})
      )

      assert_reply(view, %{saved: false, request_id: ^request})
      assert stored(slug).content == original

      wire =
        Map.merge(params, %{
          "terminal-new-child-id" => "new-terminal-child",
          "request_id" => Ecto.UUID.generate(),
          "if_rev" => revision(view)
        })

      request = wire["request_id"]
      render_hook(view, "paper-edit-block", wire)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: false, rev: saved_rev})

      expected =
        put_in(original, ["blocks", Access.at(2), "children"], [
          paragraph("new-terminal-child", "")
        ])

      assert_authored_content(slug, expected)
      saved_revision = revision(view)
      saved_content = stored(slug).content

      render_hook(view, "paper-edit-block", wire)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: true, rev: ^saved_rev})
      assert revision(view) == saved_revision
      assert stored(slug).content == saved_content

      request = Ecto.UUID.generate()

      render_hook(
        view,
        "paper-edit-block",
        Map.merge(wire, %{
          "request_id" => request,
          "if_rev" => revision(view),
          "terminal-new-child-id" => "second-child"
        })
      )

      assert_reply(view, %{saved: false, request_id: ^request})
      assert stored(slug).content == saved_content
    end

    test "#{host}: scoped body operations preserve children and reject a changed replay", %{
      conn: conn
    } do
      {slug, original} = create_paper()
      {view, path} = mount_editor(conn, unquote(host), slug)

      assert has_element?(
               view,
               "[data-paper-container-kind='terminal'][data-paper-container-id='terminal']"
             )

      request = Ecto.UUID.generate()
      text = [%{"type" => "text", "value" => "Edited child, preserved identity"}]

      wire = %{
        "ops" => [
          %{"op" => "patch-block", "id" => "terminal-child", "patch" => %{"content" => text}}
        ],
        "container_kind" => "terminal",
        "container_id" => "terminal",
        "container_run_ids" => ["terminal-child"],
        "request_id" => request,
        "if_rev" => revision(view)
      }

      render_hook(view, "paper-ops", wire)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: false})

      expected =
        put_in(original, ["blocks", Access.at(1), "children", Access.at(0), "content"], text)

      assert_authored_content(slug, expected)
      saved_content = stored(slug).content
      render_hook(view, "paper-ops", wire)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: true})
      changed = put_in(wire, ["ops", Access.at(0), "patch", "content"], [])
      render_hook(view, "paper-ops", changed)
      assert_reply(view, %{saved: false, request_id: ^request})
      assert stored(slug).content == saved_content
      {:ok, _, _} = live(conn, path)
      assert stored(slug).content == saved_content
    end
  end

  defp submit(view, event, params) do
    request = Ecto.UUID.generate()

    render_hook(
      view,
      event,
      Map.merge(params, %{"request_id" => request, "if_rev" => revision(view)})
    )

    assert_reply(view, %{saved: true, request_id: ^request})
  end

  defp assert_authored_content(slug, expected) do
    actual = stored(slug).content
    assert actual["blocks"] == expected["blocks"]
    assert actual["body"]["blocks"] == expected["blocks"]

    assert Map.drop(actual, ~w(blocks body body_html body_html_sv rev)) ==
             Map.drop(expected, ~w(blocks body body_html body_html_sv rev))

    assert Map.drop(actual["body"], ~w(blocks html)) ==
             Map.drop(expected["body"] || %{}, ~w(blocks html))
  end

  defp create_paper(terminal_extra \\ %{}) do
    slug = "terminal-editing-#{System.unique_integer([:positive])}"

    blocks = [
      paragraph("seed", "Preserved neighbor"),
      %{
        "id" => "terminal",
        "type" => "terminal",
        "title" => 7,
        "footer" => nil,
        "live" => "live",
        "children" => [Map.put(paragraph("terminal-child", "Original child"), "custom", [1, 2])],
        "custom" => %{"preserve" => true}
      },
      %{"id" => "empty-terminal", "type" => "terminal", "children" => [], "custom" => ["opaque"]}
    ]

    blocks = List.update_at(blocks, 1, &Map.merge(&1, terminal_extra))

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Terminal authoring",
          blocks: blocks
        })
      )

    {slug, paper.content}
  end

  defp paragraph(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  defp revision(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev
  defp stored(slug), do: Content.get_paper(slug, @dataset)

  defp mount_editor(conn, host, slug) do
    path =
      if host == :public,
        do: "/papers/#{slug}",
        else: scoped_studio("/d/#{@dataset}/studio/paper/#{slug}")

    {:ok, view, _} = live(conn, path)
    if host == :public, do: render_click(view, "paper-toggle-edit", %{})
    {view, path}
  end
end
