defmodule BarkparkWeb.PublicPaperAddMenuTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}

  setup %{conn: conn} do
    ensure_default_scope!()
    slug = "public-add-menu-#{System.unique_integer([:positive])}"
    token = "public-add-menu-token-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "public add menu", "production", ["read", "write"])

    blocks = [
      %{"id" => "title", "type" => "heading", "level" => 1, "text" => "Public add menu"},
      %{
        "id" => "body",
        "type" => "paragraph",
        "content" => [
          %{"type" => "strong", "children" => [%{"type" => "text", "value" => "Keep this body"}]}
        ]
      }
    ]

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Public add menu",
          "blocks" => blocks
        })
      )

    original_canvas = System.get_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      if original_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", original_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => token}), slug: slug}
  end

  for canvas <- ["0", "1"] do
    test "every offered public add-menu choice persists and deletes with canvas=#{canvas}", %{
      conn: conn,
      slug: slug
    } do
      System.put_env("BARKPARK_PAPER_CANVAS", unquote(canvas))
      {:ok, view, _} = live(conn, "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      # Read the actual shared menu, so additions automatically join this test.
      choices =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s([data-test-id="paper-add-block"] select[name="block-type"] option))
        |> LazyHTML.attribute("value")
        |> Enum.reject(&(&1 == ""))

      assert length(choices) >= 25
      assert length(Enum.uniq(choices)) == length(choices)
      original = stored_blocks(slug)

      for type <- choices do
        view
        |> element(~s([data-test-id="paper-add-block"]))
        |> render_submit(wire_params(view, %{"block-type" => type}))

        render(view)
        after_add = stored_blocks(slug)
        assert Enum.take(after_add, length(original)) == original
        assert length(after_add) == length(original) + 1
        added = List.last(after_add)
        assert added["type"] == type
        assert String.starts_with?(added["id"], "b-")
        assert :sys.get_state(view.pid).socket.assigns.save_status == "Auto-saved"

        # A fresh public mount must load the persisted structure, not socket-only state.
        {:ok, reloaded, _} = live(conn, "/papers/#{slug}")
        render_click(reloaded, "paper-toggle-edit", %{})
        assert :sys.get_state(reloaded.pid).socket.assigns.edit_blocks == after_add

        render_hook(view, "paper-delete-block", wire_params(view, %{"id" => added["id"]}))
        render(view)
        assert stored_blocks(slug) == original
        assert :sys.get_state(view.pid).socket.assigns.edit_blocks == original
        assert :sys.get_state(view.pid).socket.assigns.save_status == "Auto-saved"
      end
    end
  end

  defp stored_blocks(slug) do
    Content.get_public_paper(slug, "production").content["blocks"]
  end

  defp wire_params(view, params) do
    Map.merge(params, %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => :sys.get_state(view.pid).socket.assigns.paper_rev
    })
  end
end
