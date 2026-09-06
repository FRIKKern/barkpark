defmodule BarkparkWeb.PaperCardEditingTest do
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

    raw = "card-writer-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "Card editing", @dataset, ["read", "write"])
    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  for host <- [:public, :studio] do
    test "#{host}: grid Card chrome edits preserve slots, siblings, and placement through reload",
         %{conn: conn} do
      host = unquote(host)
      {slug, original} = create_card_grid()
      {view, path} = mount_editor(conn, host, slug)
      assert has_element?(view, "[data-test-id='paper-card-editor']")
      refute render(view) =~ "card blocks are not editable yet"
      assert stored(slug).content == original

      for card_id <- ["story:1", "story:2", "story:3"] do
        before = stored(slug).content
        [section] = before["blocks"]
        card = Enum.find(section["blocks"], &(&1["id"] == card_id))
        request = Ecto.UUID.generate()

        params = %{
          "block_id" => card_id,
          "card-tone" => "info",
          "card-title" => "Edited #{card_id}",
          "card-media-src" => "/media/edited.png",
          "card-media-alt" => "Edited image description",
          "card-action-label" => "Read the evidence",
          "card-action-href" => "/papers/evidence",
          "card-action-priority" => "primary",
          "request_id" => request,
          "if_rev" => socket_of(view).assigns.paper_rev
        }

        render_hook(view, "paper-block-autosave", params)
        assert_reply(view, %{saved: true, request_id: ^request})
        saved = stored(slug).content
        [saved_section] = saved["blocks"]
        edited = Enum.find(saved_section["blocks"], &(&1["id"] == card_id))
        assert Map.drop(saved_section, ["blocks"]) == Map.drop(section, ["blocks"])

        assert Enum.map(saved_section["blocks"], & &1["id"]) ==
                 Enum.map(section["blocks"], & &1["id"])

        assert Enum.reject(saved_section["blocks"], &(&1["id"] == card_id)) ==
                 Enum.reject(section["blocks"], &(&1["id"] == card_id))

        assert Map.drop(edited, ["tone", "slots"]) == Map.drop(card, ["tone", "slots"])
        assert edited["tone"] == "info"
        assert edited["slots"]["body"] == card["slots"]["body"]
        assert edited["slots"]["custom"] == card["slots"]["custom"]

        assert edited["slots"]["title"] == [
                 Map.put(hd(card["slots"]["title"]), "text", "Edited #{card_id}")
               ]

        assert edited["slots"]["media"] == [
                 Map.merge(hd(card["slots"]["media"]), %{
                   "src" => "/media/edited.png",
                   "alt" => "Edited image description"
                 })
               ]

        assert edited["slots"]["action"] == [
                 Map.merge(hd(card["slots"]["action"]), %{
                   "label" => "Read the evidence",
                   "href" => "/papers/evidence",
                   "priority" => "primary"
                 })
               ]

        render_hook(view, "paper-block-autosave", params)
        assert_reply(view, %{saved: true, request_id: ^request, replayed: true})
        assert stored(slug).content == saved
      end

      final = stored(slug).content
      {:ok, reloaded, _} = live(conn, path)
      toggle_public_editor(reloaded, host)
      assert has_element?(reloaded, "[data-test-id='paper-card-editor']")
      assert stored(slug).content == final
    end

    test "#{host}: queued Card body preserves newer chrome and exact retry", %{conn: conn} do
      host = unquote(host)
      {slug, _original} = create_card_grid()
      {view, path} = mount_editor(conn, host, slug)

      body_op = %{
        "op" => "patch-card-body",
        "id" => "story:2",
        "content" => [%{"type" => "text", "value" => "Queued body survives"}]
      }

      chrome_request = Ecto.UUID.generate()

      render_hook(view, "paper-block-autosave", %{
        "block_id" => "story:2",
        "card-title" => "Newer title survives",
        "card-action-label" => "Newer action survives",
        "request_id" => chrome_request,
        "if_rev" => socket_of(view).assigns.paper_rev
      })

      assert_reply(view, %{saved: true, request_id: ^chrome_request})
      before_body = stored(slug).content
      request = Ecto.UUID.generate()

      params = %{
        "ops" => [body_op],
        "request_id" => request,
        "if_rev" => socket_of(view).assigns.paper_rev
      }

      render_hook(view, "paper-ops", params)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: false})

      expected =
        update_in(
          before_body,
          [
            "blocks",
            Access.at(0),
            "blocks",
            Access.at(1),
            "slots",
            "body",
            Access.at(0),
            "content"
          ],
          fn _ -> body_op["content"] end
        )

      saved_body = stored(slug).content
      assert saved_body["rev"] == before_body["rev"] + 1
      assert saved_body["body_html"] =~ "Queued body survives"
      assert saved_body["body_html"] =~ "Newer title survives"
      expected = Map.merge(expected, Map.take(saved_body, ["rev", "body_html"]))
      expected = put_in(expected, ["body", "blocks"], expected["blocks"])
      expected = put_in(expected, ["body", "html"], expected["body_html"])
      assert saved_body["blocks"] == expected["blocks"]
      assert stored(slug).content == expected
      render_hook(view, "paper-ops", params)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: true})
      assert stored(slug).content == expected

      later_chrome_request = Ecto.UUID.generate()

      render_hook(view, "paper-block-autosave", %{
        "block_id" => "story:2",
        "card-title" => "Title saved after body",
        "request_id" => later_chrome_request,
        "if_rev" => socket_of(view).assigns.paper_rev
      })

      assert_reply(view, %{saved: true, request_id: ^later_chrome_request})

      expected =
        update_in(
          expected,
          [
            "blocks",
            Access.at(0),
            "blocks",
            Access.at(1),
            "slots",
            "title",
            Access.at(0),
            "text"
          ],
          fn _ -> "Title saved after body" end
        )

      saved_chrome = stored(slug).content
      assert saved_chrome["rev"] == saved_body["rev"] + 1
      assert saved_chrome["body_html"] =~ "Queued body survives"
      assert saved_chrome["body_html"] =~ "Title saved after body"
      expected = Map.merge(expected, Map.take(saved_chrome, ["rev", "body_html"]))
      expected = put_in(expected, ["body", "blocks"], expected["blocks"])
      expected = put_in(expected, ["body", "html"], expected["body_html"])
      assert stored(slug).content == expected

      stale_request = Ecto.UUID.generate()
      stale = Map.put(params, "request_id", stale_request)
      render_hook(view, "paper-ops", stale)
      assert_reply(view, %{saved: false, request_id: ^stale_request})
      assert stored(slug).content == expected

      invalid_request = Ecto.UUID.generate()

      invalid = %{
        "ops" => [Map.put(body_op, "content", %{"not" => "inline content"})],
        "request_id" => invalid_request,
        "if_rev" => socket_of(view).assigns.paper_rev
      }

      render_hook(view, "paper-ops", invalid)
      assert_reply(view, %{saved: false, request_id: ^invalid_request})
      assert stored(slug).content == expected
      {:ok, _, _} = live(conn, path)
      assert stored(slug).content == expected
    end

    test "#{host}: viewing the Card editor is a byte-preserving no-op", %{conn: conn} do
      host = unquote(host)
      {slug, original} = create_card_grid()
      {view, path} = mount_editor(conn, host, slug)
      assert has_element?(view, "[data-test-id='paper-card-editor']")
      toggle_public_editor(view, host)
      {:ok, _, _} = live(conn, path)
      assert stored(slug).content == original
    end
  end

  defp create_card_grid do
    slug = "card-editing-#{System.unique_integer([:positive])}"

    cards =
      for index <- 1..3 do
        %{
          "id" => "story:#{index}",
          "type" => "card",
          "tone" => "ok",
          "span" => if(index == 1, do: 2, else: 1),
          "order" => 3 - index,
          "unknown" => %{"preserve" => index},
          "slots" => %{
            "title" => [
              %{
                "type" => "heading",
                "level" => 3,
                "text" => "Story #{index}",
                "unknown" => ["title"]
              }
            ],
            "body" => [
              %{
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "Original story body"}],
                "unknown" => ["body"]
              }
            ],
            "media" => [
              %{
                "type" => "image",
                "src" => "/media/original.png",
                "alt" => "Original description",
                "width" => 320,
                "height" => 180,
                "unknown" => ["media"]
              }
            ],
            "action" => [
              %{
                "type" => "action",
                "label" => "Original action",
                "href" => "/papers/original",
                "priority" => "secondary",
                "unknown" => ["action"]
              }
            ],
            "custom" => [%{"opaque" => [1, 2, 3]}]
          }
        }
      end

    blocks = [
      %{
        "id" => "stories",
        "type" => "section",
        "variant" => "wide",
        "layout" => %{"mode" => "grid", "tracks" => 4, "gap" => "sm"},
        "blocks" => cards
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Card editing",
          blocks: blocks
        })
      )

    original = Map.put(paper.content, "blocks", blocks)
    paper |> Ecto.Changeset.change(content: original) |> Repo.update!()
    {slug, original}
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
