defmodule BarkparkWeb.Studio.StudioObjectsTest do
  @moduledoc """
  task-e24e33a2a1a4fe10 and task-19392d1e6fc661e6, on synthetic documents with
  the shapes of a Sanity page-builder site
  (`test/fixtures/studio_objects/page_builder_documents.json`: invented
  schemas, text, ids and keys).

    * Page-builder arrays (`frontPage.frontpageSections`,
      `page.landingPageSections`): each item opens in the form of its member
      type, and can be edited, added (choosing the member), moved and removed.
    * Custom blocks in a Portable Text article body (`quote`, `mediaModule`,
      `inlineFeaturedProducts`, ...): a block opens in the same object form in
      a dialog, saves back by `_key`, and a new block of each declared type can
      be inserted at the caret.

  Every round trip keeps the untouched items and blocks equal to what was
  stored, `_key`s included.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.PortableText
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @fixture Path.expand("../../../fixtures/studio_objects/page_builder_documents.json", __DIR__)
  @key ~r/\A[0-9a-f]{12}\z/

  setup %{conn: conn} do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "objects-#{suffix}", name: "Objects"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})

    raw = "objects-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "objects", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")
    scope = [workspace_id: ws.id, project_id: proj.id]

    apply_schemas!(fixture["object_schemas"] ++ fixture["document_schemas"], scope)

    for d <- fixture["documents"], do: publish!(d, scope)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj, scope: scope, fixture: fixture}
  end

  # Schemas apply in fixture order; a type that names one not
  # yet applied is retried on the next pass.
  defp apply_schemas!(schemas, scope, passes \\ 5)

  defp apply_schemas!([], _scope, _passes), do: :ok

  defp apply_schemas!(schemas, _scope, 0),
    do: flunk("schemas did not apply: #{Enum.map_join(schemas, ", ", & &1["name"])}")

  defp apply_schemas!(schemas, scope, passes) do
    failed =
      Enum.reject(schemas, fn s ->
        match?({:ok, _}, Content.upsert_schema(s, @dataset, scope))
      end)

    apply_schemas!(failed, scope, passes - 1)
  end

  defp publish!(%{"doc_id" => id, "type" => type, "title" => title, "content" => content}, scope) do
    {:ok, _} =
      Content.upsert_document(
        type,
        %{"doc_id" => id, "title" => title, "status" => "published", "content" => content},
        @dataset,
        Keyword.put(scope, :source, :api)
      )

    {:ok, _} = Content.publish_document(id, type, @dataset, scope)
  end

  defp doc_path(ws, proj, type, id),
    do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{type}/#{id}"

  defp published(fixture, id), do: Enum.find(fixture["documents"], &(&1["doc_id"] == id))

  defp draft!(type, id, scope) do
    {:ok, doc} = Content.get_document("drafts." <> id, type, @dataset, scope)
    doc
  end

  defp keys(list), do: Enum.map(list, & &1["_key"])
  defp types(list), do: Enum.map(list, & &1["_type"])

  describe "page-builder items (frontPage.frontpageSections)" do
    test "each item opens in the form of its member type",
         %{conn: conn, ws: ws, proj: proj} do
      {:ok, _view, html} = live(conn, doc_path(ws, proj, "frontPage", "frontPage"))

      refute html =~ "this list holds several item types, which this editor cannot edit yet"
      # productCardsSection's own fields, by the member schema
      assert html =~ ~s(name="doc[frontpageSections][1].heading")
      assert html =~ ~s(name="doc[frontpageSections][1].columns")
      # featureCardsSection's nested cards render their fields too
      assert html =~ ~s(name="doc[frontpageSections][0].cards[0].title")
      # the item keeps its identity in the post
      assert html =~ ~s(name="doc[frontpageSections][1]._key" value="a1f0c0de0002")
      assert html =~ ~s(name="doc[frontpageSections][1]._type" value="productCardsSection")
      # "Add item" offers the declared members
      assert html =~ ~s(data-member="videoHeroSection")
    end

    test "editing one item changes only that field; every other item keeps its stored value",
         %{conn: conn, ws: ws, proj: proj, scope: scope, fixture: fixture} do
      stored = published(fixture, "frontPage")["content"]["frontpageSections"]
      {:ok, view, _html} = live(conn, doc_path(ws, proj, "frontPage", "frontPage"))

      view
      |> form("#editor-form", %{"doc[frontpageSections][1].heading" => "New books this autumn"})
      |> render_change(%{"_target" => ["doc[frontpageSections][1].heading"]})

      saved = draft!("frontPage", "frontPage", scope).content["frontpageSections"]
      assert is_list(saved)
      assert keys(saved) == keys(stored)

      for {s, d} <- Enum.zip(stored, saved) do
        if s["_key"] == "a1f0c0de0002",
          do: assert(d == Map.put(s, "heading", "New books this autumn")),
          else: assert(d == s)
      end
    end

    test "add an item of a chosen member, move it, remove another",
         %{conn: conn, ws: ws, proj: proj, scope: scope, fixture: fixture} do
      stored = published(fixture, "frontPage")["content"]["frontpageSections"]
      {:ok, view, _html} = live(conn, doc_path(ws, proj, "frontPage", "frontPage"))

      view
      |> element(
        ~s([data-field-name="frontpageSections"] button[data-member="newsletterSection"])
      )
      |> render_click()

      saved = draft!("frontPage", "frontPage", scope).content["frontpageSections"]
      new = List.last(saved)
      assert length(saved) == length(stored) + 1
      assert new["_type"] == "newsletterSection"
      assert new["_key"] =~ @key
      # the member's declared default
      assert new["buttonLabel"] == "Sign up"
      assert Enum.drop(saved, -1) == stored

      # the new item opens and its fields post with it
      html = render(view)
      assert html =~ ~s(name="doc[frontpageSections][6].heading")

      view
      |> form("#editor-form", %{"doc[frontpageSections][6].heading" => "For teachers"})
      |> render_change(%{"_target" => ["doc[frontpageSections][6].heading"]})

      render_click(view, "array_op", %{
        "action" => "move_up",
        "field" => "frontpageSections",
        "path" => "doc[frontpageSections]",
        "index" => "6"
      })

      render_click(view, "array_op", %{
        "action" => "remove_row",
        "field" => "frontpageSections",
        "path" => "doc[frontpageSections]",
        "index" => "4"
      })

      saved = draft!("frontPage", "frontPage", scope).content["frontpageSections"]
      by_key = Map.new(stored, &{&1["_key"], &1})

      assert keys(saved) == [
               "a1f0c0de0001",
               "a1f0c0de0002",
               "a1f0c0de0003",
               "a1f0c0de0004",
               new["_key"],
               "a1f0c0de0006"
             ]

      for row <- saved, row["_key"] != new["_key"], do: assert(row == by_key[row["_key"]])
      assert Enum.find(saved, &(&1["_key"] == new["_key"]))["heading"] == "For teachers"
    end

    test "Add item without a member adds nothing", %{conn: conn, ws: ws, proj: proj, scope: scope} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj, "frontPage", "frontPage"))

      render_click(view, "array_op", %{
        "action" => "add_row",
        "field" => "frontpageSections",
        "path" => "doc[frontpageSections]"
      })

      assert {:error, _} = Content.get_document("drafts.frontPage", "frontPage", @dataset, scope)
    end
  end

  describe "page-builder items (page.landingPageSections)" do
    test "an item of each member type is added, edited and read back with its member type",
         %{conn: conn, ws: ws, proj: proj, scope: scope, fixture: fixture} do
      page_schema = Enum.find(fixture["document_schemas"], &(&1["name"] == "page"))
      field = Enum.find(page_schema["fields"], &(&1["name"] == "landingPageSections"))
      members = Enum.map(field["of"], & &1["name"])
      objects = Map.new(fixture["object_schemas"], &{&1["name"], &1})
      stored = published(fixture, "demo-landing-page")["content"]["landingPageSections"]
      assert length(members) == 15

      {:ok, view, _html} = live(conn, doc_path(ws, proj, "page", "demo-landing-page"))

      edited =
        members
        |> Enum.with_index(length(stored))
        |> Enum.map(fn {member, idx} ->
          view
          |> element(
            ~s([data-field-name="landingPageSections"] > details button[data-member="#{member}"])
          )
          |> render_click()

          # the first top-level string field of the member, when it has one
          case Enum.find(objects[member]["fields"], &(&1["type"] == "string")) do
            %{"name" => sub} ->
              name = "doc[landingPageSections][#{idx}].#{sub}"
              assert render(view) =~ ~s(name="#{name}")

              view
              |> form("#editor-form", %{name => "Test #{member}"})
              |> render_change(%{"_target" => [name]})

              {member, sub}

            nil ->
              {member, nil}
          end
        end)

      saved = draft!("page", "demo-landing-page", scope).content["landingPageSections"]
      assert types(saved) == types(stored) ++ members
      assert Enum.take(saved, length(stored)) == stored

      for {{member, sub}, row} <- Enum.zip(edited, Enum.drop(saved, length(stored))) do
        assert row["_type"] == member
        assert row["_key"] =~ @key
        if sub, do: assert(row[sub] == "Test #{member}")
      end

      assert length(Enum.uniq(keys(saved))) == length(saved)

      # reorder and remove keep the rest as stored
      before = saved

      render_click(view, "array_op", %{
        "action" => "move_down",
        "field" => "landingPageSections",
        "path" => "doc[landingPageSections]",
        "index" => "0"
      })

      render_click(view, "array_op", %{
        "action" => "remove_row",
        "field" => "landingPageSections",
        "path" => "doc[landingPageSections]",
        "index" => "2"
      })

      saved = draft!("page", "demo-landing-page", scope).content["landingPageSections"]
      [a, b | rest] = before
      expected = [b, a | rest] |> List.delete_at(2)
      assert saved == expected
    end
  end

  describe "a list inside a page-builder item" do
    test "an anchorJumpNavSection gets a link through its nested nav.items list",
         %{conn: conn, ws: ws, proj: proj, scope: scope, fixture: fixture} do
      stored = published(fixture, "demo-landing-page")["content"]["landingPageSections"]
      idx = length(stored)
      {:ok, view, _html} = live(conn, doc_path(ws, proj, "page", "demo-landing-page"))

      view
      |> element(
        ~s([data-field-name="landingPageSections"] > details button[data-member="anchorJumpNavSection"])
      )
      |> render_click()

      # The nested list's Add resolves its field through the item's `_type`.
      render_click(view, "array_op", %{
        "action" => "add_row",
        "field" => "items",
        "path" => "doc[landingPageSections][#{idx}].nav.items"
      })

      label = "doc[landingPageSections][#{idx}].nav.items[0].label"
      anchor = "doc[landingPageSections][#{idx}].nav.items[0].anchorId"
      assert render(view) =~ ~s(name="#{label}")

      view
      |> form("#editor-form", %{label => "Level one", anchor => "level-one"})
      |> render_change(%{"_target" => [anchor]})

      saved = draft!("page", "demo-landing-page", scope).content["landingPageSections"]
      assert Enum.take(saved, idx) == stored
      item = Enum.at(saved, idx)
      assert item["_type"] == "anchorJumpNavSection"
      assert item["_key"] =~ @key

      assert [%{"label" => "Level one", "anchorId" => "level-one", "_key" => link_key}] =
               item["nav"]["items"]

      # a first row inside a keyed item gets Sanity's `_key` too
      assert link_key =~ @key
    end
  end

  describe "custom blocks in a Portable Text body" do
    @article "article-demo-1"

    defp open_block(view, key) do
      render_hook(view, "pt-block-open", %{"field" => "body", "key" => key})
      assert has_element?(view, "#bp-object-dialog[data-object-key=\"#{key}\"]")
    end

    defp body_of(fixture), do: published(fixture, @article)["content"]["body"]

    test "a block box opens its fields in the block dialog",
         %{conn: conn, ws: ws, proj: proj} do
      {:ok, view, html} = live(conn, doc_path(ws, proj, "article", @article))
      assert html =~ ~s(phx-hook="BarkparkPtBlocks")

      open_block(view, "c3d0c0de0006")
      html = render(view)
      assert html =~ ~s(name="doc[__object].quote")
      assert html =~ ~s(name="doc[__object].author.label")
      assert html =~ ~s(name="doc[__object]._key" value="c3d0c0de0006")
    end

    for {type, key, name, value, expect} <- [
          {"quote", "c3d0c0de0006", "doc[__object].quote", "A shorter quote",
           %{"quote" => "A shorter quote"}},
          {"mediaModule", "c3d0c0de0004", "doc[__object].description", "Children at the pool",
           %{"description" => "Children at the pool"}},
          {"inlineFeaturedProducts", "c3d0c0de0008", "doc[__object].showDescription", "true",
           %{"showDescription" => true}}
        ] do
      test "editing a #{type} block saves it by its _key and keeps every other block",
           %{conn: conn, ws: ws, proj: proj, scope: scope, fixture: fixture} do
        key = unquote(key)
        name = unquote(name)
        stored = body_of(fixture)
        {:ok, view, _html} = live(conn, doc_path(ws, proj, "article", @article))
        open_block(view, key)

        view
        |> form("#bp-object-dialog-form-#{key}", %{name => unquote(value)})
        |> render_change(%{"_target" => [name]})

        view |> form("#bp-object-dialog-form-#{key}") |> render_submit()
        refute has_element?(view, "#bp-object-dialog")
        assert_push_event(view, "bp:pt-block-update", %{key: ^key})

        saved = draft!("article", @article, scope).content["body"]
        assert keys(saved) == keys(stored)

        for {s, d} <- Enum.zip(stored, saved) do
          if s["_key"] == key do
            assert d == Map.merge(s, unquote(Macro.escape(expect)))
            assert d["_type"] == unquote(type)
          else
            assert d == s
          end
        end
      end
    end

    test "an article with an edited block publishes from Studio",
         %{conn: conn, ws: ws, proj: proj, scope: scope} do
      {:ok, view, _html} = live(conn, doc_path(ws, proj, "article", @article))
      open_block(view, "c3d0c0de0006")

      view
      |> form("#bp-object-dialog-form-c3d0c0de0006", %{"doc[__object].quote" => "Published quote"})
      |> render_change(%{"_target" => ["doc[__object].quote"]})

      view |> form("#bp-object-dialog-form-c3d0c0de0006") |> render_submit()
      render_click(view, "publish", %{})

      refute render(view) =~ "Fix validation errors before publishing"
      {:ok, doc} = Content.get_document(@article, "article", @dataset, scope)
      quote = Enum.find(doc.content["body"], &(&1["_key"] == "c3d0c0de0006"))
      assert quote["quote"] == "Published quote"
    end

    test "each declared block type is inserted at the caret with a fresh _key",
         %{conn: conn, ws: ws, proj: proj, scope: scope, fixture: fixture} do
      stored = body_of(fixture)
      tier = fixture["article_tier"]

      # The article body declares the custom blocks it offers (`blocks.of`).
      article = Enum.find(fixture["document_schemas"], &(&1["name"] == "article"))

      body_field =
        article["fields"]
        |> Enum.find(&(&1["name"] == "body"))
        |> Map.put("blocks", %{"of" => Enum.map(tier, &%{"name" => &1})})

      {:ok, _} =
        Content.upsert_schema(
          Map.put(
            article,
            "fields",
            Enum.map(article["fields"], fn f ->
              if f["name"] == "body", do: body_field, else: f
            end)
          ),
          @dataset,
          scope
        )

      {:ok, view, html} = live(conn, doc_path(ws, proj, "article", @article))
      for t <- tier, do: assert(html =~ ~s(&quot;name&quot;:&quot;#{t}&quot;))

      for {type, n} <- Enum.with_index(tier, 1) do
        current =
          case Content.get_document("drafts." <> @article, "article", @dataset, scope) do
            {:ok, d} -> d.content["body"]
            _ -> stored
          end

        # the caret is after the second block (a paragraph)
        [first, second | rest] = current

        html =
          PortableText.to_html([first, second]) <>
            ~s(<div class="bp-pt-block bp-pt-pending" contenteditable="false" data-pt-block="__pending-p#{n}" data-pt-pending="p#{n}">Inserting</div>) <>
            PortableText.to_html(rest)

        render_hook(view, "pt-block-insert", %{
          "field" => "body",
          "type" => type,
          "pending" => "p#{n}",
          "html" => html
        })

        assert_push_event(view, "bp:pt-block-ready", %{pending: pending, key: key})
        assert pending == "p#{n}"
        assert key =~ @key
        # the new block opens in the dialog
        assert has_element?(view, "#bp-object-dialog[data-object-type=\"#{type}\"]")
        render_click(view, "object-dialog-close", %{})

        saved = draft!("article", @article, scope).content["body"]
        assert Enum.at(saved, 2)["_type"] == type
        assert Enum.at(saved, 2)["_key"] == key
        assert length(saved) == length(current) + 1
      end

      saved = draft!("article", @article, scope).content["body"]
      inserted = saved |> Enum.drop(2) |> Enum.take(length(tier))
      assert types(inserted) == Enum.reverse(tier)
      # the stored blocks are all still there, unchanged and in order
      assert Enum.reject(saved, &(&1 in inserted)) == stored
    end
  end
end
