defmodule BarkparkWeb.Studio.RemoteSaveClashOwnFieldsTest do
  @moduledoc """
  task-65543203e7b71c80: another user's save over a form with unsaved edits
  is a conflict only where it rewrote one of the fields this page changed,
  as TanStack's `rebase` / `clash` (barkpark-studio edit-bases.ts,
  edits.ts). Fields this page did not change take the remote save quietly
  and the local edits stay; text both changed merges where both changes can
  stand. Both surfaces read the remote save through `Lifecycle.doc_updated/2`:
  the desk and the old Studio page.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @banner ~s([data-test-id="doc-conflict-banner"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "clash_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Clash posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "text"},
            %{
              "name" => "tags",
              "title" => "Tags",
              "type" => "arrayOf",
              "of" => %{"type" => "string"}
            }
          ]
        },
        @dataset
      )

    id = "clash-post-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "Fixture",
          "content" => %{"excerpt" => "First words", "tags" => ["a"]}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "clash-own-fields-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "clash-own-fields", @dataset, ~w(read write admin), ws_id)
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     paths: %{desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}"}}
  end

  defp open(c, surface) do
    {:ok, view, _html} = live(c.conn, c.paths[surface])
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # A holds `edits` that did not reach the store (a save that did not land),
  # typed on the stored values (`Handlers.UnsavedBases`).
  defp unsaved!(view, edits) do
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket

      typed_on =
        Map.new(edits, fn {key, edit} -> {key, {socket.assigns.editor_form[key], edit}} end)

      assigns =
        Map.merge(socket.assigns, %{
          editor_dirty: true,
          editor_unsaved_keys: MapSet.new(Map.keys(edits)),
          editor_unsaved_bases: typed_on,
          editor_form: Map.merge(socket.assigns.editor_form, edits)
        })

      %{state | socket: %{socket | assigns: assigns}}
    end)
  end

  defp saves(view, key, doc) do
    view
    |> element("#editor-form")
    |> render_change(%{"_target" => ["doc", key], "doc" => doc})
  end

  # A post as the page sends it: `seen` is its `_bp_seen`, the number of the
  # value each field was typed from (bp-array-focus.js).
  defp posts(view, key, doc, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", key],
      "doc" => doc,
      "_bp_seen" => Jason.encode!(Map.put(seen, "v", 2))
    })
  end

  defp stored(c) do
    [_, type, id] = Regex.run(~r{/([^/;]+);([^/]+)$}, c.paths.desk)
    {doc, _, _} = Content.fetch_doc_with_draft(type, id, @dataset)
    doc
  end

  @long "Fixture " <> String.duplicate("x", 300)

  # A's title is held (over 255 characters: the save is refused and the
  # field kept), then B saves "Lead " in front of the stored title. Returns
  # the numbers of the push A was sent: [the value it showed, the merge].
  defp held_title_under_remote_save(a, b) do
    held_title!(a, fn ->
      posts(a, "title", %{"title" => @long, "excerpt" => "First words"}, %{})
    end)

    remote_title(a, b, "Lead Fixture")
  end

  defp held_title!(a, post) do
    post.()

    assert eventually(fn ->
             MapSet.member?(assigns(a).editor_unsaved_keys || MapSet.new(), "title")
           end)
  end

  # B saves `title`: the numbers of the push A was sent for it.
  defp remote_title(a, b, title) do
    saves(b, "title", %{"title" => title, "excerpt" => "First words"})
    render(a)
    assert_push_event(a, "bp:form-remote-values", %{seqs: %{"doc[title]" => [was, merged]}})
    [was, merged]
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: a save of a field this page did not change is taken in, no conflict", c do
      a = open(c, @surface)
      b = open(c, @surface)
      unsaved!(a, %{"excerpt" => "Mine, unsent"})

      saves(b, "title", %{"title" => "From B", "excerpt" => "First words"})

      assert eventually(fn -> assigns(a).editor_form["title"] == "From B" end)
      assert assigns(a).editor_form["excerpt"] == "Mine, unsent"
      assert assigns(a).doc_conflict == false
      refute assigns(a).save_status == "Updated by another user"
      refute has_element?(a, @banner)
    end

    test "#{surface}: control: a save that rewrote this page's own field still conflicts", c do
      a = open(c, @surface)
      b = open(c, @surface)
      unsaved!(a, %{"title" => "Mine, unsent"})

      saves(b, "title", %{"title" => "From B", "excerpt" => "First words"})

      assert eventually(fn -> assigns(a).doc_conflict == true end)
      assert assigns(a).editor_form["title"] == "Mine, unsent"
      assert assigns(a).save_status == "Updated by another user"
      assert has_element?(a, @banner)
    end

    test "#{surface}: text both changed apart merges, no conflict", c do
      a = open(c, @surface)
      b = open(c, @surface)
      unsaved!(a, %{"excerpt" => "First words, mine"})

      saves(b, "excerpt", %{"title" => "Fixture", "excerpt" => "Lead: First words"})

      assert eventually(fn -> assigns(a).editor_form["excerpt"] == "Lead: First words, mine" end)
      assert assigns(a).doc_conflict == false
      refute has_element?(a, @banner)
    end

    # task-881f16e32fffbe9a: words typed after text B cleared have nothing
    # left to sit next to (TanStack's merge3 gives null): a clash, not A's
    # words alone, kept quietly and saved over B's clear.
    test "#{surface}: B clears a field A holds unsaved words in: a conflict, B's clear stored",
         c do
      a = open(c, @surface)
      b = open(c, @surface)
      unsaved!(a, %{"excerpt" => "First words, mine"})

      saves(b, "excerpt", %{"title" => "Fixture", "excerpt" => ""})

      assert eventually(fn -> assigns(a).doc_conflict == true end)
      assert assigns(a).editor_form["excerpt"] == "First words, mine"
      assert has_element?(a, @banner)
      assert stored(c).content["excerpt"] in [nil, ""]
    end

    # TanStack's patch still places A's words: no false banner.
    test "#{surface}: B deletes the sentence before A's unsaved words: they merge, no conflict",
         c do
      a = open(c, @surface)
      b = open(c, @surface)
      saves(b, "excerpt", %{"title" => "Fixture", "excerpt" => "One. Two three. Four five."})

      assert eventually(fn ->
               assigns(a).editor_form["excerpt"] == "One. Two three. Four five."
             end)

      unsaved!(a, %{"excerpt" => "One. Two three. Yes four five."})

      saves(b, "excerpt", %{"title" => "Fixture", "excerpt" => "One. Four five."})

      assert eventually(fn -> assigns(a).editor_form["excerpt"] == "One. Yes four five." end)
      assert assigns(a).doc_conflict == false
      refute has_element?(a, @banner)
    end

    # The clash check is not run past its bounds (TanStack's diff stops at
    # a second): A's page answers at once, with the banner.
    test "#{surface}: a long held rewrite under B's save: the banner, at once", c do
      a = open(c, @surface)
      b = open(c, @surface)
      body = String.duplicate("alpha beta gamma delta. ", 1_900)
      saves(b, "excerpt", %{"title" => "Fixture", "excerpt" => body})
      assert eventually(fn -> assigns(a).editor_form["excerpt"] == body end)
      mid = div(byte_size(body), 2)

      unsaved!(a, %{
        "excerpt" =>
          binary_part(body, 0, mid - 10_000) <>
            String.duplicate("Q", 20_000) <> binary_part(body, mid + 10_000, mid - 10_000)
      })

      saves(b, "excerpt", %{"title" => "Fixture", "excerpt" => "B " <> body})
      started = System.monotonic_time(:millisecond)

      assert eventually(fn -> assigns(a).doc_conflict == true end)
      assert System.monotonic_time(:millisecond) - started < 500
      assert has_element?(a, @banner)
    end

    test "#{surface}: A kept typing through the merge: its next save keeps B's words", c do
      a = open(c, @surface)
      b = open(c, @surface)
      [was, _merged] = held_title_under_remote_save(a, b)

      # The page did not take the merge (the person was typing): it reports
      # the number of the value it showed, and trims its own text.
      posts(a, "title", %{"title" => "Fixture xx", "excerpt" => "First words"}, %{
        "doc[title]" => was
      })

      assert eventually(fn -> stored(c).title == "Lead Fixture xx" end)
    end

    test "#{surface}: A took the merge: its next save keeps B's words", c do
      a = open(c, @surface)
      b = open(c, @surface)
      [_was, merged] = held_title_under_remote_save(a, b)

      posts(a, "title", %{"title" => "Lead Fixture xx", "excerpt" => "First words"}, %{
        "doc[title]" => merged
      })

      assert eventually(fn -> stored(c).title == "Lead Fixture xx" end)
    end

    # #28176 review, round 2: A typed through B's first save, then B saved
    # again. A's held text was typed on "Fixture", not on B's first save, so
    # a merge against the newest version read A as deleting "Lead ".
    test "#{surface}: B saves twice over A's held title, A typing through the first: A's save keeps both",
         c do
      a = open(c, @surface)
      b = open(c, @surface)
      [was, _merged] = held_title_under_remote_save(a, b)

      posts(a, "title", %{"title" => @long <> "y", "excerpt" => "First words"}, %{
        "doc[title]" => was
      })

      [_was, merged] = remote_title(a, b, "Big Lead Fixture")
      assert assigns(a).editor_form["title"] == "Big Lead " <> @long <> "y"

      # The page took the merge, then trims.
      posts(a, "title", %{"title" => "Big Lead Fixture xx", "excerpt" => "First words"}, %{
        "doc[title]" => merged
      })

      assert eventually(fn -> stored(c).title == "Big Lead Fixture xx" end)
    end

    test "#{surface}: B saves three times over A's held title, A typing through two: A's save keeps all",
         c do
      a = open(c, @surface)
      b = open(c, @surface)
      [was, _merged] = held_title_under_remote_save(a, b)

      posts(a, "title", %{"title" => @long <> "y", "excerpt" => "First words"}, %{
        "doc[title]" => was
      })

      [was, _merged] = remote_title(a, b, "Big Lead Fixture")

      posts(a, "title", %{"title" => @long <> "yz", "excerpt" => "First words"}, %{
        "doc[title]" => was
      })

      [_was, merged] = remote_title(a, b, "Very Big Lead Fixture")
      assert assigns(a).editor_form["title"] == "Very Big Lead " <> @long <> "yz"
      refute has_element?(a, @banner)

      posts(a, "title", %{"title" => "Very Big Lead Fixture xx", "excerpt" => "First words"}, %{
        "doc[title]" => merged
      })

      assert eventually(fn -> stored(c).title == "Very Big Lead Fixture xx" end)
    end

    # A post that names no base (no `_bp_seen`: an older page, a built
    # value) leaves nothing that says what its words were typed on: B's save
    # over them is a conflict, not a merge against a guessed base.
    test "#{surface}: B saves over a held title whose base is not known: a conflict, never merged unseen",
         c do
      a = open(c, @surface)
      b = open(c, @surface)
      held_title!(a, fn -> saves(a, "title", %{"title" => @long, "excerpt" => "First words"}) end)

      saves(b, "title", %{"title" => "Lead Fixture", "excerpt" => "First words"})

      assert eventually(fn -> assigns(a).doc_conflict == true end)
      assert assigns(a).editor_form["title"] == @long
      assert has_element?(a, @banner)
    end

    test "#{surface}: a list both changed is a conflict, never ours kept unseen", c do
      a = open(c, @surface)
      b = open(c, @surface)
      unsaved!(a, %{"tags" => ["a", "mine"]})

      saves(b, "tags", %{"title" => "Fixture", "excerpt" => "First words", "tags" => ["a", "B"]})

      assert eventually(fn -> assigns(a).doc_conflict == true end)
      assert assigns(a).editor_form["tags"] == ["a", "mine"]
      assert has_element?(a, @banner)
    end
  end
end
