defmodule BarkparkWeb.PaperTocDepthFormTest do
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Barkpark.{Auth, Content}

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        "production"
      )

    token = "toc-depth-writer-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(
        token,
        "Toc depth",
        "production",
        ["read", "write"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    previous = Application.get_env(:barkpark, :portable_doc_refuse_new_errors)
    on_exit(fn -> Application.put_env(:barkpark, :portable_doc_refuse_new_errors, previous) end)

    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => token})}
  end

  test "with new errors refused, the toc form saves a depth from 1 to 6", %{conn: conn} do
    slug = fixture(2)
    refuse_new_errors()
    view = mount(conn, slug)

    for depth <- [6, 1] do
      assert %{saved: true} = submit(view, %{"depth" => Integer.to_string(depth)})
      assert stored_toc(slug)["depth"] == depth
    end
  end

  test "with new errors refused, the toc form answers a depth above 6 as a form error and stores nothing",
       %{conn: conn} do
    slug = fixture(6)
    refuse_new_errors()
    view = mount(conn, slug)
    before = stored_toc(slug)

    for depth <- ["7", "60", "6.5"] do
      assert %{saved: false, rejected: "validation"} = submit(view, %{"depth" => depth})
      assert stored_toc(slug) == before
    end
  end

  test "with new errors refused, a legacy toc above 6 keeps its depth and still saves other edits",
       %{conn: conn} do
    slug = fixture(9)
    refuse_new_errors()
    view = mount(conn, slug)

    assert %{saved: true} = submit(view, %{"depth" => "9", "numbered" => "true"})
    assert %{"depth" => 9, "numbered" => true} = stored_toc(slug)
  end

  defp refuse_new_errors,
    do: Application.put_env(:barkpark, :portable_doc_refuse_new_errors, true)

  defp submit(view, params) do
    request = Ecto.UUID.generate()

    render_hook(
      view,
      "paper-edit-block",
      Map.merge(params, %{
        "block_id" => "toc",
        "if_rev" => :sys.get_state(view.pid).socket.assigns.paper_rev,
        "request_id" => request
      })
    )

    assert_reply(view, %{request_id: ^request} = reply)
    reply
  end

  defp fixture(depth) do
    slug = "toc-depth-#{System.unique_integer([:positive])}"

    blocks = [
      %{"id" => "h-1", "type" => "heading", "level" => 2, "text" => "One"},
      %{
        "id" => "toc",
        "type" => "toc",
        "depth" => depth,
        "items" => [%{"text" => "One", "level" => 1, "anchor" => "h-1"}]
      }
    ]

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: "production",
          title: "Toc depth",
          blocks: blocks
        })
      )

    slug
  end

  defp stored_toc(slug) do
    Content.get_paper(slug, "production").content["blocks"]
    |> Enum.find(&(&1["id"] == "toc"))
  end

  defp mount(conn, slug) do
    {:ok, view, _} = live(conn, scoped_studio("/d/production/studio/paper/#{slug}"))
    view
  end
end
