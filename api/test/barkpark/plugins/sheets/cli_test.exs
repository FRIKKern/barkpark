defmodule Barkpark.Plugins.Sheets.CLITest do
  @moduledoc """
  Contract test for the Sheets CLI manifest surface.

  PURE — no app, no DB, no registry boot: it inspects the static command maps
  `Sheets.CLI.commands/0` returns, and grounds them against the route specs
  `Sheets.register_routes/1` returns.

  Mirrors `Barkpark.Plugins.Tickets.CLITest`, with one deliberate difference:
  the route table is DERIVED from `register_routes/1` rather than hand-copied
  into the test. A hand-copied table drifts silently the moment someone adds a
  route (which is exactly the defect that left this whole plugin with eight
  routes and zero commands), so here the two are asserted against each other in
  both directions.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets
  alias Barkpark.Plugins.Sheets.CLI

  # `:ingest` routes mount under `/v1/plugins` (router.ex's
  # `plugin_routes(scope: :ingest)` block), so a spec's sub-path becomes this
  # absolute path_template.
  @ingest_mount "/v1/plugins"

  @required_keys ~w(id noun verb summary http auth_tier args flags writes batch paginated dry_run default_output)a
  @valid_tiers ~w(none read write admin scoped_admin ingest)
  @valid_outputs ~w(table json yaml minimal)
  @valid_methods ~w(GET POST PUT PATCH DELETE)

  # {METHOD, absolute path} for every :ingest route the plugin mounts. The
  # `:public_root` LiveView reader is excluded: it is an HTML page, not a verb.
  defp ingest_routes do
    for {verb, path, _mod, _action, opts} <- Sheets.register_routes(%{}),
        Keyword.get(opts, :auth) == :ingest,
        into: MapSet.new() do
      {verb |> Atom.to_string() |> String.upcase(), @ingest_mount <> path}
    end
  end

  defp command_routes do
    MapSet.new(CLI.commands(), fn cmd -> {cmd.http.method, cmd.http.path_template} end)
  end

  describe "CLI.commands/0 — frozen field shape" do
    test "every command carries the required cli_command() keys with valid values" do
      commands = CLI.commands()

      # Anti-vacuity: the loop below passes for free over an empty list, and the
      # command list is BUILT (export_commands/0 comprehends over @exports), so
      # it can collapse. Compared against the mounted-route count rather than a
      # literal, so the floor tracks the plugin instead of going stale.
      assert length(commands) == MapSet.size(ingest_routes()),
             "expected one command per :ingest route, got #{length(commands)}"

      for cmd <- commands do
        for key <- @required_keys do
          assert Map.has_key?(cmd, key),
                 "command #{inspect(cmd[:id])} is missing required key #{inspect(key)}"
        end

        assert %{method: method, path_template: path} = cmd.http
        assert method in @valid_methods, "#{cmd.id}: bad HTTP method #{inspect(method)}"

        assert is_binary(path) and String.starts_with?(path, "/v1/plugins/sheets"),
               "#{cmd.id}: path_template #{inspect(path)} is not a sheets route"

        assert cmd.auth_tier in @valid_tiers, "#{cmd.id}: bad auth_tier #{inspect(cmd.auth_tier)}"

        assert cmd.default_output in @valid_outputs,
               "#{cmd.id}: bad default_output #{inspect(cmd.default_output)}"

        assert is_boolean(cmd.writes) and is_boolean(cmd.batch) and
                 is_boolean(cmd.paginated) and is_boolean(cmd.dry_run)

        assert is_list(cmd.args) and is_list(cmd.flags)
      end
    end

    test "ids are unique and every command hangs under the `sheets` noun" do
      commands = CLI.commands()
      ids = Enum.map(commands, & &1.id)

      assert ids == Enum.uniq(ids), "duplicate command ids: #{inspect(ids -- Enum.uniq(ids))}"

      # `Capabilities.plugin_noun_index/1` maps a command's noun to its plugin
      # through the plugin NAME, so a noun that is not "sheets" would lose its
      # `source: "plugin:sheets"` provenance and its noun entry.
      for cmd <- commands do
        assert cmd.noun == "sheets", "#{cmd.id}: noun #{inspect(cmd.noun)} is not `sheets`"
      end
    end

    test "every path arg is a real `:placeholder` in the command's own path" do
      for cmd <- CLI.commands(), arg <- cmd.args, arg.name != "file" do
        placeholders =
          cmd.http.path_template
          |> String.split("/")
          |> Enum.filter(&String.starts_with?(&1, ":"))
          |> Enum.map(&String.trim_leading(&1, ":"))

        assert arg.name in placeholders or cmd.http.method != "GET",
               "#{cmd.id}: arg #{inspect(arg.name)} is not a placeholder in #{cmd.http.path_template}"
      end
    end
  end

  describe "commands ↔ mounted routes" do
    test "every command names a route the plugin actually mounts" do
      routes = ingest_routes()
      assert MapSet.size(routes) > 0, "register_routes/1 exposed no :ingest routes to check"

      ungrounded = MapSet.difference(command_routes(), routes)

      assert MapSet.size(ungrounded) == 0,
             """
             Sheets CLI command(s) point at an endpoint the plugin does not mount \
             — `bp` would render the verb and the server would 404 it:

             #{ungrounded |> Enum.sort() |> Enum.map_join("\n", fn {m, p} -> "  #{m} #{p}" end)}
             """
    end

    test "every mounted :ingest route has a command" do
      uncovered = MapSet.difference(ingest_routes(), command_routes())

      assert MapSet.size(uncovered) == 0,
             """
             Sheets mount(s) an :ingest route with no CLI command — a live \
             capability with no `bp` verb and no OpenAPI operation, which is the \
             exact defect this module was written to close:

             #{uncovered |> Enum.sort() |> Enum.map_join("\n", fn {m, p} -> "  #{m} #{p}" end)}
             """
    end

    test "every command is ingest-tier, matching the bucket its route rides" do
      # All eight HTTP routes mount on `:ingest` (RequireIngestToken). A command
      # claiming a lower tier would be advertised to callers whose credential the
      # route rejects.
      for cmd <- CLI.commands() do
        assert cmd.auth_tier == "ingest",
               "#{cmd.id}: tier #{inspect(cmd.auth_tier)} but its route rides the :ingest bucket"
      end
    end
  end
end
