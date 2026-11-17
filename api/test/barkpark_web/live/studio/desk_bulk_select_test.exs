defmodule BarkparkWeb.Studio.DeskBulkSelectTest do
  @moduledoc """
  B03 and B07 on the desk, as the TanStack Studio's (barkpark-studio
  `e2e/journeys/bulk.spec.ts`, `unpublish-guard.spec.ts:43`,
  `big-list.spec.ts:128`): a list's "List options" starts selecting, each row
  has a tick, the `region` "Bulk actions" says how many are ticked and
  publishes or unpublishes them, an unpublish asks first, and one summary
  says what happened.

  What is written is the point: only the ticked documents, of the list's own
  type, in the socket's dataset, and an unpublish only after its dialog.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.Desk.Bulk

  @dataset "production"
  @list ~s([data-pane-index="1"])
  @bar ~s(#{@list} [role="region"][aria-label="Bulk actions"])
  @dialog ~s(#{@list} [role="dialog"][aria-modal="true"][data-desk-dialog="bulk-unpublish"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    note = "bs_note_#{n}"
    post = "bs_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => note,
          "title" => "Bulk notes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => post,
          "title" => "Bulk posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "note", "title" => "Note", "type" => "reference", "to" => [note]}
          ]
        },
        @dataset
      )

    ids = for k <- 1..4, do: "bs-#{n}-#{k}"

    # All four published; the second and the third then get a draft over them,
    # the fourth too (it is never ticked).
    for {id, k} <- Enum.with_index(ids, 1) do
      {:ok, _} =
        Content.create_document(note, %{"doc_id" => id, "title" => "Note #{k}"}, @dataset)

      {:ok, _} = Content.publish_document(id, note, @dataset)
      Process.sleep(5)
    end

    for {id, k} <- Enum.with_index(ids, 1), k > 1 do
      {:ok, _} =
        Content.create_document(note, %{"doc_id" => id, "title" => "Note #{k} edited"}, @dataset)
    end

    # A post refers to the second note.
    {:ok, _} =
      Content.create_document(
        post,
        %{
          "doc_id" => "bs-post-#{n}",
          "title" => "Refers",
          "content" => %{"note" => %{"_ref" => Enum.at(ids, 1), "_type" => "reference"}}
        },
        @dataset
      )

    {:ok, _} = Content.publish_document("bs-post-#{n}", post, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "bs-token-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "bs",
        @dataset,
        ~w(read write admin),
        Tenancy.get_default_workspace().id
      )

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    {:ok, view, _html} = live(conn, "#{base}/#{note}")
    render_async(view, 5_000)

    {:ok, view: view, note: note, ids: ids, pane: pane_id(view)}
  end

  defp pane_id(view) do
    [_, id] = Regex.run(~r/<section[^>]* id="(desk-pane-1-[^"]+)"/, render(view))
    id
  end

  defp state(c, id) do
    {_doc, draft?, published?} = Content.fetch_doc_with_draft(c.note, id, @dataset)
    {draft?, published?}
  end

  defp select(c), do: render_click(c.view, "bulk-select", %{"pane" => c.pane, "on" => "true"})

  defp tick(c, id, range \\ false) do
    params = if range, do: %{"id" => id, "range" => "true"}, else: %{"id" => id}

    c.view
    |> element(~s(#{@list} .bulk-check input[phx-value-id="#{id}"]))
    |> render_click(params)

    render(c.view)
  end

  defp eventually(fun), do: Enum.any?(1..300, fn _ -> fun.() or (Process.sleep(10) && false) end)

  test "List options offers Select documents; the ticks are out of reach until it is picked", c do
    item = ~s(#{@list} .dk-list-menu [role="menuitemradio"][phx-click="bulk-select"])
    assert has_element?(c.view, ~s(#{item}[aria-checked="false"]), "Select documents")
    assert has_element?(c.view, ~s(#{@list} label.bulk-check[inert] input[type="checkbox"]))
    assert has_element?(c.view, ~s(#{@list} .bulk-check input[aria-label="Select Note 1"]))
    refute has_element?(c.view, ~s(#{@list} .list-rows[data-selecting]))
    refute has_element?(c.view, @bar)

    c.view |> element(item) |> render_click()

    assert has_element?(c.view, ~s(#{item}[aria-checked="true"]), "Stop selecting")
    assert has_element?(c.view, ~s(#{@list} .list-rows[data-selecting]))
    refute has_element?(c.view, ~s(#{@list} label.bulk-check[inert]))
    # Nothing ticked yet: no bar.
    refute has_element?(c.view, @bar)

    c.view |> element(item) |> render_click()
    refute has_element?(c.view, ~s(#{@list} .list-rows[data-selecting]))
  end

  test "a tick counts; a Shift-click adds the rows between; Clear ends selecting", c do
    [a, _b, _c, d] = c.ids
    select(c)
    tick(c, a)

    assert has_element?(c.view, ~s(#{@bar} [role="status"]), "1 selected")

    assert has_element?(
             c.view,
             ~s(#{@list} .bulk-row[data-picked] input[phx-value-id="#{a}"][checked])
           )

    # The list reads newest first: the first note is its last row. A range
    # from it to the fourth is all four rows.
    tick(c, d, true)
    assert has_element?(c.view, ~s(#{@bar} [role="status"]), "4 selected")

    # A tick on a ticked row takes it out.
    tick(c, d)
    assert has_element?(c.view, ~s(#{@bar} [role="status"]), "3 selected")

    c.view |> element(~s(#{@bar} button), "Clear") |> render_click()
    refute has_element?(c.view, @bar)
    refute has_element?(c.view, ~s(#{@list} .list-rows[data-selecting]))
    refute has_element?(c.view, ~s(#{@list} .bulk-check input[checked]))
  end

  test "Publish selected publishes the ticked documents only, and says what it did", c do
    [a, b, c3, d] = c.ids
    select(c)
    for id <- [a, b, c3], do: tick(c, id)

    c.view |> element(~s(#{@bar} button.publish), "Publish selected") |> render_click()

    assert_push_event(
      c.view,
      "desk:bulk-toast",
      %{
        tone: "positive",
        title: "Published 2 of 3",
        description: "1 had no changes to publish."
      },
      5_000
    )

    for id <- [a, b, c3], do: assert(state(c, id) == {false, true})
    # Not ticked: its draft is still a draft.
    assert state(c, d) == {true, true}
    # A bulk action ends selecting.
    assert eventually(fn -> not has_element?(c.view, @bar) end)
    refute has_element?(c.view, ~s(#{@list} .list-rows[data-selecting]))
  end

  test "Unpublish selected asks first: the dialog names who refers; only its confirm unpublishes",
       c do
    [a, b, _c3, d] = c.ids
    select(c)
    for id <- [a, b], do: tick(c, id)

    c.view |> element(~s(#{@bar} button), "Unpublish selected") |> render_click()

    assert has_element?(c.view, ~s(#{@dialog} h2), "Unpublish 2 documents?")
    assert has_element?(c.view, ~s(#{@dialog} button[data-modal-focus]), "Cancel")
    # Who refers is read in a task; a confirm sent before it lands does nothing.
    render_click(c.view, "bulk-unpublish", %{"pane" => c.pane, "confirm" => "true"})
    assert state(c, a) == {false, true}
    render_async(c.view, 5_000)
    refute has_element?(c.view, ~s(#{@dialog} button[disabled]))
    # One section for the note a post refers to.
    assert has_element?(c.view, ~s(#{@dialog} section[aria-label="Referring to Note 2 edited"]))
    assert has_element?(c.view, ~s(#{@dialog} section [role="status"]), "1 document refers to")
    assert has_element?(c.view, ~s(#{@dialog} .used-in li), "Refers")
    assert has_element?(c.view, ~s(#{@dialog} button), "Disconnect references and unpublish")
    assert has_element?(c.view, ~s(#{@dialog} button.danger), "Unpublish anyway")
    # Asked, not done.
    assert state(c, a) == {false, true}

    c.view |> element(~s(#{@dialog} button[data-modal-focus])) |> render_click()
    refute has_element?(c.view, @dialog)
    assert state(c, a) == {false, true}
    assert has_element?(c.view, ~s(#{@bar} [role="status"]), "2 selected")

    c.view |> element(~s(#{@bar} button), "Unpublish selected") |> render_click()
    render_async(c.view, 5_000)
    c.view |> element(~s(#{@dialog} button.danger)) |> render_click()

    assert_push_event(c.view, "desk:bulk-toast", %{title: "Unpublished 2 of 2"}, 5_000)
    assert {_, false} = state(c, a)
    assert {_, false} = state(c, b)
    assert state(c, d) == {true, true}
    assert eventually(fn -> not has_element?(c.view, @bar) end)
  end

  test "events sent by hand write nothing they were not asked for", c do
    [a, b, _c3, d] = c.ids

    # A tick for a document the list does not hold is no tick.
    select(c)
    render_click(c.view, "bulk-publish", %{"pane" => c.pane})

    c.view
    |> element(~s(#{@list} .bulk-check input[phx-value-id="#{a}"]))
    |> render_click(%{"id" => "not-in-this-list"})

    render(c.view)
    refute has_element?(c.view, @bar)

    # A confirm with no dialog open only opens the dialog.
    tick(c, b)
    render_click(c.view, "bulk-unpublish", %{"pane" => c.pane, "confirm" => "true"})
    assert has_element?(c.view, ~s(#{@dialog} h2), "Unpublish document?")
    assert state(c, b) == {true, true}
    render_click(c.view, "bulk-unpublish-close", %{})

    # Another pane's id, or none: nothing.
    render_click(c.view, "bulk-publish", %{"pane" => "desk-pane-0-types"})
    render_click(c.view, "bulk-publish", %{})
    assert state(c, b) == {true, true}
    assert state(c, d) == {true, true}
  end

  test "the summary, in the TanStack Studio's words" do
    assert Bulk.summary(:publish, [:done, :done, :skipped]) == %{
             tone: "positive",
             title: "Published 2 of 3",
             description: "1 had no changes to publish."
           }

    assert Bulk.summary(:unpublish, [:done, :skipped]).description == "1 was not published."

    assert Bulk.summary(:unpublish, [:skipped, :skipped]) == %{
             tone: "positive",
             title: "Unpublished 0 of 2",
             description: "2 were not published."
           }

    assert Bulk.summary(:publish, [:done, {:walled, "a rule"}, {:failed, "no"}]) == %{
             tone: "critical",
             title: "Published 1 of 3",
             description: "1 blocked by the publish wall — a rule 1 failed: no"
           }

    assert Bulk.summary(:publish, [:done]).description == nil
  end
end
