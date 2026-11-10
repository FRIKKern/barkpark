defmodule BarkparkWeb.Studio.DeskListCreateTest do
  @moduledoc """
  A list pane's own "+" on the desk (`DeskLive`, /papers/desk-vertical-slice):
  a new document of the list's type opens in the next pane, the list kept
  beside it. Reference: the TanStack Studio's `NewInList` (`Structure.tsx`)
  and `openAfter(panes, index, made)`; Barkpark's LiveView Studio has the
  same "+" (`phx-click="new-document"`, `Handlers.Fields.new_document/2`).

  The markup these tests read (builder and test agree on it):

    * the "+": `[data-desk-new]` in the list pane's `.pane-header`, a link or
      a button, labelled with the type's title.

  What the new document IS is read from the store after a first edit, so
  these tests hold whether the document is written at the press (the
  LiveView Studio's way) or at the first edit (the TanStack Studio's, J18).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_create_note"
  @type_title "Desk create notes"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => @type_title,
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    n = System.unique_integer([:positive])
    a = "dcn-a-#{n}"

    {:ok, _doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => a, "title" => "Existing create note", "content" => %{}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, a: a}
  end

  defp admin(conn) do
    raw = "desk-create-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-create", @dataset, ["read", "write", "admin"], ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp settle(view), do: render_async(view, 5_000)

  defp open(conn, path) do
    {:ok, view, _html} = live(admin(conn), path)
    settle(view)
    view
  end

  @list ~s([data-pane-index="1"][data-pane-kind="list"])
  @plus @list <> " .pane-header [data-desk-new]"

  # Press the list's "+" and return the desk path it patched to.
  defp press_plus(view) do
    assert has_element?(view, @plus), "the list pane has no \"+\" (#{@plus})"
    view |> element(@plus) |> render_click()
    path = assert_patch(view)
    settle(view)
    path
  end

  # The chain after `_desk/`, as its `;`-separated panes.
  defp chain(base, path) do
    path |> String.replace_prefix(base <> "/", "") |> URI.decode() |> String.split(";")
  end

  # Poll for a value rather than read it once (CAMPAIGN rule 6).
  defp eventually(fun) do
    Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)
  end

  test "a list pane's header has a \"+\" labelled with its type", %{conn: conn, base: base} do
    view = open(conn, "#{base}/#{@type_name}")

    assert has_element?(view, @plus), "the list pane has no \"+\" (#{@plus})"

    label =
      view
      |> element(@plus)
      |> render()
      |> then(&Regex.run(~r/aria-label="([^"]*)"/, &1))
      |> then(&((&1 && List.last(&1)) || ""))

    assert String.downcase(label) =~ "desk create note",
           "the \"+\" is labelled #{inspect(label)}, not with its type"
  end

  test "the types pane has no \"+\" of its own", %{conn: conn, base: base} do
    view = open(conn, "#{base}/#{@type_name}")

    refute has_element?(view, ~s([data-pane-index="0"] [data-desk-new]))
  end

  test "\"+\" opens a new document in the next pane, its editor, the list kept", %{
    conn: conn,
    base: base,
    a: a
  } do
    view = open(conn, "#{base}/#{@type_name}")
    path = press_plus(view)

    assert [@type_name, new_id] = chain(base, path)
    assert new_id != a

    assert has_element?(view, @list)
    assert has_element?(view, ~s([data-pane-index="2"][data-pane-editing] #editor-form))
  end

  test "the new document is the list's type: typed into, the store holds it under the URL's id",
       %{conn: conn, base: base} do
    view = open(conn, "#{base}/#{@type_name}")
    path = press_plus(view)
    assert [@type_name, new_id] = chain(base, path)

    view
    |> form("#editor-form")
    |> render_change(%{"doc" => %{"title" => "Fresh from the plus"}})

    assert eventually(fn ->
             match?(
               {%{title: "Fresh from the plus"}, true, false},
               Content.fetch_doc_with_draft(@type_name, new_id, @dataset)
             )
           end),
           "no draft #{@type_name}/#{new_id} titled \"Fresh from the plus\" in the store"
  end

  test "with a document open, \"+\" opens the new one in its place, not after it", %{
    conn: conn,
    base: base,
    a: a
  } do
    view = open(conn, "#{base}/#{@type_name};#{a}")
    assert has_element?(view, ~s([data-pane-index="2"][data-pane-editing]))

    path = press_plus(view)

    assert [@type_name, new_id] = chain(base, path)
    assert new_id != a
    refute has_element?(view, ~s([data-pane-index="3"]))
  end
end
