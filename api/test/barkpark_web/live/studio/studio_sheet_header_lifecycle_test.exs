defmodule BarkparkWeb.Studio.StudioSheetHeaderLifecycleTest do
  @moduledoc """
  The sheet editor's header can rename, publish and delete the sheet
  (task-64d23dae8eed88e7).

  Found dogfooding: the header offered only the draft pill and View/Edit, so a
  sheet made in Studio stayed "Untitled" and a draft forever. The live
  `Sheets.Session` holds edits in memory and persists on a debounce, so each
  lifecycle action has a session rule, and each test here fails if its rule is
  removed:

    * Publish flushes the session first — the published row must carry the
      cell the editor typed seconds ago, not the last debounced persist.
    * Rename goes THROUGH the session — the session writes its own title on
      every persist, so a title written beside it would be reverted.
    * Delete discards the session — its terminate persist would otherwise
      upsert the deleted sheet back.

  The debounce is 60 s here, so nothing reaches the store unless one of
  those rules puts it there.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Session

  @dataset "production"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    Application.put_env(:barkpark, Barkpark.Plugins.Sheets.Session,
      debounce_ms: 60_000,
      idle_stop_ms: 60_000
    )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    :ok
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp create_sheet!(slug) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "title" => "Untitled sheet",
          "content" => %{"tabs" => [%{"name" => "Sheet 1", "cells" => %{}}]}
        },
        @dataset
      )

    doc
  end

  defp open!(conn, slug) do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    {view, with_target(view, "#sheet-grid-#{slug}"), html}
  end

  # A cell edit through the real component path; the session holds it in
  # memory (the 60 s debounce keeps it out of the store).
  defp type_cell!(target, ref, value) do
    render_hook(target, "cell-click", %{"ref" => ref, "shift" => false})
    render_hook(target, "edit-commit", %{"value" => value, "move" => "down"})
  end

  defp stored(id) do
    case Content.get_document(id, "sheet", @dataset) do
      {:ok, doc} -> doc
      {:error, :not_found} -> nil
    end
  end

  defp cells(doc), do: get_in(doc.content, ["tabs", Access.at(0), "cells"]) || %{}

  test "the header offers Rename, Publish and Delete on a draft sheet", %{conn: conn} do
    create_sheet!("hdr-offers")
    {_view, _target, html} = open!(conn, "hdr-offers")

    assert html =~ ~s(data-test-id="sheet-rename")
    assert html =~ ~s(data-test-id="sheet-publish")
    assert html =~ ~s(data-test-id="sheet-delete")
    # The Publish control says what publishing a sheet means (owner ruling #58).
    assert html =~ "Publish — makes this sheet public"
  end

  test "Publish flushes the session, so the published row carries the cell just typed",
       %{conn: conn} do
    create_sheet!("hdr-publish")
    {view, target, _html} = open!(conn, "hdr-publish")

    type_cell!(target, "A1", "42")

    # Precondition: the edit lives only in the session, not in the store.
    refute Map.has_key?(cells(stored("drafts.hdr-publish")), "A1"),
           "the 60 s debounce should have kept A1 out of the store before Publish"

    html = view |> element(~s([data-test-id="sheet-publish"])) |> render_click()
    assert html =~ "Published sheets are public"

    published = stored("hdr-publish")
    assert published, "Publish should have created the published row"

    assert %{"A1" => %{"v" => 42}} = cells(published)
  end

  # task-3b3209373291e9fd: a published sheet is public, and the header had no
  # way back. Unpublish keeps the cell typed after Publish (it lives only in
  # the session) on the new draft, and a later edit persists to the draft
  # without writing the published row back.
  test "Unpublish keeps the session's cells on the draft and never resurrects the published row",
       %{conn: conn} do
    create_sheet!("hdr-unpub")
    {view, target, _html} = open!(conn, "hdr-unpub")
    type_cell!(target, "A1", "42")
    html = view |> element(~s([data-test-id="sheet-publish"])) |> render_click()
    assert html =~ ~s(data-test-id="sheet-unpublish")
    refute html =~ ~s(data-test-id="sheet-publish")

    type_cell!(target, "B1", "7")

    refute Map.has_key?(cells(stored("hdr-unpub")), "B1"),
           "the 60 s debounce should have kept B1 in the session before Unpublish"

    html = view |> element(~s([data-test-id="sheet-unpublish"])) |> render_click()
    assert html =~ ~s(data-test-id="sheet-publish")

    assert stored("hdr-unpub") == nil, "Unpublish should remove the published row"
    assert %{"A1" => %{"v" => 42}, "B1" => %{"v" => 7}} = cells(stored("drafts.hdr-unpub"))

    type_cell!(with_target(view, "#sheet-grid-hdr-unpub"), "C1", "9")
    :ok = Session.flush("hdr-unpub", @dataset, nil)

    assert %{"C1" => %{"v" => 9}} = cells(stored("drafts.hdr-unpub"))
    assert stored("hdr-unpub") == nil, "a later persist must not write the published row back"
  end

  test "Rename writes the title through the session, and a later persist keeps it",
       %{conn: conn} do
    create_sheet!("hdr-rename")
    {view, target, _html} = open!(conn, "hdr-rename")

    # A live session holding a dirty edit: its next persist writes its OWN title.
    type_cell!(target, "A1", "1")

    html = view |> element(~s([data-test-id="sheet-rename"])) |> render_click()
    assert html =~ ~s(data-test-id="sheet-title-input")

    html =
      view
      |> form(~s(#sheet-grid-hdr-rename form[phx-submit="title-rename"]), %{
        "title" => "  Q3 budget "
      })
      |> render_submit()

    assert html =~ "Q3 budget"
    refute html =~ ~s(data-test-id="sheet-title-input")
    assert stored("drafts.hdr-rename").title == "Q3 budget"

    # The session's next persist must not put the old title back.
    type_cell!(target, "A2", "2")
    assert :ok = Session.flush("hdr-rename", @dataset, nil)

    draft = stored("drafts.hdr-rename")

    assert draft.title == "Q3 budget",
           "the session reverted the rename to #{inspect(draft.title)}"

    assert %{"A1" => _, "A2" => _} = cells(draft)
  end

  test "an empty name is refused and the old one kept", %{conn: conn} do
    create_sheet!("hdr-blank")
    {view, _target, _html} = open!(conn, "hdr-blank")

    view |> element(~s([data-test-id="sheet-rename"])) |> render_click()

    html =
      view
      |> form(~s(#sheet-grid-hdr-blank form[phx-submit="title-rename"]), %{"title" => "   "})
      |> render_submit()

    assert html =~ "a sheet needs a name"
    assert stored("drafts.hdr-blank").title == "Untitled sheet"
  end

  test "Delete removes the sheet and the session cannot bring it back", %{conn: conn} do
    create_sheet!("hdr-delete")
    {view, target, _html} = open!(conn, "hdr-delete")

    # A dirty session: stopping it the ordinary way would persist (upsert) it.
    type_cell!(target, "A1", "7")
    assert Session.whereis("hdr-delete", @dataset, nil)

    view |> element(~s([data-test-id="sheet-delete"])) |> render_click()
    html = render_click(view, "confirm-delete", %{})
    assert html =~ "Deleted “Untitled sheet”."

    refute Session.whereis("hdr-delete", @dataset, nil),
           "the live session should have been discarded with the sheet"

    stop_all_sessions()
    refute stored("drafts.hdr-delete"), "the deleted sheet's draft came back"
    refute stored("hdr-delete"), "the deleted sheet's published row came back"
  end

  test "Session.discard stops a dirty session without persisting it" do
    create_sheet!("hdr-discard")

    {:ok, _} =
      Session.apply_ops("hdr-discard", @dataset, [
        %{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => "9"}
      ])

    assert :ok = Session.discard("hdr-discard", @dataset, nil)
    refute Session.whereis("hdr-discard", @dataset, nil)
    refute Map.has_key?(cells(stored("drafts.hdr-discard")), "A1")
  end
end
