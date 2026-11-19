defmodule BarkparkWeb.Studio.DeskReadonlyGroupTabsTest do
  @moduledoc """
  In the desk's published view (`PublishedView`) and an old revision
  (`RevisionView`) the fields are read-only, but the field group tabs still
  switch groups, as the TanStack Studio's do: a document's Meta fields can be
  read there. Only the fields sit in the disabled fieldset; the tabs do not.
  A write sent from either view is still refused.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @pane "[data-pane-editing]"
  @history ",changesInspectorTab=history,inspect=sanity%2Fstructure%2Fhistory"

  @groups [
    %{"name" => "content", "title" => "Content", "default" => true},
    %{"name" => "meta", "title" => "Meta"}
  ]

  @fields [
    %{"name" => "title", "title" => "Title", "type" => "string", "group" => "content"},
    %{"name" => "excerpt", "title" => "Excerpt", "type" => "string", "group" => "content"},
    %{"name" => "stage", "title" => "Stage", "type" => "string", "group" => "meta"},
    %{"name" => "rating", "title" => "Rating", "type" => "number", "group" => "meta"}
  ]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-ro-tabs-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-ro-tabs", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    type = "rotabs_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Read-only tabs #{n}",
          "visibility" => "public",
          "groups" => @groups,
          "fields" => @fields
        },
        @dataset
      )

    id = "rotabs-#{n}"
    published = %{"excerpt" => "Old", "stage" => "review", "rating" => 3}

    {:ok, _} =
      Content.create_document(
        type,
        Map.merge(published, %{"doc_id" => id, "title" => "Published"}),
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)

    {:ok, _} =
      Content.upsert_document(
        type,
        %{
          "doc_id" => Content.draft_id(id),
          "title" => "Draft",
          "content" => %{"excerpt" => "New", "stage" => "done", "rating" => 5}
        },
        @dataset
      )

    rev =
      id
      |> Content.list_revisions(type, @dataset, limit: 10)
      |> Enum.find(&(&1.action == "publish"))

    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{type};#{id}"
    {:ok, conn: conn, type: type, id: id, base: base, rev: rev.id}
  end

  defp open(c, query) do
    {:ok, view, _html} = live(c.conn, c.base <> query)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp draft(c) do
    {:ok, doc} = Content.get_document(Content.draft_id(c.id), c.type, @dataset)
    doc
  end

  defp published(c) do
    {:ok, doc} = Content.get_document(c.id, c.type, @dataset)
    doc
  end

  # The tabs sit outside every disabled fieldset, and Meta opens; its fields
  # are inside one.
  defp tabs_switch(view, stage, holder) do
    assert has_element?(view, "#{@pane} .bp-tab-bar #bp-group-tab-meta")
    refute has_element?(view, "#{@pane} fieldset[disabled] .bp-tab-bar")
    refute has_element?(view, "#{@pane} fieldset[disabled] #bp-group-tab-meta")

    view |> element("#{@pane} #bp-group-tab-meta") |> render_click()

    assert has_element?(view, ~s(#{@pane} #bp-group-tab-meta[aria-selected="true"]))

    assert has_element?(
             view,
             ~s(#{@pane} #{holder} fieldset[disabled] #editor-form [name="doc[stage]"][value="#{stage}"])
           )

    refute has_element?(view, ~s(#{@pane} #editor-form [name="doc[excerpt]"]))
  end

  test "the published view: the group tabs switch, the fields stay read-only, a write is refused",
       c do
    before_draft = draft(c)
    before_published = published(c)
    view = open(c, "?perspective=published")

    tabs_switch(view, "review", "fieldset[data-desk-published-form]")

    EditorPost.change(view, %{"doc[stage]" => "typed"})

    assert published(c) == before_published
    assert draft(c).content == before_draft.content
  end

  # A revision's deep URL without the History inspector: the tabs are not
  # waiting, so they switch as on the draft.
  test "an old revision: the group tabs switch, the fields stay read-only, a write is refused",
       c do
    before_draft = draft(c)
    view = open(c, ",rev=#{c.rev}")

    assert has_element?(view, "#{@pane} fieldset[data-desk-revision-form]")
    tabs_switch(view, "review", "fieldset[data-desk-revision-form]")

    EditorPost.change(view, %{"doc[stage]" => "typed"})

    assert draft(c).content == before_draft.content
  end

  # With the History inspector open the tabs wait and every group's fields
  # show, read-only, as Sanity's (`HistoryPanel.waiting/1`).
  test "an old revision under History: every group's fields show in the disabled form", c do
    view = open(c, @history <> ",rev=#{c.rev}")

    refute has_element?(view, "#{@pane} fieldset[disabled] .bp-tab-bar")
    holder = "#{@pane} fieldset[disabled] #editor-form"
    assert has_element?(view, ~s(#{holder} [name="doc[stage]"][value="review"]))
    assert has_element?(view, ~s(#{holder} [name="doc[excerpt]"][value="Old"]))
  end

  test "the draft: the tabs and the fields sit in no disabled fieldset", c do
    view = open(c, "")

    refute has_element?(view, "#{@pane} fieldset[disabled] .bp-tab-bar")
    view |> element("#{@pane} #bp-group-tab-meta") |> render_click()
    refute has_element?(view, ~s(#{@pane} fieldset[disabled] [name="doc[stage]"]))
    assert has_element?(view, ~s(#{@pane} #editor-form [name="doc[stage]"][value="done"]))
  end
end
