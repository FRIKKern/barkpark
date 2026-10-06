defmodule BarkparkWeb.Studio.PaperPreviewUrlPublishedSlugTest do
  @moduledoc """
  task-27265c623ef901d2 — a paper's share card names the PUBLISHED reader path.

  A Studio body edit lands on the `drafts.<slug>` row through the block-ops
  path, and `Papers.BlockOps.paper_preview_opts/2` stamped
  `content.preview.url` with that raw slug: `/papers/drafts.<slug>`, a page
  that never resolves. The writer path already normalised. Now both do, and
  `ShareMeta` maps a stored draft path for rows written before the fix.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  defp seed_paper_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  test "a body edit through the canvas op path stores /papers/<published slug>", %{conn: conn} do
    seed_paper_schema!()

    {:ok, _} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => "og-url-walk",
          "title" => "Untitled",
          "content" => %{
            "blocks" => [
              %{
                "id" => "b0",
                "type" => "heading",
                "level" => 1,
                "content" => [%{"type" => "text", "value" => "A Title"}]
              }
            ]
          }
        },
        @dataset
      )

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/og-url-walk"))

    view
    |> render_hook("paper-ops", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => :sys.get_state(view.pid).socket.assigns.paper_rev,
      "ops" => [
        %{
          "op" => "insert-after",
          "afterId" => "b0",
          "block" => %{
            "id" => "b1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Body."}]
          }
        }
      ]
    })

    {:ok, draft} = Content.get_document("drafts.og-url-walk", "paper", @dataset)

    assert match?([_, %{"id" => "b1"}], draft.content["blocks"]),
           "the op must have landed on the draft"

    assert get_in(draft.content, ["preview", "url"]) == "/papers/og-url-walk"
  end

  test "a share card stored with /papers/drafts.<slug> emits the published reader url" do
    html =
      render_component(&BarkparkWeb.ShareMeta.head/1,
        preview: %{"url" => "/papers/drafts.old-row", "type" => "paper", "title" => "Old row"},
        page_title: "Old row"
      )

    [og_url] = Regex.run(~r/property="og:url" content="([^"]+)"/, html, capture: :all_but_first)
    assert og_url =~ ~r{/papers/old-row$}
    refute html =~ "drafts."
  end
end
