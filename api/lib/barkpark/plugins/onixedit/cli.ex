defmodule Barkpark.Plugins.OnixEdit.Cli do
  @moduledoc """
  Ergonomic CLI verbs OnixEdit contributes to the `/v1/capabilities` manifest
  (M3). Grounded ONLY in routes `register_routes/1` actually mounts.

  OnixEdit's single HTTP/API route is the ONIX exporter:

    * `export` — `GET /v1/plugins/onixedit/export/:dataset/:id` streams a `book`
      document as ONIX 3.0 XML. The route's `auth: :api` opt mounts it under the
      host's `[:api, :require_admin]` pipeline, so its required `auth_tier` is
      `"admin"`.

  Its other surfaces are NOT API verbs and so contribute no CLI command:
  `/admin/onixedit/bokbasen` + `/admin/onixedit/staleness` are admin-gated
  browser LiveViews (no flat `http.path_template`), and `publish_to_bokbasen` is
  an `action_handler`/lifecycle side-effect dispatched through the core mutate +
  Studio paths, not a dedicated HTTP route. Declaring `import` / `bokbasen-*` /
  `codelists` verbs would invent endpoints that do not exist, so they are
  intentionally omitted (additive: add them here the day a real route lands).

  Extracted verbatim from `Barkpark.Plugins.OnixEdit.cli_commands/0` behind
  the plugin facade — the callback delegates to `commands/0`. The returned
  list is byte-identical to before.
  """

  @doc """
  The CLI command catalog. Returned unchanged from the former
  `OnixEdit.cli_commands/0` body.
  """
  @spec commands() :: [map()]
  def commands do
    [
      %{
        id: "onixedit.export",
        noun: "onixedit",
        verb: "export",
        summary: "Export a book document as ONIX 3.0 XML.",
        http: %{
          method: "GET",
          path_template: "/v1/plugins/onixedit/export/:dataset/:id"
        },
        auth_tier: "admin",
        args: [
          %{
            name: "dataset",
            required: true,
            type: "string",
            summary: "Dataset (e.g. production)."
          },
          %{name: "id", required: true, type: "string", summary: "Book document id."}
        ],
        flags: [],
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: "/w/:workspace_slug/p/:project_slug"
      }
    ]
  end
end
