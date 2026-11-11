defmodule BarkparkWeb.Studio.DeskListCreateTest do
  @moduledoc """
  J18: a desk list's header has the TanStack Studio's "Create new <type>"
  button. It sends the Studio's own `new-document` to the page (no target),
  naming its pane, so the new document opens right after the list. A type
  whose desk block says `authorCreatable: false` has none.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @post "dlc_post"
  @intake "dlc_intake"

  setup %{conn: conn} do
    fields = [%{"name" => "title", "title" => "Title", "type" => "string"}]

    for {name, title, desk} <- [
          {@post, "Create posts", %{}},
          {@intake, "Intake forms", %{"authorCreatable" => false}}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => title,
            "visibility" => "public",
            "fields" => fields,
            "desk" => desk
          },
          @dataset
        )

      {:ok, _} =
        Content.create_document(name, %{"doc_id" => "#{name}-one", "title" => "One"}, @dataset)
    end

    raw = "dlc-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "dlc", @dataset, ["read", "write", "admin"], ws.id)
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"}
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  @button ~s([data-pane-index="1"] .pane-header button[aria-label="Create new Create posts"])

  test "a list's Create new sends the Studio's new-document for its pane", %{
    conn: conn,
    base: base
  } do
    view = open(conn, "#{base}/#{@post}")

    assert has_element?(
             view,
             @button <>
               ~s([phx-click="new-document"][phx-value-type="#{@post}"][phx-value-desk-pane="1"])
           )

    refute has_element?(view, @button <> "[phx-target]")

    view |> element(@button) |> render_click()
    landed = assert_patch(view, 2_000)

    assert landed =~ ~r"^#{Regex.escape(base)}/#{@post};#{@post}-[0-9a-f]+$",
           "the new document landed on #{landed}"

    # It opens in the editor, as the pane after the list.
    editing = ~s([data-pane-index="2"][data-pane-editing] #editor-form)

    assert Enum.any?(1..100, fn _ ->
             render_async(view, 5_000)
             has_element?(view, editing) or (Process.sleep(20) && false)
           end),
           "the new document never opened in the editor"
  end

  test "a type its authors do not create has no Create new", %{conn: conn, base: base} do
    view = open(conn, "#{base}/#{@intake}")
    assert has_element?(view, ~s([data-pane-index="1"] a[data-desk-row]), "One")
    refute has_element?(view, ~s([data-pane-index="1"] button[phx-click="new-document"]))
  end
end
