defmodule BarkparkWeb.Studio.SheetGrid.FilterOpsNbTest do
  @moduledoc """
  Run-8 non-gettext audit: the sheet's filter and conditional-format operator
  lists ("is equal to", "is between", …) and the value labels were literal
  English in a grid whose every other word was already Norwegian.

  Harness copied minimally from `SortToolbarTest` (that file untouched).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Tenancy}

  @dataset "production"

  setup do
    stop_all_sessions()
    on_exit(&stop_all_sessions/0)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "icon" => "grid",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => "ops-nb",
          "content" => %{
            "locale" => "nb-NO",
            "tabs" => [%{"name" => "Data", "cells" => %{"A1" => %{"v" => 1}}}]
          }
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

  defp open_filter(conn, locale) do
    {:ok, _} = Tenancy.set_workspace_locale(Tenancy.get_default_workspace(), locale)
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/ops-nb"))
    target = with_target(view, "#sheet-grid-ops-nb")
    render_click(target, "filter-open", %{"col" => "1"})
    view
  end

  defp option_labels(view) do
    view
    |> element(~s([data-test-id="sheet-filter-op"]))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  test "an nb workspace: the filter operators and the value label read Norwegian", %{conn: conn} do
    view = open_filter(conn, "nb-NO")

    assert option_labels(view) == [
             "er ikke tom",
             "er tom",
             "er lik",
             "er større enn",
             "er mindre enn",
             "er mellom",
             "inneholder"
           ]

    html =
      view
      |> element(~s([data-test-id="sheet-filter-form"]))
      |> render_change(%{"col" => "1", "op" => "eq"})

    assert html =~ "verdi"
  end

  test "an English workspace reads as before", %{conn: conn} do
    view = open_filter(conn, "en")
    assert "is between" in option_labels(view)
  end
end
