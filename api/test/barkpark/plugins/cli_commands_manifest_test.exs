defmodule Barkpark.Plugins.CliCommandsManifestTest do
  @moduledoc """
  M3 coverage: the REAL bundled plugins declare `cli_commands/0`, and those
  commands fold into the capabilities manifest at the right auth tier.

  Two layers, both PURE (no app, no DB, no registry boot):

    1. Each plugin's `cli_commands/0` returns commands grounded in a route the
       plugin actually mounts in `register_routes/1`, with the frozen field
       shape.
    2. Folded into a superset manifest and run through `Capabilities.project/2`,
       the bulldocs (`ingest`) + onixedit (`admin`) commands are VISIBLE to an
       admin caller and HIDDEN from an anonymous (`none`) caller
       (existence-hiding / fresh-install invariant).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.{Bulldocs, Capabilities, OnixEdit}

  # The flat plugin paths these plugins actually register (Bulldocs +
  # OnixEdit `register_routes/1`), prefixed with the host's `/v1/plugins` mount.
  @bulldocs_routes MapSet.new([
                     "/v1/plugins/bulldocs/papers",
                     "/v1/plugins/bulldocs/papers/:slug/ops",
                     "/v1/plugins/bulldocs/intents",
                     "/v1/plugins/bulldocs/intents/:id/processed"
                   ])

  @onixedit_routes MapSet.new(["/v1/plugins/onixedit/export/:dataset/:id"])

  defp atomize_for_manifest(cmds) do
    # The manifest folds atom-keyed cli_command() maps into string keys; mirror
    # that here so project/2 (which reads string keys) sees the same shape.
    Enum.map(cmds, fn cmd ->
      cmd
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
    end)
  end

  describe "Bulldocs.cli_commands/0" do
    test "declares five verbs, all ingest-tier, all grounded in a real route" do
      cmds = Bulldocs.cli_commands()

      ids = Enum.map(cmds, & &1.id)
      assert "bulldocs.publish" in ids
      assert "bulldocs.patch" in ids
      assert "bulldocs.intents" in ids
      assert "bulldocs.intent-processed" in ids

      # Every bulldocs command sits behind the ingest highway bucket.
      assert Enum.all?(cmds, &(&1.auth_tier == "ingest"))

      # Every path_template is a route the plugin actually mounts — no invented
      # endpoints.
      assert Enum.all?(cmds, fn c ->
               MapSet.member?(@bulldocs_routes, c.http.path_template)
             end)

      # The batch patch verb is batch + carries the M3 --if-rev guard flag.
      patch = Enum.find(cmds, &(&1.id == "bulldocs.patch"))
      assert patch.batch
      assert patch.writes
      assert Enum.any?(patch.flags, &(&1.name == "if-rev"))
    end
  end

  describe "OnixEdit.cli_commands/0" do
    test "declares the export verb at admin tier, grounded in the export route" do
      cmds = OnixEdit.cli_commands()

      assert [export] = cmds
      assert export.id == "onixedit.export"
      assert export.auth_tier == "admin"
      assert MapSet.member?(@onixedit_routes, export.http.path_template)
      refute export.writes
    end
  end

  describe "manifest fold + projection (existence-hiding)" do
    # A minimal superset that mirrors how Capabilities.manifest/2 folds plugin
    # commands in: core read/admin commands plus the real plugin commands.
    defp superset do
      core = [
        %{
          "id" => "doc.get",
          "noun" => "doc",
          "verb" => "get",
          "summary" => "…",
          "http" => %{"method" => "GET", "path_template" => "/v1/data/doc/:d/:t/:id"},
          "auth_tier" => "none",
          "args" => [],
          "flags" => [],
          "writes" => false,
          "batch" => false,
          "paginated" => false,
          "dry_run" => false,
          "default_output" => "table",
          "source" => "core"
        }
      ]

      plugin =
        (atomize_for_manifest(Bulldocs.cli_commands()) ++
           atomize_for_manifest(OnixEdit.cli_commands()))
        |> Enum.map(fn c ->
          # stringify the nested http map too, as the controller fold does.
          Map.update!(c, "http", fn h -> Map.new(h, fn {k, v} -> {to_string(k), v} end) end)
        end)

      %{
        "manifest_version" => "1",
        "server" => %{"name" => "t", "version" => "0", "base_url" => "http://localhost:4000"},
        "auth_tier" => "admin",
        "generated_at" => "2026-06-07T12:00:00Z",
        "etag" => "W/\"seed\"",
        "nouns" => [
          %{"name" => "doc", "summary" => "Docs.", "plugin" => nil},
          %{"name" => "bulldocs", "summary" => "Papers.", "plugin" => "bulldocs"},
          %{"name" => "onixedit", "summary" => "ONIX.", "plugin" => "onixedit"}
        ],
        "commands" => core ++ plugin
      }
    end

    defp ids(m), do: m["commands"] |> Enum.map(& &1["id"]) |> MapSet.new()
    defp nouns(m), do: m["nouns"] |> Enum.map(& &1["name"]) |> MapSet.new()

    test "admin caller SEES bulldocs (ingest) + onixedit (admin) commands" do
      admin = Capabilities.project(superset(), "admin")

      assert "bulldocs.publish" in ids(admin)
      assert "bulldocs.patch" in ids(admin)
      assert "onixedit.export" in ids(admin)
      assert "bulldocs" in nouns(admin)
      assert "onixedit" in nouns(admin)
    end

    test "anon (none) caller sees ZERO plugin commands or nouns (fresh-install invariant)" do
      anon = Capabilities.project(superset(), "none")

      # Only the core none-tier read survives.
      assert ids(anon) == MapSet.new(["doc.get"])
      assert nouns(anon) == MapSet.new(["doc"])

      refute "bulldocs.publish" in ids(anon)
      refute "onixedit.export" in ids(anon)
      refute "bulldocs" in nouns(anon)
      refute "onixedit" in nouns(anon)
    end
  end
end
