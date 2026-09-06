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
  alias Barkpark.Tasks.Validation

  # The flat plugin paths these plugins actually register (Bulldocs +
  # OnixEdit `register_routes/1`), prefixed with the host's `/v1/plugins` mount.
  @bulldocs_routes MapSet.new([
                     "/v1/plugins/bulldocs/papers",
                     "/v1/plugins/bulldocs/papers/:slug/ops",
                     "/v1/plugins/bulldocs/papers/:slug/proposals",
                     "/v1/plugins/bulldocs/intents",
                     "/v1/plugins/bulldocs/intents/:id/processed",
                     # Task 6 (session-handoff): the `session` verb group's routes —
                     # four on the bulldocs ingest surface (tasks 3-4), plus
                     # `session.link-task`'s route on the Tasks plugin's own mount
                     # (task 5) — declared here too since all five verb maps live
                     # in Bulldocs.cli_commands/0 (per the task-6 brief).
                     "/v1/plugins/bulldocs/sessions",
                     "/v1/plugins/bulldocs/sessions/:slug",
                     "/v1/plugins/bulldocs/sessions/:slug/events",
                     # session-conversations slice: the harness-conversation
                     # registry touch route (session.touch).
                     "/v1/plugins/bulldocs/sessions/:slug/conversations",
                     "/v1/tasks/:doc_id/sessions"
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
                 "/v1/tasks/events",
                 "/v1/tasks/claim",
                 "/v1/tasks/:doc_id",
                 "/v1/tasks/:doc_id/claim",
                 "/v1/tasks/:doc_id/close",
                 "/v1/tasks/:doc_id/release",
                 "/v1/tasks/:doc_id/stamp",
                 "/v1/tasks/:doc_id/landed",
                 "/v1/tasks/:doc_id/pulse",
                 "/v1/tasks/:doc_id/renew",
                 "/v1/tasks/:doc_id/move",
                 "/v1/tasks/:doc_id/stage",
                 # #5627 listener presence — the fleet pair rides the Tasks plugin.
                 "/v1/fleet/roster",
                 "/v1/fleet/beat"
               ])

  defp atomize_for_manifest(cmds) do
    # The manifest folds atom-keyed cli_command() maps into string keys; mirror
    # that here so project/2 (which reads string keys) sees the same shape.
    Enum.map(cmds, fn cmd ->
      cmd
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
    end)
  end

  test "public document reads retain a published default and advertise non-published perspectives" do
    commands =
      Capabilities.manifest("admin", project: false)["commands"]
      |> Map.new(&{&1["id"], &1})

    for id <- ~w(doc.get doc.ls doc.query) do
      command = Map.fetch!(commands, id)
      assert command["auth_tier"] == "none"

      perspective = Enum.find(command["flags"], &(&1["name"] == "perspective"))
      assert perspective["default"] == "published"
      assert perspective["type"] == "string"
    end
  end

  describe "Bulldocs.cli_commands/0" do
    test "declares five paper verbs, all ingest-tier, all grounded in a real route" do
      cmds = Bulldocs.cli_commands()

      ids = Enum.map(cmds, & &1.id)
      assert "bulldocs.publish" in ids
      assert "bulldocs.patch" in ids
      assert "bulldocs.propose" in ids
      assert "bulldocs.intents" in ids
      assert "bulldocs.intent-processed" in ids

      # The five `bulldocs.*` paper verbs all sit behind the ingest highway
      # bucket (the `session.*` group added in task 6 is NOT all-ingest —
      # see the dedicated describe block below).
      paper_cmds = Enum.filter(cmds, &(&1.noun == "bulldocs"))
      assert length(paper_cmds) == 5
      assert Enum.all?(paper_cmds, &(&1.auth_tier == "ingest"))

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

    test "declares the six session.* verbs (task 6 + session-conversations), grounded in real routes" do
      cmds = Bulldocs.cli_commands()
      by_id = Map.new(cmds, &{&1.id, &1})

      for id <-
            ~w(session.open session.log session.publish session.view session.link-task session.touch) do
        assert Map.has_key?(by_id, id), "missing #{id}"
      end

      session_cmds = Enum.filter(cmds, &(&1.noun == "session"))
      assert length(session_cmds) == 6
      assert Enum.all?(session_cmds, &(&1.verb in ~w(open log publish view link-task touch)))

      # Every session verb is grounded in a route the plugin (or, for
      # link-task, the Tasks plugin's own /v1/tasks mount, task 5) actually
      # registers.
      assert Enum.all?(session_cmds, fn c ->
               MapSet.member?(@bulldocs_routes, c.http.path_template)
             end)

      # session.open/publish/view/log are ingest-tier (the bulldocs ingest
      # token bucket); session.link-task is read-tier (the /v1/tasks bearer
      # scope) — the ONE exception to "all bulldocs commands are ingest".
      open = by_id["session.open"]
      log = by_id["session.log"]
      publish = by_id["session.publish"]
      view = by_id["session.view"]
      link_task = by_id["session.link-task"]
      touch = by_id["session.touch"]

      assert open.auth_tier == "ingest"
      assert log.auth_tier == "ingest"
      assert publish.auth_tier == "ingest"
      assert view.auth_tier == "ingest"
      assert link_task.auth_tier == "read"
      assert touch.auth_tier == "ingest"

      assert open.http == %{method: "POST", path_template: "/v1/plugins/bulldocs/sessions"}
      assert publish.http == %{method: "POST", path_template: "/v1/plugins/bulldocs/sessions"}

      assert log.http == %{
               method: "POST",
               path_template: "/v1/plugins/bulldocs/sessions/:slug/events"
             }

      assert view.http == %{method: "GET", path_template: "/v1/plugins/bulldocs/sessions/:slug"}

      assert link_task.http == %{method: "POST", path_template: "/v1/tasks/:doc_id/sessions"}

      assert touch.http == %{
               method: "POST",
               path_template: "/v1/plugins/bulldocs/sessions/:slug/conversations"
             }

      touch_flags = Map.new(touch.flags, &{&1.name, &1})
      assert touch_flags["conversation"].type == "string"
      assert touch_flags["harness"].type == "string"
      assert touch_flags["account"].type == "string"
      assert touch_flags["machine"].type == "string"
      assert touch_flags["cwd"].type == "string"
      refute touch.batch
      assert touch.writes

      # session.log carries the three event-shape flags (kind/ref/note) — the
      # server reads them off conn.params, which Phoenix merges from the query
      # string for a non-batch write (commandFlagBelongsInBody only routes
      # BATCH writes to the JSON body; see internal/cli/run.go), exactly like
      # the existing task.stamp precedent.
      log_flags = Map.new(log.flags, &{&1.name, &1})
      assert log_flags["kind"].type == "string"
      assert log_flags["ref"].type == "string"
      assert log_flags["note"].type == "string"
      # session-conversations slice review fix: session.log must declare
      # --conversation, or the manifest-driven CLI hard-errors (unknown flag,
      # run.go:474) on the documented `bp session log ... --conversation`
      # provenance invocation — the event-provenance half was unreachable.
      assert log_flags["conversation"].type == "string"
      refute log.batch

      # session.link-task's --add flag reaches TasksController.sessions/2's
      # Params.string_list(params["add"]) — which accepts a bare string OR a
      # list, so a single --add value (landing as a scalar query param) works.
      add_flag = Enum.find(link_task.flags, &(&1.name == "add"))
      assert add_flag.type == "string"
      refute link_task.batch

      # view is a read (GET), the rest write.
      refute view.writes
      assert Enum.all?([open, log, publish, link_task, touch], & &1.writes)
    end
  end

  describe "Tasks.cli_commands/0" do
    test "declares the fourteen task verbs, method-derived tier, grounded in a real /v1/tasks route" do
      cmds = Tasks.cli_commands()

      ids = Enum.map(cmds, & &1.id)
      assert "task.ls" in ids
      assert "task.ready" in ids
      assert "task.prime" in ids
      assert "task.events" in ids
      assert "task.get" in ids
      assert "task.claim" in ids
      assert "task.close" in ids
      assert "task.release" in ids
      assert "task.stamp" in ids
      assert "task.pulse" in ids
      assert "task.next" in ids
      assert "task.move" in ids
      assert "task.stage" in ids
      # task-59fe7b40b719b379: the non-holder landing mark, added ADDITIVELY.
      assert "task.landed" in ids
      # task-16e56d05b809dd39 — the NON-HOLDER lease extension a CI job calls so
      # a claim does not lapse underneath its own open PR (Tasks.Renew).
      assert "task.renew" in ids
      # The content-graph read verbs are NOT on the Tasks plugin — they moved
      # to CORE (Goal ges/graph-edge-seam) so the kill switch can't drop them.
      refute "task.graph" in ids
      refute "task.graph-orphans" in ids
      refute "task.graph-dangling" in ids
      # #5627 (listener presence) added the two fleet verbs to this plugin —
      # 15 task.* (13 + task.landed + task.renew) + fleet.roster/fleet.beat = 17.
      assert "fleet.roster" in ids
      assert "fleet.beat" in ids
      assert length(cmds) == 17

      {fleet_cmds, task_cmds} = Enum.split_with(cmds, &(&1.noun == "fleet"))

      # task is no longer a core noun — the verbs moved verbatim onto the Tasks
      # plugin. The tier is DERIVED FROM THE METHOD, not declared per verb: the
      # /v1/tasks scope is bearer-gated (not admin) for reads, and write-gated
      # for everything else since task-a87a3346b8ff736a. This assertion used to
      # read `auth_tier == "read"` for all of them, which pinned the manifest to
      # a surface a read-only token could genuinely claim, stamp and close.
      assert Enum.all?(task_cmds, &(&1.noun == "task"))

      for cmd <- task_cmds do
        expected = if cmd.http.method == "GET", do: "read", else: "write"

        assert cmd.auth_tier == expected,
               "#{cmd.id} is #{cmd.http.method} #{cmd.http.path_template} but declares " <>
                 "auth_tier #{inspect(cmd.auth_tier)}; the router gates every non-GET on " <>
                 "the :token_root bucket behind RequireWriteForMutation, so the manifest " <>
                 "must say #{inspect(expected)} or `bp` will promise a credential that 403s"
      end

      # The fleet pair: roster is a read; beat is the one write-tier verb
      # (listener presence heartbeat) — pinned so a tier drift is caught here.
      assert Enum.map(fleet_cmds, & &1.id) |> Enum.sort() == ["fleet.beat", "fleet.roster"]
      assert Enum.find(fleet_cmds, &(&1.id == "fleet.roster")).auth_tier == "read"
      assert Enum.find(fleet_cmds, &(&1.id == "fleet.beat")).auth_tier == "write"

      # Every path_template is a route the plugin actually mounts.
      assert Enum.all?(cmds, fn c -> MapSet.member?(@tasks_paths, c.http.path_template) end)

      # claim/close/release are the writing workflow ops.
      claim = Enum.find(cmds, &(&1.id == "task.claim"))
      close = Enum.find(cmds, &(&1.id == "task.close"))
      release = Enum.find(cmds, &(&1.id == "task.release"))
      assert claim.writes
      assert close.writes
      assert release.writes
      assert claim.default_output == "minimal"
      assert release.default_output == "minimal"

      assert release.http == %{
               method: "POST",
               path_template: "/v1/tasks/:doc_id/release"
             }

      assert Enum.map(release.args, &{&1.name, &1.type, &1.required}) == [
               {"doc_id", "string", true},
               {"worker_id", "string", true},
               {"observed_epoch", "int", true}
             ]

      # POST, so write-tier — `release` moves a task's claim lease.
      assert release.auth_tier == "write"
      assert release.flags == []

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

      # task.close declares the repeatable `set` body-carrier flag — the gate
      # the CLI's splitArgs enforces before `--set criteria:=[…]` (the
      # acceptance-criteria close-out) is accepted on the command line.
      close_set = Enum.find(close.flags, &(&1.name == "set"))
      assert close_set, "task.close must declare the set flag"
      assert close_set.repeatable
      assert close_set.summary =~ "criteria"

      # task.stamp (expressive-agent-loops D8): the pinned CLI shape —
      # `bp task stamp <id> <worker> <epoch> --criterion N
      #   (--met --evidence "…" | --miss --note "…")`.
      stamp = Enum.find(cmds, &(&1.id == "task.stamp"))
      assert stamp.writes
      assert stamp.default_output == "minimal"
      assert stamp.http.path_template == "/v1/tasks/:doc_id/stamp"

      stamp_arg_names = Enum.map(stamp.args, & &1.name)
      assert stamp_arg_names == ["doc_id", "worker_id", "observed_epoch"]
      assert Enum.all?(stamp.args, & &1.required)

      stamp_flags = Map.new(stamp.flags, &{&1.name, &1})
      assert stamp_flags["criterion"].type == "int"
      assert stamp_flags["met"].type == "bool"
      assert stamp_flags["miss"].type == "bool"
      assert stamp_flags["evidence"].type == "string"
      assert stamp_flags["note"].type == "string"

      # task.pulse (expressive-agent-loops D9): the pinned CLI shape —
      # `bp task pulse <id> <worker> --now "…" [--criterion N]` — NO epoch
      # anywhere (pulse IS the renewal; it survives fences).
      pulse = Enum.find(cmds, &(&1.id == "task.pulse"))
      assert pulse.writes
      assert pulse.default_output == "minimal"
      assert pulse.http.path_template == "/v1/tasks/:doc_id/pulse"

      pulse_arg_names = Enum.map(pulse.args, & &1.name)
      assert pulse_arg_names == ["doc_id", "worker_id"]
      assert Enum.all?(pulse.args, & &1.required)
      refute "observed_epoch" in pulse_arg_names

      pulse_flags = Map.new(pulse.flags, &{&1.name, &1})
      assert pulse_flags["now"].type == "string"
      assert pulse_flags["criterion"].type == "int"
      refute Map.has_key?(pulse_flags, "epoch")

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

      for command <- [Enum.find(cmds, &(&1.id == "task.ready")), next] do
        order = Enum.find(command.flags, &(&1.name == "order"))
        assert order.type == "string"
        refute Map.has_key?(order, :default)
      end
    end

    test "task.ready's summary says what the query returns — claimable, draft-tolerant, twin-collapsed" do
      # WORDING PIN (task tgw10-bl-drafts-in-ready-pool). The summary this
      # manifest ships is the ONLY sentence most agents ever read about the
      # ready queue — it flows to `bp task ready --help`, to docs/openapi.json,
      # and (restated) to the MCP task_ready tool. It said "List executable,
      # unblocked tasks", which was wrong on BOTH of the row's findings:
      #
      #   * lifecycle `blocked` rows ARE listed — Validation.claimable_statuses/0
      #     is ~w(open blocked) by decision, and Tasks.Queue binds exactly that
      #     list. "unblocked" told a reader the opposite.
      #   * an UNPAIRED `drafts.<id>` row is listed as itself — Tasks.Queue
      #     carries no `documents.status` predicate; only a draft with a
      #     same-scope published twin is collapsed away.
      #
      # The ruling was to correct the SENTENCE, not the query (excluding drafts
      # would hide every `bp task create` row from the queue). This test is what
      # stops the sentence from silently regressing to the comfortable lie:
      # reverting the summary reds it by name.
      ready = Enum.find(Tasks.cli_commands(), &(&1.id == "task.ready"))
      summary = ready.summary

      refute summary =~ "unblocked",
             "task.ready's summary claims the queue is `unblocked`, but " <>
               "Validation.claimable_statuses/0 is #{inspect(Validation.claimable_statuses())} " <>
               "— lifecycle `blocked` rows are listed by design. Got: #{summary}"

      assert summary =~ "claimable",
             "task.ready's summary must name what the queue actually holds " <>
               "(claimable rows), not a promise the query does not keep. Got: #{summary}"

      assert summary =~ "blocked is claimable by design",
             "task.ready's summary must state that lifecycle `blocked` is in the " <>
               "queue on purpose (Validation @claimable_statuses). Got: #{summary}"

      assert summary =~ "published or unpaired draft",
             "task.ready's summary must state that an unpaired `drafts.` row is " <>
               "listed — Tasks.Queue has no documents.status filter. Got: #{summary}"

      assert summary =~ "twin-collapsed to the published row",
             "task.ready's summary must state the twin-collapse rule, or a reader " <>
               "cannot tell WHICH of a draft/published pair the queue yields. " <>
               "Got: #{summary}"

      # Non-vacuity: the two lifecycle words the sentence commits to are the two
      # the code actually allows, so this pin cannot drift away from the query.
      assert Validation.claimable_statuses() == ~w(open blocked)
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

  describe "task.close manifest text vs the close honesty gates (mob-bl-close-manifest-lie)" do
    # THE BINDING. The task.close manifest string IS `bp task close --help` —
    # the CLI prints the server manifest verbatim — and it rotted silently once:
    # from 448749cf1 (which made a done close over unmet criteria a REFUSAL)
    # until 2026-08-23 it kept claiming "Unmet criteria never block a close
    # (soft warning only)". Nothing caught it because no test read the prose.
    #
    # This bind is a PAIR. The behaviour half lives in
    # test/barkpark/tasks/close_test.exs ("close/3 — criteria gate" and
    # "close/3 — holder gate"): those tests pin the refusals themselves, so
    # removing either gate goes red there. THIS half pins that the help text
    # names those same gates by their stable wire tokens (params.ex
    # reason_to_string/1: "criteria_unmet", "not_holder") and their overrides,
    # so text drifting back toward the lie goes red here. Change the gates,
    # change both tests — the prose can no longer diverge silently in either
    # direction.
    test "the close help names the refusals, the overrides, and the exemptions" do
      close = Enum.find(Tasks.cli_commands(), &(&1.id == "task.close"))
      assert close, "task.close must exist in the manifest"

      text =
        Enum.join(
          [close.summary] ++
            Enum.map(close.args, & &1.summary) ++ Enum.map(close.flags, & &1.summary),
          " "
        )

      # The dead lie stays dead — in any wording.
      refute text =~ ~r/never blocks? a close/i,
             "the manifest claims unmet criteria cannot block a close — Close.close/3 refuses with criteria_unmet"

      refute text =~ ~r/soft warning only/i

      # The criteria gate: refusal by wire token, indices base, and escape hatch.
      assert text =~ "REFUSED"
      assert text =~ "criteria_unmet"
      assert text =~ ~r/0-based/i
      assert text =~ ~s(criteria_override="<why it is done anyway>")
      assert text =~ "close_override.criteria"
      # The override is accept-unmet-on-the-record: it never flips a criterion.
      assert text =~ "met=false"
      # The exemptions, by name (check_criteria_proven/6 exempts them BY NAME).
      assert text =~ "cancelled"
      assert text =~ "blocked"
      assert text =~ ~r/EXEMPT/
      # The autostamp deduction (Close.unmet_after_autostamp/2).
      assert text =~ "merge_gate"
      # The holder gate and its override (PDS-D288).
      assert text =~ "not_holder"
      assert text =~ "holder_override"
      assert text =~ "close_override.holder"
      # A blank reason is not an override (Close.override_reason/1).
      assert text =~ ~r/blank reason is NOT an override/
    end

    # Same defect class, second instance found in the same sweep: task.ls
    # declared `default: 50` while the server's page default was 1000
    # (tasks_controller do_index). The CLI uses this field to calibrate its
    # truncation warning, so the wrong value made `bp task ls` warn "more may be
    # available" on fully-returned pages. This pins the manifest to the
    # controller's real default; if the controller's page size ever changes,
    # change both.
    #
    # The pin moved 1000 -> 100 with task-e2f5ecca0be9a6d1, which shrank the
    # index default (the cap stays 1000). The direction of the lie inverted with
    # it and got more dangerous: at 50 the CLI cried truncation on complete
    # pages (noisy, self-correcting — a reader who re-runs with --all learns
    # nothing new); left at 1000 while the server pages at 100, the CLI would
    # compare 100 rows against a believed limit of 1000 and stay SILENT on a
    # page that really was cut. That is the failure this assertion now guards.
    test "task.ls declares the server's REAL default page size, not a wish" do
      ls = Enum.find(Tasks.cli_commands(), &(&1.id == "task.ls"))
      limit = Enum.find(ls.flags, &(&1.name == "limit"))
      assert limit.default == 100
    end

    # Third and fourth instances from the same sweep: doc.ls and doc.query both
    # declared `default: 50` against QueryController.index's real default of
    # 100 (parse_int(params["limit"], 100), unchanged since 8b81b12279 — the
    # manifest entries were born claiming 50 two months later). media.ls (50)
    # and search.query (50) match their controllers and stay untouched. If the
    # controller's default ever changes, change these together.
    test "doc.ls and doc.query declare QueryController's real default page size" do
      manifest = Capabilities.manifest("admin", project: false)

      for id <- ["doc.ls", "doc.query"] do
        cmd = Enum.find(manifest["commands"], &(&1["id"] == id))
        assert cmd, "#{id} must exist in the manifest"
        limit = Enum.find(cmd["flags"], &(&1["name"] == "limit"))
        assert limit["default"] == 100, "#{id} limit default must match the server (100)"
      end
    end
  end

  describe "core content-graph verbs (Goal ges/graph-edge-seam)" do
    # FRESH-INSTALL invariant: the content graph roots on ANY content doc, so
    # its read verbs are CORE (not the disable-able Tasks plugin). They must be
    # in the superset manifest tagged `source: "core"` and under the `graph`
    # noun — so they survive `config :barkpark, :plugins, []`.
    test "graph.show/tasks/orphans/dangling are CORE verbs over /v1/graph/*, not plugin" do
      manifest = Capabilities.manifest("admin", project: false)
      cmds = manifest["commands"]

      graph_ids = ~w(graph.show graph.tasks graph.orphans graph.dangling)

      graph_cmds = Enum.filter(cmds, fn c -> c["id"] in graph_ids end)
      assert length(graph_cmds) == 4

      for c <- graph_cmds do
        assert c["source"] == "core"
        assert c["noun"] == "graph"
        # read-tier: the /v1/graph/* routes sit behind [:api, :require_token].
        assert c["auth_tier"] == "read"
        assert String.starts_with?(c["http"]["path_template"], "/v1/graph")
      end

      paths = MapSet.new(graph_cmds, fn c -> c["http"]["path_template"] end)

      assert MapSet.equal?(
               paths,
               MapSet.new([
                 "/v1/graph/:id",
                 "/v1/graph/:id/tasks",
                 "/v1/graph/orphans",
                 "/v1/graph/dangling"
               ])
             )

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
      refute "graph.tasks" in anon_ids
      assert "graph.show" in read_ids
      assert "graph.tasks" in read_ids
      assert "graph.orphans" in read_ids
      assert "graph.dangling" in read_ids
    end
  end

  describe "core document write verbs" do
    test "doc.create declares JSON file input alongside repeatable set overrides" do
      command =
        Capabilities.manifest("admin", project: false)["commands"]
        |> Enum.find(&(&1["id"] == "doc.create"))

      assert command
      flags = Map.new(command["flags"], &{&1["name"], &1})

      assert flags["file"]["type"] == "file"
      refute flags["file"]["repeatable"]
      assert flags["file"]["summary"] =~ "JSON object"
      assert flags["file"]["summary"] =~ "stdin"

      assert flags["set"]["type"] == "string"
      assert flags["set"]["repeatable"]
    end

    test "doc.create-or-replace and doc.create-if-not-exists both accept the --file flag" do
      commands =
        Capabilities.manifest("admin", project: false)["commands"]
        |> Map.new(&{&1["id"], &1})

      # The generic Writes help (usage.go) advertises --file for every write verb;
      # these two upsert verbs used to declare only --set, so a `--file x.json`
      # exited 2 "unknown flag --file". Both must carry the file flag, mirroring
      # doc.create.
      for id <- ~w(doc.create-or-replace doc.create-if-not-exists) do
        command = Map.fetch!(commands, id)
        flags = Map.new(command["flags"], &{&1["name"], &1})

        file_flag = flags["file"]
        assert file_flag, "#{id} must declare a --file flag"
        assert file_flag["type"] == "file"
        refute file_flag["repeatable"]
        assert file_flag["summary"] =~ "JSON object"
        assert file_flag["summary"] =~ "stdin"

        # --set survives alongside --file.
        assert flags["set"]["type"] == "string"
        assert flags["set"]["repeatable"]
      end
    end
  end

  describe "core access (airdrop-grant) verbs" do
    # FRESH-INSTALL invariant: airdrop grants are the cross-surface access layer,
    # mounted from CORE (not a plugin), so the grantor verbs survive
    # `config :barkpark, :plugins, []` alongside the token/secret/share nouns.
    test "access grant/ls/show/revoke/claim/mine are CORE verbs over /v1/access" do
      manifest = Capabilities.manifest("admin", project: false)
      cmds = manifest["commands"]

      access_cmds = Enum.filter(cmds, fn c -> c["noun"] == "access" end)
      ids = MapSet.new(access_cmds, & &1["id"])

      assert MapSet.equal?(
               ids,
               MapSet.new(
                 ~w(access.grant access.ls access.show access.revoke access.claim access.mine)
               )
             )

      for c <- access_cmds do
        assert c["source"] == "core"
        assert c["noun"] == "access"
        assert String.starts_with?(c["http"]["path_template"], "/v1/access")
      end

      # ag-bp-user-identity-auth: the grantee CLAIM/MINE verbs now SHIP — an
      # api_token can carry a USER identity via owner_user_id, so a terminal
      # `bp access claim` / `bp access mine` resolves the owner and works.
      assert Enum.any?(cmds, fn c -> c["id"] == "access.claim" end)
      assert Enum.any?(cmds, fn c -> c["id"] == "access.mine" end)

      by_id = Map.new(access_cmds, fn c -> {c["id"], c} end)

      assert by_id["access.grant"]["http"] == %{
               "method" => "POST",
               "path_template" => "/v1/access"
             }

      assert by_id["access.grant"]["auth_tier"] == "scoped_admin"
      assert by_id["access.grant"]["writes"] == true
      assert by_id["access.ls"]["http"] == %{"method" => "GET", "path_template" => "/v1/access"}
      assert by_id["access.ls"]["auth_tier"] == "read"

      assert by_id["access.show"]["http"] == %{
               "method" => "GET",
               "path_template" => "/v1/access/:id"
             }

      assert by_id["access.revoke"]["http"] == %{
               "method" => "DELETE",
               "path_template" => "/v1/access/:id"
             }

      assert by_id["access.revoke"]["auth_tier"] == "scoped_admin"

      # The grantee verbs ride /v1/access/{claim,mine} at the `read` tier (an
      # authenticated — owned — token is required; anon is existence-hidden).
      assert by_id["access.claim"]["http"] == %{
               "method" => "POST",
               "path_template" => "/v1/access/claim"
             }

      assert by_id["access.claim"]["auth_tier"] == "read"
      assert by_id["access.claim"]["writes"] == true

      assert by_id["access.mine"]["http"] == %{
               "method" => "GET",
               "path_template" => "/v1/access/mine"
             }

      assert by_id["access.mine"]["auth_tier"] == "read"

      # The `access` noun itself is CORE (plugin: nil).
      access_noun = Enum.find(manifest["nouns"], fn n -> n["name"] == "access" end)
      assert access_noun
      assert access_noun["plugin"] == nil
    end

    test "access verbs existence-hide from anon but show to an authenticated caller" do
      anon = Capabilities.manifest("none")
      read = Capabilities.manifest("read")

      anon_ids = anon["commands"] |> Enum.map(& &1["id"]) |> MapSet.new()
      read_ids = read["commands"] |> Enum.map(& &1["id"]) |> MapSet.new()

      # None of the access verbs are visible to an anonymous caller.
      refute "access.grant" in anon_ids
      refute "access.ls" in anon_ids
      refute "access.show" in anon_ids
      refute "access.revoke" in anon_ids

      # A read+ caller sees the reads AND the scoped_admin verbs (scoped_admin is
      # visible to any authenticated token — the server decides per-workspace).
      assert "access.ls" in read_ids
      assert "access.show" in read_ids
      assert "access.grant" in read_ids
      assert "access.revoke" in read_ids
    end
  end

  describe "core user-auth verbs (Phase 5, core-auth)" do
    # The /v1/auth/* verbs are CORE (pre-tenant, plugin: nil). The 5 public
    # verbs are tier "none" so an anon caller can discover login; the 4
    # session-gated verbs are tier "read" (hidden from anon, shown to any
    # authenticated caller). Routes mirror router.ex /v1/auth/* exactly.
    @auth_routes %{
      "auth.register" => {"POST", "/v1/auth/register"},
      "auth.login" => {"POST", "/v1/auth/login"},
      "auth.verify-email" => {"POST", "/v1/auth/verify-email"},
      "auth.request-reset" => {"POST", "/v1/auth/request-reset"},
      "auth.reset" => {"POST", "/v1/auth/reset"},
      "auth.me" => {"GET", "/v1/auth/me"},
      "auth.logout" => {"DELETE", "/v1/auth/logout"},
      "auth.mfa-enroll" => {"POST", "/v1/auth/mfa/enroll"},
      "auth.mfa-verify" => {"POST", "/v1/auth/mfa/verify"}
    }

    @auth_none ~w(auth.register auth.login auth.verify-email auth.request-reset auth.reset)
    @auth_read ~w(auth.me auth.logout auth.mfa-enroll auth.mfa-verify)

    test "all 9 auth verbs are CORE under the `auth` noun, route-matched, side-effect honest" do
      manifest = Capabilities.manifest("admin", project: false)
      cmds = manifest["commands"]

      auth_cmds = Enum.filter(cmds, fn c -> Map.has_key?(@auth_routes, c["id"]) end)
      assert length(auth_cmds) == 9

      for c <- auth_cmds do
        assert c["source"] == "core"
        assert c["noun"] == "auth"
        {method, path} = Map.fetch!(@auth_routes, c["id"])
        assert c["http"]["method"] == method
        assert c["http"]["path_template"] == path

        # PDS-D302 REVERSED the original "write-free" claim here. `writes` means
        # "has side effects", and internal/cli/mcp_bridge.go turns it straight
        # into ReadOnlyHint — so advertising auth.register / auth.mfa-enroll as
        # read-only told an MCP client they were safe to call unprompted. Only
        # the GET is genuinely read-only.
        assert c["writes"] == (method != "GET"),
               "#{c["id"]} (#{method}) advertises writes == #{inspect(c["writes"])}"
      end

      # tier split: 5 public "none", 4 session-gated "read".
      tier = Map.new(auth_cmds, fn c -> {c["id"], c["auth_tier"]} end)
      for id <- @auth_none, do: assert(tier[id] == "none")
      for id <- @auth_read, do: assert(tier[id] == "read")

      # the `auth` noun is a CORE noun (plugin: nil).
      auth_noun = Enum.find(manifest["nouns"], fn n -> n["name"] == "auth" end)
      assert auth_noun
      assert auth_noun["plugin"] == nil
    end

    test "anon (none) sees the 5 public auth verbs and is hidden the 4 session-gated ones" do
      anon = Capabilities.manifest("none")
      read = Capabilities.manifest("read")

      anon_ids = anon["commands"] |> Enum.map(& &1["id"]) |> MapSet.new()
      read_ids = read["commands"] |> Enum.map(& &1["id"]) |> MapSet.new()

      # anon can discover login (and the other public verbs)…
      for id <- @auth_none, do: assert(id in anon_ids)
      # …but the read-tier session verbs are existence-hidden from anon…
      for id <- @auth_read, do: refute(id in anon_ids)
      # …and visible once the caller is read+.
      for id <- @auth_none ++ @auth_read, do: assert(id in read_ids)
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
