defmodule BarkparkWeb.Studio.DeskLiveUpdatesJ06SameFieldTest do
  @moduledoc """
  J06 (barkpark-studio JOURNEYS.md): two browsers type in the SAME field;
  they converge, and nobody's focus jumps. The reference spec
  (e2e/journeys/live-edit.spec.ts) has A type at the end of the title and B
  at its start at the same moment, and both end on `bbb <title> aaa`.

  Driven in a browser first (live lane triage, 2026-11-10), desk-vs-desk,
  old-vs-old and desk-vs-old alike: focus and caret stay where each person
  typed, and each browser keeps its own text, but they never converge. The
  store holds whichever save landed last, the other person's words are gone
  from it, and both browsers show "your unsaved edits are kept".

  Focus and caret are a browser's to prove; these tests hold the server side.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @type_name "desk_live_j06"
  @title "Shared title"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk J06 notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "dj06-#{System.unique_integer([:positive])}"

    {:ok, _doc} =
      Content.create_document(
        @type_name,
        %{"doc_id" => id, "title" => @title, "content" => %{"summary" => "Words"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    url = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{@type_name};#{id}"

    {:ok, conn: conn, url: url, id: id}
  end

  defp person(conn, name) do
    raw = "desk-j06-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-j06", @dataset, ["read", "write", "admin"], ws.id)

    conn
    |> Plug.Test.init_test_session(%{"api_token" => raw})
    |> put_connect_params(%{"user_id" => "j06-#{name}-#{System.unique_integer([:positive])}"})
  end

  defp open(conn, url) do
    {:ok, view, _html} = live(conn, url)
    render_async(view, 5_000)
    assert has_element?(view, ~s([data-pane-index="2"][data-pane-editing] #editor-form))
    view
  end

  # What a browser posts when its person typed `value` into the title: the
  # field's whole text as that browser holds it. A focused input is not
  # patched by the server, so a browser that is typing holds its own text.
  defp type_title(view, value) do
    view
    |> form("#editor-form")
    |> render_change(%{"_target" => ["doc", "title"], "doc" => %{"title" => value}})
  end

  defp title_in(view) do
    view
    |> element(~s([data-pane-index="2"] #editor-form input[name="doc[title]"]))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp stored_title(id) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(@type_name, id, @dataset)
    doc.title
  end

  defp eventually(fun),
    do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  test "a save landing from the other browser never takes away what this one typed", %{
    conn: conn,
    url: url
  } do
    a = open(person(conn, "a"), url)
    b = open(person(BarkparkWeb.ConnCase.scoped_conn(), "b"), url)

    type_title(b, "bbb " <> @title)
    # A typed at the same moment, before B's save reached it.
    type_title(a, @title <> " aaa")

    # B has heard of A's save (the banner, or the merged value) before we look.
    assert eventually(fn ->
             has_element?(b, ~s([data-test-id="doc-conflict-banner"])) or
               String.contains?(title_in(b) || "", "aaa")
           end),
           "B never heard of A's save"

    assert String.contains?(title_in(b) || "", "bbb"),
           "A's save took B's typed text out of B's title: #{inspect(title_in(b))}"
  end

  test "two people typing in one field converge on one value that keeps both", %{
    conn: conn,
    url: url,
    id: id
  } do
    a = open(person(conn, "a"), url)
    b = open(person(BarkparkWeb.ConnCase.scoped_conn(), "b"), url)

    # Both type at once: B at the start, A at the end. Neither browser has
    # the other's words yet when it posts.
    type_title(b, "bbb " <> @title)
    type_title(a, @title <> " aaa")

    both? = fn v -> is_binary(v) and String.contains?(v, "bbb") and String.contains?(v, "aaa") end

    converged? =
      eventually(fn ->
        s = stored_title(id)
        both?.(s) and title_in(a) == s and title_in(b) == s
      end)

    assert converged?,
           "after both stopped: store #{inspect(stored_title(id))}, " <>
             "A shows #{inspect(title_in(a))}, B shows #{inspect(title_in(b))}; " <>
             "expected one value holding both \"bbb\" and \"aaa\""
  end
end
