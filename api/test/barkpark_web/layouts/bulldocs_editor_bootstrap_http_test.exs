defmodule BarkparkWeb.Layouts.BulldocsEditorBootstrapHttpTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Accounts, Auth, Content}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.TenancyFixtures

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

    loader = byte_offset(html, "await ensurePaperEditorAssets()")
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

  test "account authorization lifecycle retains the connected-only lazy bootstrap", %{
    conn: conn,
    slug: slug
  } do
    {workspace, project} = TenancyFixtures.ensure_default_scope!()

    {:ok, user} =
      Accounts.register_user(%{
        email: "editor-bootstrap-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _membership} = TenancyAuth.create_membership(workspace.id, user.id, "member", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    conn = Plug.Test.init_test_session(conn, %{"user_session" => raw})
    path = "/w/#{workspace.slug}/p/#{project.slug}/papers/#{slug}"

    dead_html = conn |> get(path) |> html_response(200)

    dead_toggle =
      dead_html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([phx-hook="BarkparkPaperEditToggle"]))
      |> LazyHTML.to_html()

    assert dead_toggle =~ ~s(id="paper-edit-toggle")
    assert dead_html =~ "PaperHooks.BarkparkPaperEditToggle"

    {:ok, _view, connected_html} = live(conn, path)
    assert connected_html =~ ~s(phx-hook="BarkparkPaperEditToggle")

    assert length(:binary.matches(dead_html, "new LiveView.LiveSocket(")) == 1
  end

  defp byte_offset(haystack, needle) do
    case :binary.match(haystack, needle) do
      {offset, _length} -> offset
      :nomatch -> flunk("missing #{inspect(needle)}")
    end
  end
end
