defmodule BarkparkWeb.Studio.PaperEditor.FallbackRichBodyTest do
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  alias BarkparkWeb.Studio.StudioLive.Blocks

  @rich_content [
    %{
      "type" => "strong",
      "children" => [
        %{
          "type" => "link",
          "href" => "https://example.com/guide",
          "children" => [%{"type" => "text", "value" => "Read the guide"}]
        }
      ]
    },
    %{"type" => "text", "value" => " before continuing."}
  ]

  test "a callout chrome-only change does not synthesize a lossy body patch" do
    callout = %{
      "id" => "callout-rich",
      "type" => "callout",
      "tone" => "info",
      "content" => @rich_content
    }

    patch = Blocks.build_block_patch(callout, %{"tone" => "warning"})

    assert patch["tone"] == "warning"
    refute Map.has_key?(patch, "content")
  end

  test "fallback rich bodies mount the canonical WC with their complete block JSON", %{
    conn: conn
  } do
    blocks = [
      %{
        "id" => "callout-rich",
        "type" => "callout",
        "tone" => "info",
        "content" => @rich_content
      },
      %{"id" => "ingress-rich", "type" => "ingress", "content" => @rich_content},
      %{"id" => "pullquote-rich", "type" => "pullquote", "content" => @rich_content},
      %{"id" => "list-rich", "type" => "list", "items" => [@rich_content]}
    ]

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: @slug, dataset: @dataset, blocks: blocks})
      )

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    html = open_editor(view)

    for id <- ~w(callout-rich ingress-rich pullquote-rich list-rich) do
      assert html =~ ~s(id="paper-ed-#{id}")
    end

    assert html =~ "https://example.com/guide"
    assert html =~ "Read the guide"
    refute html =~ ~s(data-test-id="paper-field-ingress")
    refute html =~ ~s(data-test-id="paper-field-pullquote")

    view
    |> element(~s([data-edit-block-id="callout-rich"] form.bp-paper-edit-form))
    |> render_change(%{
      "block_id" => "callout-rich",
      "tone" => "warning",
      "title" => "Changed chrome only",
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => :sys.get_state(view.pid).socket.assigns.paper_rev
    })

    after_chrome =
      Content.paper_blocks(@slug, @dataset) |> Enum.find(&(&1["id"] == "callout-rich"))

    assert after_chrome["tone"] == "warning"
    assert after_chrome["title"] == "Changed chrome only"
    assert after_chrome["content"] == @rich_content

    changed_content =
      put_in(
        @rich_content,
        [Access.at(0), "children", Access.at(0), "children", Access.at(0), "value"],
        "Read the revised guide"
      )

    for {id, patch} <- [
          {"callout-rich", %{"content" => changed_content}},
          {"ingress-rich", %{"content" => changed_content}},
          {"pullquote-rich", %{"content" => changed_content}},
          {"list-rich", %{"items" => [changed_content]}}
        ] do
      render_hook(view, "paper-op", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => :sys.get_state(view.pid).socket.assigns.paper_rev,
        "op" => "patch-block",
        "id" => id,
        "patch" => patch
      })
    end

    stored = Content.paper_blocks(@slug, @dataset) |> Map.new(&{&1["id"], &1})

    assert stored["callout-rich"]["content"] == changed_content
    assert stored["callout-rich"]["tone"] == "warning"
    assert stored["ingress-rich"]["content"] == changed_content
    assert stored["pullquote-rich"]["content"] == changed_content
    assert stored["list-rich"]["items"] == [changed_content]

    {:ok, reloaded, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

    reloaded_html = open_editor(reloaded)

    for id <- ~w(callout-rich ingress-rich pullquote-rich list-rich) do
      assert reloaded_html =~ ~s(id="paper-ed-#{id}")
    end

    assert reloaded_html =~ "Read the revised guide"
    assert reloaded_html =~ "https://example.com/guide"
  end
end
