defmodule BarkparkWeb.Studio.StudioSheetHistoryRestoreTest do
  @moduledoc """
  The sheet editor's header offers History, and a restore made while the sheet
  is open survives the live session (task-1eaa2c0dc6e60047).

  A live `Sheets.Session` holds the cells in memory and treats a row written
  beside it as an external change its next persist overwrites. So the restore
  goes through `Session.restore/4`: discard, write, discard, restart from the
  restored row. The debounce is 60 s, and the test flushes explicitly.
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

  defp revision_holding(doc_id, ref, value) do
    Content.list_revisions(doc_id, "sheet", @dataset, limit: 30)
    |> Enum.find(fn rev ->
      get_in(rev.content || %{}, ["tabs", Access.at(0), "cells", ref, "v"]) == value
    end)
  end

  test "the header offers History", %{conn: conn} do
    create_sheet!("hist-offers")
    {_view, _target, html} = open!(conn, "hist-offers")
    assert html =~ ~s(data-test-id="sheet-history")
  end

  test "a restore while the sheet is open is still the stored draft after the session persists",
       %{conn: conn} do
    create_sheet!("hist-restore")
    {view, target, _html} = open!(conn, "hist-restore")

    # Revision 1: A1 = old, persisted.
    type_cell!(target, "A1", "old")
    assert :ok = Session.flush("hist-restore", @dataset, nil)

    # Revision 2: A1 = new, persisted.
    type_cell!(target, "A1", "new")
    assert :ok = Session.flush("hist-restore", @dataset, nil)

    # An edit still in the session's memory only.
    type_cell!(target, "B1", "pending")

    draft_id = Content.draft_id("hist-restore")
    old = revision_holding(draft_id, "A1", "old") || revision_holding("hist-restore", "A1", "old")
    assert old, "fixture: a revision holding A1 = old exists"

    render_click(view, "show-history", %{})
    render_click(view, "restore-revision", %{"id" => old.id})

    # The session persists again (the debounce, forced): the restore holds.
    assert :ok = Session.flush("hist-restore", @dataset, nil)

    stored_cells = cells(stored(draft_id))

    assert get_in(stored_cells, ["A1", "v"]) == "old",
           "the live session overwrote the restored row: #{inspect(stored_cells)}"

    refute Map.has_key?(stored_cells, "B1")
  end
end
