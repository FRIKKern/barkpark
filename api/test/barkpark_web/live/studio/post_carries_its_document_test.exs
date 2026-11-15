defmodule BarkparkWeb.Studio.PostCarriesItsDocumentTest do
  @moduledoc """
  task-8908b6e031268f77: a post of the editor form is written into the
  document it was built for, or not at all.

  The form's inputs post after a delay. A post built from document A that
  reached the server after the pane had opened document B was written into
  B: every field of A's form. The form now names its document
  (`PostIdentity`) and `autosave` and `save` write only a post that names
  the document the editor holds.

  Both surfaces: the desk and the old Studio page.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"

  @fields [
    %{"name" => "title", "title" => "Title", "type" => "string"},
    %{"name" => "byline", "title" => "Byline", "type" => "string"},
    %{"name" => "note", "title" => "Note", "type" => "text"},
    %{"name" => "score", "title" => "Score", "type" => "number"},
    %{"name" => "flag", "title" => "Flag", "type" => "boolean"},
    %{"name" => "kind", "title" => "Kind", "type" => "select", "options" => ["a", "b", "c"]},
    %{"name" => "day", "title" => "Day", "type" => "date"},
    %{"name" => "at", "title" => "At", "type" => "datetime"},
    %{"name" => "tint", "title" => "Tint", "type" => "color"}
  ]

  defp content(n) do
    %{
      "byline" => "byline #{n}",
      "note" => "note #{n}",
      "score" => n,
      "flag" => false,
      "kind" => "a",
      "day" => "2026-09-1#{n}",
      "at" => "2026-09-1#{n}T09:00:00Z",
      "tint" => "#33669#{n}"
    }
  end

  # What a browser showing document `n` posts.
  defp form_of(n, title) do
    n
    |> content()
    |> Map.new(fn {key, value} -> {key, to_string(value)} end)
    |> Map.put("title", title)
  end

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "post_identity_#{n}"
    a = "post-identity-a-#{n}"
    b = "post-identity-b-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => type, "title" => "Posts", "visibility" => "public", "fields" => @fields},
        @dataset
      )

    for {id, k} <- [{a, 1}, {b, 2}] do
      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => id, "title" => "Title #{k}", "content" => content(k)},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "post-identity-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "post-identity", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     type: type,
     a: a,
     b: b,
     studio: {&"#{base}/#{type}/#{&1}", "#editor-form"},
     desk: {&"#{base}/_desk/#{type};#{&1}", "[data-pane-editing] #editor-form"}}
  end

  defp shows?(view, sel, id), do: has_element?(view, ~s(#{sel} #bp-seen-#{id}))

  defp await(view, sel, id) do
    assert Enum.any?(1..200, fn _ -> shows?(view, sel, id) or (Process.sleep(10) && false) end)
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

  # What the form on the page carries for its document.
  defp identity({view, sel}) do
    html = view |> element(sel) |> render()
    [_, value] = Regex.run(~r/<form[^>]*\sphx-value-_bp_doc="([^"]*)"/, html)
    value |> String.replace("&quot;", ~s(")) |> String.replace("&amp;", "&")
  end

  defp stored(c, id) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    Map.put(doc.content || %{}, "title", doc.title)
  end

  defp untouched(n), do: Map.put(content(n), "title", "Title #{n}")

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: the form names its document, the same before and after a draft exists",
         c do
      page = open(c, @surface, c.a)

      assert identity(page) == PostIdentity.value(@dataset, c.type, c.a)
      assert identity(page) == PostIdentity.value(@dataset, c.type, "drafts." <> c.a)
      refute identity(page) == PostIdentity.value(@dataset, c.type, c.b)
    end

    test "#{surface}: a change built from A that arrives after the pane opened B is not written",
         c do
      {view, _sel} = page = open(c, @surface, c.a)
      of_a = identity(page)

      goes_to(page, c, @surface, c.b)
      refute identity(page) == of_a

      render_change(view, "autosave", %{
        "_target" => ["doc", "title"],
        "_bp_doc" => of_a,
        "doc" => form_of(1, "Title 1 typed")
      })

      assert stored(c, c.b) == untouched(2)
      assert stored(c, c.a) == untouched(1)

      # The page still draws B, and B's own change is B's.
      {view, sel} = page
      assert shows?(view, sel, c.b)

      view
      |> form(sel, %{"doc" => %{"byline" => "B typed"}})
      |> render_change(%{"_target" => ["doc", "byline"]})

      assert stored(c, c.b) == Map.put(untouched(2), "byline", "B typed")
      assert stored(c, c.a) == untouched(1)
    end

    test "#{surface}: a post built in the middle of the patch from A to B is not written",
         c do
      {view, _sel} = page = open(c, @surface, c.a)
      of_a = identity(page)
      goes_to(page, c, @surface, c.b)
      of_b = identity(page)

      # The form's attributes are B's already, its inputs and last child A's.
      render_change(view, "autosave", %{
        "_target" => ["doc", "title"],
        "_bp_doc" => of_b,
        "_bp_doc_end" => of_a,
        "doc" => form_of(1, "Title 1 typed")
      })

      render_submit(view, "save", %{
        "_bp_doc" => of_b,
        "_bp_doc_end" => of_a,
        "doc" => form_of(1, "Title 1 typed")
      })

      assert stored(c, c.b) == untouched(2)
      assert stored(c, c.a) == untouched(1)
    end

    test "#{surface}: the form's last child carries the same name as the form", c do
      {view, sel} = page = open(c, @surface, c.a)
      html = view |> element(sel) |> render()

      assert [[_, value]] =
               Regex.scan(~r/<input[^>]*\sname="_bp_doc_end"[^>]*\svalue="([^"]*)"/, html)

      assert String.replace(value, "&quot;", ~s(")) == identity(page)
      assert html =~ ~r/<input[^>]*\sname="_bp_doc_end"[^>]*>\s*<\/form>/
    end

    test "#{surface}: a Save built from A that arrives after the pane opened B is not written",
         c do
      {view, _sel} = page = open(c, @surface, c.a)
      of_a = identity(page)
      goes_to(page, c, @surface, c.b)

      render_submit(view, "save", %{"_bp_doc" => of_a, "doc" => form_of(1, "Title 1 typed")})

      assert stored(c, c.b) == untouched(2)
      assert stored(c, c.a) == untouched(1)
    end

    test "#{surface}: a post sent by hand with no document, or another one, is not written",
         c do
      {view, _sel} = open(c, @surface, c.a)
      typed = form_of(1, "Typed by hand")

      for extra <- [
            %{},
            %{"_bp_doc" => PostIdentity.value(@dataset, c.type, c.b)},
            %{"_bp_doc" => c.a},
            %{"_bp_doc" => ["production", c.type, c.a]},
            %{"_bp_doc" => PostIdentity.value("other", c.type, c.a)},
            %{"_bp_doc" => PostIdentity.value(@dataset, "other", c.a)}
          ] do
        render_change(
          view,
          "autosave",
          Map.merge(%{"_target" => ["doc", "title"], "doc" => typed}, extra)
        )

        render_submit(view, "save", Map.merge(%{"doc" => typed}, extra))
        assert stored(c, c.a) == untouched(1)
      end

      # The same post with A's own value is written.
      render_change(view, "autosave", %{
        "_target" => ["doc", "title"],
        "_bp_doc" => PostIdentity.value(@dataset, c.type, c.a),
        "doc" => typed
      })

      assert stored(c, c.a) == Map.put(untouched(1), "title", "Typed by hand")
    end

    test "#{surface}: a change and a Save of the page's own form store the edit and nothing else",
         c do
      {view, sel} = open(c, @surface, c.a)

      edits = [
        {"title", "Title typed", "Title typed"},
        {"byline", "byline typed", "byline typed"},
        {"note", "note typed", "note typed"},
        {"score", "7", 7},
        {"flag", "true", true},
        {"kind", "b", "b"},
        {"day", "2026-10-02", "2026-10-02"},
        {"at", "2026-10-02T10:30:00Z", "2026-10-02T10:30:00Z"},
        {"tint", "#112233", "#112233"}
      ]

      expected =
        Enum.reduce(edits, untouched(1), fn {name, posted, kept}, expected ->
          # Over the form as the page draws it (a hidden input takes no fill).
          view
          |> element(sel)
          |> render_change(%{"_target" => ["doc", name], "doc" => %{name => posted}})

          expected = Map.put(expected, name, kept)
          assert stored(c, c.a) == expected
          expected
        end)

      view |> form(sel) |> render_submit()

      assert stored(c, c.a) == expected
      assert stored(c, c.b) == untouched(2)

      # The key is no field: not in the content, not in the form buffer.
      state = :sys.get_state(view.pid).socket.assigns

      for key <- [PostIdentity.key(), PostIdentity.end_key()] do
        refute Map.has_key?(state.editor_form, key)
        refute Map.has_key?(state.editor_doc.content, key)
      end
    end
  end
end
