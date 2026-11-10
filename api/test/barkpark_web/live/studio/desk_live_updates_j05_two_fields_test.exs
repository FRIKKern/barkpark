defmodule BarkparkWeb.Studio.DeskLiveUpdatesJ05TwoFieldsTest do
  @moduledoc """
  J05 (barkpark-studio JOURNEYS.md): two browsers, different fields of one
  post, both see each other. Two people have the same document open in the
  desk's editor (the last pane); one types in the title, the other in the
  summary.

  Driven in a browser first (live lane triage, 2026-11-10): the store keeps
  both edits, but once a browser has typed anything, it never shows the other
  person's edits again and shows "Updated by another user — your unsaved
  edits are kept" instead, though it has nothing unsaved. The old Studio does
  the same (desk-vs-desk, old-vs-old and desk-vs-old all alike).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_live_j05"
  @banner ~s([data-test-id="doc-conflict-banner"])

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk J05 notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "dj05-#{System.unique_integer([:positive])}"

    {:ok, _doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => id, "title" => "Shared note", "content" => %{"summary" => "First words"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    url = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{@type_name};#{id}"

    {:ok, conn: conn, url: url, id: id}
  end

  # Each person is their own browser: their own token and presence id.
  defp person(conn, name) do
    raw = "desk-j05-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-j05", @dataset, ["read", "write", "admin"], ws.id)

    conn
    |> Plug.Test.init_test_session(%{"api_token" => raw})
    |> put_connect_params(%{"user_id" => "j05-#{name}-#{System.unique_integer([:positive])}"})
  end

  defp open(conn, url) do
    {:ok, view, _html} = live(conn, url)
    render_async(view, 5_000)
    assert has_element?(view, ~s([data-pane-index="2"][data-pane-editing] #editor-form))
    view
  end

  # What the browser posts when someone types in one field: the whole form,
  # with the field they typed in as the target.
  defp type_in(view, field, value) do
    view
    |> form("#editor-form")
    |> render_change(%{"_target" => ["doc", field], "doc" => %{field => value}})
  end

  defp shows?(view, value),
    do: has_element?(view, ~s([data-pane-index="2"] #editor-form input[value="#{value}"]))

  # The other browser hears of a save by a broadcast: poll for the value itself.
  defp eventually(fun),
    do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(id) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(@type_name, id, @dataset)
    %{title: doc.title, summary: doc.content["summary"]}
  end

  test "the store keeps both people's edits to different fields", %{conn: conn, url: url, id: id} do
    a = open(person(conn, "a"), url)
    b = open(person(BarkparkWeb.ConnCase.scoped_conn(), "b"), url)

    type_in(b, "summary", "Summary by B")
    type_in(a, "title", "Title by A")

    assert stored(id) == %{title: "Title by A", summary: "Summary by B"}
  end

  test "each browser shows the other's edit to a different field, with no conflict", %{
    conn: conn,
    url: url,
    id: id
  } do
    a = open(person(conn, "a"), url)
    b = open(person(BarkparkWeb.ConnCase.scoped_conn(), "b"), url)

    # B types in the summary and stops; its save has landed, nothing is unsaved.
    type_in(b, "summary", "Summary by B")
    assert stored(id).summary == "Summary by B"
    assert eventually(fn -> shows?(a, "Summary by B") end), "A never showed B's summary"

    # A types in the title.
    type_in(a, "title", "Title by A")
    assert stored(id).title == "Title by A"

    shown_in_b? = eventually(fn -> shows?(b, "Title by A") end)
    b_banner? = has_element?(b, @banner)

    assert shown_in_b?,
           "B never showed A's title. B had typed once (saved, nothing unsaved) and the " <>
             "remote save was refused into a conflict banner (banner shown: #{b_banner?})"

    refute b_banner?, "B has nothing unsaved, yet shows the conflict banner"
    assert shows?(b, "Summary by B"), "B lost its own summary"

    # And the other way round, now that A has typed too.
    type_in(b, "summary", "Summary by B again")

    assert eventually(fn -> shows?(a, "Summary by B again") end),
           "A never showed B's second summary edit after A had typed"

    refute has_element?(a, @banner)
  end
end
