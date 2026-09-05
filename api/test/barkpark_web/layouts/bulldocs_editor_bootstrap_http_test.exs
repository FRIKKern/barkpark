defmodule BarkparkWeb.Layouts.BulldocsEditorBootstrapHttpTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  @dataset "production"

  setup %{conn: conn} do
    slug = "editor-bootstrap-#{System.unique_integer([:positive])}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          blocks: [
            %{
              "id" => "bootstrap-body",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Editable"}]
            }
          ]
        })
      )

    raw = "editor-bootstrap-writer-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "editor bootstrap writer", @dataset, ["read", "write"])

    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}), slug: slug}
  end

  test "authenticated initial HTML bootstraps editor assets before binding LiveSocket hooks", %{
    conn: conn,
    slug: slug
  } do
    html = conn |> get("/papers/#{slug}") |> html_response(200)

    assert html =~ ~s(phx-hook="BarkparkPaperEditToggle")
    assert html =~ "data-bp-paper-editor-loader"

    loader = byte_offset(html, "await loadPaperEditorAssets()")
    connect = byte_offset(html, "new LiveView.LiveSocket(")

    assert loader < connect

    for asset <- [
          "/assets/bp-paper-editor-shell.css",
          "/assets/bp-paper-editor.bundle.js",
          "/assets/bp-media-picker.js",
          "/assets/bp-reference-picker.js",
          "/assets/bp-rich-text-editor.js",
          "/assets/bp-paper-editor-hooks.js"
        ] do
      assert html =~ asset
    end
  end

  defp byte_offset(haystack, needle) do
    case :binary.match(haystack, needle) do
      {offset, _length} -> offset
      :nomatch -> flunk("missing #{inspect(needle)}")
    end
  end
end
