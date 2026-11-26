defmodule BarkparkWeb.Studio.StringFieldRejoinTest do
  # task-4fc7383b936f606a: B saves while A's page is between sockets. A's
  # page joins a new socket and posts the text it typed on the old value.
  # The new socket's base is B's value, the store's, so the post was
  # written as sent over B's, with no banner.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.ObjectRichText

  @dataset "production"
  @banner ~s([data-test-id="doc-conflict-banner"])
  @label "doc[meta].label"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "string_rejoin_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "String race",
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

    id = "string-rejoin-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T0",
          "content" => %{"meta" => %{"label" => "one two three"}, "notes" => "one two three"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "string-race-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "string-race", @dataset, ~w(read write admin), ws_id)
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

  # A post as the page sends it, `_bp_seen` as bp-array-focus.js keeps it.
  defp posts(view, target, fields) do
    view
    |> element("#editor-form")
    |> render_change(
      Map.merge(
        %{
          "_target" => [target],
          "doc" => %{"title" => "T0", "notes" => fields["notes"] || "one two three"},
          @label => fields["label"] || "one two three",
          "_bp_seen" => Jason.encode!(%{"v" => 2})
        },
        Map.take(fields, ["doc"])
      )
    )
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp stored_title(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.title
  end

  # The page as bp-array-focus.js keeps `_bp_seen` after the born push: a
  # field showing the stored value takes its number; one showing A's typing,
  # with no number of its own, reports 0.
  defp born(view, name, shows_stored?) do
    assert_push_event(view, "bp:form-born", %{seqs: %{^name => seq}}, 2_000)
    if shows_stored?, do: seq, else: 0
  end

  defp posts_seen(view, target, fields, n) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => %{"title" => "T0", "notes" => fields["notes"] || "one two three"},
      @label => fields["label"] || "one two three",
      "_bp_seen" => Jason.encode!(%{"v" => 2, target => n})
    })
  end

  # The desk asks before it leaves a held field (`Desk.LeaveGuard`): the
  # rejoin hold names the field, so a link, Back or a tab close asks.
  for {field, target, label} <- [
        {"label", @label, "Meta"},
        {"notes", "doc[notes]", "Notes"}
      ] do
    test "desk #{field}: the rejoin hold names the field, and the pane asks before leaving", c do
      {_a, b} = {open(c, :desk), open(c, :desk)}
      field = unquote(field)
      posts(b, unquote(target), %{field => "one twB three"})

      a2 = open(c, :desk)
      refute has_element?(a2, "[data-pane-editing][data-desk-held]")
      n = born(a2, unquote(target), false)
      posts_seen(a2, unquote(target), %{field => "one twA three"}, n)

      assert BarkparkWeb.Studio.Desk.LeaveGuard.message(assigns(a2)) =~
               "Not saved: " <> unquote(label)

      assert has_element?(a2, "[data-pane-editing][data-desk-held]")
    end
  end

  for surface <- [:desk, :studio],
      {field, target, at} <- [
        {"label", @label, ["meta", "label"]},
        {"notes", "doc[notes]", ["notes"]}
      ] do
    test "#{surface} #{field}: B saves while A's page is away, A's page rejoins and posts its typing: B's kept, A held with the banner; typing on saves A's",
         c do
      {_a, b} = {open(c, unquote(surface)), open(c, unquote(surface))}
      field = unquote(field)

      posts(b, unquote(target), %{field => "one twB three"})
      assert get_in(stored(c), unquote(at)) == "one twB three"

      # A's page joins a new socket; its field still shows A's typing.
      a2 = open(c, unquote(surface))
      n = born(a2, unquote(target), false)
      html = posts_seen(a2, unquote(target), %{field => "one twA three"}, n)

      # On main: "one twA three", no banner, B's words gone.
      assert get_in(stored(c), unquote(at)) == "one twB three"
      assert html =~ "doc-conflict-banner"
      assert get_in(assigns(a2).editor_form, unquote(at)) == "one twA three"
      assert MapSet.member?(assigns(a2).editor_unsaved_keys, hd(unquote(at)))
      # The banner names the field (`RefusedSave.status/1`).
      assert assigns(a2).editor_clash_fields == [hd(unquote(at))]

      posts_seen(a2, unquote(target), %{field => "one twAA three"}, n)

      assert ObjectRichText.eventually(fn ->
               get_in(stored(c), unquote(at)) == "one twAA three"
             end)
    end

    test "#{surface} #{field}: a plain reconnect, the field shows the stored value: typing saves, no banner",
         c do
      {_a, b} = {open(c, unquote(surface)), open(c, unquote(surface))}
      field = unquote(field)
      posts(b, unquote(target), %{field => "one twB three"})

      a2 = open(c, unquote(surface))
      n = born(a2, unquote(target), true)
      html = posts_seen(a2, unquote(target), %{field => "one twB threeA"}, n)

      assert get_in(stored(c), unquote(at)) == "one twB threeA"
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} #{field}: the page rejoins and posts the stored value back: nothing held, no banner",
         c do
      {_a, b} = {open(c, unquote(surface)), open(c, unquote(surface))}
      field = unquote(field)
      posts(b, unquote(target), %{field => "one twB three"})

      a2 = open(c, unquote(surface))
      n = born(a2, unquote(target), false)
      html = posts_seen(a2, unquote(target), %{field => "one twB three"}, n)

      assert get_in(stored(c), unquote(at)) == "one twB three"
      refute html =~ "doc-conflict-banner"
    end

    # task-6496826d722a5a06 (design A's cost): with no other save, typing
    # done while away was held too, a banner that was not needed. The page
    # keeps the text its number stands for; the born value is that text, so
    # it reports the born number, and its post saves.
    test "#{surface} #{field}: A's page rejoins with no other save and posts its typing: saved, no banner",
         c do
      field = unquote(field)
      a2 = open(c, unquote(surface))
      n = born(a2, unquote(target), true)
      html = posts_seen(a2, unquote(target), %{field => "one twA three"}, n)

      assert get_in(stored(c), unquote(at)) == "one twA three"
      refute html =~ "doc-conflict-banner"
    end
  end

  # The #28830 r1 review: every free-text field of a post from before the
  # rejoin is read, not only its target (B1, probes P2/P2b), and so is an
  # explicit Save (B2, P1/P1b). The hold draws A's words into the input
  # (B3): the desk had redrawn it with the stored value.
  defp all_born(view) do
    assert_push_event(view, "bp:form-born", %{seqs: seqs}, 2_000)
    seqs
  end

  defp form_of(fields, seen) do
    %{
      "doc" => %{
        "title" => fields["title"] || "T0",
        "notes" => fields["notes"] || "one two three"
      },
      @label => fields["label"] || "one two three",
      "_bp_seen" => Jason.encode!(Map.put(seen, "v", 2))
    }
  end

  defp changes(view, target, fields, seen),
    do:
      view
      |> element("#editor-form")
      |> render_change(Map.put(form_of(fields, seen), "_target", [target]))

  defp saves(view, fields, seen),
    do: view |> element("#editor-form") |> render_submit(form_of(fields, seen))

  defp drawn(view, name) do
    assert_push_event(view, "bp:form-remote-values", %{values: %{^name => drawn}}, 2_000)
    drawn
  end

  for surface <- [:desk, :studio] do
    for {label, number} <- [{"no number of its own", 0}, {"the old socket's number", 3}] do
      test "#{surface}: B saves notes while A's page is away; A's page rejoins and presses Save with #{label}: B's kept, A held",
           c do
        b = open(c, unquote(surface))
        posts(b, "doc[notes]", %{"notes" => "one twB three"})

        a2 = open(c, unquote(surface))
        seen = a2 |> all_born() |> Map.put("doc[notes]", unquote(number))
        html = saves(a2, %{"notes" => "one twA three"}, seen)

        # Before r2: "one twA three", no banner, B's words gone.
        assert stored(c)["notes"] == "one twB three"
        assert html =~ "doc-conflict-banner"
        refute html =~ "Saved"
        assert assigns(a2).editor_form["notes"] == "one twA three"

        assert open(c, unquote(surface)) |> assigns() |> get_in([:editor_form, "notes"]) ==
                 "one twB three"

        changes(a2, "doc[notes]", %{"notes" => "one twAA three"}, seen)
        assert ObjectRichText.eventually(fn -> stored(c)["notes"] == "one twAA three" end)
      end
    end

    test "#{surface}: B saves notes; A typed notes and label while away and its post targets the label: B's notes kept, notes held",
         c do
      b = open(c, unquote(surface))
      posts(b, "doc[notes]", %{"notes" => "one twB three"})

      a2 = open(c, unquote(surface))
      seen = a2 |> all_born() |> Map.merge(%{"doc[notes]" => 0, @label => 0})
      html = changes(a2, @label, %{"notes" => "one twA three", "label" => "one twA three"}, seen)

      # Before r2: notes "one twA three", the banner naming only meta.
      assert stored(c)["notes"] == "one twB three"
      assert html =~ "doc-conflict-banner"
      assert "notes" in assigns(a2).editor_clash_fields
      assert assigns(a2).editor_form["notes"] == "one twA three"
    end

    test "#{surface}: B saves the label; A's post targets notes and carries the label as A's page showed it: B's label kept",
         c do
      b = open(c, unquote(surface))
      posts(b, @label, %{"label" => "one twB three"})

      a2 = open(c, unquote(surface))
      seen = a2 |> all_born() |> Map.merge(%{"doc[notes]" => 0, @label => 0})

      html =
        changes(a2, "doc[notes]", %{"notes" => "one twA three", "label" => "one two three"}, seen)

      # Before r2: the label went back to "one two three", the banner naming notes.
      assert get_in(stored(c), ["meta", "label"]) == "one twB three"
      assert html =~ "doc-conflict-banner"
      # The label A never edited is a stored version, stale: put back, not
      # held (task-727f65fc259d0c7b). Notes, typed while away, are held.
      assert assigns(a2).editor_clash_fields == ["notes"]
    end

    # task-727f65fc259d0c7b (#28830 r2 review, desk Chrome 3/3): B saves the
    # label; A types in the title while away. The stale label in A's post
    # was held under the banner, and A's next key in the title wrote it over
    # B's, with the banner gone and B never told.
    test "#{surface}: B saves the label, A typed the title while away: the stale label is put back, never held, and typing on keeps B's",
         c do
      b = open(c, unquote(surface))
      posts(b, @label, %{"label" => "one twB three"})

      a2 = open(c, unquote(surface))
      seen = a2 |> all_born() |> Map.merge(%{"doc[title]" => 0, @label => 0})
      changes(a2, "doc[title]", %{"title" => "T0 AAA", "label" => "one two three"}, seen)

      assert get_in(stored(c), ["meta", "label"]) == "one twB three"
      refute "meta" in (assigns(a2).editor_clash_fields || [])
      refute MapSet.member?(assigns(a2).editor_unsaved_keys, "meta")
      assert get_in(assigns(a2).editor_form, ["meta", "label"]) == "one twB three"

      # The page's input still showing the stale label is drawn B's.
      assert drawn(a2, @label) == %{value: "one twB three", was: "one two three", draw: true}

      # On main: this wrote "one two three" over B's label.
      changes(a2, "doc[title]", %{"title" => "T0 AAAZ", "label" => "one two three"}, seen)
      assert ObjectRichText.eventually(fn -> stored_title(c) == "T0 AAAZ" end)
      assert get_in(stored(c), ["meta", "label"]) == "one twB three"
    end

    test "#{surface}: B saves the label; A's page rejoins and presses Save with the label it showed: put back and drawn, the banner names it",
         c do
      b = open(c, unquote(surface))
      posts(b, @label, %{"label" => "one twB three"})

      a2 = open(c, unquote(surface))
      seen = a2 |> all_born() |> Map.put(@label, 0)
      html = saves(a2, %{}, seen)

      assert get_in(stored(c), ["meta", "label"]) == "one twB three"
      # #28850 r1 review: a Save that put a field back says so, not "Saved".
      assert html =~ "doc-conflict-banner"
      assert assigns(a2).editor_clash_fields == ["meta"]
      refute (assigns(a2).flash || %{})["info"] == "Saved"
      assert get_in(assigns(a2).editor_form, ["meta", "label"]) == "one twB three"
      assert drawn(a2, @label) == %{value: "one twB three", was: "one two three", draw: true}

      # The page now shows B's label; a second Save keeps it.
      saves(a2, %{"label" => "one twB three", "title" => "T0 Z"}, seen)
      assert ObjectRichText.eventually(fn -> stored_title(c) == "T0 Z" end)
      assert get_in(stored(c), ["meta", "label"]) == "one twB three"
    end

    # #28850 r1 review: every draft save writes a revision, so a cap by count
    # (50) let a stale label many saves old be held, and A's next key in the
    # title wrote it over B's.
    test "#{surface}: B saved the label 55 times; A's stale label from before them all is still put back",
         c do
      b = open(c, unquote(surface))
      for i <- 1..55, do: posts(b, @label, %{"label" => "one twB three #{i}"})
      assert get_in(stored(c), ["meta", "label"]) == "one twB three 55"

      a2 = open(c, unquote(surface))
      seen = a2 |> all_born() |> Map.merge(%{"doc[title]" => 0, @label => 0})
      changes(a2, "doc[title]", %{"title" => "T0 AAA", "label" => "one two three"}, seen)
      refute "meta" in (assigns(a2).editor_clash_fields || [])

      changes(
        a2,
        "doc[title]",
        %{
          "title" => "T0 AAAZ",
          "label" => get_in(assigns(a2).editor_form, ["meta", "label"])
        },
        seen
      )

      assert ObjectRichText.eventually(fn -> stored_title(c) == "T0 AAAZ" end)
      assert get_in(stored(c), ["meta", "label"]) == "one twB three 55"
    end

    test "#{surface}: A typed the label back to its earlier version while away and presses Save: put back, the banner names it, no Saved",
         c do
      a = open(c, unquote(surface))
      posts(a, @label, %{"label" => "one two three X"})

      assert ObjectRichText.eventually(fn ->
               get_in(stored(c), ["meta", "label"]) == "one two three X"
             end)

      b = open(c, unquote(surface))
      posts(b, "doc[notes]", %{"notes" => "one twB three", "label" => "one two three X"})
      assert ObjectRichText.eventually(fn -> stored(c)["notes"] == "one twB three" end)

      a2 = open(c, unquote(surface))
      seen = a2 |> all_born() |> Map.put(@label, 0)
      html = saves(a2, %{"label" => "one two three", "notes" => "one twB three"}, seen)

      assert get_in(stored(c), ["meta", "label"]) == "one two three X"
      assert html =~ "doc-conflict-banner"
      assert assigns(a2).editor_clash_fields == ["meta"]
      refute (assigns(a2).flash || %{})["info"] == "Saved"
      assert get_in(assigns(a2).editor_form, ["meta", "label"]) == "one two three X"

      # Told, A types the label back again: saved.
      changes(a2, @label, %{"label" => "one two three", "notes" => "one twB three"}, seen)

      assert ObjectRichText.eventually(fn ->
               get_in(stored(c), ["meta", "label"]) == "one two three"
             end)
    end

    test "#{surface}: a non-target field A typed while away, no stored version: still held", c do
      b = open(c, unquote(surface))
      posts(b, @label, %{"label" => "one twB three"})

      a2 = open(c, unquote(surface))
      seen = a2 |> all_born() |> Map.merge(%{"doc[title]" => 0, @label => 0})
      html = changes(a2, "doc[title]", %{"title" => "T0 AAA", "label" => "one twA three"}, seen)

      assert get_in(stored(c), ["meta", "label"]) == "one twB three"
      assert html =~ "doc-conflict-banner"
      assert "meta" in assigns(a2).editor_clash_fields
      assert get_in(assigns(a2).editor_form, ["meta", "label"]) == "one twA three"
    end

    test "#{surface}: the hold draws A's words into the input, and typing on saves them", c do
      b = open(c, unquote(surface))
      posts(b, "doc[notes]", %{"notes" => "one twB three"})

      a2 = open(c, unquote(surface))
      seen = a2 |> all_born() |> Map.put("doc[notes]", 0)
      changes(a2, "doc[notes]", %{"notes" => "one twA three"}, seen)

      # The input takes A's words while it shows the stored value (the
      # desk's rejoin redraw), so the next key types on A's words.
      assert drawn(a2, "doc[notes]") == %{value: "one twA three", was: "one twB three"}

      changes(a2, "doc[notes]", %{"notes" => "one twA threeZ"}, seen)
      assert ObjectRichText.eventually(fn -> stored(c)["notes"] == "one twA threeZ" end)
    end
  end
end
