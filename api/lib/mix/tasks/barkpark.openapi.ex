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

  That determinism is not a promise, it is an assert: see "generation is
  byte-deterministic" in `test/barkpark/api/openapi_test.exs`, alongside the
  two mutation asserts proving that a new route and an edited help string each
  MOVE these bytes. They exist because a nondeterministic generator would make
  the CI drift gate unwinnable — "just regenerate and commit" is only a fair
  instruction if the same tree always produces the same file
  (task-openapi-drift-chronic).

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
        # Same remedy string the CI drift gate prints
        # (.github/workflows/elixir.yml, "OpenAPI drift check"). ONE canonical
        # command, spelled identically everywhere it is demanded — a gate that
        # names a different incantation than the docs is how the regen habit
        # failed to form in the first place (task-openapi-drift-chronic).
        IO.puts(:stderr, """
        #{@path} is STALE.

        Regenerate it from the repo root:

            cd api && mix barkpark.openapi && cd .. && git add docs/openapi.json

        Generation is byte-deterministic, so the resulting diff is exactly the
        descriptor change your edit implies — review it and commit it with the
        change, not in a follow-up PR.
        """)

        System.halt(1)
    end
  end
end
