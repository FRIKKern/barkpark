defmodule Mix.Tasks.Barkpark.Codelists.Seed do
  @moduledoc """
  Seed the codelist registry from a publisher-supplied EDItEUR ONIX XML.

  Usage:

      mix barkpark.codelists.seed --plugin onixedit --issue 73 \\
          --source path/to/onix-codelists.xml

  ## Source resolution (BYO model — Phase 4 D21)

  Path is resolved in this order:

    1. `--source PATH` argument
    2. `BARKPARK_ONIX_CODELIST_PATH` environment variable
    3. `Barkpark.Plugins.Settings.get/1` → `"codelist_path"`

  When all three are unset, the task prints a guided message pointing at
  the Studio first-boot wizard and exits 1. **No silent failure.**

  ## Issue versioning

  `--issue` is required. Re-running with the same issue is a no-op
  (idempotent re-registration). Re-running with a *different* issue
  inserts a new codelist row alongside the previous one — issue 73 and
  issue 74 of the same list_id can coexist.

  ## License

  Barkpark ships the parser only. Publishers fetch the XML snapshot from
  the EDItEUR website themselves; redistribution is not granted by this
  repo. See `docs/plugins/codelists-byo.md`.
  """
  @shortdoc "Seed the codelist registry from an EDItEUR ONIX XML snapshot"

  use Mix.Task

  alias Barkpark.Codelists.EDItEUR

  @switches [
    plugin: :string,
    issue: :string,
    version: :string,
    source: :string,
    repo: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("unknown switches: #{inspect(invalid)}")
    end

    plugin = Keyword.get(opts, :plugin, "onixedit")
    issue = Keyword.get(opts, :issue) || Keyword.get(opts, :version)

    if is_nil(issue) or issue == "" do
      Mix.raise("--issue VERSION is required (e.g. --issue 73)")
    end

    source =
      case EDItEUR.resolve_source(plugin: plugin, source: Keyword.get(opts, :source)) do
        {:ok, path} ->
          path

        {:error, :not_found} ->
          Mix.shell().error(first_boot_message())
          exit({:shutdown, 1})
      end

    Mix.shell().info("==> seeding codelists for #{plugin} from #{source} (issue #{issue})")

    Mix.Task.run("app.start")

    case EDItEUR.parse_xml(source, plugin: plugin) do
      {:ok, parsed} ->
        case EDItEUR.seed(parsed, plugin: plugin, issue: issue) do
          {:ok, list_ids} ->
            Mix.shell().info("==> seeded #{length(list_ids)} codelist(s):")

            Enum.each(list_ids, fn id ->
              Mix.shell().info("    - #{id}")
            end)

            :ok

          {:error, reason} ->
            Mix.raise("seed failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("parse failed: #{inspect(reason)}")
    end
  end

  defp first_boot_message do
    """
    No EDItEUR codelist source configured.

    Barkpark ships the parser only — publishers bring their own EDItEUR
    ONIX codelist XML snapshot (see docs/plugins/codelists-byo.md).

    Provide a path one of these ways and re-run:

      1. mix barkpark.codelists.seed --source /path/to/onix-codelists.xml ...
      2. export BARKPARK_ONIX_CODELIST_PATH=/path/to/onix-codelists.xml
      3. configure the path via the Studio plugin-settings wizard at /studio
         (sets the "codelist_path" key for plugin "onixedit")
    """
  end
end
