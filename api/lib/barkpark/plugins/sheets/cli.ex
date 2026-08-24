defmodule Barkpark.Plugins.Sheets.CLI do
  @moduledoc """
  Sheets — the `bp` CLI manifest surface, folded into `GET /v1/capabilities`.

  Until this module existed the sheets plugin declared EIGHT HTTP routes and
  ZERO CLI commands, so its entire wire API (import, ops, five exports) was a
  live server capability with no `bp` verb and no `/v1/openapi.json` operation:
  reachable by curl, invisible to every generated client. The routes are in
  `Barkpark.Plugins.Sheets.register_routes/1`; the drift guard that now fails on
  this shape is `BarkparkWeb.Contract.RouterManifestDriftTest`.

  ## `import` sends a real multipart body

  `POST /v1/plugins/sheets/import` takes `multipart/form-data`. `bp` used to
  decide multipart by sniffing the route for the substring `"/media"`, so this
  command's declared `type: "file"` arg was serialized as
  `{"file": "<local path>"}` JSON and the server answered `multipart field
  "file" is required`. The verb was therefore withheld on manifest-honesty
  grounds until #14115 made `mediaUploadFileArg/2` read the manifest's own
  declaration instead of the route text. Re-declared and exercised end to end:
  import a csv, `sheets ops` it, `sheets export-csv` it back.

  ## Why export is five commands, not one with a `--format` flag

  A manifest command carries exactly ONE `http.path_template`, and the server
  spells the format in the PATH (`export.xlsx`, `export.csv`, …), not in a
  query param. One command with a format flag would have to lie about its path
  for four of the five formats — and `/v1/openapi.json` is generated from that
  path, so the lie would propagate into the spec. Five honest commands cost
  five entries and stay true to the routes.

  The `/sheets/:slug` LiveView reader (`auth: :public_root`) is deliberately
  absent: it is an HTML page for a browser, not a JSON verb — the OnixEdit CLI
  moduledoc documents the same omission for its two admin LiveViews.
  """

  @doc """
  The sheet CLI command maps, in the frozen `cli_command()` shape
  (`docs/cli/manifest.schema.json#/$defs/command`).

  Consumed by `Barkpark.Plugins.Sheets.cli_commands/0` (the plugin delegate),
  which the capabilities controller folds into the manifest, stamping
  `source: "plugin:sheets"` provenance from the `sheets` noun.
  """
  @spec commands() :: [map()]
  def commands do
    [
      %{
        id: "sheets.import",
        noun: "sheets",
        verb: "import",
        summary:
          "Import a spreadsheet (.xlsx/.csv/.tsv) as a type-`sheet` document; " <>
            "re-importing the same slug is idempotent.",
        http: %{method: "POST", path_template: "/v1/plugins/sheets/import"},
        auth_tier: "ingest",
        args: [
          %{
            name: "file",
            required: true,
            type: "file",
            summary: "Spreadsheet to import (.xlsx, .csv or .tsv). Max 15 MB."
          }
        ],
        flags: [
          %{
            name: "slug",
            type: "string",
            summary: "Document id to write (default: the slugified file basename)."
          },
          %{name: "title", type: "string", summary: "Sheet title (default: the file basename)."},
          %{
            name: "dataset",
            type: "string",
            summary: "Dataset to write into.",
            default: "production"
          },
          %{
            name: "sep",
            type: "string",
            summary:
              "csv/tsv only: override the quote-aware separator sniff (\",\", \";\" or a tab)."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "sheets.ops",
        noun: "sheets",
        verb: "ops",
        summary:
          "Apply a batch of cell and structural ops to a sheet (set_cell, insert_rows, " <>
            "rename_tab, merge_cells, undo/redo, …). Ops apply INDIVIDUALLY — invalid " <>
            "ones land in `errors` with their index while the rest apply.",
        http: %{method: "POST", path_template: "/v1/plugins/sheets/:slug/ops"},
        auth_tier: "ingest",
        args: [
          %{name: "slug", required: true, type: "slug", summary: "Sheet slug to patch."}
        ],
        flags: [
          %{
            name: "file",
            type: "file",
            summary: "Body from a file or - for stdin: {\"ops\": [ … ]}."
          },
          %{
            name: "dataset",
            type: "string",
            summary: "Dataset the sheet lives in.",
            default: "production"
          },
          %{
            name: "request_id",
            type: "string",
            summary:
              "Idempotency key (≤200 bytes): a retry with the same value replays the " <>
                "first reply with `replayed: true` and applies nothing."
          }
        ],
        writes: true,
        batch: true,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      }
    ] ++ export_commands()
  end

  # One command per export route: the format is a PATH suffix on the server, and
  # a manifest command carries exactly one path_template (see the moduledoc).
  @exports [
    {"xlsx", "xlsx", "Excel workbook (all tabs), sent as an attachment.", false},
    {"csv", "csv", "Comma-separated values for ONE tab, sent as an attachment.", true},
    {"tsv", "tsv", "Tab-separated values for ONE tab, sent as an attachment.", true},
    {"md", "md", "Markdown tables (all tabs), sent as an attachment.", false},
    {"html", "html", "HTML rendering (all tabs), served inline.", false}
  ]

  defp export_commands do
    for {format, extension, summary, per_tab?} <- @exports do
      %{
        id: "sheets.export-#{format}",
        noun: "sheets",
        verb: "export-#{format}",
        summary: "Export a sheet as #{summary}",
        http: %{
          method: "GET",
          path_template: "/v1/plugins/sheets/:slug/export.#{extension}"
        },
        auth_tier: "ingest",
        args: [
          %{name: "slug", required: true, type: "slug", summary: "Sheet slug to export."}
        ],
        flags: export_flags(per_tab?),
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      }
    end
  end

  defp export_flags(per_tab?) do
    dataset = %{
      name: "dataset",
      type: "string",
      summary: "Dataset the sheet lives in.",
      default: "production"
    }

    if per_tab? do
      [
        dataset,
        %{name: "tab", type: "int", summary: "0-based tab index to export.", default: 0}
      ]
    else
      [dataset]
    end
  end
end
