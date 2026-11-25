defmodule BarkparkWeb.Studio.StudioLeaveGuardTest do
  # task-c4b59891f88686e0: a field held under the conflict banner keeps A's
  # words in the form, unsaved. The desk asks before it leaves
  # (`Desk.LeaveGuard`, `data-desk-held`); Studio had no guard, so a link
  # or a tab close dropped A's words with no warning. Studio's editor form
  # now carries the question, naming the field, as `data-studio-held`
  # (bp-studio-leave.js asks with it).
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.ObjectRichText

  @dataset "production"
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

  # A held: B's save lands under A's post rewriting the same letter.
  defp hold(c, surface, target, field) do
    {a, b} = {open(c, surface), open(c, surface)}

    ObjectRichText.inside(
      a,
      fn -> posts(b, target, %{field => "one twB three"}) end,
      fn -> posts(a, target, %{field => "one twA three"}) end
    )

    assert has_element?(a, ~s([data-test-id="doc-conflict-banner"]))
    a
  end

  for {field, target, label} <- [{"label", @label, "Meta"}, {"notes", "doc[notes]", "Notes"}] do
    test "studio #{field}: a held field puts the question, naming it, on the editor form", c do
      a = hold(c, :studio, unquote(target), unquote(field))

      # On main: no data-studio-held, nothing asks.
      assert [question] =
               a
               |> render()
               |> LazyHTML.from_document()
               |> LazyHTML.query("form#editor-form")
               |> LazyHTML.attribute("data-studio-held")

      assert question == "Not saved: #{unquote(label)}. What you typed there will be lost."
    end

    test "studio #{field}: typing on saves A's words and the question goes", c do
      a = hold(c, :studio, unquote(target), unquote(field))
      posts(a, unquote(target), %{unquote(field) => "one twAA three"})

      assert ObjectRichText.eventually(fn ->
               not has_element?(a, "form#editor-form[data-studio-held]")
             end)
    end

    test "desk #{field}: the desk asks from its pane, not the Studio form", c do
      a = hold(c, :desk, unquote(target), unquote(field))
      assert has_element?(a, "[data-pane-editing][data-desk-held]")
      refute has_element?(a, "form#editor-form[data-studio-held]")
    end
  end

  # #28836 r1 review: Studio's list rows and New document are phx-click
  # buttons, not links. A row click left the held field with no question
  # and A's words were gone. The server asks (`StudioLive.LeaveAsk`).
  test "studio: a row of another document asks first and stays, A's words kept; the same press again leaves",
       c do
    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => c.id <> "-2", "title" => "Second", "content" => %{}},
        @dataset
      )

    a = hold(c, :studio, "doc[notes]", "notes")
    row = ~s(button[phx-click="select"][phx-value-id="#{c.id}-2"])
    assert ObjectRichText.eventually(fn -> has_element?(a, row) end)

    # On r1: the editor moved to the second document, A's words dropped.
    html = a |> element(row) |> render_click()
    assert html =~ "Not saved: Notes. What you typed there will be lost."
    # task-66200f2c6a01ab57: the flash says the press was stopped, and how to go.
    assert html =~ "What you typed there will be lost. Press again to leave."
    assert Content.published_id(assigns(a).editor_doc.doc_id) == c.id
    assert assigns(a).editor_form["notes"] == "one twA three"
    assert has_element?(a, "form#editor-form[data-studio-held]")

    a |> element(row) |> render_click()
    assert Content.published_id(assigns(a).editor_doc.doc_id) == c.id <> "-2"
  end

  # #28836 r2 review: the asked press outlived its hold. Asked on row X,
  # the hold ended by typing on, a new clash held notes again: row X then
  # left with no question, and A's words were lost.
  test "studio: a press asked under a hold that ended asks again under the next hold", c do
    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => c.id <> "-2", "title" => "Second", "content" => %{}},
        @dataset
      )

    a = hold(c, :studio, "doc[notes]", "notes")
    row = ~s(button[phx-click="select"][phx-value-id="#{c.id}-2"])
    assert ObjectRichText.eventually(fn -> has_element?(a, row) end)
    a |> element(row) |> render_click()

    posts(a, "doc[notes]", %{"notes" => "one twAA three"})

    assert ObjectRichText.eventually(fn ->
             not has_element?(a, "form#editor-form[data-studio-held]")
           end)

    b = open(c, :studio)

    ObjectRichText.inside(
      a,
      fn -> posts(b, "doc[notes]", %{"notes" => "one twAA thBee"}) end,
      fn -> posts(a, "doc[notes]", %{"notes" => "one twAA thAee"}) end
    )

    assert has_element?(a, "form#editor-form[data-studio-held]")

    # On f28fe5636e: the editor moved to the second document, A's words lost.
    html = a |> element(row) |> render_click()
    assert html =~ "Not saved: Notes."
    assert Content.published_id(assigns(a).editor_doc.doc_id) == c.id
    assert assigns(a).editor_form["notes"] == "one twAA thAee"
  end

  test "studio: New document asks first while a field is held", c do
    a = hold(c, :studio, "doc[notes]", "notes")

    html = render_click(a, "new-document", %{"type" => c.type})

    assert html =~ "Not saved: Notes."
    assert Content.published_id(assigns(a).editor_doc.doc_id) == c.id
    assert assigns(a).editor_form["notes"] == "one twA three"
  end

  # Opening the document again reads it from the store: the held words go.
  test "studio: the open document's own row asks too", c do
    a = hold(c, :studio, "doc[notes]", "notes")
    row = ~s(button[phx-click="select"][phx-value-id="#{c.id}"])
    assert ObjectRichText.eventually(fn -> has_element?(a, row) end)

    html = a |> element(row) |> render_click()

    assert html =~ "Not saved: Notes."
    assert assigns(a).editor_form["notes"] == "one twA three"
  end

  test "studio: nothing held, nothing asked", c do
    a = open(c, :studio)
    posts(a, "doc[notes]", %{"notes" => "one two three four"})
    assert ObjectRichText.eventually(fn -> stored(c)["notes"] == "one two three four" end)
    refute has_element?(a, "form#editor-form[data-studio-held]")
  end

  test "studio: the layout loads the guard under its content hash", c do
    {:ok, _view, html} = live(c.conn, c.paths.studio)
    assert html =~ BarkparkWeb.StaticAssets.path("bp-studio-leave.js")
    assert BarkparkWeb.StaticAssets.path("bp-studio-leave.js") =~ "/assets/v/"
  end
end
