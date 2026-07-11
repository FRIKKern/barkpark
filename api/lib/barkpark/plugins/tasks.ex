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

    * `register_routes/1` — the twelve `/v1/tasks` endpoints the `bp task` CLI
      consumes, declared with `auth: :token_root` so the dormant
      host-level `scope "/v1", BarkparkWeb do … plugin_routes(scope: :token_root)`
      wrapper mounts them at `/v1/tasks/*` behind the `[:api, :require_token]`
      pipeline. Replaces the explicit `scope "/v1/tasks"` block that used to live
      in `router.ex` (C4-3b). The `TasksController` itself stays in core; this
      plugin only owns the route declarations.

    * `cli_commands/0` — the nine `task.*` CLI verbs (`ls`, `ready`, `prime`, `get`,
      `claim`, `close`, `stamp`, `next`, `move`) the `/v1/capabilities` manifest
      exposes. Five
      moved verbatim from `Barkpark.Plugins.Capabilities`'s core verb registry;
      `next` (the queue-based atomic claim) and `stamp` (criterion-level
      mid-claim evidence) were added later. `task` is no
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
  Declares the `task` document type by delegating to
  `Barkpark.Tasks.schema_definitions/1`.

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

  Non-task documents pass untouched.
  """
  @impl Barkpark.Plugin
  def lifecycle_hooks do
    %{before_save: [&quality_gate/1]}
  end

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

  Two entries:

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

    task_list =
      if task_schema_present?(dataset) do
        [%{type: :document_list, label: "Tasks", doc_type: "task", icon: "✅"}]
      else
        []
      end

    task_list ++ [projects_link]
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
  The `/v1/tasks` endpoints the `bp task` CLI consumes, mirroring —
  order-preserving — the `scope "/v1/tasks"` block this replaces
  in `router.ex`
  (C4-3b). Every spec carries `auth: :token_root`, so the dormant host-level
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
      {:post, "/tasks/claim", BarkparkWeb.TasksController, :claim, auth: :token_root},
      {:post, "/tasks/edges", BarkparkWeb.TasksController, :add_edge, auth: :token_root},
      {:get, "/tasks/:doc_id", BarkparkWeb.TasksController, :show, auth: :token_root},
      {:get, "/tasks/:doc_id/edges", BarkparkWeb.TasksController, :edges, auth: :token_root},
      {:post, "/tasks/:doc_id/claim", BarkparkWeb.TasksController, :claim_by_id,
       auth: :token_root},
      {:post, "/tasks/:doc_id/close", BarkparkWeb.TasksController, :close, auth: :token_root},
      {:post, "/tasks/:doc_id/stamp", BarkparkWeb.TasksController, :stamp, auth: :token_root},
      {:post, "/tasks/:doc_id/labels", BarkparkWeb.TasksController, :relabel, auth: :token_root},
      {:post, "/tasks/:doc_id/papers", BarkparkWeb.TasksController, :papers, auth: :token_root},
      {:post, "/tasks/:doc_id/move", BarkparkWeb.TasksController, :move, auth: :token_root},
      # Barkpark Projects — the native task BOARD (read-only :ops LiveView),
      # mounted at /admin/projects (the :ops bucket). /admin (not /studio) so
      # the desk-link scoper leaves the path intact — see desk_items/1 and the
      # pulse dashboard precedent. This is the GUI realization of the task
      # design-language spec; the tasks plugin owns type:task, so the board
      # belongs in its namespace.
      {:live, "/projects", Barkpark.Plugins.Tasks.Web.BoardLive, :index, auth: :ops}
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

  Nine verbs over nine routes, all `auth_tier: "read"` (the `/v1/tasks` scope is
  `:api + :require_token`, NOT admin — claim/close are bearer-gated workflow ops,
  not document mutations):

    * `ls` — `GET /v1/tasks` (paginated). READ, table.
    * `ready` — `GET /v1/tasks/ready` (paginated). READ, table.
    * `get` — `GET /v1/tasks/:doc_id`. READ, table.
    * `claim` — `POST /v1/tasks/:doc_id/claim`. WRITES, minimal receipt.
    * `close` — `POST /v1/tasks/:doc_id/close`. WRITES, minimal receipt.
    * `stamp` — `POST /v1/tasks/:doc_id/stamp` (criterion-level mid-claim
      evidence, expressive-agent-loops D8). WRITES, minimal receipt.
    * `next` — `POST /v1/tasks/claim` (queue-based: atomically hand me the next
      ready task in priority order). WRITES, minimal receipt. Returns
      `{"ok":false,"reason":"no_ready"}` with HTTP 200 when the queue is empty —
      a valid outcome, not an error.
    * `move` — `POST /v1/tasks/:doc_id/move` (rail-l3 re-parent). WRITES, minimal
      receipt.
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
          %{name: "limit", type: "int", summary: "Max tasks to return.", default: 50}
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
        summary: "List ready (unblocked) tasks.",
        http: %{method: "GET", path_template: "/v1/tasks/ready"},
        auth_tier: "read",
        args: [],
        flags: [
          %{name: "limit", type: "int", summary: "Max tasks to return.", default: 50}
        ],
        writes: false,
        batch: false,
        paginated: true,
        dry_run: false,
        default_output: "table",
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
          %{name: "limit", type: "int", summary: "Ready-head and event-window size.", default: 10}
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
          "Close a claimed task by id; --set 'criteria:=[…]' marks acceptance criteria met with evidence in the same atomic write. By default fences on a claim-time work digest: if the task's brief (title/description/acceptance_criteria) changed under your claim, the close 409s doc_changed_since_claim — re-read, then close again (or --set observed_rev=<rev> for strict full-rev CAS instead).",
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
                "\"evidence\":\"PR #1234\"}]' flips acceptance_criteria met/evidence atomically " <>
                "with the close (same rev CAS — no separate racing mutation). Optional " <>
                "\"criterion\" per entry text-guards against a reordered/edited list (409 " <>
                "criteria_mismatch). Unmet criteria never block a close (soft warning only). " <>
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
        id: "task.stamp",
        noun: "task",
        verb: "stamp",
        summary:
          "Stamp ONE acceptance criterion mid-claim: --criterion N with either --met --evidence \"…\" (flips the lock; evidence is REQUIRED, non-empty) or --miss --note \"…\" (records the honest attempt on the criterion's attempts list — bounded to the 5 most recent — WITHOUT flipping met). Holder-only + the same epoch fence as close (a lapsed claim can't stamp — renew via re-claim, then restamp); your own stamps never trip close's work-digest fence. Emits a task.criterion event. Stamp is progress; close is the seal.",
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
            summary: "Zero-based index into acceptance_criteria — the criterion to stamp."
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
        summary: "Atomically claim the next ready task (priority order).",
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

      dep_edges ++ parent_edges
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
