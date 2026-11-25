defmodule BarkparkWeb.Studio.StringFieldExplicitSaveRaceTest do
  # task-998551f010da1d5e: the explicit Save (phx-submit) of a string field
  # whose store moved under it. B's save lands after A's Save is read and
  # before its write (`ObjectRichText.inside/3`), as in
  # `StringFieldWriteRaceTest` for an autosave. The Save skipped the bases
  # and the under-lock read, and A's text was written over B's, no banner.
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
    type = "string_save_race_#{n}"

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

    id = "string-save-race-#{n}"

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

  # The explicit Save, as the page submits the whole form.
  defp saves(view, fields) do
    view
    |> element("#editor-form")
    |> render_submit(%{
      "doc" => %{"title" => "T0", "notes" => fields["notes"] || "one two three"},
      @label => fields["label"] || "one two three",
      "_bp_seen" => Jason.encode!(%{"v" => 2})
    })
  end

  for surface <- [:desk, :studio],
      {field, target, at} <- [
        {"label", @label, ["meta", "label"]},
        {"notes", "doc[notes]", ["notes"]}
      ] do
    test "#{surface} #{field}: both rewrite one letter, B's save lands under A's Save: B's kept, A held with the banner; typing on saves A's",
         c do
      {a, b} = {open(c, unquote(surface)), open(c, unquote(surface))}
      field = unquote(field)

      html =
        ObjectRichText.inside(
          a,
          fn -> posts(b, unquote(target), %{field => "one twB three"}) end,
          fn -> saves(a, %{field => "one twA three"}) end
        )

      # On main: "one twA three", no banner, B's words gone.
      assert get_in(stored(c), unquote(at)) == "one twB three"
      assert html =~ "doc-conflict-banner"
      assert has_element?(a, @banner)
      assert get_in(assigns(a).editor_form, unquote(at)) == "one twA three"

      posts(a, unquote(target), %{field => "one twAA three"})

      assert ObjectRichText.eventually(fn ->
               get_in(stored(c), unquote(at)) == "one twAA three"
             end)
    end

    test "#{surface} #{field}: each types in a word of their own, B's save lands under A's Save: both kept, no banner",
         c do
      {a, b} = {open(c, unquote(surface)), open(c, unquote(surface))}
      field = unquote(field)

      html =
        ObjectRichText.inside(
          a,
          fn -> posts(b, unquote(target), %{field => "one two THREE"}) end,
          fn -> saves(a, %{field => "ONE two three"}) end
        )

      # On main: "ONE two three", B's THREE gone.
      assert get_in(stored(c), unquote(at)) == "ONE two THREE"
      refute html =~ "doc-conflict-banner"
    end
  end

  # #28826 review: a Save posts every field, so a field A never changed
  # was held over B's save of it, and A's next Save wrote the stale text.
  for surface <- [:desk, :studio] do
    test "#{surface}: A Saves a label change while B's notes save lands inside: no banner, B's notes kept through A's next Save",
         c do
      {a, b} = {open(c, unquote(surface)), open(c, unquote(surface))}

      html =
        ObjectRichText.inside(
          a,
          fn -> posts(b, "doc[notes]", %{"notes" => "one two THREE"}) end,
          fn -> saves(a, %{"label" => "ONE two three"}) end
        )

      assert stored(c)["notes"] == "one two THREE"
      assert get_in(stored(c), ["meta", "label"]) == "ONE two three"
      refute html =~ "doc-conflict-banner"
      assert assigns(a).editor_form["notes"] == "one two THREE"

      html = saves(a, %{"label" => "ONE two threeX", "notes" => assigns(a).editor_form["notes"]})

      refute html =~ "doc-conflict-banner"
      assert stored(c)["notes"] == "one two THREE"
      assert get_in(stored(c), ["meta", "label"]) == "ONE two threeX"
    end
  end

  test "an explicit Save with no other editor: saved as sent, no banner", c do
    a = open(c, :studio)
    html = saves(a, %{"notes" => "one two three four", "label" => "one"})
    assert stored(c)["notes"] == "one two three four"
    assert get_in(stored(c), ["meta", "label"]) == "one"
    refute html =~ "doc-conflict-banner"
  end
end
