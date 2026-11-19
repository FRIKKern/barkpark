defmodule BarkparkWeb.Studio.DeskPublishedViewTest do
  @moduledoc """
  The desk's published perspective (`?perspective=published`, `PublishedView`),
  as the TanStack Studio's (`DocumentPane.tsx` `viewingPublished`,
  `PublishedFooter`; barkpark-studio `e2e/journeys/lifecycle.spec.ts:123`):

  - the form shows the published version, read-only, in a disabled fieldset;
  - Unpublish leaves the form there, empty and read-only, says "Unpublished
    just now", and keeps the draft as it was stored;
  - every write sent by hand while it is shown is refused on the server;
  - the header menu offers only reads, and Copy document copies the
    published version;
  - the Published and Draft pills are buttons that switch the perspective.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @pane "[data-pane-editing]"
  @form ~s(#{@pane} fieldset[data-desk-published-form][disabled])
  @footer ~s(#{@pane} .doc-footer)
  @unpublish ~s(#{@footer} button.dk-publish.danger[data-desk-unpublish])
  @dialog ~s(#{@pane} [role="dialog"][aria-modal="true"][data-desk-dialog="unpublish"])
  @menu ~s(#{@pane} [role="menu"][id$="-editor-actions"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "pv_post_#{n}"
    single = "pv_single_#{n}"

    for {name, extra} <- [{type, %{}}, {single, %{"singleton" => true}}] do
      {:ok, _} =
        Content.upsert_schema(
          Map.merge(
            %{
              "name" => name,
              "title" => "Pv post",
              "visibility" => "public",
              "fields" => [
                %{"name" => "title", "title" => "Title", "type" => "string"},
                %{"name" => "summary", "title" => "Summary", "type" => "text"}
              ]
            },
            extra
          ),
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-published-view-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id

    {:ok, _} =
      Auth.create_token(raw, "desk-published-view", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     base: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk",
     type: type,
     single: single,
     n: n}
  end

  # A document published with `published`; with `draft`, a draft over it.
  defp doc!(c, published, draft \\ nil) do
    id = "pv-#{c.n}-#{System.unique_integer([:positive])}"
    {:ok, _} = Content.create_document(c.type, Map.put(published, "doc_id", id), @dataset)
    {:ok, _} = Content.publish_document(id, c.type, @dataset)

    if draft,
      do:
        {:ok, _} =
          Content.upsert_document(
            c.type,
            Map.put(draft, "doc_id", Content.draft_id(id)),
            @dataset
          )

    id
  end

  defp open(c, path) do
    {:ok, view, _html} = live(c.conn, c.base <> "/" <> path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp row(type, doc_id) do
    case Content.get_document(doc_id, type, @dataset) do
      {:ok, doc} -> Map.take(doc, [:title, :content, :rev, :status])
      _ -> nil
    end
  end

  defp count(type) do
    case Content.list_documents(type, @dataset) do
      {:ok, docs} -> length(docs)
      docs when is_list(docs) -> length(docs)
    end
  end

  # The title input of the form the pane draws, as the browser reads it.
  defp title_value(view, scope \\ @pane) do
    html = view |> element(scope) |> render()
    [input] = Regex.run(~r/<input\b[^>]*name="doc\[title\]"[^>]*>/, html)

    case Regex.run(~r/\svalue="([^"]*)"/, input) do
      [_, value] -> value
      nil -> ""
    end
  end

  defp status(view), do: view |> element(~s(#{@footer} [role="status"])) |> render() |> words()

  defp words(html),
    do: html |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  defp own_mark(c, id), do: %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, id)}

  test "the published version is shown read-only; the draft perspective shows the draft", c do
    id = doc!(c, %{"title" => "Pub title", "summary" => "Pub sum"}, %{"title" => "Draft title"})

    view = open(c, "#{c.type};#{id}?perspective=published")
    assert has_element?(view, @form)
    assert title_value(view, @form) == "Pub title"
    assert view |> element(@form) |> render() =~ "Pub sum"
    assert has_element?(view, ~s(#{@pane} .title-row .title), "Pub title")
    assert status(view) == "Last published just now"
    refute has_element?(view, ~s(#{@pane} [data-desk-publish]))

    view = open(c, "#{c.type};#{id}")
    refute has_element?(view, ~s(#{@pane} [data-desk-published-form]))
    refute has_element?(view, ~s(#{@pane} fieldset[disabled]))
    assert title_value(view) == "Draft title"
  end

  test "Unpublish keeps the form, empty and read-only, says Unpublished just now, and keeps the draft as stored",
       c do
    id =
      doc!(c, %{"title" => "Pub title", "summary" => "Pub sum"}, %{
        "title" => "Draft title",
        "summary" => "Draft sum"
      })

    before = row(c.type, Content.draft_id(id))
    view = open(c, "#{c.type};#{id}?perspective=published")

    EditorPost.press_on(view, element(view, @unpublish))
    assert row(c.type, id)

    EditorPost.press_on(
      view,
      element(view, ~s(#{@dialog} button[data-desk-confirm="unpublish"]), "Unpublish now")
    )

    refute row(c.type, id)
    assert row(c.type, Content.draft_id(id)) == before

    assert eventually(fn -> has_element?(view, ~s(#{@unpublish}[disabled])) end)
    assert has_element?(view, @form)
    assert title_value(view, @form) == ""
    refute view |> element(@form) |> render() =~ "Draft sum"
    assert status(view) == "Unpublished just now"
    # TanStack's `docTitle` for a document with no version to show.
    assert has_element?(view, ~s(#{@pane} .title-row .title), "New Pv post")
    # The confirm sends the focus here; it is still in the page.
    assert has_element?(
             view,
             ~s(#{@pane} .pane-header button[aria-label="Show document actions"])
           )

    refute has_element?(view, @dialog)

    # Reloaded, the same: the history says what happened.
    view = open(c, "#{c.type};#{id}?perspective=published")
    assert title_value(view, @form) == ""
    assert status(view) == "Unpublished just now"
  end

  test "Unpublish of a document with no draft makes one from the published version", c do
    id = doc!(c, %{"title" => "Only pub", "summary" => "Pub sum"})
    published = row(c.type, id)
    view = open(c, "#{c.type};#{id}?perspective=published")

    EditorPost.press_on(view, element(view, @unpublish))

    EditorPost.press_on(
      view,
      element(view, ~s(#{@dialog} button[data-desk-confirm="unpublish"]), "Unpublish now")
    )

    refute row(c.type, id)
    draft = row(c.type, Content.draft_id(id))
    assert {draft.title, draft.content, draft.status} == {"Only pub", published.content, "draft"}
    assert eventually(fn -> title_value(view, @form) == "" end)
    assert status(view) == "Unpublished just now"
  end

  test "never published: the form is empty, Unpublish greyed out, and no words", c do
    id = "pv-draft-#{c.n}"

    {:ok, _} =
      Content.create_document(c.type, %{"doc_id" => id, "title" => "Draft only"}, @dataset)

    view = open(c, "#{c.type};#{id}?perspective=published")
    assert title_value(view, @form) == ""
    assert has_element?(view, ~s(#{@unpublish}[disabled][title="Not published"]))
    assert status(view) == ""
  end

  test "every write sent by hand while the published version is shown is refused", c do
    id =
      doc!(c, %{"title" => "Pub title", "summary" => "Pub sum"}, %{
        "title" => "Draft title",
        "summary" => "Draft sum"
      })

    draft = row(c.type, Content.draft_id(id))
    published = row(c.type, id)
    before = count(c.type)

    publish_rev =
      id
      |> Content.list_revisions(c.type, @dataset, limit: 10)
      |> Enum.find(&(&1.action == "publish"))

    view = open(c, "#{c.type};#{id}?perspective=published")

    EditorPost.change(view, %{"doc" => %{"title" => "Typed"}})
    EditorPost.submit(view, %{"doc" => %{"title" => "Saved"}})

    field_clip =
      Jason.encode!(%{
        "type" => "sanityClipboardItem",
        "isDocument" => false,
        "schemaTypeName" => "x",
        "value" => "PASTED",
        "barkpark" => %{
          "kind" => "field",
          "field" => %{"name" => "from", "sig" => "string", "value" => "PASTED"}
        }
      })

    doc_clip =
      Jason.encode!(%{
        "type" => "sanityClipboardItem",
        "isDocument" => true,
        "barkpark" => %{
          "kind" => "document",
          "fields" => [%{"name" => "title", "sig" => "string", "value" => "PASTED DOC"}]
        }
      })

    mark = own_mark(c, id)

    render_hook(
      view,
      "desk-field-paste",
      Map.merge(mark, %{"field" => "title", "clip" => field_clip})
    )

    render_hook(view, "desk-doc-paste", Map.merge(mark, %{"clip" => doc_clip}))
    render_hook(view, "desk-field-revert", Map.merge(mark, %{"all" => "true"}))

    for {event, params} <- [
          {"publish", %{}},
          {"discard-draft", %{}},
          {"confirm-discard", %{}},
          {"delete-doc", %{}},
          {"confirm-delete", %{}},
          {"duplicate-doc", %{}},
          {"restore-revision", %{"id" => publish_rev.id}},
          {"sidebar-label-add", %{"value" => "x"}}
        ] do
      EditorPost.press(view, event, params)
    end

    render_async(view, 5_000)
    assert row(c.type, Content.draft_id(id)) == draft
    assert row(c.type, id) == published
    assert count(c.type) == before
    assert has_element?(view, @form)
  end

  test "the header menu offers only reads; Copy document copies the published version", c do
    id = doc!(c, %{"title" => "Pub title"}, %{"title" => "Draft title"})
    view = open(c, "#{c.type};#{id}?perspective=published")
    actions = view |> element(@menu) |> render()

    for write <- ~w(publish discard-draft duplicate-doc delete-doc paste-document) do
      refute actions =~ ~s(data-desk-doc-action="#{write}"), write
    end

    assert actions =~ ~s(data-desk-doc-action="show-history")
    assert actions =~ ~s(data-desk-doc-action="copy-document")
    # No footer menu either: TanStack's `PublishedFooter` has none.
    refute has_element?(view, ~s(#{@footer} button[aria-label="Open document actions"]))

    render_hook(view, "desk-doc-copy", %{})
    assert_push_event(view, "desk:doc-copied", %{json: json})
    assert Jason.decode!(json)["value"]["title"] == "Pub title"
  end

  test "the pills switch the perspective, keeping the pane's params", c do
    id = doc!(c, %{"title" => "Pub title"}, %{"title" => "Draft title"})
    view = open(c, "#{c.type};#{id}")
    published = ~s(#{@pane} .pane-header button.dk-chip[aria-pressed])

    assert has_element?(
             view,
             ~s(#{published}[aria-pressed="false"][data-tone="positive"]),
             "Published"
           )

    assert has_element?(view, ~s(#{published}[aria-pressed="true"][data-selected]), "Draft")

    view |> element(published, "Published") |> render_click()
    assert_patch(view, "#{c.base}/#{c.type};#{id}?perspective=published")
    render_async(view, 5_000)
    assert has_element?(view, @form)
    assert has_element?(view, ~s(#{published}[aria-pressed="true"][data-selected]), "Published")
    assert has_element?(view, ~s(#{published}[aria-pressed="false"]), "Draft")
    refute has_element?(view, ~s(#{published}[aria-pressed="false"][data-selected]), "Draft")

    view |> element(published, "Draft") |> render_click()
    assert_patch(view, "#{c.base}/#{c.type};#{id}")
    render_async(view, 5_000)
    refute has_element?(view, ~s(#{@pane} [data-desk-published-form]))
    assert title_value(view) == "Draft title"

    # The live form comes back in a new box, not morphed into the published
    # version's: Chrome drew a morphed-back form with no layout box (blank).
    # The fieldset around it keeps its id.
    holder = ~s(#{@pane} fieldset.dk-revision-form[id$="-form-holder"])
    assert has_element?(view, ~s|#{holder}:not([disabled]) > [id$="-form-box"] #editor-form|)
    view |> element(published, "Published") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, ~s(#{holder}[disabled] > [id$="-form-box-published"] #editor-form))
    refute has_element?(view, ~s(#{holder} > [id$="-form-box"]))

    # Never published: the Published pill is a greyed-out span, no button.
    draft_id = "pv-never-#{c.n}"
    {:ok, _} = Content.create_document(c.type, %{"doc_id" => draft_id, "title" => "D"}, @dataset)
    view = open(c, "#{c.type};#{draft_id}")

    assert has_element?(
             view,
             ~s(#{@pane} .pane-header span.dk-chip[data-off][aria-disabled="true"]),
             "Published"
           )

    refute has_element?(view, ~s(#{published}), "Published")
  end

  test "a singleton's published version: its words and no Unpublish", c do
    {:ok, _} =
      Content.create_document(c.single, %{"doc_id" => c.single, "title" => "Settings"}, @dataset)

    {:ok, _} = Content.publish_document(c.single, c.single, @dataset)

    view = open(c, "#{c.single}?perspective=published")
    assert has_element?(view, @form)
    assert status(view) == "Last published just now"
    refute has_element?(view, ~s(#{@footer} [data-desk-unpublish]))
    refute has_element?(view, ~s(#{@footer} [data-desk-publish]))
  end
end
