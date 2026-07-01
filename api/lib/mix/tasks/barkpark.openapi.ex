defmodule Mix.Tasks.Barkpark.Openapi do
  @moduledoc """
  Regenerate (or verify) the checked-in OpenAPI 3.1 descriptor at
  `docs/openapi.json`.

      mix barkpark.openapi          # write docs/openapi.json
      mix barkpark.openapi --check  # exit 1 if the file is stale (CI drift gate)

  The generation source is `Barkpark.Api.OpenApi.spec/0` — the same capabilities
  manifest the `/v1/capabilities` endpoint serves — so a route added to the
  registry without regenerating fails the `--check` gate. The spec carries no
  timestamp (`info.version` is the app vsn, not a `generated_at`), so generation
  is deterministic and the drift check is meaningful.

  `app.start` is required because the manifest reads the running plugin
  `Registry`; the checked-in artifact must be generated with the app started so
  plugin routes are present.
  """
  @shortdoc "Generate/verify docs/openapi.json"

  use Mix.Task

  # The canonical artifact lives at the REPO-ROOT docs/ (alongside api-v1.md §9,
  # the error-table source). The mix task runs inside the `api/` Mix project, so
  # the path is one level up.
  @path "../docs/openapi.json"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    next = Jason.encode!(Barkpark.Api.OpenApi.spec(), pretty: true) <> "\n"

    if "--check" in args do
      check(next)
    else
      File.write!(@path, next)
      IO.puts("wrote #{@path}")
    end
  end

  defp check(next) do
    case File.read(@path) do
      {:ok, ^next} ->
        IO.puts("#{@path} up to date")

      _ ->
        IO.puts(:stderr, "#{@path} is STALE — run `mix barkpark.openapi` and commit the result")
        System.halt(1)
    end
  end
end
