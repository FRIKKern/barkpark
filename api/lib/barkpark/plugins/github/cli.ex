defmodule Barkpark.Plugins.Github.CLI do
  @moduledoc """
  GitHub — the `bp` CLI manifest surface, folded into `GET /v1/capabilities`.

  The API design IS the CLI design: the operator verb `bp github adopt <task>`
  falls out of the capabilities manifest with ZERO bespoke Go code (the Tickets
  precedent). This module returns the command map(s) in the frozen
  `cli_command()` shape (`docs/cli/manifest.schema.json#/$defs/command`); the
  plugin module `github.ex` delegates its `cli_commands/0` here via
  `Code.ensure_loaded?(Github.CLI)`, so the two slices merge cleanly across
  worktrees even when only one of them has landed.

  ## One verb (this wave): `github adopt`

  `adopt` flips a born-dark `src:github` intake task into Barkpark ownership —
  strips `needs-human`, sets `content.github.state = "adopted"`, posts a
  backlink comment on the source issue. It is `read`-tier and rides the `:token`
  bucket at `POST /v1/plugins/github/adopt/:id`: a bearer-gated OPERATOR action,
  NOT admin — an operator with a normal token runs it. `writes: true` (it mutates
  the task). It NEVER auto-claims (charter D6); a human claims the adopted task
  afterward through the normal `bp task` path.
  """

  @doc """
  The `github` CLI command maps, in the frozen `cli_command()` shape.

  Consumed by `Barkpark.Plugins.Github.cli_commands/0` (the plugin delegate) and
  folded into the capabilities manifest by the capabilities controller, which
  stamps `source: "plugin:github"` provenance from the `github` noun.
  """
  @spec commands() :: [map()]
  def commands do
    [
      %{
        id: "github.adopt",
        noun: "github",
        verb: "adopt",
        summary:
          "Adopt a src:github intake task into Barkpark (strip needs-human, flip ownership, post a backlink). Never auto-claims.",
        http: %{method: "POST", path_template: "/v1/plugins/github/adopt/:id"},
        auth_tier: "read",
        args: [
          %{name: "id", required: true, type: "string", summary: "Task id (gh-<num>)."}
        ],
        flags: [
          %{name: "dataset", type: "string", summary: "Dataset.", default: "production"}
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      }
    ]
  end
end
