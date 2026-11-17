defmodule BarkparkWeb.Studio.DeskNewDocTest do
  @moduledoc """
  J18 on the desk (`Desk.NewDoc`, `Desk.NewDocMenu`): Create new offers the
  ways to start a type, its own and its desk block's templates; the new
  document opens at `;<uuid>,template=<id>` and is not stored until its
  first edit, which stores exactly one document with the initial values,
  the template's values and the edit. Each stored-row check reads the row
  back from the database.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @uuid "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author = "nd_author_#{n}"
    post = "nd_post_#{n}"
    form = "nd_form_#{n}"
    alan = "nd-alan-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => "New doc authors",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => post,
          "title" => "New doc post",
          "visibility" => "public",
          "initial_values" => %{"featured" => false},
          "desk" => %{
            "templates" => [
              %{
                "id" => "nd-by-alan",
                "title" => "Post by Alan Turing",
                "value" => %{"author" => alan}
              }
            ]
          },
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "slug",
              "title" => "Slug",
              "type" => "slug",
              "options" => %{"source" => "title"}
            },
            %{"name" => "featured", "title" => "Featured", "type" => "boolean"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [author]}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => form,
          "title" => "New doc form",
          "visibility" => "public",
          "initial_values" => %{"note" => "Read the terms"},
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "agree", "title" => "Agree", "type" => "boolean"},
            %{
              "name" => "note",
              "title" => "Shown when agreed",
              "type" => "string",
              "visibleWhen" => %{"field" => "agree", "operator" => "eq", "value" => true}
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(author, %{"doc_id" => alan, "title" => "Alan Turing"}, @dataset)

    {:ok, _} = Content.publish_document(alan, author, @dataset)

    {:ok, _} =
      Content.create_document(
        post,
        %{"doc_id" => "nd-post-#{n}", "title" => "Old post"},
        @dataset
      )

    raw = "nd-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "nd", @dataset, ["read", "write", "admin"], ws.id)
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     post: post,
     form: form,
     alan: alan}
  end

  defp settle(view), do: render_async(view, 5_000)

  defp poll(view, fun, tries \\ 50) do
    settle(view)

    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && poll(view, fun, tries - 1)
    end
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    settle(view)
    view
  end

  defp editing?(view), do: has_element?(view, "[data-pane-editing] #editor-form")

  defp rows(type),
    do: Repo.all(from d in Content.Document, where: d.type == ^type, select: d.doc_id)

  # The list "+" (or its menu item `template`), then the patch it answers with.
  defp create(view, type, template, pane \\ "1") do
    params = %{"type" => type, "template" => template, "desk-pane" => pane}
    render_click(view, "new-document", params)
    landed = assert_patch(view, 2_000)
    assert poll(view, fn -> editing?(view) end), "the new document never opened in the editor"
    landed
  end

  defp id_of(landed), do: Regex.run(~r/;(#{@uuid}),/, landed, capture: :all_but_first) |> hd()

  describe "the list's Create new" do
    test "a type with a template is a menu of its ways to start", c do
      view = open(c.conn, "#{c.base}/#{c.post}")
      plus = ~s([data-pane-index="1"] button[aria-label="Create new New doc post"])
      assert poll(view, fn -> has_element?(view, plus <> ~s([aria-haspopup="menu"])) end)

      items = ~s([data-pane-index="1"] [role="menu"] [role="menuitem"][phx-click="new-document"])
      assert has_element?(view, items <> ~s([phx-value-template="#{c.post}"]), "New doc post")

      assert has_element?(
               view,
               items <> ~s([phx-value-template="nd-by-alan"]),
               "Post by Alan Turing"
             )
    end

    test "a type with one way to start is one button", c do
      view = open(c.conn, "#{c.base}/#{c.form}")
      plus = ~s([data-pane-index="1"] button[aria-label="Create new New doc form"])

      assert poll(view, fn ->
               has_element?(
                 view,
                 plus <> ~s([phx-click="new-document"][phx-value-template="#{c.form}"])
               )
             end)

      refute has_element?(view, ~s([data-pane-index="1"] .dk-new-menu))
    end
  end

  describe "a new document waits for its first edit" do
    test "it opens at a uuid with its template, and stores nothing", c do
      view = open(c.conn, "#{c.base}/#{c.post}")
      before = rows(c.post)

      landed = create(view, c.post, c.post)
      assert landed =~ ~r"^#{Regex.escape(c.base)}/#{c.post};#{@uuid},template=#{c.post}$"
      id = id_of(landed)

      # The type's initial value is in the form, and nothing is stored.
      assert has_element?(view, ~s(#editor-form input[name="doc[title]"]))
      assert rows(c.post) == before
      assert {nil, _, _} = Content.fetch_doc_with_draft(c.post, id, @dataset)

      # A post of the form as it was drawn changes nothing: still no row.
      EditorPost.change(view, %{"doc" => %{"title" => "", "featured" => "false"}})
      assert rows(c.post) == before

      # Leaving it costs nothing.
      render_patch(view, "#{c.base}/#{c.post}")
      settle(view)
      assert rows(c.post) == before
    end

    test "the first edit stores one document: the initial values and the edit", c do
      view = open(c.conn, "#{c.base}/#{c.post}")
      before = rows(c.post)
      id = c.post |> then(&create(view, &1, &1)) |> id_of()

      EditorPost.change(view, %{"doc" => %{"title" => "My brand new post"}})
      assert rows(c.post) -- before == ["drafts." <> id]

      {:ok, stored} = Content.get_document("drafts." <> id, c.post, @dataset)
      assert stored.title == "My brand new post"
      assert stored.content["featured"] == false

      # The next edit writes the same row, and Generate fills the slug from the title.
      EditorPost.press(view, "slug-generate", %{"field" => "slug"})
      assert rows(c.post) -- before == ["drafts." <> id]
      {:ok, stored} = Content.get_document("drafts." <> id, c.post, @dataset)
      assert stored.title == "My brand new post"

      assert stored.content["slug"] == %{"_type" => "slug", "current" => "my-brand-new-post"}
    end

    test "a template's values are in the form and in the stored document", c do
      view = open(c.conn, "#{c.base}/#{c.post}")
      landed = create(view, c.post, "nd-by-alan")
      assert landed =~ ~r",template=nd-by-alan$"
      id = id_of(landed)
      assert render(view) =~ "Alan Turing"
      assert {nil, _, _} = Content.fetch_doc_with_draft(c.post, id, @dataset)

      EditorPost.change(view, %{"doc" => %{"title" => "Templated post"}})
      {:ok, stored} = Content.get_document("drafts." <> id, c.post, @dataset)
      assert stored.content["author"]["_ref"] == c.alan
      assert stored.content["featured"] == false
    end

    test "a field hidden at the start still gets its initial value", c do
      view = open(c.conn, "#{c.base}/#{c.form}")
      id = c.form |> then(&create(view, &1, &1)) |> id_of()
      refute has_element?(view, ~s(#editor-form [name="doc[note]"]))

      EditorPost.change(view, %{"doc" => %{"title" => "Hidden initial probe"}})
      {:ok, stored} = Content.get_document("drafts." <> id, c.form, @dataset)
      assert stored.content["note"] == "Read the terms"
    end

    test "its URL opens the same new document again before the first edit", c do
      view = open(c.conn, "#{c.base}/#{c.post}")
      landed = create(view, c.post, "nd-by-alan")
      id = id_of(landed)

      again = open(c.conn, landed)
      assert poll(again, fn -> editing?(again) end)
      assert render(again) =~ "Alan Turing"
      assert {nil, _, _} = Content.fetch_doc_with_draft(c.post, id, @dataset)
    end

    test "a uuid with no template is no new document: no form opens to write", c do
      id = Ecto.UUID.generate()
      view = open(c.conn, "#{c.base}/#{c.post};#{id}")
      settle(view)
      refute editing?(view)
      assert {nil, _, _} = Content.fetch_doc_with_draft(c.post, id, @dataset)
    end
  end

  test "the navbar's Create new lists every way to start, and opens its type's list and the doc",
       c do
    view = open(c.conn, "#{c.base}/#{c.form}")

    assert has_element?(
             view,
             ~s(button[aria-label="Create new document"][popovertarget="dk-new-doc"])
           )

    option = ~s(#dk-new-doc [role="option"][phx-value-at="root"])

    assert has_element?(
             view,
             option <> ~s([phx-value-template="nd-by-alan"]),
             "Post by Alan Turing"
           )

    assert has_element?(view, option <> ~s([phx-value-template="#{c.post}"]), "New doc post")

    view |> element(option <> ~s([phx-value-template="nd-by-alan"])) |> render_click()
    landed = assert_patch(view, 2_000)
    assert landed =~ ~r"^#{Regex.escape(c.base)}/#{c.post};#{@uuid},template=nd-by-alan$"
    assert poll(view, fn -> editing?(view) end)
  end
end
