defmodule BarkparkWeb.Studio.DeskLiveUpdatesNewVersionTest do
  @moduledoc """
  J53 (JOURNEYS.md): a new server version while tabs are open. A restart
  drops every socket; each open tab rejoins, which mounts the LiveView again
  from the URL the tab is on. The tab must come back where it was, and when
  the server now serves other assets than the ones the tab loaded, the tab is
  told to reload ("Reload to update").

  A rejoining LiveView client sends `_track_static`: the URLs of the page's
  `phx-track-static` tags, as the tab loaded them. `BarkparkWeb.StaticAssets`
  already content-hashes every `/assets` URL, so a tab built from older
  assets sends URLs the server no longer prints.

  Browser half (text typed and not yet sent when the server went away):
  `desk_live_updates_offline_typing_test.exs` (same path: a rejoin) and
  `$ORCH/tmp/live-w2/restart.mjs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias BarkparkWeb.StaticAssets

  @dataset "production"
  @type_name "desk_version_note"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Desk version notes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "string"}
          ]
        },
        @dataset
      )

    n = System.unique_integer([:positive])

    for {id, title} <- [{"dvn-a-#{n}", "Alpha version"}, {"dvn-b-#{n}", "Beta version"}] do
      {:ok, _doc} =
        Content.create_document(
          @type_name,
          %{"doc_id" => id, "title" => title, "content" => %{"summary" => "About " <> title}},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    raw = "desk-version-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "desk-version", @dataset, ~w(read write admin), ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    chain = "#{@type_name};dvn-a-#{n};dvn-b-#{n},type=#{@type_name},parentRefPath=more"
    {:ok, conn: conn, url: "#{base}/#{chain}", base: base}
  end

  defp settle(view), do: render_async(view, 5_000)

  defp poll(fun) do
    Enum.any?(1..300, fn _ -> fun.() or (Process.sleep(20) && false) end)
  end

  defp panes(view) do
    ~r/data-pane-index="(\d+)"[^>]*data-pane-kind="(\w+)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, index, kind] -> index <> ":" <> kind end)
    |> Enum.uniq()
  end

  test "a tab that rejoins after a restart comes back to the same panes and the same document",
       %{conn: conn, url: url} do
    {:ok, before, _html} = live(conn, url)
    assert poll(fn -> settle(before) && has_element?(before, "[data-pane-editing] #editor-form") end)
    shape = panes(before)
    title = before |> element("[data-pane-editing] #editor-form input[name=\"doc[title]\"]") |> render()

    # The server went away: on the new one the tab mounts again from its URL,
    # in a process that knows nothing of the old one.
    {:ok, again, _html} = live(conn, url)
    refute again.pid == before.pid

    assert poll(fn -> settle(again) && has_element?(again, "[data-pane-editing] #editor-form") end),
           "the rejoined desk never brought the editor back"

    assert panes(again) == shape
    assert shape == ~w(0:types 1:list 2:doc 3:doc)
    assert title =~ "Beta version"

    assert again |> element("[data-pane-editing] #editor-form input[name=\"doc[title]\"]") |> render() =~
             "Beta version"

    assert has_element?(again, ~s([data-pane-index="2"] dd), "About Alpha version")
  end

  test "the page names the assets it was built with, so a later version can be noticed", %{
    conn: conn,
    base: base
  } do
    html = conn |> get(base) |> html_response(200)

    assert html =~ ~r/<script\b[^>]*phx-track-static[^>]*src="#{Regex.escape(StaticAssets.path("bp-desk.js"))}"|<script\b[^>]*src="#{Regex.escape(StaticAssets.path("bp-desk.js"))}"[^>]*phx-track-static/,
           "no phx-track-static on the desk's scripts: a rejoining tab cannot say which build it runs"
  end

  test "a tab built from older assets is told to reload to update", %{conn: conn, url: url} do
    old = String.replace(StaticAssets.path("bp-desk.js"), ~r{/v/[^/]+/}, "/v/0ld0ld0ld0ld0ld/")

    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"_track_static" => [old]})
      |> live(url)

    settle(view)

    assert render(view) =~ "Reload to update",
           "a tab running other assets than the server now serves is not told to reload"
  end
end
