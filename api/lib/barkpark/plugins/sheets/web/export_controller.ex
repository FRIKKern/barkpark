defmodule Barkpark.Plugins.Sheets.Web.ExportController do
  @moduledoc """
  GET /v1/plugins/sheets/:slug/export.{xlsx,csv,tsv,md,html} — spreadsheet
  export (M5).

  Mounted by `Barkpark.Plugins.Sheets.register_routes/1` on the `:ingest`
  bucket (`RequireIngestToken`), like the import side and the Bulldocs
  ingest API.

  Lookup is draft-first (the working copy the import path writes), with a
  published fallback — the same selection precedence the OnixEdit export
  uses. `?dataset=` defaults to `"production"`. CSV/TSV take `?tab=`
  (0-based, default 0); xlsx/md/html convert the whole document. xlsx, csv,
  tsv and md send as attachments; html renders inline (it is a viewable
  page).
  """

  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.{Csv, Html, Markdown, XlsxExport}

  @default_dataset "production"
  @xlsx_mime "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  def export_xlsx(conn, %{"slug" => slug} = params) do
    with {:ok, doc} <- fetch_sheet(slug, params),
         {:ok, binary} <- build_xlsx(doc, slug) do
      conn
      |> put_resp_content_type(@xlsx_mime, nil)
      |> attachment("#{slug}.xlsx")
      |> send_resp(200, binary)
    else
      error -> error_json(conn, error)
    end
  end

  def export_csv(conn, params), do: delimited(conn, params, ",", "csv", "text/csv")

  def export_tsv(conn, params),
    do: delimited(conn, params, "\t", "tsv", "text/tab-separated-values")

  def export_md(conn, %{"slug" => slug} = params) do
    case fetch_sheet(slug, params) do
      {:ok, doc} ->
        conn
        |> put_resp_content_type("text/markdown")
        |> attachment("#{slug}.md")
        |> send_resp(200, Markdown.export(doc.content || %{}))

      error ->
        error_json(conn, error)
    end
  end

  def export_html(conn, %{"slug" => slug} = params) do
    case fetch_sheet(slug, params) do
      {:ok, doc} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, Html.export(doc.content || %{}, doc.title || slug))

      error ->
        error_json(conn, error)
    end
  end

  defp delimited(conn, %{"slug" => slug} = params, sep, ext, mime) do
    with {:ok, doc} <- fetch_sheet(slug, params),
         {:ok, tab_index} <- tab_index(params),
         {:ok, text} <- export_tab(doc, tab_index, sep) do
      conn
      |> put_resp_content_type(mime)
      |> attachment("#{slug}.#{ext}")
      |> send_resp(200, text)
    else
      error -> error_json(conn, error)
    end
  end

  # Draft first (the working copy the import path writes), published
  # fallback — both ids resolve via the Content draft/published helpers.
  defp fetch_sheet(slug, params) do
    dataset =
      case params["dataset"] do
        d when is_binary(d) and d != "" -> d
        _ -> @default_dataset
      end

    # M1 read-your-writes: a live session's memory is authoritative — ask it
    # to persist its debounced state before the read. Cheap, and a no-op
    # when no session is live for this sheet.
    Barkpark.Sheets.Session.flush(slug, dataset)

    with {:error, :not_found} <-
           Content.get_document(Content.draft_id(slug), "sheet", dataset),
         {:error, :not_found} <-
           Content.get_document(Content.published_id(slug), "sheet", dataset) do
      {:error, :not_found, "not_found",
       "no sheet #{inspect(slug)} in dataset #{inspect(dataset)}"}
    else
      {:ok, doc} -> {:ok, doc}
    end
  end

  defp build_xlsx(doc, slug) do
    case XlsxExport.to_binary(doc.content || %{}, "#{slug}.xlsx") do
      {:ok, binary} -> {:ok, binary}
      {:error, message} -> {:error, :unprocessable_entity, "export_failed", message}
    end
  end

  defp tab_index(params) do
    case params["tab"] do
      nil ->
        {:ok, 0}

      raw ->
        case Integer.parse(to_string(raw)) do
          {n, ""} when n >= 0 ->
            {:ok, n}

          _ ->
            {:error, :unprocessable_entity, "invalid_tab",
             "tab must be a non-negative integer, got #{inspect(raw)}"}
        end
    end
  end

  defp export_tab(doc, tab_index, sep) do
    case Csv.export(doc.content || %{}, tab_index, sep) do
      {:ok, text} ->
        {:ok, text}

      {:error, :tab_not_found} ->
        {:error, :not_found, "tab_not_found", "the sheet has no tab #{tab_index}"}
    end
  end

  defp attachment(conn, filename) do
    put_resp_header(conn, "content-disposition", ~s(attachment; filename="#{filename}"))
  end

  defp error_json(conn, {:error, status, code, message}) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
