defmodule BarkparkWeb.PaperFigureEditingTest do
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

    raw = "figure-writer-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "Figure editing", @dataset, ["read", "write"])
    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  for host <- [:public, :studio] do
    test "#{host}: Figure child and caption persist independently with exact retry and reload", %{
      conn: conn
    } do
      host = unquote(host)
      {slug, original} = create_legacy_figure()
      {view, path} = mount_editor(conn, host, slug)
      [projected] = Content.ensure_block_ids(original["blocks"])
      child_id = projected["child"]["id"]

      assert is_binary(child_id) and child_id != ""
      assert has_element?(view, "[data-test-id='paper-figure-editor']")

      assert has_element?(
               view,
               "[data-paper-container-kind='figure'][data-paper-container-id='figure']"
             )

      refute has_element?(
               view,
               "[data-paper-container-kind='figure'][data-paper-container-row-id]"
             )

      assert stored(slug).content == original

      request = Ecto.UUID.generate()

      params = %{
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => child_id,
            "patch" => %{"content" => [%{"type" => "text", "value" => "Edited child"}]}
          }
        ],
        "container_kind" => "figure",
        "container_id" => "figure",
        "container_run_ids" => [child_id],
        "request_id" => request,
        "if_rev" => socket_of(view).assigns.paper_rev
      }

      render_hook(view, "paper-ops", params)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: false, rev: revision})
      saved = stored(slug).content
      [figure] = saved["blocks"]
      assert is_map(figure["child"])
      assert figure["child"]["content"] == [%{"type" => "text", "value" => "Edited child"}]
      assert figure["child"]["opaque"] == %{"preserve" => [1, 2]}
      assert figure["opaque"] == "outer metadata"
      assert figure["caption"] == "Original caption"

      render_hook(view, "paper-ops", params)
      assert_reply(view, %{saved: true, request_id: ^request, replayed: true, rev: ^revision})
      assert stored(slug).content == saved
      changed_retry = put_in(params, ["ops", Access.at(0), "patch", "content"], [])
      render_hook(view, "paper-ops", changed_retry)
      assert_reply(view, %{saved: false, request_id: ^request})
      assert stored(slug).content == saved

      for invalid_context <- [
            %{"container_row_id" => "illegal-row"},
            %{"container_run_ids" => []},
            %{"container_run_ids" => [child_id, "unrelated"]},
            %{"container_id" => "wrong-parent"}
          ] do
        invalid_request = Ecto.UUID.generate()

        invalid =
          params
          |> Map.merge(invalid_context)
          |> Map.put("request_id", invalid_request)
          |> Map.put("if_rev", socket_of(view).assigns.paper_rev)

        render_hook(view, "paper-ops", invalid)
        assert_reply(view, %{saved: false, request_id: ^invalid_request})
        assert stored(slug).content == saved
      end

      for structural_op <- [
            %{"op" => "remove-block", "id" => child_id},
            %{
              "op" => "insert-after",
              "after" => child_id,
              "block" => %{"id" => "extra-child", "type" => "paragraph", "content" => []}
            }
          ] do
        structural_request = Ecto.UUID.generate()

        structural =
          params
          |> Map.put("ops", [structural_op])
          |> Map.put("request_id", structural_request)
          |> Map.put("if_rev", socket_of(view).assigns.paper_rev)

        render_hook(view, "paper-ops", structural)
        assert_reply(view, %{saved: false, request_id: ^structural_request})
        assert stored(slug).content == saved
      end

      caption_request = Ecto.UUID.generate()

      caption_params = %{
        "block_id" => "figure",
        "caption" => "Edited caption",
        "request_id" => caption_request,
        "if_rev" => socket_of(view).assigns.paper_rev
      }

      render_hook(view, "paper-block-autosave", caption_params)
      assert_reply(view, %{saved: true, request_id: ^caption_request})
      [caption_saved] = stored(slug).content["blocks"]
      assert caption_saved == Map.put(figure, "caption", "Edited caption")

      {:ok, reloaded, _} = live(conn, path)
      toggle_public_editor(reloaded, host)
      assert has_element?(reloaded, "[data-test-id='paper-figure-editor']")
      assert has_element?(reloaded, "input[name='caption'][value='Edited caption']")
      render_hook(reloaded, "paper-block-autosave", caption_params)
      assert_reply(reloaded, %{saved: true, request_id: ^caption_request, replayed: true})
      assert hd(stored(slug).content["blocks"]) == caption_saved
    end

    test "#{host}: opening and closing a legacy Figure editor does not persist generated child IDs",
         %{conn: conn} do
      host = unquote(host)
      {slug, original} = create_legacy_figure()
      {view, path} = mount_editor(conn, host, slug)
      assert has_element?(view, "[data-test-id='paper-figure-editor']")
      toggle_public_editor(view, host)
      {:ok, _, _} = live(conn, path)
      assert stored(slug).content == original
    end
  end

  defp create_legacy_figure do
    slug = "figure-editing-#{System.unique_integer([:positive])}"

    blocks = [
      %{
        "id" => "figure",
        "type" => "figure",
        "caption" => "Original caption",
        "opaque" => "outer metadata",
        "child" => %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Original child"}],
          "opaque" => %{"preserve" => [1, 2]}
        }
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          title: "Figure editing",
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
