defmodule BarkparkWeb.Studio.EventsCarryTheirDocumentTest do
  @moduledoc """
  task-8908b6e031268f77: a press that writes the open document without
  posting its form is written into the document it was pressed in, or not
  at all.

  A list's Add, Remove and Move (`array_op`) and Generate on a slug
  (`slug-generate`) ran against whatever document the socket held when they
  arrived (so did the old pickers' events, since removed,
  task-c42545346b93cbb0). A press in document A that
  reached the server after the pane had opened document B changed B. Each
  now names its document (`PostIdentity.pressed/3`); the mark is the one
  the editor form on the page carries, read here from the rendered page.

  Both surfaces: the desk and the old Studio page.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"

  defp fields(person) do
    [
      %{"name" => "title", "title" => "Title", "type" => "string"},
      %{"name" => "slug", "title" => "Slug", "type" => "slug"},
      %{"name" => "tags", "title" => "Tags", "type" => "arrayOf", "of" => %{"type" => "string"}},
      %{"name" => "author", "title" => "Author", "type" => "reference", "refType" => person},
      %{"name" => "cover", "title" => "Cover", "type" => "image"}
    ]
  end

  defp content(n, person),
    do: %{
      "slug" => "slug-#{n}",
      "tags" => ["one #{n}", "two #{n}"],
      "author" => person,
      "cover" => "/media/files/cover-#{n}.png"
    }

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "event_identity_#{n}"
    person = "event_person_#{n}"
    a = "event-identity-a-#{n}"
    b = "event-identity-b-#{n}"
    p1 = "event-person-1-#{n}"
    p2 = "event-person-2-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => person,
          "title" => "People",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Posts",
          "visibility" => "public",
          "fields" => fields(person)
        },
        @dataset
      )

    for id <- [p1, p2] do
      {:ok, _} = Content.create_document(person, %{"doc_id" => id, "title" => id}, @dataset)
    end

    for {id, k} <- [{a, 1}, {b, 2}] do
      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => id, "title" => "Title #{k}", "content" => content(k, p1)},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "event-identity-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "event-identity", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     type: type,
     a: a,
     b: b,
     p1: p1,
     p2: p2,
     studio: {&"#{base}/#{type}/#{&1}", "#editor-form"},
     desk: {&"#{base}/_desk/#{type};#{&1}", "[data-pane-editing] #editor-form"}}
  end

  defp await(view, sel, id) do
    want = ~s(#{sel}[phx-value-_bp_doc*="#{id}"])
    assert Enum.any?(1..200, fn _ -> has_element?(view, want) or (Process.sleep(10) && false) end)
  end

  defp open(c, surface, id) do
    {url, sel} = Map.fetch!(c, surface)
    {:ok, view, _html} = live(c.conn, url.(id))
    render_async(view, 5_000)
    await(view, sel, id)
    {view, sel}
  end

  # The pane opens another document, as a click on its row does.
  defp goes_to({view, sel}, c, surface, id) do
    {url, _sel} = Map.fetch!(c, surface)
    render_patch(view, url.(id))
    await(view, sel, id)
  end

  defp stored(c, id) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    Map.put(doc.content || %{}, "title", doc.title)
  end

  defp untouched(c, n), do: n |> content(c.p1) |> Map.put("title", "Title #{n}")

  # Each press, the params its control sends, and what a written one leaves
  # in the stored document `n`.
  defp presses(c) do
    [
      {"array_op add", "array_op", %{"action" => "add_row", "field" => "tags", "path" => ""},
       &Map.put(&1, "tags", &1["tags"] ++ [nil])},
      {"array_op remove", "array_op",
       %{"action" => "remove_row", "field" => "tags", "path" => "", "index" => "0"},
       &Map.put(&1, "tags", tl(&1["tags"]))},
      {"array_op move", "array_op",
       %{"action" => "move_down", "field" => "tags", "path" => "", "index" => "0"},
       &Map.put(&1, "tags", Enum.reverse(&1["tags"]))},
      {"slug-generate", "slug-generate", %{"field" => "slug"}, &Map.put(&1, "slug", slug_of(&1))}
    ]
  end

  defp slug_of(%{"title" => title}), do: title |> String.downcase() |> String.replace(" ", "-")

  # The stored fields a press may change, in one shape: a cleared field and
  # an absent one are the same, and a slug is its text.
  defp fields_of(doc) do
    doc
    |> Map.take(~w(title slug tags author cover))
    |> Map.new(fn
      {"slug", %{"current" => text}} -> {"slug", text}
      {"author", %{"_ref" => id}} -> {"author", id}
      pair -> pair
    end)
    |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  # The press's message to the page itself, if it sent one, is read too.
  defp settle(view), do: render(view)

  for surface <- [:desk, :studio] do
    @surface surface

    for {label, index} <- Enum.with_index(~w(add remove move slug)) do
      @label label
      @index index

      test "#{surface}: #{label} pressed in A that arrives after the pane opened B changes nothing",
           c do
        {_label, event, params, _change} = Enum.at(presses(c), @index)
        {view, _sel} = page = open(c, @surface, c.a)
        of_a = EditorPost.marks(view)

        goes_to(page, c, @surface, c.b)
        refute EditorPost.marks(view) == of_a

        EditorPost.press(view, event, params, of_a)
        settle(view)

        assert fields_of(stored(c, c.b)) == fields_of(untouched(c, 2))
        assert fields_of(stored(c, c.a)) == fields_of(untouched(c, 1))
      end

      test "#{surface}: #{label} that names another document, or a made-up one, changes nothing",
           c do
        {_label, event, params, _change} = Enum.at(presses(c), @index)
        {view, _sel} = open(c, @surface, c.a)

        for mark <- [
              %{"_bp_doc" => c.a},
              %{"_bp_doc" => ""},
              %{"_bp_doc" => [@dataset, c.type, c.a]},
              %{"_bp_doc" => PostIdentity.value(@dataset, c.type, c.b)},
              %{"_bp_doc" => PostIdentity.value("other", c.type, c.a)}
            ] do
          # Not a reload either: the page stays.
          assert is_binary(render_click(view, event, Map.merge(params, mark)))
          settle(view)

          # Asked after each press: two moves put a list back as it was.
          assert fields_of(stored(c, c.a)) == fields_of(untouched(c, 1))
        end
      end

      # A page whose script is older than the rule sends no mark at all.
      test "#{surface}: #{label} with no mark at all writes nothing and reloads the page", c do
        {_label, event, params, _change} = Enum.at(presses(c), @index)
        {view, _sel} = open(c, @surface, c.a)
        {url, _sel} = Map.fetch!(c, @surface)

        assert {:error, {:redirect, %{to: to}}} = render_click(view, event, params)
        assert URI.decode(to) == URI.decode(url.(c.a))

        assert fields_of(stored(c, c.a)) == fields_of(untouched(c, 1))
      end

      test "#{surface}: #{label} pressed in the open document is written there", c do
        {_label, event, params, change} = Enum.at(presses(c), @index)
        {view, _sel} = open(c, @surface, c.b)

        EditorPost.press(view, event, params)
        settle(view)

        assert fields_of(stored(c, c.b)) == fields_of(change.(untouched(c, 2)))
        assert fields_of(stored(c, c.a)) == fields_of(untouched(c, 1))
      end
    end

    test "#{surface}: the Add button of the page, pressed with the page's mark, adds the row",
         c do
      {view, sel} = open(c, @surface, c.a)

      EditorPost.press_on(
        view,
        element(view, ~s(#{sel} [phx-value-action="add_row"][phx-value-field="tags"]))
      )

      assert stored(c, c.a)["tags"] == ["one 1", "two 1", nil]
    end
  end

  test "a press's mark for a document whose id has quotes, <, &, é and spaces", c do
    odd = ~s(o'dd "id" <b> & é #{System.unique_integer([:positive])})
    mark = PostIdentity.value(@dataset, c.type, odd)
    socket = %{id: "t", assigns: %{dataset: @dataset, editor_doc: %{doc_id: odd, type: c.type}}}

    draft = %{
      socket
      | assigns: %{socket.assigns | editor_doc: %{doc_id: "drafts." <> odd, type: c.type}}
    }

    for held <- [socket, draft] do
      assert {:ran, %{"field" => "tags"}} ==
               PostIdentity.pressed(%{"_bp_doc" => mark, "field" => "tags"}, held, fn params, _ ->
                 {:ran, params}
               end)
    end

    for none <- [%{"field" => "tags"}, %{"field" => "tags", "_bp_doc" => ""}] do
      assert {:noreply, socket} ==
               PostIdentity.pressed(none, socket, fn _, _ -> flunk("ran") end)
    end
  end
end
