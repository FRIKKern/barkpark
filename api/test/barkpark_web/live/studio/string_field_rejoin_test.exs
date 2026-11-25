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

    # Design A's cost (task-6496826d722a5a06): with no other save, typing
    # done while away is held too. A banner that was not needed; no words lost.
    test "#{surface} #{field}: A's page rejoins with no other save and posts its typing: held with the banner, typing on saves",
         c do
      field = unquote(field)
      a2 = open(c, unquote(surface))
      n = born(a2, unquote(target), false)
      html = posts_seen(a2, unquote(target), %{field => "one twA three"}, n)

      assert get_in(stored(c), unquote(at)) == "one two three"
      assert html =~ "doc-conflict-banner"

      posts_seen(a2, unquote(target), %{field => "one twAA three"}, n)

      assert ObjectRichText.eventually(fn ->
               get_in(stored(c), unquote(at)) == "one twAA three"
             end)
    end
  end
end
