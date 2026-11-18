defmodule BarkparkWeb.Studio.DeskDuplicateSlugTest do
  @moduledoc """
  J28 in the desk (WP9): Duplicate opens a copy with a uuid id, the source's
  title and every field, as a draft, in the original's place; a slug another
  document of the type has is "already in use" (TanStack `lib/slug-unique.ts`):
  the field's label carries the mark, the Validation panel lists it, Publish
  is blocked, and Publish asks again before it writes. The old Studio's
  Duplicate keeps its `<type>-<hex>` id and " (copy)" title.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @mark ~s([data-pane-editing] .field label[for="slug"] [role="img"][aria-label="Validation error: Slug is already in use"])
  @publish ~s([data-pane-editing] .dk-edit-footer button.dk-publish[data-desk-publish])

  @links [
    %{"_key" => "l1", "label" => "First"},
    %{"_key" => "l2", "label" => "Second"}
  ]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "dup_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Dup #{type}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "slug", "title" => "Slug", "type" => "slug"},
            %{"name" => "summary", "title" => "Summary", "type" => "text"},
            %{"name" => "tags", "title" => "Tags", "type" => "array", "of" => "string"},
            %{
              "name" => "links",
              "title" => "Links",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "fields" => [%{"name" => "label", "title" => "Label", "type" => "string"}]
              }
            }
          ]
        },
        @dataset
      )

    id = "dup-src-#{n}"
    slug = "dup-slug-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "Source post",
          "slug" => slug,
          "summary" => "A summary",
          "tags" => ["a", "b"],
          "links" => @links
        },
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-dup-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-dup", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    scope = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, type: type, id: id, slug: slug, n: n, scope: scope, base: scope <> "/_desk"}
  end

  defp settle(view), do: render_async(view, 5_000)

  defp poll(view, fun, tries \\ 25) do
    settle(view)

    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(view, fun, tries - 1)
    end
  end

  defp open(c, id) do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.type};#{id}")
    assert poll(view, fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp duplicate(view) do
    BarkparkWeb.EditorPost.press(view, "duplicate-doc", %{})
    landed = assert_patch(view, 2_000)
    settle(view)
    landed
  end

  defp copy_id(c, landed) do
    prefix = "#{c.base}/#{c.type};"
    assert String.starts_with?(landed, prefix), "the copy opened at #{landed}"
    String.replace_prefix(landed, prefix, "")
  end

  defp make(c, id, slug) do
    {:ok, _} =
      Content.create_document(c.type, %{"doc_id" => id, "title" => id, "slug" => slug}, @dataset)
  end

  # ── Duplicate ───────────────────────────────────────────────────────────

  test "Duplicate lands on the copy's uuid with the source's title, and says so", c do
    view = open(c, c.id)
    copy = copy_id(c, duplicate(view))

    assert copy =~ @uuid, "the copy's id is #{copy}"

    assert poll(view, fn ->
             has_element?(
               view,
               ~s|[data-pane-editing] input[name="doc[title]"][value="Source post"]|
             )
           end),
           "the copy did not open with the source's title"

    assert render(view) =~ "The document was successfully duplicated"
  end

  test "the stored copy has every field of the source, the new id, and is a draft", c do
    view = open(c, c.id)
    copy = copy_id(c, duplicate(view))

    {:ok, source} = Content.get_document(c.id, c.type, @dataset)
    assert {:ok, row} = Content.get_document("drafts." <> copy, c.type, @dataset)
    assert {:error, :not_found} = Content.get_document(copy, c.type, @dataset)

    assert row.title == "Source post"
    assert row.content["title"] == source.content["title"]
    assert row.content["slug"] == c.slug
    assert row.content["summary"] == "A summary"
    assert row.content["tags"] == ["a", "b"]
    assert Enum.map(row.content["links"], & &1["label"]) == ["First", "Second"]
    assert Enum.all?(row.content["links"], &is_binary(&1["_key"]))
    assert Map.keys(row.content) -- Map.keys(source.content) == []
    assert Map.keys(source.content) -- Map.keys(row.content) == []
  end

  test "the old Studio's Duplicate keeps its type-and-hex id and the (copy) title", c do
    {:ok, view, _html} = live(c.conn, "#{c.scope}/#{c.type}/#{c.id}")
    settle(view)
    BarkparkWeb.EditorPost.press(view, "duplicate-doc", %{})
    landed = assert_patch(view, 2_000)

    assert landed =~ ~r"/#{c.type}-[0-9a-f]{16}(\?|$)", "the copy opened at #{landed}"
    [_, copy] = Regex.run(~r"/(#{c.type}-[0-9a-f]{16})", landed)

    assert {:ok, %{title: "Source post (copy)"}} =
             Content.get_document("drafts." <> copy, c.type, @dataset)
  end

  # ── Slug in use ─────────────────────────────────────────────────────────

  test "a duplicate's copied slug is in use: marked, listed, Publish blocked; a new slug clears it",
       c do
    view = open(c, c.id)
    refute has_element?(view, @mark)

    duplicate(view)

    assert poll(view, fn -> has_element?(view, @mark) end), "the copied slug is not marked"
    assert has_element?(view, ~s(#{@publish}[disabled]))
    assert has_element?(view, ~s([data-pane-editing] button.validation-btn[data-level="error"]))

    BarkparkWeb.EditorPost.hook(view, "autosave", %{"doc" => %{"slug" => "a-new-slug-#{c.n}"}})

    assert poll(view, fn -> not has_element?(view, @mark) end), "the new slug is still marked"
  end

  test "a slug in Sanity's {current} shape and a plain one are the same slug, either way", c do
    obj = "dup-obj-#{c.n}"
    str = "dup-str-#{c.n}"
    shared = "shared-#{c.n}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => obj, "title" => "Obj", "slug" => %{"_type" => "slug", "current" => shared}},
        @dataset
      )

    make(c, str, shared)

    for id <- [str, obj] do
      view = open(c, id)
      assert poll(view, fn -> has_element?(view, @mark) end), "#{id}'s slug is not marked"
    end
  end

  test "another dataset's or another type's document with the slug does not take it", c do
    other = "dup_other_#{c.n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => other,
          "title" => "Other",
          "visibility" => "public",
          "fields" => [%{"name" => "slug", "title" => "Slug", "type" => "slug"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(other, %{"doc_id" => "dup-oth-#{c.n}", "slug" => c.slug}, @dataset)

    {:ok, _} =
      Content.create_document(c.type, %{"doc_id" => "dup-st-#{c.n}", "slug" => c.slug}, "staging")

    view = open(c, c.id)
    settle(view)
    refute has_element?(view, @mark)
    refute has_element?(view, "[data-pane-editing] button.validation-btn")
  end

  test "Publish asks again, and refuses a slug taken since the form's answer", c do
    mine = "dup-mine-#{c.n}"
    slug = "taken-meanwhile-#{c.n}"
    make(c, mine, slug)

    view = open(c, mine)
    refute has_element?(view, @mark)
    refute has_element?(view, ~s(#{@publish}[disabled]))

    make(c, "dup-took-#{c.n}", slug)
    BarkparkWeb.EditorPost.press(view, "publish", %{})

    assert poll(view, fn -> has_element?(view, @mark) end), "the taken slug is not marked"
    assert render(view) =~ "Slug: Slug is already in use"
    assert has_element?(view, ~s(#{@publish}[disabled]))
    assert {:error, :not_found} = Content.get_document(mine, c.type, @dataset)
  end
end
