defmodule BarkparkWeb.Studio.StudioFlashContainerTest do
  @moduledoc """
  task-51cc4c46e1076bd6: a flash used to insert its own node into
  .studio-shell, before the id-keyed #studio-panes. The patch moved the panes
  to make room, and the element focused inside them (the Publiser button that
  raised the flash) lost focus to <body>. The flash now fills a container that
  is always there, so a flash appearing leaves the shell's children where they
  were.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "flash-doc", "title" => "Flash"}, @dataset)

    {:ok, conn: conn}
  end

  # The ids of .studio-shell's element children, in order; id-less ones as "".
  defp shell_children(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(".studio-shell > *")
    |> Enum.map(fn node -> node |> LazyHTML.attribute("id") |> List.first() || "" end)
  end

  test "a flash fills the stable container and moves none of the shell's children", %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/flash-doc"))

    before = shell_children(html)
    assert "studio-flash" in before
    refute html =~ ~s(class="flash flash-)

    # Publishing answers with a flash.
    after_html = render_click(view, "publish", %{})

    assert after_html =~ ~s(class="flash flash-)
    assert shell_children(after_html) == before

    [container] =
      after_html |> LazyHTML.from_document() |> LazyHTML.query("#studio-flash") |> Enum.to_list()

    assert LazyHTML.to_html(container) =~ "flash flash-"
  end
end
