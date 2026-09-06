defmodule BarkparkWeb.PublicPaperPasteRoundtripTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}

  @dataset "production"
  @ops_fixture Path.expand(
                 "../../support/fixtures/paper-editor/paste-redo-ops.json",
                 __DIR__
               )
  @paste_ops @ops_fixture |> File.read!() |> Jason.decode!()

  setup %{conn: conn} do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    slug = "public-paste-roundtrip-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          blocks: [
            %{
              "id" => "paragraph-1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Start "}]
            }
          ]
        })
      )

    raw = "paste-roundtrip-writer-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "paste roundtrip writer", @dataset, ["read", "write"])

    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}), slug: slug}
  end

  test "the canonical redone paste batch persists through the public editor and reload", %{
    conn: conn,
    slug: slug
  } do
    {:ok, view, _html} = live(conn, "/papers/#{slug}")
    render_click(view, "paper-toggle-edit", %{})

    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-ops", %{
      "request_id" => request_id,
      "if_rev" => assigns_of(view).paper_rev,
      "ops" => @paste_ops
    })

    assert persisted_content(slug) == hd(@paste_ops)["patch"]["content"]
    assert assigns_of(view).save_status == "Auto-saved"

    {:ok, reloaded, _html} = live(conn, "/papers/#{slug}")
    render_click(reloaded, "paper-toggle-edit", %{})

    reloaded_block =
      Enum.find(assigns_of(reloaded).edit_blocks, &(&1["id"] == "paragraph-1"))

    assert reloaded_block["content"] == hd(@paste_ops)["patch"]["content"]
  end

  defp persisted_content(slug) do
    slug
    |> Content.paper_blocks(@dataset)
    |> Enum.find(&(&1["id"] == "paragraph-1"))
    |> Map.fetch!("content")
  end

  defp assigns_of(view), do: :sys.get_state(view.pid).socket.assigns
end
