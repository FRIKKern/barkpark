defmodule BarkparkWeb.Studio.SheetGrid.FileIO do
  @moduledoc """
  Download and CSV import for the Studio sheet editor (task-da387f54432114d8).

  Ruling (b) on that task: the LiveView builds the file and hands it to the
  browser, and an import arrives as a LiveView upload. There is no new HTTP
  door. The token-only export and import routes
  (`Sheets.Web.ExportController`, `Sheets.Web.ImportController`) stay as they
  are.

  Both directions work on what the editor already holds:

    * A download serializes `socket.assigns.content`, the content this socket
      renders. The host authorized and scoped that read when it mounted the
      grid, so a download reaches no byte the viewer cannot already see.
    * An import becomes ordinary session ops (`add_tab`, then `set_cell`), so
      it goes through the same write wall as typing (`Ops.send_ops/2` drops
      everything for a host without write capability) and lands in the open
      sheet only.

  Caps: a download over `download_byte_cap/0` bytes is refused (the file
  rides the LiveView socket base64-encoded). An upload over
  `import_byte_cap/0` bytes is refused by `allow_upload`, and an import over
  `import_cell_cap/0` non-empty cells is refused whole, with nothing applied.
  """

  alias Barkpark.Plugins.Sheets
  alias Barkpark.Plugins.Sheets.{Core, Csv, XlsxExport}
  alias BarkparkWeb.Studio.SheetGrid.Ops

  @xlsx_mime "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  @download_byte_cap 5_000_000
  @import_byte_cap 5_000_000
  # The same bound as a paste and the session's cell cap.
  @import_cell_cap 50_000

  def download_byte_cap, do: @download_byte_cap
  def import_byte_cap, do: @import_byte_cap
  def import_cell_cap, do: @import_cell_cap

  @doc """
  Build the download for `format` ("xlsx" = every tab, "csv" = tab `tab`).

  Returns the payload the client handler (`phx:bp:sheet-download` in
  bp-sheet-grid.js) turns into a file, or an error sentence for the notice.
  """
  @spec download(map(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, %{filename: String.t(), mime: String.t(), data: String.t()}}
          | {:error, String.t()}
  def download(content, title, tab, format)

  def download(content, title, _tab, "xlsx") do
    filename = file_base(title) <> ".xlsx"

    case XlsxExport.to_binary(content || %{}, filename) do
      {:ok, binary} -> payload(binary, filename, @xlsx_mime)
      {:error, message} -> {:error, "Download failed: #{message}"}
    end
  end

  def download(content, title, tab, "csv") do
    case Csv.export(content || %{}, tab, ",") do
      {:ok, text} -> payload(text, file_base(title) <> ".csv", "text/csv")
      {:error, :tab_not_found} -> {:error, "Download failed: this tab no longer exists."}
    end
  end

  def download(_content, _title, _tab, _format), do: {:error, "Unknown download format."}

  defp payload(bytes, filename, mime) do
    if byte_size(bytes) > @download_byte_cap do
      {:error,
       "This sheet is too large to download here (#{mb(byte_size(bytes))} MB; " <>
         "the limit is #{mb(@download_byte_cap)} MB)."}
    else
      {:ok, %{filename: filename, mime: mime, data: Base.encode64(bytes)}}
    end
  end

  # A file name from the sheet title: letters, digits, space, dot, dash and
  # underscore survive; anything else (path separators, quotes, control
  # characters) becomes a dash.
  defp file_base(title) do
    base =
      (title || "")
      |> String.replace(~r/[^\p{L}\p{N} ._-]+/u, "-")
      |> String.slice(0, 100)
      |> String.replace(~r/^[\s.-]+|[\s.-]+$/u, "")

    if base == "", do: "sheet", else: base
  end

  defp mb(bytes), do: Float.round(bytes / 1_000_000, 1)

  @doc """
  Turn an uploaded CSV/TSV into the ops that add it as a new tab named after
  the file. `tabs` is the sheet's current tab list (for a unique name and the
  new tab's index).

  Returns `{:ok, ops, %{name, index, rows, cells}}` or `{:error, sentence}`.
  Nothing is applied on an error.
  """
  @spec import_ops(binary(), String.t(), list()) ::
          {:ok, [map()],
           %{name: String.t(), index: non_neg_integer(), rows: integer(), cells: integer()}}
          | {:error, String.t()}
  def import_ops(raw, filename, tabs) when is_binary(raw) do
    ext = String.downcase(Path.extname(filename || ""))
    default_sep = if ext == ".tsv", do: "\t", else: ","

    with :ok <- import_ext(ext),
         {:ok, text} <- Csv.normalize_encoding(raw),
         sep = Csv.sniff_separator(text, default_sep),
         {:ok, rows} <- Csv.parse(text, sep) do
      rows =
        rows
        |> Enum.take(Sheets.grid_max_row())
        |> Enum.map(&Enum.take(&1, Sheets.grid_max_col()))

      cells =
        for {row, r} <- Enum.with_index(rows, 1),
            {val, c} <- Enum.with_index(row, 1),
            is_binary(val),
            val != "",
            do: {Core.format_ref({c, r}), val}

      cond do
        cells == [] ->
          {:error, "The file has no values to import."}

        length(cells) > @import_cell_cap ->
          {:error,
           "The file has #{length(cells)} values; an import can add at most #{@import_cell_cap}."}

        true ->
          index = length(tabs)
          name = unique_tab_name(tab_base(filename), tabs)

          ops =
            [%{"op" => "add_tab", "name" => name}] ++
              for {ref, val} <- cells do
                %{"op" => "set_cell", "tab" => index, "ref" => ref, "raw" => Ops.parse_raw(val)}
              end

          {:ok, ops, %{name: name, index: index, rows: length(rows), cells: length(cells)}}
      end
    else
      {:error, :not_csv} -> {:error, "Choose a .csv or .tsv file."}
      {:error, message} when is_binary(message) -> {:error, "Import failed: #{message}"}
      {:error, other} -> {:error, "Import failed: #{inspect(other)}"}
    end
  end

  # `allow_upload` takes `accept: :any` (the mime registry has no `.tsv`), so
  # the extension is checked here.
  defp import_ext(ext) when ext in [".csv", ".tsv", ".txt"], do: :ok
  defp import_ext(_ext), do: {:error, :not_csv}

  defp tab_base(filename) do
    base = filename |> to_string() |> Path.basename() |> Path.rootname() |> String.trim()
    base = String.slice(base, 0, 60)
    if base == "", do: "Imported", else: base
  end

  defp unique_tab_name(base, tabs) do
    taken =
      for {t, i} <- Enum.with_index(tabs),
          into: MapSet.new(),
          do: String.downcase((is_map(t) && Map.get(t, "name")) || "Sheet #{i + 1}")

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base} #{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, String.downcase(&1))))
  end
end
