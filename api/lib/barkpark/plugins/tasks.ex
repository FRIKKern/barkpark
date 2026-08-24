defmodule Barkpark.Plugins.Tasks do
  @moduledoc """
  Tasks — the W7 task-document substrate, as a first-party plugin.

  Tasks live as rows in the `documents` table (everything is a task: a goal/epic
  is a root task, a phase is a task with children, a rail is the chronological
  child tasks of a task). This was core machinery wired straight into
  `seeds.exs` and `config.exs`; the C4 plugin lift moves the *declarative* parts
  onto the plugin highway, while the heavy lifting stays in core.

  The split (mirroring the Bulldocs lift): *core* keeps the reusable machinery —
  `Barkpark.Tasks` (the schema builder + lifecycle validator + claim/close
  primitives), `Barkpark.Tasks.{TtlSweeper, Compactor, Edge}`, and the
  `/v1/tasks` + `/v1/rail` controllers — and this plugin is the thin wiring
  layer that declares the schema and schedules the cron.

  ## What this module contributes

    * `register_schemas/1` — the `task` document type, built by
      `Barkpark.Tasks.schema_definitions/1`. Auto-registers on every boot via
      `Barkpark.Plugins.Bootstrap.register_all_schemas/0`, idempotent on
      `(name, dataset)`. Replaces the inline registration loop that used to live
      in `seeds.exs`.
    * `oban_crontab/0` — the two task cron entries (TTL sweep every minute,
      compaction every six hours), collected at boot by
      `Barkpark.Plugins.Registry.collect_oban_crontab/0` and merged into the
      host's `Oban.Plugins.Cron` `:crontab` before Oban starts. Replaces the two
      tuples that used to live in `config/config.exs`. The `tasks_ttl` /
      `tasks_compact` queue declarations stay in config — only the worker
      *scheduling* moves here.

    * `register_routes/1` — the `/v1/tasks` endpoints the `bp task` CLI
      consumes, declared with `auth: :token_root` so the dormant
      host-level `scope "/v1", BarkparkWeb do … plugin_routes(scope: :token_root)`
      wrapper mounts them at `/v1/tasks/*` behind the `[:api, :require_token]`
      pipeline. Replaces the explicit `scope "/v1/tasks"` block that used to live
      in `router.ex` (C4-3b). The `TasksController` itself stays in core; this
      plugin only owns the route declarations.

    * `cli_commands/0` — the eleven `task.*` CLI verbs (`ls`, `ready`, `prime`,
      `events`, `get`, `claim`, `close`, `stamp`, `pulse`, `next`, `move`) the
      `/v1/capabilities` manifest exposes. Five
      moved verbatim from `Barkpark.Plugins.Capabilities`'s core verb registry;
      `next` (the queue-based atomic claim), `stamp` (criterion-level mid-claim
      evidence) and `pulse` (now-line heartbeat + lease renewal) were added later. `task` is no
      longer a core noun: the capabilities controller now derives
      `source: "plugin:tasks"` provenance for these commands. The content-graph
      read verbs (`graph` / `graph-orphans` / `graph-dangling`) are NOT here —
      they live in the CORE verb registry (Goal ges/graph-edge-seam) so they
      survive the `:plugins, []` kill switch (the graph roots on ANY doc).

  The persisted `type` discriminator is still `"task"` and the API surface
  (`/v1/tasks`, `/v1/rail`) is unchanged — only the registration/scheduling/routing
  wiring became a plugin.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/tasks/plugin.json"

  # Tasks is core content — surfaced in the MAIN tier of the Desk Structure.
  @impl Barkpark.Plugin
  def structure_placement, do: :main

  require Logger

  @doc """
  Declares the `task` and `listener` document types by delegating to
  `Barkpark.Tasks.schema_definitions/1` (`listener` is Personal Dev Fleet
  presence — see `Barkpark.Tasks.Fleet`; its type name is exactly
  `"listener"`, never `"task"`, so the literal `type == "task"` filters in
  the GitHub outbox, `/v1/tasks/events` and `/v1/tasks/prime` structurally
  exclude presence rows).

  `dataset` comes from `opts[:dataset]` when supplied (Bootstrap calls this with
  `[]`), defaulting to `"production"` — matching every other seed schema and the
  legacy `seeds.exs` loop this replaces.
  """
  @impl Barkpark.Plugin
  def register_schemas(opts) do
    dataset = Keyword.get(opts, :dataset, "production")
    Barkpark.Tasks.schema_definitions(dataset)
  end

  @doc """
  Authoring quality gate — a `before_save` structural gate on `type:task`
  document writes (the sheets-gate precedent, `Barkpark.Plugins.Sheets`).

  Three graduated responses, tuned so a well-formed task is the path of least
  resistance (parity §6 layer 2 — a well-formed task is the path of least
  resistance; empty-title tasks must not publish):

    * **empty title → HALT (409).** A task whose resulting title is blank
      (nil or whitespace-only) cannot be saved. The title is read from the
      incoming write, falling back to the stored row on a partial update — so
      a metadata-only patch of an already-titled task is never blocked; only a
      genuine title-less create (or an explicit blanking) halts. Surfaces as
      `{:error, {:halted, reason}}` → HTTP 409 (`content/errors.ex`).
    * **zero acceptance_criteria on a fresh task → SOFT WARN.** A brand-new
      task (no prior row) carrying no acceptance criteria still SAVES; it only
      emits a `Logger.warning`. Never a hard stop — quick authoring and the
      fresh-install invariant stay smooth (no trivial blocks).
    * **malformed acceptance_criteria → HALT (409).** A write whose
      `acceptance_criteria` is not a list, or is a list with a non-map
      (non-`{criterion, met, evidence}`) entry, is rejected. Defense-in-depth
      over `Barkpark.Tasks.Validation` (which rejects the same shapes earlier
      with a 422) — the gate owns the structural contract at the `before_save`
      boundary for any path that reaches it directly.
    * **MERGE-GATED wording without `merge_gate: true` → SOFT WARN.** A
      criterion that OPENS with the `MERGE-GATED` marker but carries no flag
      saves normally and emits a `Logger.warning`. The close-time autostamp
      keys on the FLAG, never on the wording, so the two vocabularies drift
      silently — measured 2026-08-22: 2870 worded criteria, 35 flagged.
      Deliberately narrow (leading position only) and deliberately advisory;
      see `warn_unflagged_merge_gates/1` for why widening it or promoting it
      to a halt is unsafe.

  Non-task documents pass untouched.
  """
  @impl Barkpark.Plugin
  def lifecycle_hooks do
    %{before_save: [&quality_gate/1], before_publish: [&portable_brief_gate/1]}
  end

  @tui_block_types ~w(
    heading paragraph list callout divider section code table figure action
    pullquote embed ingress eyebrow byline diagram asciicast image composite
    arrayOf codelist localizedText form questionnaire PdSheet sheet note stage
    card columns terminal notes cards pipeline status-legend tasks task-list
    task-detail task-board roadmap heatmap stat stats stat-grid gauge-list chart
    dashboard field-string field-slug field-text field-boolean field-select
    field-datetime field-color field-reference field-image
  )

  # Publish wall: a task that cannot render as PortableDoc in the terminal is
  # not a publishable task. Draft authoring remains permissive; publication
  # gives every agent an actionable repair message.
  defp portable_brief_gate(%{doc: %{"type" => "task"} = doc}) do
    with content when is_map(content) <- fetch(doc, "content"),
         brief when is_map(brief) <- fetch(content, "brief"),
         1 <- fetch(brief, "version"),
         blocks when is_list(blocks) and blocks != [] <- fetch(brief, "blocks"),
         :ok <- validate_brief_blocks(blocks) do
      :ok
    else
      {:halt, _} = halted ->
        halted

      _ ->
        {:halt,
         "task brief is required before publish — set content.brief to " <>
           "PortableDoc {version: 1, blocks: [...]} so bp task tui can render it"}
    end
  end

  defp portable_brief_gate(_payload), do: :ok

  defp validate_brief_blocks(blocks) do
    Enum.reduce_while(blocks, :ok, fn
      %{} = block, :ok ->
        type = fetch(block, "type")

        cond do
          type not in @tui_block_types ->
            {:halt,
             {:halt,
              "task brief contains unsupported block type #{inspect(type)} — " <>
                "use a bp task tui PortableDoc block type (for prose: heading, paragraph, callout, list)"}}

          true ->
            case validate_nested_brief_blocks(block) do
              :ok -> {:cont, :ok}
              {:halt, _} = halted -> {:halt, halted}
            end
        end

      _other, :ok ->
        {:halt, {:halt, "task brief blocks must be PortableDoc objects with a supported type"}}
    end)
  end

  defp validate_nested_brief_blocks(block) do
    with :ok <- validate_optional_block_list(fetch(block, "blocks")),
         :ok <- validate_optional_child(fetch(block, "child")) do
      :ok
    end
  end

  defp validate_optional_block_list(:absent), do: :ok
  defp validate_optional_block_list(list) when is_list(list), do: validate_brief_blocks(list)
  defp validate_optional_block_list(_), do: {:halt, "nested task brief blocks must be a list"}

  defp validate_optional_child(:absent), do: :ok
  defp validate_optional_child(%{} = child), do: validate_brief_blocks([child])
  defp validate_optional_child(_), do: {:halt, "task brief figure child must be a block object"}

  # ── Authoring quality gate (before_save) ──────────────────────────────────

  defp quality_gate(%{doc: %{"type" => "task"} = doc} = payload) do
    prev = Map.get(payload, :prev_doc)

    with :ok <- gate_title(doc, prev) do
      gate_criteria(doc, prev)
    end
  end

  defp quality_gate(_payload), do: :ok

  # Empty-title hard stop. The effective title is what the row WILL carry: the
  # incoming value when the write sets `title`, else the stored title on an
  # update. Only a blank effective title halts — so a partial update of a
  # titled task never trips the gate.
  defp gate_title(doc, prev) do
    title =
      case fetch(doc, "title") do
        :absent -> prev && prev.title
        value -> value
      end

    if blank_title?(title) do
      {:halt,
       "task title is required — a task cannot be saved with an empty title " <>
         "(authoring quality gate)"}
    else
      :ok
    end
  end

  defp blank_title?(nil), do: true
  defp blank_title?(t) when is_binary(t), do: String.trim(t) == ""
  defp blank_title?(_), do: false

  # Acceptance-criteria gate over the INCOMING write's content. Malformed
  # (non-list, or a list with a non-map entry) → halt. Zero criteria (empty
  # list, or key absent) on a genuine create → soft warn, save proceeds. A
  # write that carries no `content` at all (pure metadata patch) is exempt.
  defp gate_criteria(doc, prev) do
    case fetch(doc, "content") do
      content when is_map(content) ->
        eval_criteria(fetch(content, "acceptance_criteria"), prev)

      _ ->
        :ok
    end
  end

  defp eval_criteria(:absent, prev), do: warn_if_create_zero(prev)
  defp eval_criteria([], prev), do: warn_if_create_zero(prev)

  defp eval_criteria(list, _prev) when is_list(list) do
    if Enum.all?(list, &is_map/1) do
      warn_unflagged_merge_gates(list)
      :ok
    else
      {:halt,
       "acceptance_criteria entries must be {criterion, met, evidence} maps — " <>
         "got a non-object entry"}
    end
  end

  defp eval_criteria(_other, _prev) do
    {:halt, "acceptance_criteria must be a list of {criterion, met, evidence} maps"}
  end

  # A fresh task (no prior row) with no criteria: warn, never block.
  defp warn_if_create_zero(nil) do
    Logger.warning(
      "task quality gate: a new task is being saved with zero acceptance_criteria — " <>
        "consider adding at least one measurable criterion (soft warning, save proceeds)"
    )

    :ok
  end

  defp warn_if_create_zero(_prev), do: :ok

  # THE MERGE-GATE WORDING NAG. The `MERGE-GATED` text convention and the
  # `merge_gate` criterion flag are two vocabularies, and ONLY THE FLAG IS
  # MACHINE-READABLE: `Tasks.Close.autostamp_merge_gate/6` fires on
  # `merge_gate: true` and cannot see the wording. Measured 2026-08-22 over the
  # published corpus: 2870 criteria are worded as merge-gated and 35 carry the
  # flag — so ~2811 rows are wired to a convention the automation cannot see,
  # and a lead who merges expecting an auto-stamp waits forever. This warns the
  # AUTHOR of a new criterion so the gap stops widening; the existing rows are a
  # separate MIGRATION (`pds-w25-backlog-merge-gate-split`).
  #
  # DELIBERATELY NARROW, AND A MISS IS FREE — read this before "improving" it.
  # It matches ONLY the marker in LEADING position. A census of 1845
  # marker-bearing criteria found 1740 leading, 51 NON-leading that are
  # nonetheless genuine gates ("LEAD-OWNED (merge-gated):", "PR merged to main
  # (LEAD CLOSES THIS …)"), and 54 that merely mention merge-gating — position
  # and prose misclassify in OPPOSITE directions, so no text rule separates them
  # cleanly. That refuted a proposed narrowing of the `bp task stamp` REFUSAL,
  # where a false negative lets a builder fabricate a merge close. Here the
  # asymmetry is reversed and benign: a false negative is one un-nagged author.
  #
  # THEREFORE THIS MUST NEVER BECOME A HALT, and it must never be widened to
  # catch the 105 non-leading cases — widening it would nag ~54 authors whose
  # criterion was never a gate. The flag stays the ONLY machine signal:
  # `autostamp_merge_gate` must NOT be taught to read this wording.
  @merge_gate_lead ~r/^\s*[\[\(]?\s*\*{0,2}\s*MERGE[-\s]GATED\b/i

  defp warn_unflagged_merge_gates(list) do
    unflagged =
      list
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _i} ->
        merge_gate_worded?(entry) and not merge_gate_flagged?(entry)
      end)
      |> Enum.map(fn {_entry, i} -> i end)

    if unflagged != [] do
      message =
        "acceptance_criteria #{inspect(unflagged)} open with the MERGE-GATED " <>
          "marker but carry no `merge_gate: true` — the close-time autostamp keys on the FLAG, not " <>
          "the wording, so a lead merge will not flip them. Add \"merge_gate\": true to each " <>
          "gate entry (soft warning, save proceeds)"

      # Journal copy (grep-able in prod logs) AND the advisory channel: the
      # Logger line alone let 669 unflagged rows accumulate in silence — its
      # only reader was the server journal, which no task author ever sees.
      # Warnings.put rides the mutate SUCCESS envelope (`warnings: [...]`),
      # which the bp CLI prints to stderr (emitWarnings) and Studio folds into
      # its save flash — so the author is told at the moment of authoring.
      # Collect-only-when-listening: a caller with no open collector drops it.
      Logger.warning("task quality gate: " <> message)
      Barkpark.Content.Warnings.put("merge_gate_unflagged", message, "warning")
    end

    :ok
  end

  defp merge_gate_worded?(entry) do
    case Map.get(entry, "criterion") do
      text when is_binary(text) -> Regex.match?(@merge_gate_lead, text)
      _ -> false
    end
  end

  defp merge_gate_flagged?(entry), do: Map.get(entry, "merge_gate") == true

  # String-or-atom key fetch that distinguishes an ABSENT key from a present
  # nil/false value (write paths string-key their attrs; the atom fallback is
  # belt-and-braces for a struct/atom-keyed caller). Returns `:absent` when the
  # key is missing entirely.
  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, safe_atom(key), :absent)
    end
  end

  defp fetch(_map, _key), do: :absent

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__quality_gate_nonexistent_key__
  end

  @doc """
  Contributes the Tasks desk group to the Studio Structure pane via the
  plugin desk-item highway (`Barkpark.Plugin.desk_items/1`, collected by
  `Barkpark.Plugins.Registry.collect_desk_items/1` after the host's
  built-in groups — see `Barkpark.Structure.build_desk_items/3`).

  Three entries:

    * a `:document_list` for the `task` type, gated on the `task` schema
      actually existing in the requested dataset — mirroring how the host
      groups gate on `Map.has_key?(schemas, name)`, so a dataset that never
      registered the task schema (e.g. a clean `bp setup` profile on a
      non-production dataset) gets no dead "Tasks" row. The list pane opens
      each task in the regular Studio form editor (`PaneBuilder`'s
      `:plugin_document_list` branch).
    * a `:link` to **Projects** (`/admin/projects`) — the Barkpark Projects
      BOARD (`Barkpark.Plugins.Tasks.Web.BoardLive`). Ungated by schema
      presence: the board reads the task corpus globally, so it is reachable
      from any dataset's desk. `/admin/*` (not `/studio/*`) so the desk-link
      scoper leaves the path intact — the pulse dashboard precedent.
    * a `:link` to **Fleet** (`/admin/fleet`) — the Personal Dev Fleet desk
      tile (`Barkpark.Plugins.Tasks.Web.FleetLive`), a read-only listener
      roster. Ungated by schema presence for the same reason: the roster reads
      the `type:listener` corpus globally (PDF-D19).
  """
  @impl Barkpark.Plugin
  def desk_items(dataset) do
    # The Barkpark Projects board link — the visual kanban over type:task docs
    # (BoardLive at /admin/projects). Ungated by schema presence: the board
    # reads the task corpus GLOBALLY, so it is reachable from any dataset's desk
    # (the pulse dashboard precedent — a plain `:link` to an `/admin/*` ops
    # path, left untouched by the `/studio/<x>` desk-link scoper). The Tasks
    # document-list below stays schema-gated so a dataset that never registered
    # the task schema gets no dead "Tasks" list — but it keeps the Projects
    # link.
    projects_link = %{type: :link, label: "Projects", path: "/admin/projects", icon: "columns"}

    # The Personal Dev Fleet desk tile — a read-only listener roster at
    # /admin/fleet (Barkpark.Plugins.Tasks.Web.FleetLive). Ungated by schema
    # presence, exactly like the Projects link: the roster reads the
    # type:listener corpus GLOBALLY (PDF-D19), so it is reachable from any
    # dataset's desk. `/admin/*` (not `/studio/*`) so the desk-link scoper leaves
    # the path intact — the pulse dashboard precedent. It vanishes with the whole
    # Tasks plugin (the enablement highway skips a disabled plugin's callbacks).
    fleet_link = %{type: :link, label: "Fleet", path: "/admin/fleet", icon: "activity"}

    task_list =
      if task_schema_present?(dataset) do
        [%{type: :document_list, label: "Tasks", doc_type: "task", icon: "✅"}]
      else
        []
      end

    task_list ++ [projects_link, fleet_link]
  end

  @doc """
  Plugin-contributed top-menu tab — surfaces **Projects** in the Studio topbar
  next to Structure / Media / API, pointing at the Barkpark Projects board
  (`Barkpark.Plugins.Tasks.Web.BoardLive` at `/admin/projects`). Mirrors the
  OnixEdit "Bokbasen" precedent: a plugin-contributed tab for an `/admin/*`
  ops console — rendered in the chrome, route-enforced by the `:ops` gate
  (`["ops", "admin"]`), and it disappears entirely when the Tasks plugin is
  off (the fresh-install invariant). Active for any path under
  `/admin/projects`. `order: 35` sits it just after the built-in API tab
  (orders 10/20/30) and ahead of the flat admin singletons (tmux 40,
  styleguide 50, Bokbasen 50).
  """
  @impl Barkpark.Plugin
  def top_menu_entries do
    [
      %{
        label: "Projects",
        path: "/admin/projects",
        icon: "columns",
        order: 35,
        active_when: "/admin/projects"
      },
      # The Personal Dev Fleet tile (Barkpark.Plugins.Tasks.Web.FleetLive at
      # /admin/fleet) — the read-only listener roster. `order: 36` sits it right
      # after Projects (35). Same `:ops` route enforcement + fresh-install
      # invariant as Projects: the tab disappears entirely when the Tasks plugin
      # is off. Active for any path under /admin/fleet.
      %{
        label: "Fleet",
        path: "/admin/fleet",
        icon: "activity",
        order: 36,
        active_when: "/admin/fleet"
      }
    ]
  end

  # Failure-safe schema probe. The rescue/catch matters beyond defensive
  # style: the Registry's `resolver_is_default_lift?/4` fingerprint RUNS
  # `desk_items("production")` once at registration time — a context with
  # no DB sandbox ownership (tests) and possibly no Repo yet (boot). A
  # raise there would mis-fingerprint the default resolver as an author
  # override and log a spurious "defines both" warning on every
  # registration. No schema reachable → no desk entry, never a crash.
  defp task_schema_present?(dataset) do
    match?({:ok, _}, Barkpark.Content.get_schema("task", dataset))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  Contributes the two task Oban cron entries, moved verbatim from
  `config/config.exs`:

    * `{"* * * * *", Barkpark.Tasks.TtlSweeper}` — W7-05 TTL sweep, runs every
      minute (the finest Oban.Cron granularity; sub-minute cadence is
      intentionally not supported).
    * `{"0 */6 * * *", Barkpark.Tasks.Compactor}` — W7-06 task-document
      compaction, every six hours (coarser than the TTL sweep because
      compaction is batch storage maintenance, not real-time crash recovery; a
      per-task advisory lock serializes it with claim/close/sweep).

  Collected at boot by `Barkpark.Plugins.Registry.collect_oban_crontab/0` and
  appended to the host's `Oban.Plugins.Cron` `:crontab` (C4-1 boot merge).
  """
  @impl Barkpark.Plugin
  def oban_crontab do
    [
      {"* * * * *", Barkpark.Tasks.TtlSweeper},
      {"0 */6 * * *", Barkpark.Tasks.Compactor}
    ]
  end

  @doc """
  The fourteen `/v1/tasks` endpoints the `bp task` CLI consumes, mirroring —
  order-preserving — the `scope "/v1/tasks"` block this replaced in `router.ex`
  (C4-3b), plus later verb additions (stamp, pulse, events). Every spec carries
  `auth: :token_root`, so the dormant host-level
  `scope "/v1", BarkparkWeb do … plugin_routes(scope: :token_root)` wrapper
  mounts them at `/v1/tasks/*` behind the `[:api, :require_token]` pipeline
  (authenticated bearer, NOT admin — claim/close are workflow ops, not document
  mutations; their atomicity lives in `Tasks.claim/2` + `Tasks.close/3`).

  Static routes are declared BEFORE the `/:doc_id` catchall so an empty path
  doesn't match as `:doc_id = ""` — the documented Phoenix static/dynamic
  disambiguation idiom. The `TasksController` stays in core; this plugin owns
  only the route declarations.
  """
  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      {:get, "/tasks", BarkparkWeb.TasksController, :index, auth: :token_root},
      {:get, "/tasks/ready", BarkparkWeb.TasksController, :ready, auth: :token_root},
      # prime must mount BEFORE /tasks/:doc_id or it resolves as a doc id.
      {:get, "/tasks/prime", BarkparkWeb.TasksController, :prime, auth: :token_root},
      # events (the keyset task-events feed) must ALSO mount BEFORE
      # /tasks/:doc_id — same precedent as prime, or `/v1/tasks/events` resolves
      # as `:doc_id = "events"`.
      {:get, "/tasks/events", BarkparkWeb.TasksController, :events, auth: :token_root},
      {:post, "/tasks/claim", BarkparkWeb.TasksController, :claim, auth: :token_root},
      {:post, "/tasks/edges", BarkparkWeb.TasksController, :add_edge, auth: :token_root},
      {:get, "/tasks/:doc_id", BarkparkWeb.TasksController, :show, auth: :token_root},
      {:get, "/tasks/:doc_id/edges", BarkparkWeb.TasksController, :edges, auth: :token_root},
      {:post, "/tasks/:doc_id/claim", BarkparkWeb.TasksController, :claim_by_id,
       auth: :token_root},
      {:post, "/tasks/:doc_id/close", BarkparkWeb.TasksController, :close, auth: :token_root},
      {:post, "/tasks/:doc_id/release", BarkparkWeb.TasksController, :release, auth: :token_root},
      {:post, "/tasks/:doc_id/stamp", BarkparkWeb.TasksController, :stamp, auth: :token_root},
      {:post, "/tasks/:doc_id/pulse", BarkparkWeb.TasksController, :pulse, auth: :token_root},
      {:post, "/tasks/:doc_id/labels", BarkparkWeb.TasksController, :relabel, auth: :token_root},
      {:post, "/tasks/:doc_id/papers", BarkparkWeb.TasksController, :papers, auth: :token_root},
      {:post, "/tasks/:doc_id/sessions", BarkparkWeb.TasksController, :sessions,
       auth: :token_root},
      {:post, "/tasks/:doc_id/move", BarkparkWeb.TasksController, :move, auth: :token_root},
      {:post, "/tasks/:doc_id/stage", BarkparkWeb.TasksController, :stage, auth: :token_root},
      # Personal Dev Fleet presence (Wave A) — literal paths mount at
      # /v1/fleet/* on the same :token_root bucket (the flat /v1/tasks family;
      # AssignDefaultScope resolves scope — PDF-D19). Presence VOCABULARY, not
      # an order protocol: beat writes the listener row, roster reads it.
      {:post, "/fleet/beat", BarkparkWeb.TasksController, :fleet_beat, auth: :token_root},
      {:get, "/fleet/roster", BarkparkWeb.TasksController, :fleet_roster, auth: :token_root},
      # Barkpark Projects — the native task BOARD (read-only :ops LiveView),
      # mounted at /admin/projects (the :ops bucket). /admin (not /studio) so
      # the desk-link scoper leaves the path intact — see desk_items/1 and the
      # pulse dashboard precedent. This is the GUI realization of the task
      # design-language spec; the tasks plugin owns type:task, so the board
      # belongs in its namespace.
      {:live, "/projects", Barkpark.Plugins.Tasks.Web.BoardLive, :index, auth: :ops},
      # Personal Dev Fleet desk tile — the read-only listener ROSTER
      # (Barkpark.Plugins.Tasks.Web.FleetLive), mounted at /admin/fleet (the
      # :ops bucket, admin-gated). Reads the flat global-per-dataset roster
      # (PDF-D19), 5s poll, no PubSub. /admin (not /studio) so the desk-link
      # scoper leaves the path intact — the Projects precedent above. The tasks
      # plugin owns type:listener presence, so the tile lives in its namespace.
      {:live, "/fleet", Barkpark.Plugins.Tasks.Web.FleetLive, :index, auth: :ops}
      # NOTE: the content-graph reads (/graph/orphans, /graph/dangling,
      # /graph/:id) are NO LONGER declared here. They moved to CORE
      # (router.ex `scope "/v1" … get("/graph/…")`) because the graph roots on
      # ANY content doc, not just tasks — so they must survive the
      # `config :barkpark, :plugins, []` kill switch (fresh-install invariant).
    ]
  end

  @doc """
  The CLI verbs Tasks contributes to the `/v1/capabilities` manifest (M3),
  moved verbatim from `Barkpark.Plugins.Capabilities`'s core verb registry (the
  C4 plugin lift — task is no longer a core noun). Each command is grounded in a
  `/v1/tasks` route that `register_routes/1` ABOVE actually mounts; the
  verb/method/path/auth_tier/args/flags are byte-identical to the former core
  definitions — only the provenance changes (the capabilities controller now
  stamps `source: "plugin:tasks"` instead of `"core"`).

  Thirteen verbs over thirteen routes, all `auth_tier: "read"` (the `/v1/tasks` scope is
  `:api + :require_token`, NOT admin — claim/close/release are bearer-gated workflow ops,
  not document mutations):

    * `ls` — `GET /v1/tasks` (paginated). READ, table.
    * `ready` — `GET /v1/tasks/ready` (paginated). READ, table.
    * `events` — `GET /v1/tasks/events?since=<id>` (keyset replay over
      `mutation_events`, id-ASC; the response carries the next `cursor` +
      `has_more`). READ, json.
    * `get` — `GET /v1/tasks/:doc_id`. READ, table.
    * `claim` — `POST /v1/tasks/:doc_id/claim`. WRITES, minimal receipt.
    * `close` — `POST /v1/tasks/:doc_id/close`. WRITES, minimal receipt.
    * `release` — `POST /v1/tasks/:doc_id/release`. WRITES, minimal receipt.
    * `stamp` — `POST /v1/tasks/:doc_id/stamp` (criterion-level mid-claim
      evidence, expressive-agent-loops D8). WRITES, minimal receipt.
    * `next` — `POST /v1/tasks/claim` (queue-based: atomically hand me the next
      ready task in priority order). WRITES, minimal receipt. Returns
      `{"ok":false,"reason":"no_ready"}` with HTTP 200 when the queue is empty —
      a valid outcome, not an error.
    * `move` — `POST /v1/tasks/:doc_id/move` (rail-l3 re-parent). WRITES, minimal
      receipt.
    * `pulse` — `POST /v1/tasks/:doc_id/pulse` (now-line heartbeat + lease
      renewal, one atomic write; no epoch arg — pulse survives fences). WRITES,
      minimal receipt.
    * `stage` — `POST /v1/tasks/:doc_id/stage` (sanctioned thought-state
      transition: considering | researching | open — enforces the Transitions
      legality table, writes/clears content.engagement, no epoch fence). WRITES,
      minimal receipt.

  Plus the `fleet` noun (Personal Dev Fleet presence, Wave A):

    * `roster` — `GET /v1/fleet/roster`. READ, table (the `documents` envelope
      key — PDF-D21).
    * `beat` — `POST /v1/fleet/beat`. WRITES, minimal receipt (zero-row atomic
      heartbeat — PDF-D17).
  """
  @impl Barkpark.Plugin
  def cli_commands do
    [
      %{
        id: "task.ls",
        noun: "task",
        verb: "ls",
        summary: "List tasks in the queue.",
        http: %{method: "GET", path_template: "/v1/tasks"},
        auth_tier: "read",
        args: [],
        flags: [
          # default MUST match the server's actual page size (tasks_controller
          # do_index: Params.parse_limit(params["limit"], 1000, 1000)). It was
          # born as 50 — false from day one — and the CLI reads this field to
          # calibrate its "page may be truncated" warning (internal/cli/run.go
          # defaultPageLimit), so every `bp task ls` over a >=50-row corpus
          # printed a false "more may be available" even when the server had
          # returned everything.
          %{name: "limit", type: "int", summary: "Max tasks to return.", default: 1000},
          %{name: "offset", type: "int", summary: "Task-index row offset.", default: 0}
        ],
        writes: false,
        batch: false,
        paginated: true,
        dry_run: false,
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "task.ready",
        noun: "task",
        verb: "ready",
        summary: "List executable, unblocked tasks (priority order by default).",
        http: %{method: "GET", path_template: "/v1/tasks/ready"},
        auth_tier: "read",
        args: [],
        flags: [
          %{name: "limit", type: "int", summary: "Max tasks to return.", default: 50},
          %{name: "offset", type: "int", summary: "Ready-queue row offset.", default: 0},
          %{
            name: "order",
            type: "string",
            summary:
              "Optional closure_nearest campaign order: fewest unmet criteria, then oldest, then logical task id."
          }
        ],
        writes: false,
        batch: false,
        paginated: true,
        dry_run: false,
        default_output: "table",
        # Supports the brief/full projection (wave axi-brief-views): agents get
        # a token-thrifty card list by default, humans the full envelope.
        # Emitted only under ?views=1 — Capabilities.maybe_gate_views strips it
        # otherwise, so the default wire shape is byte-identical to today.
        views: Barkpark.Plugins.Capabilities.agent_views_descriptor(),
        scoped_prefix: nil
      },
      %{
        id: "task.prime",
        noun: "task",
        verb: "prime",
        summary:
          "One-call agent rehydration: my in-progress claims, the ready head, recent events, lifecycle counts.",
        http: %{method: "GET", path_template: "/v1/tasks/prime"},
        auth_tier: "read",
        args: [],
        flags: [
          %{
            name: "worker",
            type: "string",
            summary: "Narrow in_progress to this worker's claims."
          },
          %{
            name: "limit",
            type: "int",
            summary: "Ready-head and event-window size.",
            default: 10
          },
          %{
            name: "order",
            type: "string",
            summary:
              "Optional closure_nearest order for the ready head; compatibility order remains the default."
          }
        ],
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "json",
        # Supports the brief/full projection (wave axi-brief-views): the brief
        # prime response is the ≤5 KB resume card an agent gets by default.
        # Emitted only under ?views=1 (Capabilities.maybe_gate_views).
        views: Barkpark.Plugins.Capabilities.agent_views_descriptor(),
        scoped_prefix: nil
      },
      %{
        id: "task.events",
        noun: "task",
        verb: "events",
        summary:
          "Replay task events since a cursor — a keyset stream over mutation_events, id-ASC. Pass --since <id> (the last event id you saw); the response carries the next `cursor` + `has_more`. The one poll feed every surface reads; omit --since to replay from the start.",
        http: %{method: "GET", path_template: "/v1/tasks/events"},
        auth_tier: "read",
        args: [],
        flags: [
          %{
            name: "since",
            type: "int",
            summary:
              "Resume cursor: return only events whose id is greater than this (the last event id you saw). Omit to replay from the start of the backlog.",
            default: 0
          },
          %{
            name: "limit",
            type: "int",
            summary: "Max events to return per call (1–500).",
            default: 500
          },
          %{
            name: "dataset",
            type: "string",
            summary: "Dataset to read task events from (defaults to production)."
          }
        ],
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "json",
        scoped_prefix: nil
      },
      %{
        id: "task.get",
        noun: "task",
        verb: "get",
        summary: "Fetch one task by id.",
        http: %{method: "GET", path_template: "/v1/tasks/:doc_id"},
        auth_tier: "read",
        args: [
          %{name: "doc_id", required: true, type: "string", summary: "Task document id."}
        ],
        flags: [],
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "task.claim",
        noun: "task",
        verb: "claim",
        summary: "Claim a ready task by id.",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/claim"},
        auth_tier: "read",
        args: [
          %{
            name: "doc_id",
            required: true,
            type: "string",
            summary: "Task document id to claim."
          },
          %{
            name: "worker_id",
            required: true,
            type: "string",
            summary: "Worker identity claiming the task."
          }
        ],
        flags: [
          %{
            name: "resources",
            type: "string",
            summary:
              "Comma-separated resource strings (e.g. file paths) to fence while this claim is live; 409 resource_conflict if another live claim holds any."
          },
          %{
            name: "observed_rail_rev",
            type: "string",
            summary:
              "The rail_rev (rail ETag) you last observed for this task's parent rail. When it differs from the current rail_rev the response carries a rail_changed notice — advisory, never a gate."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "task.close",
        noun: "task",
        verb: "close",
        summary:
          "Close a claimed task by id; --set 'criteria:=[…]' updates acceptance criteria in the same atomic write (omitted evidence preserves the stored value; evidence:\"\" clears it). By default fences on a claim-time work digest: if the task's brief (title/description/acceptance_criteria) changed under your claim, the close 409s doc_changed_since_claim and the response names current_rev + changed_fields. To recover: re-read the task, reconcile those changed fields, then close with that current_rev via --set observed_rev=<current_rev> (strict full-rev CAS, bypasses the digest fence). A plain re-read is NOT enough — a same-worker re-read preserves the claim-time work digest, so closing again without observed_rev repeats the same 409. Two honesty gates can also refuse: a done close over unmet acceptance criteria (409 criteria_unmet) and a close by a non-holder (409 not_holder) — each with a loud on-the-record --set override (criteria_override / holder_override); see the set flag.",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/close"},
        auth_tier: "read",
        args: [
          %{
            name: "doc_id",
            required: true,
            type: "string",
            summary: "Task document id to close."
          },
          %{
            name: "worker_id",
            required: true,
            type: "string",
            summary: "Worker identity that holds the claim."
          },
          %{
            name: "observed_epoch",
            required: true,
            type: "int",
            summary: "Claim epoch returned at claim time (optimistic concurrency guard)."
          },
          %{
            name: "lifecycle_status",
            required: false,
            type: "string",
            summary: "done | cancelled | blocked (defaults to done when omitted)."
          },
          %{
            name: "reason",
            required: false,
            type: "string",
            summary: "One-line close rationale, persisted as content.close_reason."
          }
        ],
        flags: [
          %{
            name: "set",
            type: "string",
            repeatable: true,
            summary:
              "Extra close-body fields as key=value (key:=json for typed). The expectation " <>
                "close-out (task-proves-paper): --set 'criteria:=[{\"index\":0,\"met\":true," <>
                "\"evidence\":\"PR #1234\",\"criterion\":\"<the criterion's exact stored wording>\"}]' " <>
                "flips acceptance_criteria met/evidence atomically " <>
                "with the close (same rev CAS — no separate racing mutation). \"criterion\" is " <>
                "REQUIRED on every entry with met=true: the 0-based index alone is unverifiable, so an " <>
                "unguarded met-flip is REJECTED (409 criterion_text_required) rather than silently " <>
                "flipping a neighbouring criterion, and a text that does not match the row at that index " <>
                "is REJECTED too (409 criteria_mismatch). An entry with met=false needs no text. Optional " <>
                "evidence is presence-sensitive: omit the key to preserve stored evidence, or " <>
                "send evidence:\"\" to clear it. THE CRITERIA GATE (close honesty, PDS-D289): a " <>
                "done close over unmet acceptance criteria is REFUSED — 409 criteria_unmet, naming " <>
                "the 0-based unmet indices. Unmet is measured on the task AS STORED (criteria " <>
                "flipped in this very close command do not count), and a criterion the merge-gate " <>
                "autostamp is about to prove on its own authority (an explicit merge_gate:true " <>
                "marker plus a landed digest riding this close) is deducted before the count. The " <>
                "way through is --set criteria_override=\"<why it is done anyway>\": the close " <>
                "lands ON THE RECORD as close_override.criteria (actor + unmet rows + reason) and " <>
                "the unmet criteria stay met=false — an override never flips them. cancelled and " <>
                "blocked closes are EXEMPT by name (abandoning acceptance criteria is what " <>
                "cancelling means). THE HOLDER GATE (PDS-D288): a close by a worker other than " <>
                "the claim's holder is REFUSED — 409 not_holder — unless it carries --set " <>
                "holder_override=\"<why you are closing someone else's claim>\", recorded as " <>
                "close_override.holder. A blank reason is NOT an override for either key. " <>
                "--set observed_rev=<rev> pins the strict full-rev CAS and BYPASSES the default " <>
                "work-digest fence (use when you intend to close against the exact rev you read)."
          },
          %{
            name: "observed_rail_rev",
            type: "string",
            summary:
              "The rail_rev (rail ETag) you last observed for this task's parent rail. When it differs from the current rail_rev the response carries a rail_changed notice — advisory, never a gate."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "task.release",
        noun: "task",
        verb: "release",
        summary: "Release a held task claim without waiting for its lease to expire.",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/release"},
        auth_tier: "read",
        args: [
          %{
            name: "doc_id",
            required: true,
            type: "string",
            summary: "Task document id to release."
          },
          %{
            name: "worker_id",
            required: true,
            type: "string",
            summary: "Worker identity that holds the claim."
          },
          %{
            name: "observed_epoch",
            required: true,
            type: "int",
            summary: "Claim epoch returned at claim time (optimistic concurrency guard)."
          }
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "task.stamp",
        noun: "task",
        verb: "stamp",
        summary:
          "Stamp ONE acceptance criterion mid-claim: --criterion N (N is the ZERO-BASED index — the first criterion is 0, NOT 1) with either --met --evidence \"…\" (flips the lock; evidence is REQUIRED, non-empty) or --miss --note \"…\" (records the honest attempt on the criterion's attempts list — bounded to the 5 most recent — WITHOUT flipping met). --met ALSO REQUIRES --criterion-text \"<the criterion's exact stored wording>\": the index alone is unverifiable, so an unguarded met-flip is REJECTED (409 criterion_text_required) rather than silently flipping whatever row the index lands on. If the text does not match the row at N the stamp is REJECTED too (409 criteria_mismatch) — nothing is written. --miss needs no text (it flips nothing). A criterion that is a MERGE GATE — the LEAD's to close when the PR merges — REFUSES a --met (409 merge_gated_criterion) unless you pass --merge-gated; a builder flipping one fabricates a done before the PR exists. Holder-only + the same epoch fence as close (a lapsed claim can't stamp — renew via re-claim, then restamp); your own stamps never trip close's work-digest fence. Emits a task.criterion event. Stamp is progress; close is the seal.",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/stamp"},
        auth_tier: "read",
        args: [
          %{
            name: "doc_id",
            required: true,
            type: "string",
            summary: "Task document id to stamp."
          },
          %{
            name: "worker_id",
            required: true,
            type: "string",
            summary: "Worker identity that holds the claim (holder-only)."
          },
          %{
            name: "observed_epoch",
            required: true,
            type: "int",
            summary: "Claim epoch returned at claim time (same fence as close)."
          }
        ],
        flags: [
          %{
            name: "criterion",
            type: "int",
            summary:
              "ZERO-BASED index into acceptance_criteria — the first criterion is 0, the second is 1 (do NOT pass a 1-based number). This is the criterion to stamp."
          },
          %{
            name: "criterion-text",
            type: "string",
            summary:
              "REQUIRED with --met (optional with --miss): the criterion's exact stored wording, copied verbatim from acceptance_criteria[N].criterion. It is the off-by-one guard — a --met stamp with NO text is REJECTED (409 criterion_text_required), and one whose text does not match the row at --criterion N is REJECTED (409 criteria_mismatch), instead of silently flipping a neighbour."
          },
          %{
            name: "met",
            type: "bool",
            summary: "Mark the criterion met. Requires non-empty --evidence."
          },
          %{
            name: "evidence",
            type: "string",
            summary:
              "Concrete proof for --met (gate output, test names, PR) — required, non-empty."
          },
          %{
            name: "miss",
            type: "bool",
            summary:
              "Record an honest failed attempt. Appends {note,ts,worker} to the criterion's attempts (5 most recent kept); met never flips."
          },
          %{
            name: "note",
            type: "string",
            summary: "What was tried and why it missed — required with --miss, non-empty."
          },
          %{
            name: "merge-gated",
            type: "bool",
            summary:
              "LEAD ONLY — the override that lets a --met flip a MERGE GATE (a criterion the lead closes when the PR merges). Builders must NOT pass it: without it such a stamp is refused (409 merge_gated_criterion), which is the point — flipping a gate before the PR exists fabricates a done. A criterion counts as a gate if it carries \"merge_gate\": true, or (when it carries no explicit \"merge_gate\" key) if its wording mentions MERGE-GATED / MERGE GATE. That prose fallback is deliberately wide and mis-fires on ~3.5% of marker-bearing rows that merely DISCUSS merge-gating; the fix for those is to set \"merge_gate\": false on the criterion, not to reach for this flag."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "task.next",
        noun: "task",
        verb: "next",
        summary: "Atomically claim the next executable task (priority order by default).",
        http: %{method: "POST", path_template: "/v1/tasks/claim"},
        auth_tier: "read",
        args: [
          %{
            name: "worker_id",
            required: true,
            type: "string",
            summary: "Worker identity claiming the task."
          },
          %{
            name: "phase_id",
            required: false,
            type: "string",
            summary: "Restrict the claim to tasks under this phase id."
          }
        ],
        flags: [
          %{
            name: "order",
            type: "string",
            summary:
              "Optional closure_nearest campaign order: fewest unmet criteria, then oldest, then logical task id."
          },
          %{
            name: "observed_rail_rev",
            type: "string",
            summary:
              "The rail_rev (rail ETag) you last observed for the claimed task's parent rail. When it differs from the claimed task's current rail_rev the response carries a rail_changed notice — advisory, never a gate."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "task.move",
        noun: "task",
        verb: "move",
        summary:
          "Re-parent a task (rail-l3): move it under another task's rail, or omit new_parent_id to move it to the root. Emits a task.reparented event; the response carries the destination rail_rev + the source from_rail_rev.",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/move"},
        auth_tier: "read",
        args: [
          %{
            name: "doc_id",
            required: true,
            type: "string",
            summary: "Task document id to move."
          },
          %{
            name: "new_parent_id",
            required: false,
            type: "string",
            summary: "Destination parent task id; omit (or null) to move to the root."
          }
        ],
        flags: [],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "task.stage",
        noun: "task",
        verb: "stage",
        summary:
          "Stage a task between the thought/backlog states — the sanctioned lifecycle-transition verb. `state` is the target: considering | researching | open, OR the row's OWN current state. Enforces the charter-D7 transition-legality table for those targets: considering⇄researching; considering|researching→open; open→considering; the terminal/blocked reopen edges done→open, cancelled→open, blocked→open, in_progress→open; same→same. THE TERMINAL SAME-STATE ADJUDICATION EDGE (PDS wave 25): a same-state no-op is accepted on EVERY status, not just the stageable ones — done→done, blocked→blocked, in_progress→in_progress — so a FINISHED row can record its disposition/reason/reopen-trigger IN PLACE instead of being resurrected to `open` first (which would leave it saying open while carrying claim.closed_by, and put it back in `bp task ready`). It widens ADJUDICATION, not MOVEMENT: the from-state is read from the locked row, never from your input, so state==current is satisfiable only by a row already in that state, and the write set never includes content.claim — a done→done stage leaves lifecycle_status=done and close attribution byte-identical. (The false-done reopen recipe DEPENDS on reopening a done task — it legitimately re-enters the ready backlog via stage, KEEPING its claim; no epoch machinery.) Writes content.engagement {object,holder,ts,lapse_ttl_seconds,lapses_at} — an EPHEMERAL lease the TtlSweeper deletes wholesale after ~900s — on →considering/researching and clears it on →open; a `note` does NOT ride that lease, it lands on the DURABLE content.disposition_reason (no sweeper owns it) on EVERY target including →open; emits a task.staged event carrying staged.note_key. PDS wave 24: this verb also owns the ADJUDICATION TRIPLE — --disposition (open|parked|closed, normalised here because one writer means one normaliser), --note/content.disposition_reason and --reopen-trigger are written in that same CAS update or not at all, and a --disposition parked with no trigger on the stage and none on the row is refused BEFORE anything is written. Raw /v1/data/mutate changes of content.disposition on a type:task are refused and name this verb. done is reached ONLY through `bp task close`, in_progress ONLY through `bp task claim`, kills go through close (→ cancelled); an illegal transition (e.g. open → done) is a 422 naming from,to. NO epoch fence — thought is not contended work.",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/stage"},
        auth_tier: "read",
        args: [
          %{
            name: "doc_id",
            required: true,
            type: "string",
            summary: "Task document id to stage."
          },
          %{
            name: "state",
            required: true,
            type: "string",
            summary:
              "Target lifecycle state: considering | researching | open — or the row's OWN current state (e.g. done on a done row), the same-state no-op that adjudicates a finished row in place without reopening it."
          }
        ],
        flags: [
          %{
            name: "object",
            type: "string",
            summary:
              "What the thought is ABOUT: research | build. Written into content.engagement on a →considering/researching stage (defaults to research); ignored on →open. An invalid value 400s."
          },
          %{
            name: "note",
            type: "string",
            summary:
              "Free-text adjudication reason. Written to the DURABLE content.disposition_reason — NOT to the engagement lease, which the TTL sweeper deletes after ~900s. Recorded on every stageable target. IT REPLACES, IT DOES NOT APPEND: the field holds ONE reason for ONE disposition, so a second annotator supersedes the first WITHOUT WARNING — do not use it as a general annotation channel, and never put a caution there that another agent must still see. Nothing is destroyed: every stage emits a task.staged event carrying the note IN FULL, so a superseded note is recoverable from `bp task events`. A blank note overwrites nothing."
          },
          %{
            name: "worker",
            type: "string",
            summary:
              "The agent/worker owning the thought, stamped into content.engagement.holder."
          },
          %{
            name: "disposition",
            type: "string",
            summary:
              "The adjudication TERM (PDS wave 24): open | parked | closed, trimmed and downcased by this one writer. Written to the DURABLE content.disposition in the SAME CAS update as the transition and the reason. This verb is the ONLY writer: /v1/data/mutate refuses a raw change of content.disposition on a type:task and names this flag. Omitted → the row's existing term is left exactly as it was. Anything outside the vocabulary is a 400."
          },
          %{
            name: "reopen-trigger",
            type: "string",
            summary:
              "What would make a parked row worth reconsidering. Written to the DURABLE content.reopen_trigger. REQUIRED with --disposition parked unless the row already carries one — a park with no trigger is a 422 (missing_reopen_trigger) and NOTHING is written, because a park that cannot say what would reopen it has decided nothing. Blank counts as absent."
          },
          %{
            name: "rerun",
            type: "string",
            summary:
              "PDS wave 28 — THE FOURTH DURABLE KEY: one command an auditor can run to try to prove this reason WRONG. Written to the DURABLE content.disposition_rerun in the SAME CAS update as the rest of the adjudication; the raw /v1/data/mutate door refuses it and names this flag, exactly as it does for content.disposition. OPTIONAL, and that is deliberate: a reason may honestly refuse to be checkable (a licence, a runtime-only probe, a judgment call) and omitting --rerun is a PASS, demoted never rejected. LEGAL SPELLINGS — `git rev-list --count origin/main..<sha> | grep -qx 0`, `git cat-file -e origin/main:<path>`, `git grep -n <token> origin/main -- <path>`; each reports the probe's OWN failure as a non-zero exit. REFUSED SPELLINGS (422 unfalsifiable_rerun, NOTHING written): `git -C` in any spelling (also --git-dir/--work-tree — it retargets the repo the check runs against), a `test`/`[` filesystem predicate (asserts about the local checkout, not origin/main), `$( … )` or backtick command substitution (the exit code becomes the outer command's, swallowing the probe's failure), `git merge-base --is-ancestor` (refused by truth-grip's own screen), and a PIPE-MASKED tail whose last stage merely formats (head/tail/wc/cat/jq/…) — `git show origin/main:<deleted> | head -1` exits 0 while the bare `git show` exits 128. Blank counts as absent. Distinctness is NOT applied to this field (PDS-D391b/D336(a)): a SHARED rerun over distinct rows is the honest shape."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      %{
        id: "task.pulse",
        noun: "task",
        verb: "pulse",
        summary:
          "Heartbeat a held claim: write the now-line (what you're doing right now) AND renew the lease (epoch bump + ts refresh) in one atomic write. No epoch arg — pulse survives fence bumps; a lost lease (reaped/released/closed) is 409 not_holder, never a silent re-claim. Boards render claim.now with its ts so a stale pulse reads stale.",
        http: %{method: "POST", path_template: "/v1/tasks/:doc_id/pulse"},
        auth_tier: "read",
        args: [
          %{
            name: "doc_id",
            required: true,
            type: "string",
            summary: "Task document id to pulse."
          },
          %{
            name: "worker_id",
            required: true,
            type: "string",
            summary: "Worker identity that holds the claim."
          }
        ],
        flags: [
          %{
            name: "now",
            type: "string",
            summary:
              "The now-line text (required, max 500 bytes), e.g. \"warm-up pinned, rerunning\"."
          },
          %{
            name: "criterion",
            type: "int",
            summary:
              "Optional acceptance_criteria index this pulse is working on (boards spin that lock)."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      },
      # ── The fleet noun (Personal Dev Fleet, Wave A) ──────────────────────
      # Presence vocabulary over /v1/fleet/* — beat (heartbeat write) and
      # roster (fail-closed presence read). Dispatch and table rendering are
      # manifest-driven: ZERO Go changes (the roster envelope's `documents`
      # key is what every installed bp binary renders as a real table).
      %{
        id: "fleet.roster",
        noun: "fleet",
        verb: "roster",
        summary:
          "The fleet roster: every listener with online/offline computed server-side (offline iff now - last_seen > ttl_s; missing last_seen = offline, fail closed) plus each worker's current in_progress task.",
        http: %{method: "GET", path_template: "/v1/fleet/roster"},
        auth_tier: "read",
        args: [],
        flags: [
          %{
            name: "dataset",
            type: "string",
            summary: "Dataset to read the roster from (defaults to production)."
          }
        ],
        writes: false,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "table",
        scoped_prefix: nil
      },
      %{
        id: "fleet.beat",
        noun: "fleet",
        verb: "beat",
        summary:
          "Listener presence heartbeat: upsert this worker's listener row (first beat registers it; every later beat is one zero-row atomic write). last_seen is server-stamped — send ttl as data, never a timestamp.",
        http: %{method: "POST", path_template: "/v1/fleet/beat"},
        auth_tier: "write",
        args: [
          %{
            name: "worker",
            required: true,
            type: "string",
            summary: "Worker identity beating (the unique presence key)."
          }
        ],
        flags: [
          %{
            name: "status",
            type: "string",
            summary: "Self-declared state: idle | working | blocked."
          },
          %{
            name: "ttl",
            type: "int",
            summary: "Self-declared staleness budget in seconds (default 120)."
          },
          %{
            name: "agent",
            type: "string",
            summary: "What runs the session: claude-code | codex | custom."
          },
          %{
            name: "scope",
            type: "string",
            summary: "What the listener works on (repo, area, project)."
          },
          %{
            name: "capacity",
            type: "string",
            summary:
              "Capacity for routing. A JSON object string is validated + stored structured, e.g. '{\"size_class\":\"heavy\",\"slots_total\":2,\"slots_free\":1,\"budget\":5.0}' (size_class: light | standard | heavy | xl); a plain string is a legacy free-form hint, e.g. \"1 task\"."
          },
          %{
            name: "dataset",
            type: "string",
            summary: "Dataset to write the listener row into (defaults to production)."
          }
        ],
        writes: true,
        batch: false,
        paginated: false,
        dry_run: false,
        default_output: "minimal",
        scoped_prefix: nil
      }
      # NOTE: the content-graph read verbs (graph / graph-orphans /
      # graph-dangling over /v1/graph/*) are NO LONGER declared here. They
      # moved to the CORE verb registry (Barkpark.Plugins.Capabilities, the
      # `graph` noun) because the content graph roots on ANY content doc — so
      # the verbs must survive the `config :barkpark, :plugins, []` kill switch
      # alongside their CORE-mounted /v1/graph/* routes (fresh-install
      # invariant).
    ]
  end

  @doc """
  Projects a task document's dependency + hierarchy edges into the content
  graph (Goal ges/graph-edge-seam Phase 3).

  Implemented as the RESOLVER form directly (not the bare additive
  `extract_edges/2`) — the `@resolver_callbacks` entry for
  `resolve_extract_edges` is `{nil, nil, nil, :none}`, so the registry collects
  ONLY the resolver form. This mirrors how plugins implement
  `resolve_doc_actions/2`. The default lift is supplied here explicitly:
  `prev ++ extract_edges(ctx.doc)`.

  PURE — no `get_document`, no `task_edges` query, no DB. It reads ONLY the doc
  payload:

    * `doc.task_edges` — the doc's HYDRATED `task_edges` rows. The authoritative
      dependency store is the `task_edges` table, NOT `content.dependencies`
      (which `Barkpark.Tasks.schema_definitions/1` documents as a DEAD KEY the
      engine never writes/reads). Because this callback must be pure, it cannot
      query `task_edges` itself — the EdgeProjector worker hydrates the rows onto
      the payload via `Tasks.hydrate_edges/1` BEFORE projection (see
      `Barkpark.EdgeProjector.ProjectorWorker`). Each hydrated row carries its
      real `:kind` (`"blocks"` | `"discovered-from"`) which is mapped STRAIGHT
      THROUGH — never hardcoded `"blocks"`. Both kinds are whitelisted in
      `Barkpark.Content.Edge`, so they pass changeset validation.
    * `content.parent_id` — the hierarchy parent → one `parent` edge
      (`from_id` = child, `to_id` = parent).
    * `content.wave_paper` and `content.papers` — the paper this task cites →
      one edge per distinct target, `kind` = the source field name. Neither key
      reaches the CORE extractor as an edge (`wave_paper` is undeclared;
      `papers` is a bare `"array"`, not `arrayOf reference`), so without this
      they contributed nothing to the graph. `design_doc` is a declared
      `reference` and is projected by the core extractor, NOT here — a task
      citing one paper through several keys gets one edge per key, which is
      what `Tasks.Expectations.driven_tasks/2` reports as its `via` list. See
      `paper_citation_edges/2` for the measured corpus impact and for why this
      rides the plugin callback rather than a schema `reference` declaration.

  When `doc.task_edges` is absent (an un-hydrated payload — e.g. a task saved
  outside the projector worker, or a non-task doc), NO dependency edge is
  emitted: the dead `content.dependencies` key is NEVER read, so an un-hydrated
  task simply contributes only its `parent` edge until the worker re-hydrates it
  on the next rebuild. The core Projector pass resolves dangling targets; this
  callback never does. Guards a `nil` `ctx.doc` (the `{nil, nil, nil, :none}`
  entry skips the registration-time fingerprint, so a nil-doc crash would only
  surface at collection time) → returns `prev` unchanged.
  """
  @impl Barkpark.Plugin
  def resolve_extract_edges(prev, ctx) do
    case Map.get(ctx, :doc) do
      nil -> prev
      doc -> prev ++ extract_edges(doc, ctx)
    end
  end

  @impl Barkpark.Plugin
  def extract_edges(nil, _ctx), do: []

  def extract_edges(doc, _ctx) do
    doc_id = Map.get(doc, :doc_id) || Map.get(doc, "doc_id")
    content = Map.get(doc, :content) || Map.get(doc, "content") || %{}

    if is_binary(doc_id) do
      from_id = Barkpark.Content.published_id(doc_id)

      dep_edges = dep_edges_from_task_edges(doc, from_id)
      parent_edges = parent_edge(content, from_id)
      paper_edges = paper_citation_edges(content, from_id)

      dep_edges ++ parent_edges ++ paper_edges
    else
      []
    end
  end

  # Read the HYDRATED `task_edges` rows off the payload. The worker attaches
  # them as `doc.task_edges` — a list of `%{to_id: <doc_id>, kind: <kind>}` maps
  # (PKs already resolved back to doc_ids by `hydrate_edges/1`). Each row's real
  # `kind` is carried straight through (NEVER hardcoded "blocks"), so both
  # `blocks` AND `discovered-from` edges surface. An un-hydrated payload (no
  # `:task_edges` key) yields []. NEVER reads `content.dependencies` (DEAD KEY).
  defp dep_edges_from_task_edges(doc, from_id) do
    doc
    |> hydrated_task_edges()
    |> Enum.flat_map(fn row ->
      to = Map.get(row, :to_id) || Map.get(row, "to_id")
      kind = Map.get(row, :kind) || Map.get(row, "kind")

      if is_binary(to) and to != "" and is_binary(kind) and kind != "" do
        [
          %{
            from_id: from_id,
            to_id: Barkpark.Content.published_id(to),
            kind: kind,
            plugin_source: "tasks"
          }
        ]
      else
        []
      end
    end)
  end

  defp hydrated_task_edges(doc) do
    case Map.get(doc, :task_edges) || Map.get(doc, "task_edges") do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end

  defp parent_edge(content, from_id) do
    case Map.get(content, "parent_id") do
      parent when is_binary(parent) and parent != "" ->
        [
          %{
            from_id: from_id,
            to_id: Barkpark.Content.published_id(parent),
            kind: "parent",
            plugin_source: "tasks"
          }
        ]

      _ ->
        []
    end
  end

  # ── Paper citations: `wave_paper` + `papers` (graph-papers) ────────────────
  #
  # A task cites the Paper that drives it through THREE keys, and until this
  # function existed only ONE of them reached the graph:
  #
  #   * `design_doc` — declared `"type" => "reference"` on the task schema, so
  #     `Content.Edges.extract_edges/2` projects it. Untouched here.
  #   * `papers` — declared `"type" => "array"`. `extract_field_edges/2` matches
  #     only `"reference"` and `"arrayOf"`-of-`"reference"`; a bare `"array"`
  #     falls to its catch-all `[]` clause.
  #   * `wave_paper` — not declared on the task schema at all, so it is never in
  #     the `fields` list the core extractor folds over. The epic-cycle harness
  #     is its only writer.
  #
  # MEASURED on the live corpus (2026-08-24, 7249 published tasks / 1015
  # published papers): 213 tasks carry `design_doc`, 412 carry `papers`, 4320
  # carry `wave_paper`. Distinct papers reachable through `bp graph tasks` was
  # 24; the three keys together cite 564. Every wave paper the epic-cycle
  # harness has written was disconnected from its own wave.
  #
  # WHY HERE AND NOT ON THE SCHEMA. `parent_id` is the precedent directly above:
  # a plain content key the plugin knows names a document, projected by this
  # pure callback rather than by a schema `reference` declaration. Taking that
  # route keeps two properties the schema route would break — `papers` stays the
  # v1 read-only array whose sole writer is `POST /v1/tasks/:id/papers` (and its
  # `check_optional_string_list` validation), and `wave_paper` stays undeclared,
  # so declaring it does not hand 4320 rows an editable Studio input on a field
  # the harness owns. `design_doc` also stays the ONE single-reference field, so
  # `?expand=design_doc` is unaffected.
  #
  # `kind` IS the source field name, matching the graph-edge-seam convention the
  # core extractor follows, so `Tasks.Expectations.driven_tasks/2` reports the
  # citing channel in its `via` list. That reader is kind-agnostic and already
  # documents the multi-channel case ("a task may cite the paper via more than
  # one field"), so nothing downstream needed a change to read these.
  defp paper_citation_edges(content, from_id) do
    wave_edges =
      content
      |> Map.get("wave_paper")
      |> List.wrap()
      |> paper_edges(from_id, "wave_paper")

    list_edges =
      content
      |> Map.get("papers")
      |> List.wrap()
      |> paper_edges(from_id, "papers")

    wave_edges ++ list_edges
  end

  # One edge per non-blank id. Deduped on the resolved target because
  # `content_edges` is unique on `(from_id, to_id, kind)` — a `papers` list that
  # names the same paper twice (or names both `slug` and `drafts.slug`, which
  # `published_id/1` collapses to one target) must not emit a colliding pair.
  defp paper_edges(values, from_id, kind) do
    values
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&Barkpark.Content.published_id(String.trim(&1)))
    |> Enum.uniq()
    |> Enum.map(fn to_id ->
      %{from_id: from_id, to_id: to_id, kind: kind, plugin_source: "tasks"}
    end)
  end

  @doc """
  Hydrate a task document's payload with its authoritative `task_edges` rows so
  the PURE `extract_edges/2` callback can project them WITHOUT a DB call.

  This is the seam that resolves the purity-vs-correctness contradiction: the
  real dependency data lives in the `task_edges` table (keyed on
  `documents.id`), but `extract_edges/2` must be pure. The EdgeProjector worker
  — which already touches the DB to list the corpus — calls this on each task
  doc BEFORE handing it to the projector. It:

    1. resolves the doc's PK (`documents.id`) — a `%Document{}` already carries
       it as `:id`;
    2. fetches the doc's OUTBOUND `task_edges` rows (`Tasks.edges(pk, direction:
       :outbound, kind: :all)` — every kind, not just `:blocks`);
    3. maps each row's `to_id` (a PK) back to its `doc_id` string, carrying the
       row's `kind`;
    4. attaches the result as `doc.task_edges` (`[%{to_id: doc_id, kind: kind}]`).

  Only `type == "task"` docs are hydrated; any other doc (or a doc whose PK
  cannot be resolved) is returned UNCHANGED. Returns the (possibly hydrated)
  doc.
  """
  @spec hydrate_edges(map()) :: map()
  def hydrate_edges(doc) when is_map(doc) do
    if task_doc?(doc) do
      case doc_pk(doc) do
        pk when is_binary(pk) ->
          rows =
            pk
            |> Barkpark.Tasks.edges(direction: :outbound, kind: :all)
            |> Enum.flat_map(&edge_row_to_payload/1)

          put_task_edges(doc, rows)

        _ ->
          doc
      end
    else
      doc
    end
  end

  def hydrate_edges(doc), do: doc

  @doc """
  Batched `hydrate_edges/1` over a whole corpus — the EdgeProjector rebuild
  path. Per-doc result identical, but the DB cost is FLAT instead of per-doc:
  ONE outbound `task_edges` query over every task doc's PK (all kinds) plus
  ONE `documents` id→doc_id map for the targets — was one `Tasks.edges/2`
  query per task doc plus one `Repo.get/2` per edge row (the rebuild-path
  N+1). Non-task docs, and task docs with no resolvable PK, pass through
  UNCHANGED; input order is preserved.
  """
  @spec hydrate_edges_batch([map()]) :: [map()]
  def hydrate_edges_batch(docs) when is_list(docs) do
    pks =
      docs
      |> Enum.filter(&task_doc?/1)
      |> Enum.map(&doc_pk/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if pks == [] do
      docs
    else
      payloads_by_pk = task_edge_payloads_by_pk(pks)

      Enum.map(docs, fn doc ->
        with true <- is_map(doc) and task_doc?(doc),
             pk when is_binary(pk) <- doc_pk(doc) do
          put_task_edges(doc, Map.get(payloads_by_pk, pk, []))
        else
          _ -> doc
        end
      end)
    end
  end

  # ONE outbound task_edges query over all task PKs + ONE Document id→doc_id
  # map for the targets; rows whose target row no longer exists are dropped
  # (mirrors edge_row_to_payload/1). Grouped by from_id for the per-doc attach.
  defp task_edge_payloads_by_pk(pks) do
    import Ecto.Query, only: [from: 2]

    edge_rows =
      Barkpark.Repo.all(from(e in Barkpark.Tasks.Edge, where: e.from_id in ^pks))

    doc_id_by_pk =
      case edge_rows |> Enum.map(& &1.to_id) |> Enum.uniq() do
        [] ->
          %{}

        to_pks ->
          from(d in Barkpark.Content.Document,
            where: d.id in ^to_pks,
            select: {d.id, d.doc_id}
          )
          |> Barkpark.Repo.all()
          |> Map.new()
      end

    edge_rows
    |> Enum.group_by(& &1.from_id)
    |> Map.new(fn {from_pk, rows} ->
      payloads =
        Enum.flat_map(rows, fn row ->
          case Map.get(doc_id_by_pk, row.to_id) do
            to_doc_id when is_binary(to_doc_id) -> [%{to_id: to_doc_id, kind: row.kind}]
            _ -> []
          end
        end)

      {from_pk, payloads}
    end)
  end

  # Map a `task_edges` row (PK-keyed) to the payload shape the pure callback
  # reads: `%{to_id: <doc_id>, kind: <kind>}`. Resolves the `to_id` PK back to
  # its `doc_id` string; drops the row if the target row no longer exists.
  defp edge_row_to_payload(%Barkpark.Tasks.Edge{to_id: to_pk, kind: kind}) do
    case Barkpark.Repo.get(Barkpark.Content.Document, to_pk) do
      %Barkpark.Content.Document{doc_id: to_doc_id} when is_binary(to_doc_id) ->
        [%{to_id: to_doc_id, kind: kind}]

      _ ->
        []
    end
  end

  defp edge_row_to_payload(_), do: []

  defp task_doc?(doc) do
    (Map.get(doc, :type) || Map.get(doc, "type") || Map.get(doc, "_type")) == "task"
  end

  defp doc_pk(%Barkpark.Content.Document{id: id}) when is_binary(id), do: id
  defp doc_pk(doc), do: Map.get(doc, :id) || Map.get(doc, "id")

  defp put_task_edges(%Barkpark.Content.Document{} = doc, rows),
    do: Map.put(doc, :task_edges, rows)

  defp put_task_edges(doc, rows) when is_map(doc), do: Map.put(doc, :task_edges, rows)
end
