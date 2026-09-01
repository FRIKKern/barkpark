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

  Read-your-writes: every export flushes the live session first. A flush
  whose persist fails is a 503 (`flush_failed`, `retry-after: 2`) — the
  persisted row is stale and must not be served as fresh; the session's
  debounce retry stays armed, so a retry shortly succeeds.

  ## The read is TENANT-SCOPED (task-ef3eb91bf7f87d4c)

  `fetch_sheet/3` threads `BarkparkWeb.ScopeHelpers.scope_opts/1` into both
  `Content.get_document/4` calls. Without it the lookup passed no
  `:workspace_id`, `Content.Scope.scope_to_workspace_or_global/3` took its
  nil→global arm, and ANY ingest-token holder exported ANY tenant's sheet by
  slug — with a same-slug collision across two tenants raising
  `Ecto.MultipleResultsError` (a 500) instead of picking one.

  The scope is real because the `:ingest` pipeline now resolves one:
  `DeriveWorkspaceFromToken` for the admin-token arm, `AssignDefaultScope` for
  the shared-secret arm (see `BarkparkWeb.Plugs.RequireIngestToken`). A
  resolved workspace takes `scope_to_workspace/3`'s strict `workspace_id = ?`
  clause; an unresolved REQUEST gets `ScopeHelpers`' `:shared_only` sentinel,
  which reads the shared layer only. Neither path can reach the permissive
  nil arm, so a forgotten scope here fails CLOSED (404), never open.
  """

  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets.{Csv, Html, Markdown, XlsxExport}

  @default_dataset "production"
  @xlsx_mime "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  # Sobelow XSS.SendResp false-positive: `binary` is the xlsx file bytes from
  # `XlsxExport.to_binary/2`, served under the FIXED office MIME `@xlsx_mime`
  # with `Content-Disposition: attachment` — a binary download, never an
  # HTML/script-executable response body.
  # sobelow_skip ["XSS.SendResp"]
  def export_xlsx(conn, %{"slug" => slug} = params) do
    with {:ok, doc} <- fetch_sheet(conn, slug, params),
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
    case fetch_sheet(conn, slug, params) do
      {:ok, doc} ->
        conn
        |> put_resp_content_type("text/markdown")
        |> attachment("#{slug}.md")
        |> send_resp(200, Markdown.export(doc.content || %{}))

      error ->
        error_json(conn, error)
    end
  end

  # Sobelow XSS.SendResp false-positive: this is a legitimate viewable HTML page
  # (like the `/papers/:slug` reader). Every dynamic value in the body is escaped
  # before it reaches the response: `Html.export/2` HTML-escapes the title and tab
  # names, and every cell value renders through the shared PortableDoc walker
  # (`Barkpark.PortableDoc.Render.Walk.sheet_cell_html/2`), which `escape_html`s
  # plain cells and routes URL cells through the `safe_url/1` scheme allowlist. A
  # `<script>` in a cell renders as inert `&lt;script&gt;` text. The escaping
  # invariant is pinned by `HtmlTest` "cell value with HTML/script is escaped".
  # sobelow_skip ["XSS.SendResp"]
  def export_html(conn, %{"slug" => slug} = params) do
    case fetch_sheet(conn, slug, params) do
      {:ok, doc} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, Html.export(doc.content || %{}, doc.title || slug))

      error ->
        error_json(conn, error)
    end
  end

  # Sobelow XSS.ContentType + XSS.SendResp false-positives: `mime` is NEVER
  # attacker-controlled — the only two callers pass compile-time literals
  # (`export_csv` → "text/csv", `export_tsv` → "text/tab-separated-values"); no
  # request value flows into it. `text` is the CSV/TSV delimited data served with
  # `Content-Disposition: attachment` under that fixed text MIME — a data
  # download, not an HTML/script response body.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp delimited(conn, %{"slug" => slug} = params, sep, ext, mime) do
    with {:ok, doc} <- fetch_sheet(conn, slug, params),
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
  # BOTH reads carry the caller's tenancy scope (see the moduledoc): the
  # `conn` is the only source of it, which is why it is threaded here rather
  # than the slug/params pair alone.
  defp fetch_sheet(conn, slug, params) do
    scope = scope_opts(conn)

    dataset =
      case params["dataset"] do
        d when is_binary(d) and d != "" -> d
        _ -> @default_dataset
      end

    # M1 read-your-writes: a live session's memory is authoritative — ask it
    # to persist its debounced state before the read. Cheap, and a no-op
    # when no session is live for this sheet. A FAILED persist means the
    # row below is stale — surface a clean 503 instead of serving it; the
    # session keeps retrying on its debounce, so the hint is honest.
    case Barkpark.Plugins.Sheets.Session.flush(slug, dataset) do
      :ok ->
        with {:error, :not_found} <-
               Content.get_document(Content.draft_id(slug), "sheet", dataset, scope),
             {:error, :not_found} <-
               Content.get_document(Content.published_id(slug), "sheet", dataset, scope) do
          {:error, :not_found, "not_found",
           "no sheet #{inspect(slug)} in dataset #{inspect(dataset)}"}
        else
          {:ok, doc} -> {:ok, doc}
        end

      {:error, _reason} ->
        {:error, :service_unavailable, "flush_failed",
         "the sheet's latest edits could not be persisted — retry in a few seconds"}
    end
  end

  defp build_xlsx(doc, slug) do
    case XlsxExport.to_binary(doc.content || %{}, "#{slug}.xlsx") do
      {:ok, binary} -> {:ok, binary}
      {:error, message} -> {:error, :unprocessable_entity, "export_build_failed", message}
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

  # The 503 carries the machine-readable retry hint (the session's debounce
  # is 2s, so the next attempt usually lands after the armed retry).
  defp error_json(conn, {:error, :service_unavailable, code, message}) do
    conn
    |> put_resp_header("retry-after", "2")
    |> put_status(:service_unavailable)
    |> json(%{error: %{code: code, message: message}})
  end

  defp error_json(conn, {:error, status, code, message}) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
