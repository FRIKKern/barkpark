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

    # The shell's own header sits outside the read-only fields now. The desk
    # hides it; a press sent anyway is refused.
    view |> element("#{@pane} #doc-action-publish") |> render_click()

    assert published(c) == before_published
    assert draft(c).content == before_draft.content
  end

  # A revision's deep URL without the History inspector: the tabs are not
  # waiting, so they switch as on the draft.
  test "an old revision: the group tabs switch, the fields stay read-only, a write is refused",
       c do
    before_draft = draft(c)
    before_published = published(c)
    view = open(c, ",rev=#{c.rev}")

    assert has_element?(view, "#{@pane} fieldset[data-desk-revision-form]")
    tabs_switch(view, "review", "fieldset[data-desk-revision-form]")

    EditorPost.change(view, %{"doc[stage]" => "typed"})
    view |> element("#{@pane} #doc-action-publish") |> render_click()

    assert draft(c).content == before_draft.content
    assert published(c) == before_published
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

  # task-2dd6262184d64bb4: as the TanStack Studio's `GroupTabs` (`disabled &&
  # value !== g.name`), the tab shown while the groups wait, All fields, stays
  # live and is the tab stop, so the open focus (bp-tab-keys.js `formStart`)
  # has a tab to take; the other tabs wait. All three were disabled, and the
  # focus sat on BODY.
  for {name, query} <- [revision: :revision, draft: ""] do
    test "History open on the #{name}: All fields stays live and the tab stop, the other tabs wait",
         c do
      query = if unquote(query) == :revision, do: ",rev=#{c.rev}", else: ""
      view = open(c, @history <> query)

      assert has_element?(
               view,
               "#{@pane} #bp-group-tab-all-fields:not([disabled])[aria-selected=\"true\"][tabindex=\"0\"]"
             )

      assert has_element?(view, "#{@pane} #bp-group-tab-content[disabled]")
      assert has_element?(view, "#{@pane} #bp-group-tab-meta[disabled]")
    end
  end

  # The conflict banner sits above the read-only fields: Reload is refused in
  # both views (`refuses?/2`), so it is drawn disabled there, as it was inside
  # the old disabled holder. A conflict with unsaved edits is set on the
  # socket here: no event reaches a read-only view with them.
  for {name, query} <- [published: "?perspective=published", revision: :revision, draft: ""] do
    test "a conflict banner on the #{name}: Reload is drawn #{if name == :draft, do: "enabled", else: "disabled"}",
         c do
      query = if unquote(query) == :revision, do: ",rev=#{c.rev}", else: unquote(query)
      view = open(c, query)

      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        %{state | socket: Phoenix.Component.assign(socket, :doc_conflict, true)}
      end)

      view |> element("#{@pane} #bp-group-tab-meta") |> render_click()
      assert has_element?(view, ~s(#{@pane} [data-test-id="doc-conflict-reload"]))

      disabled? = has_element?(view, ~s(#{@pane} [data-test-id="doc-conflict-reload"][disabled]))
      assert disabled? == (unquote(name) != :draft)
    end
  end

  # task-2dd6262184d64bb4: the Studio's phone trail (`desk_crumbs`) was drawn
  # in the desk too, a bare "/" before the pane row from the narrow bucket on.
  # Arriving there it moved the row (`#studio-panes`, the WidthBucket hook's
  # element), and the focused group tab with it fell to BODY.
  test "a narrower width bucket draws nothing new before the desk's pane row", c do
    view = open(c, "")
    assert has_element?(view, "#{@pane} #studio-panes")

    for bucket <- ~w(narrow phone standard wide) do
      render_hook(view, "width-bucket", %{"bucket" => bucket})
      refute has_element?(view, ".bp-desk-crumbs"), "a trail at #{bucket}"
      assert has_element?(view, "#{@pane} #studio-panes #bp-group-tab-meta")
    end
  end

  test "the draft: the tabs and the fields sit in no disabled fieldset", c do
    view = open(c, "")

    refute has_element?(view, "#{@pane} fieldset[disabled] .bp-tab-bar")
    view |> element("#{@pane} #bp-group-tab-meta") |> render_click()
    refute has_element?(view, ~s(#{@pane} fieldset[disabled] [name="doc[stage]"]))
    assert has_element?(view, ~s(#{@pane} #editor-form [name="doc[stage]"][value="done"]))
  end
end
