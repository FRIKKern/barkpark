defmodule Barkpark.Plugins.Sheets.Web.ImportController do
  @moduledoc """
  POST /v1/plugins/sheets/import — multipart spreadsheet import (M5).

  Mounted by `Barkpark.Plugins.Sheets.register_routes/1` on the `:ingest`
  bucket — shared-secret bearer token via `RequireIngestToken`, exactly like
  the Bulldocs ingest API.

      POST /v1/plugins/sheets/import
      Authorization: Bearer <ingest token>
      Content-Type: multipart/form-data
      file=<upload .xlsx | .csv | .tsv>   (required)
      slug=<doc id>                       (optional — defaults to the
                                           slugified file basename)
      title=<title>                       (optional — defaults to the
                                           file basename)
      dataset=<dataset>                   (optional — "production")
      sep=<"," | ";" | "\t">              (optional — csv/tsv only; overrides
                                           the quote-aware separator sniff)

  The kind is detected from the filename extension (content-type fallback).
  For csv/tsv the raw bytes are first transcoded to UTF-8 (`Csv.normalize_encoding/1`
  handles UTF-16 BOM streams and Windows-1252 "ANSI CSV"), then the separator
  is resolved — an explicit `sep` param, else `Csv.sniff_separator/2`.
  Conversion goes through `XlsxImport` / `Csv`; the document persists via
  `Content.upsert_document/4` (idempotent re-imports), so the formula
  engine recompute and the embed write-through ride the canonical save
  path — unknown functions keep the file's cached value with
  `"stale" => true`, per the bound grill decision.

  Caps (both reject with **413** — Plug's `:request_entity_too_large`; the
  JSON shape stays the codebase's `%{error: %{code, message}}` envelope):

    * **bytes** — uploads over 15_000_000 bytes reject on the on-disk size
      BEFORE any bytes are read or parsed (xlsx decompression is unbounded;
      the multipart layer alone accepts far more).
    * **cells** — more than `Barkpark.Plugins.Sheets.cell_cap/0` non-empty
      cells rejects, enforced incrementally inside the converters (the fold
      aborts the moment the running count exceeds the cap, never
      materializing the rest); `check_cap/1` stays as a post-hoc backstop.
  """

  use BarkparkWeb, :controller

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  alias Barkpark.Content
  alias Barkpark.Plugins.Sheets
  alias Barkpark.Plugins.Sheets.{Csv, XlsxImport}
  alias Barkpark.Tenancy

  @byte_cap 15_000_000
  @default_dataset "production"
  @slug_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/

  def create(conn, params) do
    with {:ok, upload} <- fetch_upload(params),
         {:ok, kind} <- detect_kind(upload),
         :ok <- check_byte_cap(upload),
         {:ok, raw} <- read_upload(upload),
         {:ok, content} <- convert(kind, raw, params),
         {:ok, cell_count} <- check_cap(content),
         {:ok, slug, title, dataset} <- resolve_identity(params, upload),
         {:ok, doc} <- save(conn, slug, title, dataset, content) do
      json(conn, %{
        ok: true,
        slug: slug,
        doc_id: doc.doc_id,
        dataset: dataset,
        type: "sheet",
        tabs: length(Map.get(content, "tabs", [])),
        cells: cell_count
      })
    else
      {:error, status, code, message} ->
        conn
        |> put_status(status)
        |> json(%{error: %{code: code, message: message}})
    end
  end

  defp fetch_upload(%{"file" => %Plug.Upload{} = upload}), do: {:ok, upload}

  defp fetch_upload(_params),
    do:
      {:error, :unprocessable_entity, "missing_file",
       "multipart field \"file\" is required (xlsx, csv or tsv)"}

  defp detect_kind(%Plug.Upload{filename: filename, content_type: content_type}) do
    case filename |> to_string() |> Path.extname() |> String.downcase() do
      ".xlsx" ->
        {:ok, :xlsx}

      ".csv" ->
        {:ok, :csv}

      ".tsv" ->
        {:ok, :tsv}

      _ ->
        case content_type do
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" ->
            {:ok, :xlsx}

          "text/csv" ->
            {:ok, :csv}

          "text/tab-separated-values" ->
            {:ok, :tsv}

          _ ->
            {:error, :unprocessable_entity, "unsupported_format",
             "unsupported file #{inspect(filename)} — expected .xlsx, .csv or .tsv"}
        end
    end
  end

  # Cheap pre-parse guard on the on-disk byte size — nothing is read into
  # memory and nothing parses before this passes.
  defp check_byte_cap(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @byte_cap ->
        {:error, :request_entity_too_large, "upload_too_large",
         "upload is #{size} bytes; the cap is #{@byte_cap}"}

      {:ok, _stat} ->
        :ok

      {:error, reason} ->
        {:error, :unprocessable_entity, "unreadable_upload", "#{reason}"}
    end
  end

  # Sobelow Traversal.FileModule false-positive: `path` is `Plug.Upload.path` —
  # the framework-managed temp file Plug wrote the multipart body to, NOT a
  # user-supplied name. The attacker-controlled `filename` is used only for
  # extension detection (`detect_kind/1`) and slug derivation (`resolve_identity/2`,
  # which slugifies + regex-validates it); it never reaches `File.read`. No
  # request string is joined into this path, so directory traversal is impossible.
  # Pinned by `ImportControllerTest` "a traversal-laden filename reads the upload
  # temp path, never the named path".
  # sobelow_skip ["Traversal.FileModule"]
  defp read_upload(%Plug.Upload{path: path}) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, :unprocessable_entity, "unreadable_upload", "#{reason}"}
    end
  end

  @sep_options [",", ";", "\t"]

  defp convert(:xlsx, raw, _params), do: wrap_convert(XlsxImport.to_content(raw), "invalid_xlsx")
  defp convert(:csv, raw, params), do: convert_delimited(raw, params, ",", "invalid_csv")
  defp convert(:tsv, raw, params), do: convert_delimited(raw, params, "\t", "invalid_tsv")

  # Import hygiene ordering: transcode to UTF-8, THEN resolve the separator
  # (explicit `sep` param, else quote-aware sniff), THEN parse/infer.
  defp convert_delimited(raw, params, default_sep, code) do
    case Csv.normalize_encoding(raw) do
      {:ok, text} ->
        sep = resolve_sep(params["sep"], text, default_sep)
        wrap_convert(Csv.import_content(text, sep), code)

      {:error, message} ->
        {:error, :unprocessable_entity, code, message}
    end
  end

  defp resolve_sep(sep, _text, _default) when sep in @sep_options, do: sep
  defp resolve_sep(_sep, text, default), do: Csv.sniff_separator(text, default)

  defp wrap_convert({:ok, content}, _code), do: {:ok, content}

  # The converters abort their fold the moment the running non-empty-cell
  # count exceeds the cap — `count` is a lower bound on the full total.
  defp wrap_convert({:error, {:cell_cap_exceeded, count}}, _code),
    do:
      {:error, :request_entity_too_large, "sheet_too_large",
       "import carries at least #{count} non-empty cells; the cap is #{Sheets.cell_cap()}"}

  # An xlsx whose declared decompressed size exceeds the pre-extract ceiling is a
  # decompression bomb — same 413 class as the cell cap, refused before inflate.
  defp wrap_convert({:error, :xlsx_decompressed_size_exceeded}, _code),
    do:
      {:error, :request_entity_too_large, "sheet_too_large",
       "xlsx decompressed size exceeds the import ceiling"}

  defp wrap_convert({:error, message}, code),
    do: {:error, :unprocessable_entity, code, message}

  # Post-hoc backstop — the converters enforce the cap incrementally, so
  # this only fires for content that arrived through some other seam.
  defp check_cap(content) do
    count = cell_count(content)

    if count > Sheets.cell_cap() do
      {:error, :request_entity_too_large, "sheet_too_large",
       "import carries #{count} non-empty cells; the cap is #{Sheets.cell_cap()}"}
    else
      {:ok, count}
    end
  end

  defp cell_count(content) do
    for tab <- Map.get(content, "tabs", []),
        is_map(tab),
        {_addr, cell} <- Map.get(tab, "cells") || %{},
        is_map(cell),
        Map.get(cell, "v") not in [nil, ""] or is_binary(Map.get(cell, "f")),
        reduce: 0 do
      acc -> acc + 1
    end
  end

  defp resolve_identity(params, %Plug.Upload{filename: filename}) do
    base = filename |> to_string() |> Path.basename() |> Path.rootname()

    slug =
      case params["slug"] do
        s when is_binary(s) and s != "" -> s
        _ -> Tenancy.slugify(base)
      end

    title =
      case params["title"] do
        t when is_binary(t) and t != "" -> t
        _ -> base
      end

    dataset =
      case params["dataset"] do
        d when is_binary(d) and d != "" -> d
        _ -> @default_dataset
      end

    if is_binary(slug) and Regex.match?(@slug_pattern, slug) do
      {:ok, slug, title, dataset}
    else
      {:error, :unprocessable_entity, "invalid_slug",
       "cannot derive a usable slug from #{inspect(params["slug"] || base)}"}
    end
  end

  # The write carries the caller's tenancy scope (task-ef3eb91bf7f87d4c).
  # Without it `Content.WriteScope.resolve_write_scope/1` fell through to the
  # seeded Default for EVERY import, so an admin token bound to workspace B
  # imported into Default and then could not export what it had just written
  # once the read became scoped. Import and export now name the SAME tenant.
  # The nil-scope posture is unchanged: an unresolved request yields the
  # `:shared_only` sentinel, which `resolve_write_scope/1` collapses to nil and
  # stamps Default exactly as before.
  defp save(conn, slug, title, dataset, content) do
    case Content.upsert_document(
           "sheet",
           %{"doc_id" => slug, "title" => title, "content" => content},
           dataset,
           [source: "sheets_import"] ++ scope_opts(conn)
         ) do
      {:ok, doc} ->
        {:ok, doc}

      {:error, {:halted, reason}} ->
        {:error, :unprocessable_entity, "invalid_sheet", to_string(reason)}

      {:error, _changeset} ->
        {:error, :unprocessable_entity, "invalid_sheet", "could not store sheet"}
    end
  end
end
