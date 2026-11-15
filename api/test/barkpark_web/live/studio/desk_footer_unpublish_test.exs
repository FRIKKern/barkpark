defmodule BarkparkWeb.Studio.DeskFooterUnpublishTest do
  @moduledoc """
  B07 and J04: at `?perspective=published` the edit pane's footer offers a
  button named "Unpublish" in Publish's place, as the TanStack Studio's
  `PublishedFooter` (barkpark-studio `e2e/journeys/unpublish-guard.spec.ts:20`,
  `lifecycle.spec.ts:130`). It opens the desk's unpublish dialog, which
  always asks; only the dialog's confirm unpublishes. Without that
  perspective, on a singleton, and in the old Studio the footer is as it was.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.Panes

  @dataset "production"
  @pane "[data-pane-editing]"
  @footer ~s(#{@pane} .doc-footer)
  @unpublish ~s(#{@footer} button.dk-publish.danger[data-desk-unpublish])
  @publish ~s(#{@footer} button[data-desk-publish])
  @dialog ~s(#{@pane} [role="dialog"][aria-modal="true"][data-desk-dialog="unpublish"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "fu_post_#{n}"
    single = "fu_single_#{n}"

    for {name, extra} <- [{type, %{}}, {single, %{"singleton" => true}}] do
      {:ok, _} =
        Content.upsert_schema(
          Map.merge(
            %{
              "name" => name,
              "title" => "Footer unpublish #{name}",
              "visibility" => "public",
              "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
            },
            extra
          ),
          @dataset
        )
    end

    id = "fu-#{n}"
    other = "fu-other-#{n}"

    for {t, doc_id} <- [{type, id}, {type, other}, {single, single}] do
      {:ok, _} = Content.create_document(t, %{"doc_id" => doc_id, "title" => "Here"}, @dataset)
      {:ok, _} = Content.publish_document(doc_id, t, @dataset)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-footer-unpublish-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id

    {:ok, _} =
      Auth.create_token(raw, "desk-footer-unpublish", @dataset, ~w(read write admin), ws_id)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: base, type: type, single: single, id: id, other: other}
  end

  defp open(c, path) do
    {:ok, view, _html} = live(c.conn, c.base <> "/" <> path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp published?(type, id) do
    {_doc, _draft?, published?} = Content.fetch_doc_with_draft(type, id, @dataset)
    published?
  end

  test "the published perspective: Unpublish in Publish's place opens the dialog, which asks",
       c do
    view = open(c, "#{c.type};#{c.id}?perspective=published")

    assert has_element?(
             view,
             ~s(#{@unpublish}[type="button"][phx-click="unpublish"]),
             "Unpublish"
           )

    refute has_element?(view, ~s(#{@unpublish}[disabled]))
    refute has_element?(view, @publish)
    # The "…" stays beside it.
    assert has_element?(view, ~s(#{@footer} button[aria-label="Open document actions"]))

    view |> element(@unpublish) |> render_click()

    # The press only asks.
    assert has_element?(view, ~s(#{@dialog} h2), "Unpublish document?")
    assert published?(c.type, c.id)

    view |> element(~s(#{@dialog} button[data-modal-focus]), "Cancel") |> render_click()
    refute has_element?(view, @dialog)
    assert published?(c.type, c.id)
    refute has_element?(view, ~s(#{@unpublish}[disabled]))
  end

  test "the dialog's confirm unpublishes; Unpublish is then greyed out and the focus goes to the pane's actions",
       c do
    view = open(c, "#{c.type};#{c.id}?perspective=published")
    view |> element(@unpublish) |> render_click()

    confirm = ~s(#{@dialog} button.danger[data-desk-confirm="unpublish"])

    # A greyed-out opener cannot take the focus back, so the confirm sends it
    # to "Show document actions", where unpublish-guard.spec.ts expects it.
    [_, button_id] =
      Regex.run(
        ~r/ id="([^"]+)"/,
        view
        |> element(~s(#{@pane} .pane-header button[aria-label="Show document actions"]))
        |> render()
      )

    focus =
      Phoenix.HTML.html_escape(~s(["focus",{"to":"[id=\\"#{button_id}\\"]"}]))
      |> Phoenix.HTML.safe_to_string()

    js = view |> element(confirm) |> render()
    assert js =~ "[[&quot;push&quot;,{&quot;event&quot;:&quot;confirm-unpublish&quot;}],"
    assert js =~ focus

    view |> element(confirm, "Unpublish now") |> render_click()

    refute has_element?(view, @dialog)
    refute published?(c.type, c.id)
    assert eventually(fn -> has_element?(view, ~s(#{@unpublish}[disabled])) end)
    refute has_element?(view, @publish)
    # The menu still publishes the draft that is left.
    assert has_element?(view, ~s(#{@footer} [data-desk-doc-action="publish"]))
  end

  test "a draft over the published version: Unpublish unpublishes and keeps the draft as it is",
       c do
    view = open(c, "#{c.type};#{c.id}?perspective=published")

    view |> element("#editor-form") |> render_change(%{"doc" => %{"title" => "Typed"}})
    render_async(view, 5_000)

    draft = fn -> Content.get_document("drafts." <> c.id, c.type, @dataset) end
    assert eventually(fn -> match?({:ok, %{title: "Typed"}}, draft.()) end)
    {:ok, before} = draft.()

    # Still offered, as the TanStack Studio's: only "nothing published" greys it out.
    refute has_element?(view, ~s(#{@unpublish}[disabled]))
    view |> element(@unpublish) |> render_click()
    assert published?(c.type, c.id)

    view
    |> element(~s(#{@dialog} button[data-desk-confirm="unpublish"]), "Unpublish now")
    |> render_click()

    refute published?(c.type, c.id)
    assert {:error, _} = Content.get_document(c.id, c.type, @dataset)
    {:ok, kept} = draft.()
    assert {kept.title, kept.content, kept.rev} == {before.title, before.content, before.rev}
    assert eventually(fn -> has_element?(view, ~s(#{@unpublish}[disabled])) end)
  end

  test "nothing published: Unpublish is greyed out and says why", c do
    {:ok, _} =
      Content.create_document(c.type, %{"doc_id" => "fu-draft-#{c.id}", "title" => "D"}, @dataset)

    view = open(c, "#{c.type};fu-draft-#{c.id}?perspective=published")

    assert has_element?(view, ~s(#{@unpublish}[disabled][title="Not published"]), "Unpublish")

    # Offered: no title to explain.
    view = open(c, "#{c.type};#{c.id}?perspective=published")
    refute has_element?(view, ~s(#{@unpublish}[title]))
  end

  test "the pane's own inspector keeps the perspective: Incoming references opens and closes with it",
       c do
    view = open(c, "#{c.type};#{c.id}?perspective=published")
    inspect = "inspect=sanity%2Fstructure%2Fincoming-references"

    view
    |> element(~s(#{@pane} .pane-header [data-desk-doc-action="incoming-references"]))
    |> render_click()

    assert_patch(view, "#{c.base}/#{c.type};#{c.id},#{inspect}?perspective=published")
    assert has_element?(view, @unpublish)
    refute has_element?(view, @publish)

    view |> element(~s(#{@pane} [data-desk-inspector-close])) |> render_click()
    assert_patch(view, "#{c.base}/#{c.type};#{c.id}?perspective=published")
    assert has_element?(view, @unpublish)

    # Without the perspective the same links carry no query.
    view = open(c, "#{c.type};#{c.id}")

    view
    |> element(~s(#{@pane} .pane-header [data-desk-doc-action="incoming-references"]))
    |> render_click()

    assert_patch(view, "#{c.base}/#{c.type};#{c.id},#{inspect}")
  end

  test "no perspective, drafts, or any other value: the footer is Publish, as it was", c do
    for query <- [
          "",
          "?perspective=drafts",
          "?perspective=PUBLISHED",
          "?perspective=",
          "?view=published"
        ] do
      view = open(c, "#{c.type};#{c.id}#{query}")

      assert has_element?(view, ~s(#{@publish}.dk-publish[disabled])), query
      refute has_element?(view, ~s(#{@footer} [data-desk-unpublish])), query
    end
  end

  test "the perspective is the page's: a desk link to another document does not carry it", c do
    view = open(c, "#{c.type};#{c.id}?perspective=published")
    assert has_element?(view, @unpublish)

    render_patch(view, "#{c.base}/#{c.type};#{c.other}")
    render_async(view, 5_000)

    assert eventually(fn -> has_element?(view, ~s(#{@publish}[disabled])) end)
    refute has_element?(view, ~s(#{@footer} [data-desk-unpublish]))
  end

  test "a singleton is never unpublished: its footer stays Publish, and the event does nothing",
       c do
    view = open(c, "#{c.single}?perspective=published")

    assert has_element?(view, ~s(#{@publish}[disabled]))
    refute has_element?(view, ~s(#{@footer} [data-desk-unpublish]))

    render_hook(view, "unpublish", %{})
    render_hook(view, "confirm-unpublish", %{"disconnect" => "true"})
    refute has_element?(view, @dialog)
    assert published?(c.single, c.single)
  end

  test "a hand-sent unpublish with another document's id only asks about the open one", c do
    view = open(c, "#{c.type};#{c.id}?perspective=published")

    render_hook(view, "unpublish", %{"id" => c.other, "disconnect" => "true"})

    assert has_element?(view, ~s(#{@dialog} p strong), "Here")
    assert published?(c.type, c.id)
    assert published?(c.type, c.other)

    render_hook(view, "confirm-unpublish", %{"id" => c.other, "disconnect" => "TRUE"})
    refute published?(c.type, c.id)
    assert published?(c.type, c.other)
  end

  test "Panes.perspective/1: published for exactly that value" do
    assert Panes.perspective("http://x/w/a/_desk/post;p1?perspective=published") == :published
    assert Panes.perspective("http://x/_desk/post;p1?a=1&perspective=published") == :published
    assert Panes.perspective("http://x/_desk/post;p1,perspective=published") == :drafts
    assert Panes.perspective("http://x/_desk/post;p1?perspective=drafts") == :drafts
    assert Panes.perspective("http://x/_desk/post;p1?perspective=published%20") == :drafts
    assert Panes.perspective("http://x/_desk/post;p1?perspective=%ZZ") == :drafts
    assert Panes.perspective("http://x/_desk/post;p1") == :drafts
    assert Panes.perspective(nil) == :drafts

    assert Panes.keep_perspective("/d/_desk/post;p1", :published) ==
             "/d/_desk/post;p1?perspective=published"

    assert Panes.keep_perspective("/d/_desk/post;p1", :drafts) == "/d/_desk/post;p1"
  end

  # Control: the old Studio reads no perspective.
  test "the old Studio has no footer Unpublish", c do
    {:ok, _view, html} =
      live(
        c.conn,
        String.replace(c.base, "/_desk", "") <> "/#{c.type}/#{c.id}?perspective=published"
      )

    assert html =~ ~s(id="editor-form")
    refute html =~ "data-desk-unpublish"
    refute html =~ "dk-publish"
  end
end
