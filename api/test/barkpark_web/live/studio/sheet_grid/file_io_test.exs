defmodule BarkparkWeb.Studio.SheetGrid.FileIOTest do
  @moduledoc """
  task-da387f54432114d8 — the sheet editor's Download and CSV import.

  Ruling (b): the LiveView builds the download and pushes it to the browser,
  and an import arrives as a LiveView upload. These tests drive the real
  component: the pushed payload is decoded and compared with what the grid
  holds, and an import is read back from the live session.

  `async: false` — sheet sessions are globally registered processes that read
  and persist through the SQL sandbox in shared mode, like the sibling
  SheetGrid suites.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias Barkpark.Plugins.Sheets.{Session, XlsxImport}
  alias Barkpark.TenancyFixtures
  alias BarkparkWeb.Studio.SheetGrid.FileIO

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
          "icon" => "grid",
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

  defp create_sheet!(slug, title, tabs, opts \\ []) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "title" => title,
          "content" => %{"locale" => "nb-NO", "tabs" => tabs}
        },
        @dataset,
        opts
      )

    doc
  end

  defp open!(conn, slug) do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    {view, with_target(view, "#sheet-grid-#{slug}")}
  end

  defp open_panel!(view) do
    view |> element(~s([data-test-id="sheet-file"])) |> render_click()
  end

  defp download!(view, format) do
    unless has_element?(view, ~s([data-test-id="sheet-file-panel"])), do: open_panel!(view)
    view |> element(~s([data-test-id="sheet-download-#{format}"])) |> render_click()
    assert_push_event(view, "bp:sheet-download", %{filename: filename, mime: mime, data: data})
    {filename, mime, Base.decode64!(data)}
  end

  defp session_tabs(slug) do
    {:ok, content} = Session.peek(slug, @dataset)
    content["tabs"]
  end

  describe "download" do
    test "xlsx carries every tab and the values the grid shows", %{conn: conn} do
      create_sheet!("fio-xlsx", "Budsjett 2027", [
        %{"name" => "Inntekter", "cells" => %{"A1" => %{"v" => 150}, "A2" => %{"f" => "A1*2"}}},
        %{"name" => "Utgifter", "cells" => %{"B3" => %{"v" => "husleie"}}}
      ])

      {view, _target} = open!(conn, "fio-xlsx")
      {filename, mime, bytes} = download!(view, "xlsx")

      assert filename == "Budsjett 2027.xlsx"
      assert mime == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

      {:ok, back} = XlsxImport.to_content(bytes)
      assert Enum.map(back["tabs"], & &1["name"]) == ["Inntekter", "Utgifter"]
      [t0, t1] = back["tabs"]
      assert t0["cells"]["A1"]["v"] == 150
      assert t0["cells"]["A2"]["f"] == "A1*2"
      assert t1["cells"]["B3"]["v"] == "husleie"
    end

    test "csv is the open tab only", %{conn: conn} do
      create_sheet!("fio-csv", "Liste", [
        %{"name" => "En", "cells" => %{"A1" => %{"v" => "first tab"}}},
        %{"name" => "To", "cells" => %{"A1" => %{"v" => "second"}, "B1" => %{"v" => 2}}}
      ])

      {view, target} = open!(conn, "fio-csv")
      render_click(target, "tab-switch", %{"tab" => "1"})

      {filename, "text/csv", text} = download!(view, "csv")
      assert filename == "Liste.csv"
      assert text =~ "second,2"
      refute text =~ "first tab"
    end

    test "a read-only member can download but gets no import form", %{conn: conn} do
      {:ok, _} =
        Auth.create_token(
          "fio-readonly",
          "fio readonly",
          @dataset,
          ["read"],
          TenancyFixtures.default_workspace_id!()
        )

      create_sheet!("fio-ro", "RO", [%{"name" => "Data", "cells" => %{"A1" => %{"v" => "x"}}}])

      {:ok, view, _html} =
        conn
        |> Plug.Test.init_test_session(%{"api_token" => "fio-readonly"})
        |> live(scoped_studio("/d/#{@dataset}/studio/sheet/fio-ro"))

      assert view |> element(~s([data-test-id="sheet-file"])) |> render() =~ "Download"
      {_filename, _mime, text} = download!(view, "csv")
      assert text =~ "x"
      refute has_element?(view, ~s([data-test-id="sheet-import-form"]))

      # A forged import event from this host writes nothing.
      view |> with_target("#sheet-grid-fio-ro") |> render_submit("csv-import", %{})
      assert {:error, :no_session} = Session.peek("fio-ro", @dataset)
    end

    test "a same-slug sheet in another workspace never reaches the download", %{conn: conn} do
      other_ws = TenancyFixtures.create_workspace!()
      other_proj = TenancyFixtures.create_project!(other_ws)

      create_sheet!(
        "fio-tenant",
        "Theirs",
        [%{"name" => "Secret", "cells" => %{"A1" => %{"v" => "other-tenant-secret"}}}],
        workspace_id: other_ws.id,
        project_id: other_proj.id
      )

      {default_ws, default_proj} = TenancyFixtures.ensure_default_scope!()

      create_sheet!(
        "fio-tenant",
        "Ours",
        [%{"name" => "Data", "cells" => %{"A1" => %{"v" => "our-value"}}}],
        workspace_id: default_ws.id,
        project_id: default_proj.id
      )

      {view, _target} = open!(conn, "fio-tenant")
      {_filename, _mime, text} = download!(view, "csv")
      assert text =~ "our-value"
      refute text =~ "other-tenant-secret"

      {_filename, _mime, bytes} = download!(view, "xlsx")
      {:ok, back} = XlsxImport.to_content(bytes)
      assert Enum.map(back["tabs"], & &1["name"]) == ["Data"]
    end

    test "Escape closes the panel and returns focus to its button", %{conn: conn} do
      create_sheet!("fio-esc", "E", [%{"name" => "Data", "cells" => %{}}])
      {view, _target} = open!(conn, "fio-esc")

      open_panel!(view)
      panel = view |> element(~s([data-test-id="sheet-file-panel"])) |> render()
      assert panel =~ "file-close"
      assert panel =~ "sheet-grid-fio-esc-file-btn"

      view
      |> element(~s([data-test-id="sheet-file-panel"]))
      |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, ~s([data-test-id="sheet-file-panel"]))

      assert view |> element(~s([data-test-id="sheet-file"])) |> render() =~
               ~s(aria-expanded="false")
    end
  end

  describe "csv import" do
    test "adds the file as a new tab named after it and switches to it", %{conn: conn} do
      create_sheet!("fio-imp", "Imp", [
        %{"name" => "Data", "cells" => %{"A1" => %{"v" => "keep"}}}
      ])

      {view, _target} = open!(conn, "fio-imp")
      open_panel!(view)

      csv = "navn;beløp\nhusleie;12000\n\"strøm; nett\";=B2*2\n"

      upload =
        file_input(view, ~s([data-test-id="sheet-import-form"]), :csv_import, [
          %{name: "Kostnader.csv", content: csv, type: "text/csv"}
        ])

      render_upload(upload, "Kostnader.csv")
      view |> element(~s([data-test-id="sheet-import-form"])) |> render_submit()

      [data, imported] = session_tabs("fio-imp")
      assert data["cells"] == %{"A1" => %{"v" => "keep"}}
      assert imported["name"] == "Kostnader"
      cells = imported["cells"]
      assert cells["A1"]["v"] == "navn"
      assert cells["B2"]["v"] == 12000
      assert cells["A3"]["v"] == "strøm; nett"
      assert cells["B3"]["f"] == "B2*2"
      assert cells["B3"]["v"] == 24000

      assert view |> element(~s([role="tab"][aria-selected="true"])) |> render() =~ "Kostnader"
      refute has_element?(view, ~s([data-test-id="sheet-file-panel"]))
    end

    test "a second import of the same file gets a unique tab name", %{conn: conn} do
      create_sheet!("fio-dup", "Dup", [%{"name" => "Tall", "cells" => %{}}])
      {view, _target} = open!(conn, "fio-dup")

      for _ <- 1..2 do
        open_panel!(view)

        view
        |> file_input(~s([data-test-id="sheet-import-form"]), :csv_import, [
          %{name: "tall.csv", content: "1,2\n", type: "text/csv"}
        ])
        |> render_upload("tall.csv")

        view |> element(~s([data-test-id="sheet-import-form"])) |> render_submit()
      end

      assert Enum.map(session_tabs("fio-dup"), & &1["name"]) == ["Tall", "tall 2", "tall 3"]
    end
  end

  describe "FileIO units" do
    test "a download over the byte cap is refused with a sentence" do
      big = String.duplicate("x", FileIO.download_byte_cap() + 1)
      content = %{"tabs" => [%{"name" => "T", "cells" => %{"A1" => %{"v" => big}}}]}

      assert {:error, message} = FileIO.download(content, "T", 0, "csv")
      assert message =~ "too large to download"
    end

    test "the file name drops path separators and quotes" do
      content = %{"tabs" => [%{"name" => "T", "cells" => %{}}]}
      assert {:ok, %{filename: "a-b-c.csv"}} = FileIO.download(content, ~s(a/b"c), 0, "csv")
      assert {:ok, %{filename: "sheet.csv"}} = FileIO.download(content, "../", 0, "csv")
      assert {:ok, %{filename: "Sjø 2027.csv"}} = FileIO.download(content, "Sjø 2027", 0, "csv")
    end

    test "an import over the cell cap is refused whole" do
      row = Enum.map_join(1..100, ",", &Integer.to_string/1)
      csv = String.duplicate(row <> "\n", div(FileIO.import_cell_cap(), 100) + 1)

      assert {:error, message} = FileIO.import_ops(csv, "big.csv", [])
      assert message =~ "at most #{FileIO.import_cell_cap()}"
    end

    test "an empty file is refused, a TSV uses tabs" do
      assert {:error, "The file has no values to import."} =
               FileIO.import_ops("\n\n", "e.csv", [])

      assert {:ok, ops, %{name: "t", index: 1}} =
               FileIO.import_ops("a\tb,c\n", "t.tsv", [%{"name" => "Sheet 1"}])

      assert [%{"op" => "add_tab", "name" => "t"} | sets] = ops
      assert Enum.map(sets, & &1["raw"]) == ["a", "b,c"]
    end
  end
end
