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

  alias Barkpark.Plugins.{Bulldocs, Capabilities, OnixEdit, Tasks}

  # The flat plugin paths these plugins actually register (Bulldocs +
  # OnixEdit `register_routes/1`), prefixed with the host's `/v1/plugins` mount.
  @bulldocs_routes MapSet.new([
                     "/v1/plugins/bulldocs/papers",
                     "/v1/plugins/bulldocs/papers/:slug/ops",
                     "/v1/plugins/bulldocs/intents",
                     "/v1/plugins/bulldocs/intents/:id/processed"
                   ])

  @onixedit_routes MapSet.new(["/v1/plugins/onixedit/export/:dataset/:id"])

  # The flat `/v1/tasks` paths the Tasks plugin's cli verbs are grounded in
  # (every one is mounted by Tasks.register_routes/1). The content-graph verbs
  # are NOT here — they moved to the CORE verb registry (Goal
  # ges/graph-edge-seam) so they survive the `:plugins, []` kill switch; see
  # the "core graph verbs" describe block below.
  @tasks_paths MapSet.new([
                 "/v1/tasks",
                 "/v1/tasks/ready",
                 "/v1/tasks/prime",
                 "/v1/tasks/claim",
                 "/v1/tasks/:doc_id",
                 "/v1/tasks/:doc_id/claim",
                 "/v1/tasks/:doc_id/close"
               ])

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

  describe "Tasks.cli_commands/0" do
    test "declares the seven task verbs, all read-tier, grounded in a real /v1/tasks route" do
      cmds = Tasks.cli_commands()

      ids = Enum.map(cmds, & &1.id)
      assert "task.ls" in ids
      assert "task.ready" in ids
      assert "task.prime" in ids
      assert "task.get" in ids
      assert "task.claim" in ids
      assert "task.close" in ids
      assert "task.next" in ids
      # The content-graph read verbs are NOT on the Tasks plugin — they moved
      # to CORE (Goal ges/graph-edge-seam) so the kill switch can't drop them.
      refute "task.graph" in ids
      refute "task.graph-orphans" in ids
      refute "task.graph-dangling" in ids
      assert length(cmds) == 7

      # task is no longer a core noun — the verbs moved verbatim onto the Tasks
      # plugin; auth_tier stays "read" (the /v1/tasks scope is bearer-gated, not
      # admin).
      assert Enum.all?(cmds, &(&1.noun == "task"))
      assert Enum.all?(cmds, &(&1.auth_tier == "read"))

      # Every path_template is a route the plugin actually mounts.
      assert Enum.all?(cmds, fn c -> MapSet.member?(@tasks_paths, c.http.path_template) end)

      # claim/close are the writing workflow ops.
      claim = Enum.find(cmds, &(&1.id == "task.claim"))
      close = Enum.find(cmds, &(&1.id == "task.close"))
      assert claim.writes
      assert close.writes
      assert claim.default_output == "minimal"

      # task.claim declares required worker_id body arg (server requires it).
      claim_arg_names = Enum.map(claim.args, & &1.name)
      assert "doc_id" in claim_arg_names
      assert "worker_id" in claim_arg_names
      worker_id_arg = Enum.find(claim.args, &(&1.name == "worker_id"))
      assert worker_id_arg.required

      # task.close declares worker_id + observed_epoch (required) and
      # lifecycle_status (optional) as body args.
      close_arg_names = Enum.map(close.args, & &1.name)
      assert "doc_id" in close_arg_names
      assert "worker_id" in close_arg_names
      assert "observed_epoch" in close_arg_names
      assert "lifecycle_status" in close_arg_names

      close_worker = Enum.find(close.args, &(&1.name == "worker_id"))
      close_epoch = Enum.find(close.args, &(&1.name == "observed_epoch"))
      close_status = Enum.find(close.args, &(&1.name == "lifecycle_status"))
      assert close_worker.required
      assert close_epoch.required
      refute close_status.required

      # task.next is the queue-based atomic claim (POST /v1/tasks/claim):
      # worker_id required, phase_id optional — both body args (no path
      # placeholder on the route).
      next = Enum.find(cmds, &(&1.id == "task.next"))
      assert next.writes
      assert next.default_output == "minimal"
      assert next.http.path_template == "/v1/tasks/claim"

      next_worker = Enum.find(next.args, &(&1.name == "worker_id"))
      next_phase = Enum.find(next.args, &(&1.name == "phase_id"))
      assert next_worker.required
      refute next_phase.required
      refute Enum.any?(next.args, &(&1.name == "doc_id"))
    end

    test "manifest declares every noun its cli verbs use → provenance resolves to plugin:tasks" do
      # The capabilities controller stamps source "plugin:<plugin_name>" by mapping
      # a command's NOUN back to a plugin via that plugin's manifest "nouns"
      # (falling back to the plugin slug). The Tasks plugin's noun ("task") differs
      # from its slug ("tasks"), so plugin.json MUST declare nouns: ["task"] — else
      # provenance silently degrades to a bare "plugin" (regression guard for the
      # bug found in Phase D review).
      manifest = Tasks.manifest()
      declared = manifest["nouns"] || []
      slug = manifest["plugin_name"]

      for noun <- Tasks.cli_commands() |> Enum.map(& &1.noun) |> Enum.uniq() do
        assert noun in declared or noun == slug,
               "cli noun #{inspect(noun)} is neither in manifest nouns #{inspect(declared)} " <>
                 "nor equal to plugin_name #{inspect(slug)} — capabilities would stamp bare :plugin"
      end

      assert "task" in declared
    end
  end

  describe "core content-graph verbs (Goal ges/graph-edge-seam)" do
    # FRESH-INSTALL invariant: the content graph roots on ANY content doc, so
    # its read verbs are CORE (not the disable-able Tasks plugin). They must be
    # in the superset manifest tagged `source: "core"` and under the `graph`
    # noun — so they survive `config :barkpark, :plugins, []`.
    test "graph.show/orphans/dangling are CORE verbs over /v1/graph/*, not plugin" do
      manifest = Capabilities.manifest("admin", project: false)
      cmds = manifest["commands"]

      graph_ids = ~w(graph.show graph.orphans graph.dangling)

      graph_cmds = Enum.filter(cmds, fn c -> c["id"] in graph_ids end)
      assert length(graph_cmds) == 3

      for c <- graph_cmds do
        assert c["source"] == "core"
        assert c["noun"] == "graph"
        # read-tier: the /v1/graph/* routes sit behind [:api, :require_token].
        assert c["auth_tier"] == "read"
        assert String.starts_with?(c["http"]["path_template"], "/v1/graph")
      end

      paths = MapSet.new(graph_cmds, fn c -> c["http"]["path_template"] end)
      assert MapSet.equal?(paths, MapSet.new(["/v1/graph/:id", "/v1/graph/orphans", "/v1/graph/dangling"]))

      # The `graph` noun is a CORE noun (plugin: nil).
      graph_noun = Enum.find(manifest["nouns"], fn n -> n["name"] == "graph" end)
      assert graph_noun
      assert graph_noun["plugin"] == nil
    end

    test "an anonymous (none) caller still sees the graph verbs hidden (read-tier)" do
      # read-tier verbs are existence-hidden from anon — but VISIBLE to a read+
      # caller. This proves they project through the normal tier ladder rather
      # than being plugin-gated.
      anon = Capabilities.manifest("none")
      read = Capabilities.manifest("read")

      anon_ids = anon["commands"] |> Enum.map(& &1["id"]) |> MapSet.new()
      read_ids = read["commands"] |> Enum.map(& &1["id"]) |> MapSet.new()

      refute "graph.show" in anon_ids
      assert "graph.show" in read_ids
      assert "graph.orphans" in read_ids
      assert "graph.dangling" in read_ids
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
