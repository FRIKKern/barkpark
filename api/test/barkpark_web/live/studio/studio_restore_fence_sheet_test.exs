defmodule BarkparkWeb.Studio.StudioRestoreFenceSheetTest do
  @moduledoc """
  task-5b74471e6a2d6de8, the sheet's restore (`Session.restore/4`): the same
  fence, through the sheet's own path. Set up as
  `StudioSheetHistoryRestoreTest` is (60 s debounce, explicit flushes).
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

  defp type_cell!(target, ref, value) do
    render_hook(target, "cell-click", %{"ref" => ref, "shift" => false})
    render_hook(target, "edit-commit", %{"value" => value, "move" => "down"})
  end

  defp cells(slug) do
    {:ok, doc} = Content.get_document(Content.draft_id(slug), "sheet", @dataset)
    get_in(doc.content, ["tabs", Access.at(0), "cells"]) || %{}
  end

  test "a sheet's Restore pressed late, with a cell unflushed: refused, every cell stays",
       %{conn: conn} do
    slug = "rfence-sheet-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "title" => "Untitled sheet",
          "content" => %{"tabs" => [%{"name" => "Sheet 1", "cells" => %{}}]}
        },
        @dataset
      )

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    target = with_target(view, "#sheet-grid-#{slug}")

    type_cell!(target, "A1", "old")
    assert :ok = Session.flush(slug, @dataset, nil)
    type_cell!(target, "A1", "new")
    assert :ok = Session.flush(slug, @dataset, nil)

    old =
      Content.list_revisions(slug, "sheet", @dataset, limit: 30)
      |> Enum.find(&(get_in(&1.content || %{}, ["tabs", Access.at(0), "cells", "A1", "v"]) == "old"))

    assert old, "fixture: a revision holding A1 = old exists"

    render_click(view, "show-history", %{})

    [button] =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(#history-list button[phx-value-id="#{old.id}"]))
      |> Enum.to_list()

    pressed =
      for key <- ~w(id if_rev),
          [value] <- [LazyHTML.attribute(button, "phx-value-#{key}")],
          into: %{},
          do: {key, value}

    assert is_binary(pressed["if_rev"]), "the sheet's Restore names no state"

    # Someone's edit is stored before the press arrives, and another is still
    # in the session's memory only.
    type_cell!(target, "B1", "later")
    assert :ok = Session.flush(slug, @dataset, nil)
    type_cell!(target, "C1", "pending")

    BarkparkWeb.EditorPost.press(view, "restore-revision", pressed)

    # The session persists (the debounce, forced): the unflushed cell was kept.
    assert :ok = Session.flush(slug, @dataset, nil)
    stored = cells(slug)
    assert get_in(stored, ["A1", "v"]) == "new", "the late restore wrote the old cells back"
    assert get_in(stored, ["B1", "v"]) == "later"

    assert get_in(stored, ["C1", "v"]) == "pending",
           "the refused restore dropped the session's unflushed cell"
  end
end
