defmodule BarkparkWeb.Studio.DeskLiveTest do
  @moduledoc """
  The desk slice (/papers/desk-vertical-slice): the pane chain comes from the
  URL, and every row is a real link whose href is the URL it patches to.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_slice_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk slice notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    n = System.unique_integer([:positive])

    for {id, title} <- [{"dsn-a-#{n}", "Alpha note"}, {"dsn-b-#{n}", "Beta note"}] do
      {:ok, _doc} =
        Content.create_document(
          @type_name,
          %{"doc_id" => id, "title" => title, "content" => %{"summary" => "About " <> title}},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, a: "dsn-a-#{n}", b: "dsn-b-#{n}"}
  end

  defp sign_in(conn, permissions) do
    raw = "desk-slice-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-slice", @dataset, permissions, ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp admin(conn), do: sign_in(conn, ["read", "write", "admin"])

  test "the root URL draws the desk root alone, its rows links", %{conn: conn, base: base} do
    {:ok, view, _html} = live(admin(conn), base)

    assert has_element?(
             view,
             ~s([data-testid="panes"] [data-pane-index="0"][data-pane-kind="types"])
           )

    refute has_element?(view, ~s([data-pane-index="1"]))
    assert has_element?(view, ~s([data-pane-index="0"] a[data-desk-row][href^="#{base}/"]))
    refute has_element?(view, "#desk-panes [phx-click]")
  end

  test "a deep link draws root, list and document", %{conn: conn, base: base, a: a} do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")

    assert has_element?(view, ~s([data-pane-index="0"][data-pane-kind="types"]))
    assert has_element?(view, ~s([data-pane-index="1"][data-pane-kind="list"]))
    assert has_element?(view, ~s([data-pane-index="2"][data-pane-kind="doc"]))
    refute has_element?(view, ~s([data-pane-index="3"]))

    # The open row is the current one; its sibling is not.
    assert has_element?(view, ~s([data-pane-index="1"] a[aria-current="true"]), "Alpha note")
    refute has_element?(view, ~s([data-pane-index="1"] a[aria-current="true"]), "Beta note")

    # The document is printed, not edited.
    assert has_element?(view, ~s([data-pane-index="2"] dd), "About Alpha note")
    refute has_element?(view, "#desk-panes :is(input, textarea, form)")
  end

  test "a row's href is the pane URL, and following it patches there", %{
    conn: conn,
    base: base,
    a: a,
    b: b
  } do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")

    beta = ~s([data-pane-index="1"] a[data-desk-row][href="#{base}/#{@type_name};#{b}"])
    assert has_element?(view, beta, "Beta note")

    view |> element(beta) |> render_click()
    assert_patch(view, "#{base}/#{@type_name};#{b}")

    assert has_element?(view, ~s([data-pane-index="1"] a[aria-current="true"]), "Beta note")
    assert has_element?(view, ~s([data-pane-index="2"] dd), "About Beta note")
  end

  test "closing a pane goes to the URL without it", %{conn: conn, base: base, a: a} do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};#{a}")

    view |> element(~s([data-pane-index="2"] a.dk-close)) |> render_click()
    assert_patch(view, "#{base}/#{@type_name}")
    refute has_element?(view, ~s([data-pane-index="2"]))
  end

  test "a missing document and an unknown type say so in their own pane", %{
    conn: conn,
    base: base
  } do
    {:ok, view, _html} = live(admin(conn), "#{base}/#{@type_name};no-such-doc")
    assert has_element?(view, ~s([data-pane-index="1"] a[data-desk-row]))
    assert has_element?(view, ~s([data-pane-index="2"] .dk-note), "no-such-doc")

    {:ok, view, _html} = live(admin(conn), "#{base}/no_such_type")
    assert has_element?(view, ~s([data-pane-index="1"] .dk-note), "no_such_type")
  end

  test "someone who is not a workspace admin lands on the Studio", %{conn: conn, base: base} do
    studio = String.replace_suffix(base, "/_desk", "")

    assert {:error, {:live_redirect, %{to: ^studio}}} = live(sign_in(conn, ["read"]), base)
  end
end
