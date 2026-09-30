defmodule BarkparkWeb.Studio.StudioSheetBirthTabTest do
  @moduledoc """
  A Studio-born sheet has a tab 0 to write into.

  Found on the stranger walk (2026-09-30): Sheets → New sheet → type `42` into
  A1 → "1 op(s) rejected: the sheet has no tab 0", and the value was gone. The
  desk seeded a sheet with `content: %{}`; the grid paints a phantom "Sheet 1"
  when there are no tabs, but the session's op path resolves tab 0 for real
  (`Barkpark.Plugins.Sheets.Core.get_tab/2`) and refuses every op. The store is the
  proof: the persisted birth must carry a real tab 0.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.Core, as: Sheets

  @dataset "production"

  setup do
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

  test "a Studio-born sheet carries tab 0, so the first cell edit has somewhere to land",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))

    html = render_click(view, "new-document", %{"type" => "sheet"})
    refute html =~ "Failed to create"

    created =
      "sheet"
      |> Content.list_documents(@dataset, perspective: :raw)
      |> Enum.find(&Content.draft?(&1.doc_id))

    assert created, "expected the created sheet draft row to exist"

    tab = Sheets.get_tab(created.content, 0)

    assert tab == %{"name" => "Sheet 1", "cells" => %{}},
           """
           A Studio-born sheet must carry a real, empty tab 0 — without it the
           session refuses the first cell edit with "the sheet has no tab 0".

           got content: #{inspect(created.content)}
           """
  end
end
