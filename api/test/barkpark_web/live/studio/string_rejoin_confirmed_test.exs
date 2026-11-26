defmodule BarkparkWeb.Studio.StringRejoinConfirmedTest do
  # task-fe9d8741f0641f97: the page keeps, across a socket rejoin, the
  # digest of the last value the server confirmed it shows (`TextConfirmed`).
  # A post on a rejoined socket whose digest is the store's was typed on the
  # store (a wifi blip, nobody else saving): it is written. One whose digest
  # differs was typed on a value B's save replaced: it is held, and the
  # hold stays on autosave until a Save or Reload, with the banner saying so.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.ObjectRichText

  @dataset "production"
  @banner ~s([data-test-id="doc-conflict-banner"])
  @paused ~s([data-test-id="doc-conflict-paused"])
  @label "doc[meta].label"
  @t0 "one two three"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "string_confirmed_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "String confirmed",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "meta",
              "title" => "Meta",
              "type" => "composite",
              "fields" => [%{"name" => "label", "title" => "Label", "type" => "string"}]
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "string-confirmed-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T0",
          "content" => %{"meta" => %{"label" => @t0}, "notes" => @t0}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "string-confirmed-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "string-confirmed",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     paths: %{desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}"}}
  end

  defp open(c, surface) do
    {:ok, view, _html} = live(c.conn, c.paths[surface])
    render_async(view, 5_000)
    assert ObjectRichText.eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    Map.put(doc.content, "title", doc.title)
  end

  defp label(c), do: get_in(stored(c), ["meta", "label"])

  # The page's `_bp_seen` as bp-array-focus.js keeps it: the form draws it,
  # the born push numbers each field, and a digest is taken with its value.
  defp page(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))

    seen = value |> String.replace("&quot;", ~s(")) |> Jason.decode!()
    assert_push_event(view, "bp:form-born", %{seqs: seqs, oks: oks}, 2_000)
    seen |> Map.merge(seqs) |> Map.put("v", 2) |> Map.put("ok", Map.merge(seen["ok"] || %{}, oks))
  end

  defp confirmed(view, seen) do
    assert_push_event(view, "bp:form-confirmed", %{oks: oks}, 2_000)
    Map.update!(seen, "ok", &Map.merge(&1, oks))
  end

  defp form_of(fields, seen) do
    %{
      "doc" => %{"title" => fields["title"] || "T0", "notes" => fields["notes"] || @t0},
      @label => fields["label"] || @t0,
      "_bp_seen" => Jason.encode!(seen)
    }
  end

  defp changes(view, target, fields, seen),
    do:
      view
      |> element("#editor-form")
      |> render_change(Map.put(form_of(fields, seen), "_target", [target]))

  defp saves(view, fields, seen),
    do: view |> element("#editor-form") |> render_submit(form_of(fields, seen))

  # A types " A1" and it lands; the page takes the confirmed digest. Then
  # the socket drops: the page keeps its `_bp_seen`, A types " A7" offline.
  defp typed_then_dropped(c, surface) do
    a = open(c, surface)
    seen = page(a)
    changes(a, @label, %{"label" => @t0 <> " A1"}, seen)
    assert label(c) == @t0 <> " A1"
    seen = confirmed(a, seen)
    GenServer.stop(a.pid, :normal)
    seen
  end

  for surface <- [:desk, :studio] do
    test "#{surface}: a reconnect after A's own autosave, nobody else saving: A's typing is written, no banner",
         c do
      seen = typed_then_dropped(c, unquote(surface))
      a2 = open(c, unquote(surface))
      _ = page(a2)

      # On main: held with the banner, a wifi blip read as B's save.
      html = changes(a2, @label, %{"label" => @t0 <> " A1 A7"}, seen)
      assert label(c) == @t0 <> " A1 A7"
      refute html =~ "doc-conflict-banner"

      changes(a2, @label, %{"label" => @t0 <> " A1 A7 A8"}, seen)
      assert label(c) == @t0 <> " A1 A7 A8"
    end

    test "#{surface}: a reconnect after B's save took on the page: A's typing is written, B's kept",
         c do
      a = open(c, unquote(surface))
      seen = page(a)
      b = open(c, unquote(surface))
      changes(b, @label, %{"label" => "B5 " <> @t0}, page(b))

      # A's page shows B's value: it takes the number and the digest.
      assert_push_event(a, "bp:form-remote-values", %{seqs: seqs, oks: oks}, 2_000)

      seen =
        seen |> Map.put(@label, List.last(seqs[@label])) |> Map.update!("ok", &Map.merge(&1, oks))

      GenServer.stop(a.pid, :normal)

      a2 = open(c, unquote(surface))
      _ = page(a2)
      html = changes(a2, @label, %{"label" => "B5 " <> @t0 <> " A7"}, seen)
      assert label(c) == "B5 " <> @t0 <> " A7"
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface}: B saves while A's page is away: held; typing on stays held, other fields autosave, a Save writes and autosave resumes",
         c do
      seen = typed_then_dropped(c, unquote(surface))
      b = open(c, unquote(surface))
      changes(b, @label, %{"label" => "B5 " <> @t0 <> " A1"}, page(b))

      a2 = open(c, unquote(surface))
      _ = page(a2)

      # On main the second key wrote A's words over B5, and the banner went.
      for words <- [" A1 A7", " A1 A7 ", " A1 A7 A8"] do
        changes(a2, @label, %{"label" => @t0 <> words}, seen)
        assert label(c) == "B5 " <> @t0 <> " A1"
        assert has_element?(a2, @banner)

        assert has_element?(a2, @paused, "Autosave is paused for Meta until you Save or Reload.")
      end

      # A types in notes: it autosaves; the label stays held.
      changes(a2, "doc[notes]", %{"label" => @t0 <> " A1 A7 A8", "notes" => @t0 <> " N"}, seen)
      assert stored(c)["notes"] == @t0 <> " N"
      assert label(c) == "B5 " <> @t0 <> " A1"
      assert has_element?(a2, @paused)

      # A presses Save: A's words are written, and the page is confirmed them.
      saves(a2, %{"label" => @t0 <> " A1 A7 A8", "notes" => @t0 <> " N"}, seen)
      assert label(c) == @t0 <> " A1 A7 A8"
      refute has_element?(a2, @paused)
      seen = confirmed(a2, seen)

      changes(a2, @label, %{"label" => @t0 <> " A1 A7 A8 A9", "notes" => @t0 <> " N"}, seen)
      assert label(c) == @t0 <> " A1 A7 A8 A9"
      refute has_element?(a2, @banner)
    end

    test "#{surface}: B saves while A's page is away; Reload takes B's and ends the pause", c do
      seen = typed_then_dropped(c, unquote(surface))
      b = open(c, unquote(surface))
      changes(b, @label, %{"label" => "B5 " <> @t0 <> " A1"}, page(b))

      a2 = open(c, unquote(surface))
      _ = page(a2)
      changes(a2, @label, %{"label" => @t0 <> " A1 A7"}, seen)
      assert has_element?(a2, @paused)

      a2 |> element(~s([data-test-id="doc-conflict-reload"])) |> render_click()
      refute has_element?(a2, @banner)
      assert label(c) == "B5 " <> @t0 <> " A1"
    end
  end
end
