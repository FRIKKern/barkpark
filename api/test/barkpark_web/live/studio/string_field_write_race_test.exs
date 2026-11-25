defmodule BarkparkWeb.Studio.StringFieldWriteRaceTest do
  # task-5b8f13c40a052514: two tabs type in one word of a string field. B's
  # save lands after A's post is read and before A's write
  # (`ObjectRichText.inside/3`), so A's socket has not heard of it, and the
  # later write was laid over the first with no banner.
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
    type = "string_race_#{n}"

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

    id = "string-race-#{n}"

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

  for surface <- [:desk, :studio],
      {field, target, at} <- [
        {"label", @label, ["meta", "label"]},
        {"notes", "doc[notes]", ["notes"]}
      ] do
    test "#{surface} #{field}: both rewrite one letter, B's save lands under A's post: B's kept, A held with the banner; typing on saves A's",
         c do
      {a, b} = {open(c, unquote(surface)), open(c, unquote(surface))}
      field = unquote(field)

      html =
        ObjectRichText.inside(
          a,
          fn -> posts(b, unquote(target), %{field => "one twB three"}) end,
          fn -> posts(a, unquote(target), %{field => "one twA three"}) end
        )

      # On main: "one twA three", no banner, B's words gone.
      assert get_in(stored(c), unquote(at)) == "one twB three"
      assert html =~ "doc-conflict-banner"
      assert has_element?(a, @banner)
      assert get_in(assigns(a).editor_form, unquote(at)) == "one twA three"

      # Typing on what A was shown saves A's words over theirs.
      posts(a, unquote(target), %{field => "one twAA three"})

      assert ObjectRichText.eventually(fn ->
               get_in(stored(c), unquote(at)) == "one twAA three"
             end)
    end

    test "#{surface} #{field}: each types in a word of their own, B's save lands under A's post: both kept, no banner",
         c do
      {a, b} = {open(c, unquote(surface)), open(c, unquote(surface))}
      field = unquote(field)

      html =
        ObjectRichText.inside(
          a,
          fn -> posts(b, unquote(target), %{field => "one two THREE"}) end,
          fn -> posts(a, unquote(target), %{field => "ONE two three"}) end
        )

      # On main: "ONE two three", B's THREE gone.
      assert get_in(stored(c), unquote(at)) == "ONE two THREE"
      refute html =~ "doc-conflict-banner"
    end

    # task-eeecd067e3fb1b1f: B's socket heard A's save, B's page had not
    # drawn it (a focused input is never set), and B's post names no number.
    test "#{surface} #{field}: both rewrite one letter, B's page had not drawn A's save: A's kept, B held with the banner; typing on saves B's",
         c do
      {a, b} = {open(c, unquote(surface)), open(c, unquote(surface))}
      field = unquote(field)

      posts(a, unquote(target), %{field => "one twA three"})
      _ = render(b)
      html = posts(b, unquote(target), %{field => "one twBBB three"})

      # On main: "one twBBB three", no banner, A's letter gone.
      assert get_in(stored(c), unquote(at)) == "one twA three"
      assert html =~ "doc-conflict-banner"
      assert get_in(assigns(b).editor_form, unquote(at)) == "one twBBB three"

      posts(b, unquote(target), %{field => "one twBBBB three"})

      assert ObjectRichText.eventually(fn ->
               get_in(stored(c), unquote(at)) == "one twBBBB three"
             end)
    end

    test "#{surface} #{field}: each types in a word of their own, B's page had not drawn A's save: both kept, no banner",
         c do
      {a, b} = {open(c, unquote(surface)), open(c, unquote(surface))}
      field = unquote(field)

      posts(a, unquote(target), %{field => "ONE two three"})
      _ = render(b)
      html = posts(b, unquote(target), %{field => "one two THREE"})

      assert get_in(stored(c), unquote(at)) == "ONE two THREE"
      refute html =~ "doc-conflict-banner"
    end
  end
end
