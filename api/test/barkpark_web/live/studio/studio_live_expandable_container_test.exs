defmodule BarkparkWeb.Studio.StudioLiveExpandableContainerTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    slug = "studio-expandable-#{System.unique_integer([:positive])}"

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

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          blocks: [
            %{
              "id" => "details",
              "type" => "expandable",
              "summary" => "Details",
              "children" => [
                %{
                  "id" => "nested",
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "Before"}]
                }
              ],
              "unknown" => "keep"
            }
          ]
        })
      )

    %{slug: slug}
  end

  test "Studio Paper mounts an eligible nested canvas and persists its scoped batch after remount",
       %{conn: conn, slug: slug} do
    path = scoped_studio("/d/#{@dataset}/studio/paper/#{slug}")
    {:ok, view, html} = live(conn, path)

    assert html =~ ~s(data-paper-container-id="details")
    assert html =~ ~s(phx-hook="BarkparkPaperCanvas")

    request_id = Ecto.UUID.generate()

    render_hook(view, "paper-ops", %{
      "ops" => [
        %{
          "op" => "patch-block",
          "id" => "nested",
          "patch" => %{"content" => [%{"type" => "text", "value" => "After"}]}
        }
      ],
      "container_id" => "details",
      "container_run_ids" => ["nested"],
      "if_rev" => socket_of(view).assigns.paper_rev,
      "request_id" => request_id
    })

    assert_reply(view, %{saved: true, request_id: ^request_id})

    assert [%{"unknown" => "keep", "children" => [%{"content" => content}]}] = stored_blocks(slug)
    assert content == [%{"type" => "text", "value" => "After"}]

    {:ok, reloaded, _html} = live(recycle(conn), path)
    assert socket_of(reloaded).assigns.paper_doc.content["blocks"] == stored_blocks(slug)
  end

  defp stored_blocks(slug) do
    slug
    |> Content.get_paper(@dataset)
    |> get_in([Access.key!(:content), "blocks"])
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
