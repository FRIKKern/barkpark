defmodule BarkparkWeb.Studio.DeskReviewChangesTest do
  @moduledoc """
  J15 on the desk, as the TanStack Studio has it (`ReviewChanges.tsx`,
  `Fields.tsx` `ChangeBar`): a field the draft changed since publish has a
  change bar that opens Review changes; the tab lists each changed field
  with its diff and a Revert; Revert all reverts them all. A revert writes
  the published value of that field back into the draft and nothing else,
  for every kind of value (the stored row read back). A press named for
  another document, or for none, writes nothing.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @review ",changesInspectorTab=review,inspect=sanity%2Fstructure%2Fhistory"
  @panel ~s([data-pane-editing] aside[aria-label="History"] [role="tabpanel"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "rvw_#{n}"
    author_type = "rvwa_#{n}"
    f = fn name, t, extra -> Map.merge(%{"name" => name, "title" => name, "type" => t}, extra) end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author_type,
          "title" => "Authors #{n}",
          "visibility" => "public",
          "fields" => [f.("title", "string", %{})]
        },
        @dataset
      )

    for {id, title} <- [{"rvwa1-#{n}", "Ada Lovelace"}, {"rvwa2-#{n}", "Grace Hopper"}] do
      {:ok, _} =
        Content.create_document(author_type, %{"doc_id" => id, "title" => title}, @dataset)

      {:ok, _} = Content.publish_document(id, author_type, @dataset)
    end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Review #{n}",
          "visibility" => "public",
          "fields" => [
            f.("title", "string", %{"title" => "Title"}),
            f.("slug", "slug", %{"title" => "Slug"}),
            f.("excerpt", "text", %{"title" => "Excerpt"}),
            f.("count", "number", %{}),
            f.("flag", "boolean", %{}),
            f.("choice", "select", %{"options" => ["a", "b", "c"]}),
            f.("reviewer", "reference", %{"to" => [author_type]}),
            f.("cover", "image", %{}),
            f.("cta", "composite", %{
              "fields" => [
                %{"name" => "url", "type" => "string"},
                %{"name" => "label", "type" => "string"}
              ]
            }),
            f.("tags", "arrayOf", %{"of" => [%{"type" => "string"}]}),
            f.("links", "arrayOf", %{
              "of" => [
                %{
                  "name" => "link",
                  "type" => "composite",
                  "fields" => [
                    %{"name" => "title", "type" => "string"},
                    %{"name" => "url", "type" => "string"}
                  ]
                }
              ]
            }),
            f.("body", "richText", %{}),
            f.("untouched", "string", %{})
          ]
        },
        @dataset
      )

    block = fn key, text ->
      %{
        "_type" => "block",
        "_key" => key,
        "style" => "normal",
        "markDefs" => [],
        "children" => [%{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}]
      }
    end

    published = %{
      "slug" => %{"current" => "fixture-post"},
      "excerpt" => "Short excerpt for the post.",
      "count" => 7,
      "flag" => false,
      "choice" => "b",
      "reviewer" => %{"_ref" => "rvwa1-#{n}", "_type" => "reference"},
      "cover" => %{"url" => "/media/files/old.png", "assetId" => "old", "alt" => "Old"},
      "cta" => %{"url" => "https://old.test", "label" => "Old"},
      "tags" => ["one", "two"],
      "links" => [
        %{"_key" => "l1", "title" => "Docs", "url" => "https://docs.test"},
        %{"_key" => "l2", "title" => "Blog", "url" => "https://blog.test"}
      ],
      "body" => [block.("b1", "First paragraph."), block.("b2", "Second paragraph.")],
      "untouched" => "Same in both"
    }

    draft = %{
      "slug" => %{"current" => "post-reviewed"},
      "excerpt" => "Changed for review.",
      "count" => 9,
      "flag" => true,
      "choice" => "c",
      "reviewer" => %{"_ref" => "rvwa2-#{n}", "_type" => "reference"},
      "cover" => %{"url" => "/media/files/new.png", "assetId" => "new", "alt" => "New"},
      "cta" => %{"url" => "https://new.test", "label" => "Old"},
      "tags" => ["one", "three"],
      "links" => [
        %{"_key" => "l2", "title" => "Blog", "url" => "https://blog.test"},
        %{"_key" => "l3", "title" => "News", "url" => "https://news.test"}
      ],
      "body" => [block.("b1", "First paragraph, edited."), block.("b2", "Second paragraph.")],
      "untouched" => "Same in both"
    }

    id = "rvw-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Fixture post", "content" => published},
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)

    {:ok, _} =
      Content.upsert_document(
        type,
        %{"doc_id" => Content.draft_id(id), "title" => "Post reviewed", "content" => draft},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-review-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-review", @dataset, ~w(read write admin), ws_id)
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     root: root,
     url: "#{root}/#{type};#{id}"}
  end

  defp open(c, params \\ "") do
    {:ok, view, _} = live(c.conn, c.url <> params)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c, id) do
    {:ok, doc} = Content.get_document(id, c.type, @dataset)
    Map.put(doc.content, "title", doc.title)
  end

  defp draft(c), do: stored(c, Content.draft_id(c.id))
  defp published(c), do: stored(c, c.id)

  defp revert(view, params),
    do: render_hook(view, "desk-field-revert", Map.merge(mark(view), params))

  defp mark(view), do: Map.take(EditorPost.marks(view), [PostIdentity.key()])

  describe "change bars" do
    # On the old code every field's change bar was an empty, hidden span.
    test "a field the draft changed has a change bar that opens Review changes", c do
      view = open(c)

      for name <- ~w(title slug excerpt) do
        bar = ~s|[data-pane-editing] .field:has([id="#{name}"]) > button.change-bar|

        assert has_element?(view, bar <> ~s([aria-label="Review changes"])),
               "#{name} has no change bar"
      end

      refute has_element?(
               view,
               ~s|[data-pane-editing] .field:has([id="untouched"]) > button.change-bar|
             )

      assert has_element?(
               view,
               ~s|[data-pane-editing] .field:has([id="untouched"]) > span.change-bar[hidden]|
             )

      view
      |> element(~s|[data-pane-editing] .field:has([id="title"]) > button.change-bar|)
      |> render_click()

      to = assert_patch(view)
      assert to =~ "changesInspectorTab=review" and to =~ "inspect=sanity%2Fstructure%2Fhistory"
    end

    test "a document never published, and one with no draft, have none", c do
      {:ok, _} = Content.discard_draft(c.id, c.type, @dataset)
      view = open(c)
      refute has_element?(view, "[data-pane-editing] button.change-bar")
    end
  end

  describe "the Review changes tab" do
    # On the old code the tab's panel was empty.
    test "lists each changed field with its diff, from the last publish", c do
      view = open(c, @review)
      panel = view |> element(@panel) |> render()

      assert panel =~ "Published:"
      assert has_element?(view, ~s(#{@panel} button[aria-label^="From: Published: "]))
      assert has_element?(view, ~s(#{@panel} li[data-field="title"]), "Post reviewed")
      assert has_element?(view, ~s(#{@panel} li[data-field="title"] del), "Fixture")
      assert has_element?(view, ~s(#{@panel} li[data-field="title"] ins), "reviewed")
      assert has_element?(view, ~s(#{@panel} li[data-field="slug"] .review-fromto), "→")
      assert has_element?(view, ~s(#{@panel} li[data-field="slug"] del), "fixture-post")
      assert has_element?(view, ~s(#{@panel} li[data-field="reviewer"] del), "Ada Lovelace")
      assert has_element?(view, ~s(#{@panel} li[data-field="reviewer"] ins), "Grace Hopper")

      assert has_element?(
               view,
               ~s(#{@panel} li[data-field="links"] li[data-kind="added"]),
               "News"
             )

      assert has_element?(
               view,
               ~s(#{@panel} li[data-field="links"] li[data-kind="removed"]),
               "Docs"
             )

      assert has_element?(
               view,
               ~s(#{@panel} li[data-field="body"] p[data-change="changed"] ins),
               "edited"
             )

      refute has_element?(view, ~s(#{@panel} li[data-field="body"]), "Second paragraph")

      assert has_element?(
               view,
               ~s(#{@panel} li[data-field="cta"] .review-attr),
               "https://new.test"
             )

      refute has_element?(view, ~s(#{@panel} li[data-field="untouched"]))

      assert has_element?(view, ~s(#{@panel} button[aria-label="Revert changes to Title"]))
      assert has_element?(view, ~s(#{@panel} button.revert-all[aria-label="Revert all"]))
      assert panel =~ "<p>Are you sure you want to revert all 12 changes?</p>"

      assert length(String.split(panel, "<p>Are you sure you want to revert the change?</p>")) ==
               2
    end

    # A pane's id has a colon: "#<id>" picked nothing in Chrome, so the
    # confirm reverted no field and sat at the window's corner.
    test "a field's revert names that field on the confirm, by a selector that finds it", c do
      view = open(c, @review)

      [ops] =
        view
        |> element(~s(#{@panel} button[aria-label="Revert changes to Title"]))
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("button")
        |> LazyHTML.attribute("phx-click")

      sets =
        for ["set_attr", %{"to" => to, "attr" => [k, v]}] <- Jason.decode!(ops), do: {to, k, v}

      assert [{field_to, "phx-value-field", "title"}, {box_to, "style", style}] = sets
      assert has_element?(view, field_to, "Revert change")
      assert has_element?(view, box_to)
      [anchor] = Regex.run(~r/position-anchor: --([^;]+);/, style, capture: :all_but_first)
      assert anchor =~ ~r/^[A-Za-z0-9_-]+$/
      assert render(view) =~ "anchor-name: --#{anchor}"
    end

    test "with one change there is no Revert all; with none it says so", c do
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => Content.draft_id(c.id),
          "title" => "Post reviewed",
          "content" => Map.delete(published(c), "title")
        },
        @dataset
      )

      view = open(c, @review)
      assert has_element?(view, ~s(#{@panel} li[data-field="title"]))
      refute has_element?(view, ~s(#{@panel} .revert-all))

      revert(view, %{"field" => "title"})
      assert has_element?(view, @panel, "There are no changes")
    end

    test "right after a publish, it shows what that publish changed", c do
      {:ok, _} = Content.publish_document(c.id, c.type, @dataset)
      view = open(c, @review)

      assert has_element?(view, ~s(#{@panel} li[data-field="title"] ins), "reviewed")
      refute has_element?(view, @panel, "There are no changes")
      assert has_element?(view, ~s(#{@panel} button[aria-label^="To: Published: "]))
    end
  end

  describe "Revert" do
    # Every kind of value: the stored draft row holds the published value of
    # the reverted field and keeps every other field it had.
    test "one field at a time writes that field's published value back, any kind", c do
      view = open(c, @review)
      pub = published(c)
      before = draft(c)

      names = ~w(title slug excerpt count flag choice reviewer cover cta tags links body)

      Enum.reduce(names, before, fn name, expected ->
        revert(view, %{"field" => name})
        expected = Map.put(expected, name, pub[name])
        now = draft(c)

        for key <- Map.keys(expected) ++ Map.keys(now), uniq: true do
          assert now[key] == expected[key],
                 "after reverting #{name}, #{key} is #{inspect(now[key])}, not #{inspect(expected[key])}"
        end

        refute has_element?(view, ~s(#{@panel} li[data-field="#{name}"])), "#{name} still listed"
        expected
      end)

      assert has_element?(view, @panel, "There are no changes")
      refute has_element?(view, "[data-pane-editing] button.change-bar")
    end

    test "Revert all writes every changed field back", c do
      view = open(c, @review)

      EditorPost.press_on(
        view,
        element(view, "#{@panel} [data-desk-review-revert][phx-value-all]")
      )

      pub = published(c)
      now = draft(c)
      for {k, v} <- pub, do: assert(now[k] == v, "#{k} is #{inspect(now[k])}")
      assert has_element?(view, @panel, "There are no changes")
    end

    test "the form shows the reverted value", c do
      view = open(c, @review)
      revert(view, %{"field" => "title"})

      assert view |> element(~s([data-pane-editing] #editor-form input[id="title"])) |> render() =~
               ~s(value="Fixture post")

      assert has_element?(
               view,
               ~s([data-pane-editing] #editor-form [id="excerpt"]),
               "Changed for review."
             )
    end

    test "a press named for another document, or for none, writes nothing", c do
      view = open(c, @review)
      before = draft(c)
      other = %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, "someone-else")}

      render_hook(view, "desk-field-revert", Map.merge(other, %{"field" => "title"}))
      render_hook(view, "desk-field-revert", %{"field" => "title"})
      render_hook(view, "desk-field-revert", Map.merge(other, %{"all" => "true"}))
      revert(view, %{"field" => "no-such-field"})
      revert(view, %{"field" => "untouched"})

      assert draft(c) == before
    end

    test "nothing is written while a revision is shown", c do
      rev =
        c.id
        |> Content.list_revisions(c.type, @dataset, limit: 10)
        |> Enum.find(&(&1.action == "publish"))

      view = open(c, @review <> ",rev=#{rev.id}")
      before = draft(c)
      revert(view, %{"field" => "title"})
      revert(view, %{"all" => "true"})
      assert draft(c) == before
    end
  end

  describe "reads" do
    # The published version is read once per draft, and the diff is made in
    # memory: an edit costs the same reads with twelve changed fields as with
    # one.
    test "an edit with Review changes open reads nothing per changed field", c do
      view = open(c, @review)
      edit = fn title -> EditorPost.change(view, %{"doc" => %{"title" => title}}) end

      {_, many} =
        Barkpark.QueryCounter.census(fn ->
          Barkpark.QueryCounter.own(view.pid) && edit.("Edit one")
        end)

      for name <- ~w(slug excerpt count flag choice reviewer cover cta tags links body),
          do: revert(view, %{"field" => name})

      assert [_] = :sys.get_state(view.pid).socket.assigns.desk_review.changes

      {_, one} =
        Barkpark.QueryCounter.census(fn ->
          Barkpark.QueryCounter.own(view.pid) && edit.("Edit two")
        end)

      assert many == one, "with 12 changes: #{inspect(many)}; with 1: #{inspect(one)}"
    end
  end

  describe "the word diff" do
    alias BarkparkWeb.Studio.Desk.FieldDiff

    # TanStack's textDiff runs diff-match-patch's semantic cleanup: a short
    # kept word between two edits is part of them.
    test "folds short kept words between edits into one removal and one addition" do
      assert FieldDiff.text_diff("Short excerpt for post 24.", "Changed for review.") ==
               [removed: "Short excerpt for post 24", added: "Changed for review", same: "."]

      assert FieldDiff.text_diff("the quick brown fox", "the quick red fox") ==
               [same: "the quick ", removed: "brown", added: "red", same: " fox"]
    end

    # A doc written through the API keeps a slug as its text; the form
    # writes the slug object. The same slug is no change.
    test "a slug or a reference is the same as text or as its object; rich text is its blocks" do
      assert FieldDiff.same?("post-24", %{"_type" => "slug", "current" => "post-24"})
      assert FieldDiff.same?(%{"_ref" => "ada", "_type" => "reference"}, "ada")
      refute FieldDiff.same?("post-24", %{"_type" => "slug", "current" => "post-25"})
      refute FieldDiff.same?(%{"_ref" => "ada", "_weak" => true}, "ada")

      blocks = [
        %{
          "id" => "p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Hi"}]
        }
      ]

      assert FieldDiff.same?(%{"blocks" => blocks}, %{"blocks" => blocks, "html" => "<p>Hi</p>"})
      refute FieldDiff.same?(%{"blocks" => []}, %{"blocks" => blocks, "html" => "<p>Hi</p>"})
    end
  end
end
