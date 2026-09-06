defmodule BarkparkWeb.PaperStageEditingTest do
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Barkpark.{Auth, Content}

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
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        "production"
      )

    token = "stage-writer-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "Stage editing", "production", ["read", "write"])
    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => token})}
  end

  for host <- [:public, :studio] do
    test "#{host}: slotted Stage saves authoritative text and retains provenance across reload",
         %{conn: conn} do
      {slug, original} = fixture()
      {view, path} = mount(conn, unquote(host), slug)
      assert has_element?(view, "#stage-form-stage")
      refute has_element?(view, "bp-paper-canvas[data-canvas-blocks*='stage']")
      assert has_element?(view, "[data-test-id='paper-stage-preview']", "Original")

      assert has_element?(
               view,
               "[data-test-id='paper-stage-preview'] textarea[name='stage-title']",
               "Original"
             )

      assert has_element?(
               view,
               "[data-test-id='paper-stage-preview'] textarea[name='stage-detail']"
             )

      refute has_element?(view, "details [name='stage-title'], details [name='stage-detail']")
      assert has_element?(view, "details [name='stage-source-mode']")
      assert render(view) =~ "4 words"
      rev = revision(view)

      submit(view, %{
        "stage-title" => "Original",
        "stage-source-mode" => "provenance",
        "stage-source-text" => "queue.ex:42"
      })

      assert revision(view) == rev
      assert stored(slug) == original
      submit(view, %{"stage-title" => "Changed"})

      expected =
        put_in(
          original,
          [Access.at(0), "slots", "title", Access.at(0), "content", Access.at(0), "value"],
          "Changed"
        )

      assert stored(slug) == expected
      assert has_element?(view, "[data-test-id='paper-stage-preview']", "Changed")
      {:ok, _, _} = live(conn, path)
      assert stored(slug) == expected
    end

    test "#{host}: outdated Stage canvas gets a typed refusal without mutation", %{conn: conn} do
      {slug, original} = fixture()
      {view, _} = mount(conn, unquote(host), slug)

      for op <- [
            %{
              "op" => "patch-block",
              "id" => "stage",
              "patch" => %{"title" => "Invisible flat shadow", "source" => true}
            },
            %{
              "op" => "append-block",
              "block" => %{"id" => "old-stage", "type" => "stage", "title" => "Old client"}
            }
          ] do
        request = Ecto.UUID.generate()
        rev = revision(view)
        render_hook(view, "paper-ops", %{"ops" => [op], "if_rev" => rev, "request_id" => request})

        assert_reply(view, %{
          saved: false,
          rejected: "outdated_stage_canvas",
          request_id: ^request,
          current_rev: ^rev
        })

        assert stored(slug) == original
      end
    end
  end

  defp submit(view, params) do
    request = Ecto.UUID.generate()

    render_hook(
      view,
      "paper-edit-block",
      Map.merge(params, %{
        "block_id" => "stage",
        "if_rev" => revision(view),
        "request_id" => request
      })
    )

    assert_reply(view, %{saved: true, request_id: ^request})
  end

  defp fixture do
    slug = "stage-editing-#{System.unique_integer([:positive])}"

    blocks = [
      %{
        "id" => "stage",
        "type" => "stage",
        "title" => "Shadow",
        "source" => "queue.ex:42",
        "qa" => "parent",
        "slots" => %{
          "future" => %{"preserve" => true},
          "title" => [
            %{
              "id" => "title",
              "type" => "paragraph",
              "qa" => "paragraph",
              "content" => [
                %{"id" => "leaf", "type" => "text", "value" => "Original", "qa" => "leaf"}
              ]
            }
          ]
        }
      },
      %{
        "id" => "neighbor",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Unchanged neighbor"}]
      }
    ]

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: "production",
          title: "Stage authoring",
          blocks: blocks
        })
      )

    {slug, stored(slug)}
  end

  defp stored(slug), do: Content.get_paper(slug, "production").content["blocks"]
  defp revision(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev

  defp mount(conn, host, slug) do
    path =
      if host == :public,
        do: "/papers/#{slug}",
        else: scoped_studio("/d/production/studio/paper/#{slug}")

    {:ok, view, _} = live(conn, path)
    if host == :public, do: render_click(view, "paper-toggle-edit", %{})
    {view, path}
  end
end
