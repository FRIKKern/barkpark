defmodule Barkpark.Plugins.Tickets.CLITest do
  @moduledoc """
  Contract test for the Tickets CLI manifest surface (charter Decision 5 + the
  pinned route table). PURE — no app, no DB, no registry boot: it inspects the
  static command maps `Tickets.CLI.commands/0` returns.

  Mirrors `Barkpark.Plugins.CliCommandsManifestTest`: every command map carries
  the frozen `cli_command()` field shape, is grounded in a route the Tickets
  plugin actually mounts (the charter route table), has a unique id, and hangs
  under exactly the `ticket` / `ticket-key` nouns — so the Go manifest renderer
  and `Capabilities.project/2` see the byte-compatible shape they expect.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Tickets.CLI

  # The charter's pinned route table (Wave 1), expressed as the ABSOLUTE
  # path_templates the routes mount at: the `:ticket_key` + `:token_root` buckets
  # mount under `/v1`, the admin key-management bucket under `/v1/plugins`. Every
  # cli command's http.path_template MUST be one of these — no invented endpoints.
  @charter_routes MapSet.new([
                    # submitter (:ticket_key)
                    "/v1/tickets",
                    "/v1/tickets/:id",
                    "/v1/tickets/:id/messages",
                    "/v1/tickets/:id/attachments",
                    "/v1/tickets/:id/attachments/:asset_id",
                    # operator (:token_root)
                    "/v1/tickets/inbox",
                    "/v1/tickets/inbox/:id",
                    "/v1/tickets/inbox/:id/attachments/:asset_id",
                    "/v1/tickets/:id/answer",
                    "/v1/tickets/:id/close",
                    # key management (:api admin, /v1/plugins)
                    "/v1/plugins/tickets/keys",
                    "/v1/plugins/tickets/keys/:id/rotate",
                    "/v1/plugins/tickets/keys/:id/pause",
                    "/v1/plugins/tickets/keys/:id/unpause",
                    "/v1/plugins/tickets/keys/:id"
                  ])

  # The frozen top-level keys every cli_command() map must carry (the Go
  # manifest decoder + the schema's `required` list). scoped_prefix is optional.
  @required_keys ~w(id noun verb summary http auth_tier args flags writes batch paginated dry_run default_output)a

  @valid_tiers ~w(none read write admin scoped_admin ingest)
  @valid_outputs ~w(table json yaml minimal)
  @valid_methods ~w(GET POST PUT PATCH DELETE)

  describe "CLI.commands/0 — frozen field shape" do
    test "every command carries the required cli_command() keys" do
      for cmd <- CLI.commands() do
        for key <- @required_keys do
          assert Map.has_key?(cmd, key),
                 "command #{inspect(cmd[:id])} is missing required key #{inspect(key)}"
        end

        assert %{method: method, path_template: path} = cmd.http
        assert method in @valid_methods, "#{cmd.id}: bad HTTP method #{inspect(method)}"
        assert is_binary(path) and String.starts_with?(path, "/v1/")

        assert cmd.auth_tier in @valid_tiers, "#{cmd.id}: bad auth_tier #{inspect(cmd.auth_tier)}"

        assert cmd.default_output in @valid_outputs,
               "#{cmd.id}: bad default_output #{inspect(cmd.default_output)}"

        assert is_list(cmd.args)
        assert is_list(cmd.flags)
        assert is_boolean(cmd.writes)
        assert is_boolean(cmd.batch)
        assert is_boolean(cmd.paginated)
        assert is_boolean(cmd.dry_run)
      end
    end

    test "every arg declares name/required/type/summary; every flag declares name/type/summary" do
      for cmd <- CLI.commands() do
        for arg <- cmd.args do
          assert Map.has_key?(arg, :name)
          assert Map.has_key?(arg, :required)
          assert Map.has_key?(arg, :type)
          assert Map.has_key?(arg, :summary)
        end

        for flag <- cmd.flags do
          assert Map.has_key?(flag, :name)
          assert Map.has_key?(flag, :type)
          assert Map.has_key?(flag, :summary)
        end
      end
    end
  end

  describe "CLI.commands/0 — grounded in the charter route table" do
    test "every path_template matches a charter route (no invented endpoints)" do
      for cmd <- CLI.commands() do
        assert MapSet.member?(@charter_routes, cmd.http.path_template),
               "#{cmd.id}: path #{inspect(cmd.http.path_template)} is not in the charter route table"
      end
    end

    test "path args match the :placeholders in their path_template" do
      for cmd <- CLI.commands() do
        placeholders =
          Regex.scan(~r/:([a-z_]+)/, cmd.http.path_template)
          |> Enum.map(fn [_, name] -> name end)
          |> MapSet.new()

        arg_names = MapSet.new(cmd.args, & &1.name)

        # Every :placeholder must be satisfied by a declared arg (the CLI binds
        # path params like `:id` from positional args).
        for ph <- placeholders do
          assert MapSet.member?(arg_names, ph),
                 "#{cmd.id}: path placeholder :#{ph} has no matching declared arg"
        end
      end
    end
  end

  describe "CLI.commands/0 — ids + nouns" do
    test "ids are unique" do
      ids = Enum.map(CLI.commands(), & &1.id)
      assert length(ids) == length(Enum.uniq(ids)), "duplicate command ids: #{inspect(ids)}"
    end

    test "the charter-pinned command ids are all present, and nothing extra" do
      ids = CLI.commands() |> Enum.map(& &1.id) |> Enum.sort()

      expected =
        Enum.sort([
          "ticket.inbox",
          "ticket.show",
          "ticket.answer",
          "ticket.close",
          "ticket-key.mint",
          "ticket-key.ls",
          "ticket-key.rotate",
          "ticket-key.pause",
          "ticket-key.unpause",
          "ticket-key.revoke"
        ])

      assert ids == expected
    end

    test "nouns are exactly \"ticket\" and \"ticket-key\"" do
      nouns = CLI.commands() |> Enum.map(& &1.noun) |> Enum.uniq() |> Enum.sort()
      assert nouns == ["ticket", "ticket-key"]

      # id prefix agrees with the noun (ticket-key.mint hangs under "ticket-key",
      # not the "ticket" noun the shared prefix could be mistaken for).
      for cmd <- CLI.commands() do
        assert String.starts_with?(cmd.id, cmd.noun <> "."),
               "#{cmd.id}: id prefix disagrees with noun #{inspect(cmd.noun)}"
      end
    end
  end

  describe "CLI.commands/0 — auth tiers + write semantics" do
    test "every `ticket` verb is read-tier, every `ticket-key` verb is admin-tier" do
      for cmd <- CLI.commands() do
        case cmd.noun do
          "ticket" -> assert cmd.auth_tier == "read", "#{cmd.id} should be read-tier"
          "ticket-key" -> assert cmd.auth_tier == "admin", "#{cmd.id} should be admin-tier"
        end
      end
    end

    test "the mutating verbs write; the read verbs don't" do
      by_id = Map.new(CLI.commands(), &{&1.id, &1})

      for id <- ~w(ticket.answer ticket.close
                   ticket-key.mint ticket-key.rotate ticket-key.pause
                   ticket-key.unpause ticket-key.revoke) do
        assert by_id[id].writes, "#{id} must set writes: true"
      end

      for id <- ~w(ticket.inbox ticket.show ticket-key.ls) do
        refute by_id[id].writes, "#{id} must be a read (writes: false)"
      end
    end

    test "answer declares the --close bool flag (answer-and-close in one write)" do
      answer = Enum.find(CLI.commands(), &(&1.id == "ticket.answer"))
      close_flag = Enum.find(answer.flags, &(&1.name == "close"))
      assert close_flag, "ticket.answer must declare the --close flag"
      assert close_flag.type == "bool"
    end

    test "mint takes a name arg and defaults to table output (the handoff card)" do
      mint = Enum.find(CLI.commands(), &(&1.id == "ticket-key.mint"))
      assert Enum.any?(mint.args, &(&1.name == "name" and &1.required))
      # Default output must NOT be `minimal` — the quickstart handoff card is the
      # primary human output, and a minimal receipt would hide the raw key.
      assert mint.default_output == "table"
    end
  end
end
