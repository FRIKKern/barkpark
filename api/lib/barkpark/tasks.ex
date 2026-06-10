defmodule Barkpark.Tasks do
  @moduledoc """
  W7a step 1 — Task-document schema on the existing `documents` substrate.

  Tasks live as rows in the `documents` table, scoped by the shipped
  workspace/project/dataset tenancy primitives. Everything is a task: a
  goal/epic is just a root task, a phase is just a task with children, and
  a rail is the chronological child tasks of a task. This module owns:

    * the single `task` schema definition the seeds.exs and
      `Plugins.Bootstrap` paths register so it appears in the
      `schema_definitions` table alongside `post`/`page`/`paper`;
    * the **lifecycle status** axis for task documents — a separate axis
      from the existing `documents.status` (Sanity draft/published flow);
    * a `validate_task_content/1` validator the document write paths call
      before insert/update when `type == "task"`.

  ## Status-axis decision (per plan §1 "Status widening")

  The plan offered two options. This module picks **option (b)** — store
  the task lifecycle on a NEW jsonb field `content.lifecycle_status`,
  leave `documents.status` alone for the existing draft/published flow.

  Rationale:

    * `documents.status` already mixes two orthogonal axes (Sanity
      `draft/published/archived` + project-type `active/planning/completed`).
      Adding `open/in_progress/blocked/done/cancelled` would mix a third
      axis and force every reader pattern-matching on `status` to know
      which one applies.
    * Future Tasks API + Studio dual-reads of the SAME task row need both
      axes independently: a task can be a `documents.status="draft"` (not
      yet visible in published reads) while carrying
      `content.lifecycle_status="open"` (orchestrator-claimable).
    * Minimal schema diff: no enum widening, no string-list to keep in
      sync across changeset + Studio. The DB-level guarantee is a
      conditional check constraint on `content->>'lifecycle_status'`
      that fires only for `type='task'` rows (see migration
      `20260528100000_w7a_task_schema`).
    * Reversible cleanly: the migration's `down/0` drops the constraint.

  ## Field contract for `kind:task` (per plan §1)

      content: %{
        "kind" => "task",                       # required, must equal "task"
        "lifecycle_status" => "open",           # required, one of the 5 below
        "priority" => 0..4,                     # optional integer, 0..4 inclusive
        "assignee" => "<token-id>" | nil,       # optional string
        "dependencies" => ["<doc_id>", ...],    # optional array of strings
        "claim" => %{                           # optional map (claim primitives, W7-04)
          "worker" => "<id>",
          "ts_iso" => "2026-05-27T11:23:45Z",
          "epoch"  => 1
        },
        "parent_id" => "<parent-task-doc-id>"   # optional string (hierarchy)
      }

  The validator enforces only what is REQUIRED + the enum shape of the five
  string fields; everything else is shape-checked permissively (the
  authoritative `task_edges` table arrives in W7-02). The plan calls this
  "the tightened contract — what the live readers actually consume."

  The **task-dossier** schema (see `task_schema/1`) additionally declares
  optional working-memory fields — `description`, `design`, `design_doc`,
  `acceptance_criteria`, `estimate`, `due_at`, `labels`, `worklog`,
  `blocked_reason`, `attachments`, `outcome`, `close_reason`, `retro`,
  `papers`, `history`, `history_summary` — all shape-checked
  top-level-only when present, never required. The engine reads none of
  them; they are agent/human working memory on the same row.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.{Document, MutationEvent, Scope, SchemaDefinition}
  alias Barkpark.Repo
  alias Barkpark.Tasks.Edge

  # W7-04 mutation_events kinds. Routed into the existing `mutation` text column
  # so the spine, webhooks, and listen endpoint surface task ops alongside
  # document ops without a schema change.
  @event_task_claimed "task.claimed"
  @event_task_closed "task.closed"
  @event_task_mutated "task.mutated"
  # tt5: file-claim label support. Emitted when content.labels changes via
  # relabel_by_id/3 (the bd-shim's `update --add-label/--remove-label` path).
  @event_task_relabeled "task.relabeled"
  # Phase A: task→paper reference support. Emitted when content.papers changes
  # via update_paper_refs_by_id/3 (the `/v1/tasks/:doc_id/papers` path).
  @event_task_referenced "task.referenced"

  @closed_lifecycle_statuses ~w(done cancelled blocked)

  @lifecycle_statuses ~w(open in_progress blocked done cancelled)
  @kinds ~w(task)

  @doc "The five lifecycle-status string values a task document may carry."
  @spec lifecycle_statuses() :: [String.t()]
  def lifecycle_statuses, do: @lifecycle_statuses

  @doc "The `content.kind` discriminator values (only `task`)."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  # ─── Schema definitions (registered via seeds.exs + Plugins.Bootstrap) ─────

  @doc """
  Returns the `%SchemaDefinition{}` struct the W7 substrate needs: `task`.

  The schema is the **task dossier** — the complete working memory an AI
  agent needs for one unit of work, in four editor groups: a *Brief* it
  claims against (description, design, acceptance criteria, a reference to
  the design paper, an estimate), a *Work* surface it appends to (worklog,
  blocked_reason, attachments), a *Close-out* it should fill (outcome with
  resolution + actuals, retro), and a *System* ledger only engines write
  (claim, history, edges mirror). Every storage shape stays byte-compatible
  with the engine: the schema declares the truth about every live key
  instead of leaving half the contract undeclared, and upgrades exactly the
  fields where a richer type buys workflow value (parent_id → reference,
  design_doc → expandable reference, acceptance_criteria → checkable
  arrayOf-composite) without changing what the ready query, sweeper, or
  compactor read. The hard write contract is still `validate_task_content/1`.

  Everything is a task: goals/epics, phases, and events are all just tasks
  (a goal is a root task, a phase is a task with children).

  `dataset` defaults to `"production"` — matching every other seed schema.
  """
  @spec schema_definitions(String.t()) :: [SchemaDefinition.t()]
  def schema_definitions(dataset \\ "production") do
    [task_schema(dataset)]
  end

  @doc "Just the `task` schema struct (callers that only need one)."
  @spec task_schema(String.t()) :: SchemaDefinition.t()
  def task_schema(dataset \\ "production") do
    %SchemaDefinition{
      name: "task",
      title: "Task",
      icon: "✅",
      visibility: "public",
      dataset: dataset,

      # Generic list-row preview (host affordance, plugin-declared data):
      # badge + "P<n>" meta. UNCHANGED on purpose — only two slots exist
      # (PaneBuilder), the pane-doc-badge--<slug> CSS modifiers already
      # theme the lifecycle values, and priority is the ready-sort key so
      # it earns the meta slot over assignee/due_at.
      list_preview: %{
        "badge" => "lifecycle_status",
        "meta" => %{"field" => "priority", "prefix" => "P"}
      },

      # Editor tab bar (Sanity-style groups; lucide icons — book.json idiom).
      # INVARIANT: once groups exist, a field without a "group" key appears
      # on NO tab — every field below must carry one (regression-tested in
      # tasks_schema_dossier_test.exs).
      groups: [
        %{"name" => "brief", "title" => "Brief", "icon" => "clipboard-list"},
        %{"name" => "work", "title" => "Work", "icon" => "activity"},
        %{"name" => "close", "title" => "Close", "icon" => "flag"},
        %{"name" => "system", "title" => "System", "icon" => "settings"}
      ],

      # Bookmarkable ?desk= filter chips over the task list pane.
      desk_groups: [
        %{
          "name" => "open",
          "title" => "Open",
          "filter" => %{"content.lifecycle_status" => %{"eq" => "open"}}
        },
        %{
          "name" => "in_progress",
          "title" => "In progress",
          "filter" => %{"content.lifecycle_status" => %{"eq" => "in_progress"}}
        },
        %{
          "name" => "blocked",
          "title" => "Blocked",
          "filter" => %{"content.lifecycle_status" => %{"eq" => "blocked"}}
        },
        %{
          "name" => "closed",
          "title" => "Closed",
          "filter" => %{"content.lifecycle_status" => %{"in" => ["done", "cancelled"]}}
        },
        %{"name" => "all", "title" => "All", "filter" => %{}}
      ],

      # `initial_values` is deliberately ABSENT. `create_document` validates
      # task content BEFORE the initial-values merge, so defaults here cannot
      # make a bare Studio create pass `validate_task_content/1` — and a
      # priority default WOULD deep-merge into every API create that omits
      # priority, silently moving those tasks from NULLS-LAST to mid-queue
      # in the ready sort. Studio task creation needs a create-path change,
      # not schema metadata.

      # Soft cross-field nudges → Studio banner only, never blocks a save.
      # Close-loop discipline without fighting the API-single-writer model.
      cross_validations: [
        %{
          "name" => "done_needs_outcome",
          "title" => "A finished task should record an outcome summary",
          "rule" => %{
            "any" => [
              %{
                "field" => "lifecycle_status",
                "operator" => "in",
                "value" => ["open", "in_progress", "blocked"]
              },
              %{"field" => "outcome.summary", "operator" => "non_empty"}
            ]
          },
          "level" => "warning",
          "fields" => ["outcome"]
        },
        %{
          "name" => "blocked_needs_reason",
          "title" => "A blocked task should say what it is blocked on",
          "rule" => %{
            "any" => [
              %{"field" => "lifecycle_status", "operator" => "neq", "value" => "blocked"},
              %{"field" => "blocked_reason", "operator" => "non_empty"}
            ]
          },
          "level" => "warning",
          "fields" => ["blocked_reason"]
        },
        # status==in_progress without a live claim.worker means someone
        # hand-flipped status around the claim/close engine.
        %{
          "name" => "claimed_has_worker",
          "title" =>
            "in_progress tasks should carry a live claim (set via POST /v1/tasks/:id/claim, not by hand)",
          "rule" => %{
            "any" => [
              %{"field" => "lifecycle_status", "operator" => "neq", "value" => "in_progress"},
              %{"field" => "claim.worker", "operator" => "non_empty"}
            ]
          },
          "level" => "warning",
          "fields" => ["lifecycle_status", "claim"]
        },
        %{
          "name" => "cancelled_needs_reason",
          "title" => "Cancelled tasks should record why",
          "rule" => %{
            "any" => [
              %{"field" => "lifecycle_status", "operator" => "neq", "value" => "cancelled"},
              %{"field" => "close_reason", "operator" => "non_empty"}
            ]
          },
          "level" => "warning",
          "fields" => ["close_reason"]
        }
      ],

      # Editor-header link action — agent/human bridge to the raw API view.
      actions: [
        %{
          "name" => "open_api",
          "label" => "Open in Tasks API",
          "kind" => "link",
          "icon" => "external-link",
          "opts" => %{"href" => "/v1/tasks/:id"}
        }
      ],
      fields: [
        # ── BRIEF — what the claiming agent reads first ─────────────────
        %{"name" => "title", "title" => "Title", "type" => "string", "group" => "brief"},

        # The what/why. The only free-text field bd-shim writes today
        # (`bd create --description`) — finally declared. `text` not
        # richText: agents write markdown strings, a textarea round-trips
        # them verbatim.
        %{
          "name" => "description",
          "title" => "Description",
          "type" => "text",
          "rows" => 6,
          "group" => "brief",
          "description" =>
            "What this task is and why it exists. Markdown. Written at create time; the claiming agent reads this first."
        },

        # Approach sketch inline; the FULL design doc travels as design_doc.
        %{
          "name" => "design",
          "title" => "Design notes",
          "type" => "text",
          "rows" => 8,
          "group" => "brief",
          "description" =>
            "Approach / architecture sketch, constraints, files to touch. Markdown. For a full design paper, set design_doc instead."
        },

        # Single reference = the ONE join the read path supports:
        # ?expand=design_doc inlines the whole paper in one hop (Expand
        # requires a single non-empty string id — arrays never expand).
        # Stored as a bare paper doc-id string (v1 reference model).
        # Distinct from `papers` (engine-owned list, see system group).
        %{
          "name" => "design_doc",
          "title" => "Design paper",
          "type" => "reference",
          "refType" => "paper",
          "group" => "brief",
          "description" =>
            "Primary design paper (paper doc-id). Expand on read with ?expand=design_doc to get the full paper inline when claiming."
        },

        # Checkable contract for "done". arrayOf-composite renders editable
        # rows with ▲/▼ ordering in Studio; agents tick `met` and cite
        # `evidence` (commit/test) before close — auditable close-out.
        %{
          "name" => "acceptance_criteria",
          "title" => "Acceptance criteria",
          "type" => "arrayOf",
          "ordered" => true,
          "group" => "brief",
          "description" =>
            "Definition of done. The closing agent must set met=true with evidence (commit SHA, test name, URL) per criterion.",
          "of" => %{
            "name" => "criterion",
            "type" => "composite",
            "fields" => [
              %{"name" => "criterion", "title" => "Criterion", "type" => "text", "rows" => 2},
              %{"name" => "met", "title" => "Met", "type" => "boolean"},
              %{"name" => "evidence", "title" => "Evidence", "type" => "string"}
            ]
          }
        },

        # Estimate at create; calibrated against outcome.actual_size at
        # close. Lets a context-budget-constrained agent pick small work
        # off `bd ready`.
        %{
          "name" => "estimate",
          "title" => "Estimate",
          "type" => "composite",
          "group" => "brief",
          "description" =>
            "Set before work starts. Compare with outcome.actual_size at close to calibrate future estimates.",
          "fields" => [
            %{
              "name" => "size",
              "title" => "Size",
              "type" => "select",
              "options" => ["xs", "s", "m", "l", "xl"]
            },
            %{"name" => "reason", "title" => "Reason", "type" => "string"}
          ]
        },

        # Native datetime-local picker in Studio. Engine-inert by design;
        # agents/humans set it. (Started/closed timestamps live in the
        # engine-owned claim map — NOT duplicated here to avoid drift.)
        %{
          "name" => "due_at",
          "title" => "Due",
          "type" => "datetime",
          "group" => "brief",
          "description" =>
            "Soft deadline. Engine-inert — for humans and planners, not the ready sort."
        },

        # UNCHANGED storage: integer 0..4, 0 highest (ready ORDER BY
        # (content->>'priority')::int ASC NULLS LAST). Stays `number` — a
        # select would store strings and break both the sort cast and the
        # micro-validator's integer check.
        %{
          "name" => "priority",
          "title" => "Priority",
          "type" => "number",
          "group" => "brief",
          "description" => "0 (highest) .. 4 (lowest). Drives bd-ready ordering."
        },

        # PROMOTED from undeclared: the relabel endpoint union-writes it;
        # now also human-editable rows in Studio (arrayOf-of-string).
        # NOTE: dual-writer — a Studio save replaces the whole list while
        # agents union-write via the endpoint; rev CAS makes it
        # last-write-wins.
        %{
          "name" => "labels",
          "title" => "Labels",
          "type" => "arrayOf",
          "ordered" => false,
          "group" => "brief",
          "description" =>
            "Free-form scope tags. Agents: POST /v1/tasks/:id/labels {add,remove} (union semantics).",
          "of" => %{"type" => "string"}
        },

        # UPGRADED string → reference. Persistence is IDENTICAL (a
        # reference stores the bare doc-id string), so the ready phase
        # filter (exact match) and the controller's prefix-agnostic
        # filters read exactly what they read today. Studio gains a
        # typeahead pill; the read path gains ?expand=parent_id.
        %{
          "name" => "parent_id",
          "title" => "Parent task",
          "type" => "reference",
          "refType" => "task",
          "group" => "brief",
          "description" =>
            "Doc-id of the parent task (a goal is a root task; this task is one rail of its parent). Plain string, may carry a drafts. prefix."
        },

        # ── WORK — the in_progress surface ──────────────────────────────
        # `select` keeps the Elixir-side single source of truth
        # (`lifecycle_statuses/0` feeds options, `require_string_in/4`,
        # and the DB CHECK). Deliberately NOT a codelist — that would mint
        # a second source of truth for an enum three layers already
        # enforce.
        %{
          "name" => "lifecycle_status",
          "title" => "Lifecycle",
          "type" => "select",
          "options" => lifecycle_statuses(),
          "group" => "work",
          "validation" => %{"required" => true},
          "description" =>
            "open | in_progress | blocked | done | cancelled. Engine-written by claim/close/sweep; agents do not set in_progress by hand."
        },
        %{
          "name" => "assignee",
          "title" => "Assignee",
          "type" => "string",
          "group" => "work",
          "description" =>
            "Worker id holding the claim. Engine-written on claim, cleared on lease reap. Close does NOT clear it (last worker stays attributed)."
        },

        # Fleet handoff memory. Append-only by convention via the generic
        # mutate path. NOT named `history` — the compactor owns that key
        # and tail-replaces it; worklog must never collide.
        %{
          "name" => "worklog",
          "title" => "Worklog",
          "type" => "arrayOf",
          "ordered" => true,
          "group" => "work",
          "description" =>
            "Append-only progress journal. Each claiming agent reads this for handoff context and appends terse entries (decisions, obstacles). Keep entries short — this is not compacted.",
          "of" => %{
            "name" => "entry",
            "type" => "composite",
            "fields" => [
              %{"name" => "ts", "title" => "At", "type" => "datetime"},
              %{"name" => "worker", "title" => "Worker", "type" => "string"},
              %{
                "name" => "kind",
                "title" => "Kind",
                "type" => "select",
                "options" => ["progress", "decision", "obstacle", "handoff"]
              },
              %{"name" => "note", "title" => "Note", "type" => "text", "rows" => 3}
            ]
          }
        },

        # Conditional: only rendered while the task is actually blocked.
        # Paired with the blocked_needs_reason soft banner.
        %{
          "name" => "blocked_reason",
          "title" => "Blocked on",
          "type" => "text",
          "rows" => 3,
          "group" => "work",
          "visibleWhen" => %{
            "field" => "lifecycle_status",
            "operator" => "eq",
            "value" => "blocked"
          },
          "description" =>
            "What this task is waiting for. Set when closing with lifecycle_status=blocked, or when filing a blocks edge."
        },

        # Evidence artifacts (screenshots, logs, exports). Values are bare
        # mediaAsset doc-id strings. Rows render as plain id text inputs —
        # arrayOf-of-reference gets no per-row picker (media-plugin
        # precedent).
        %{
          "name" => "attachments",
          "title" => "Attachments",
          "type" => "arrayOf",
          "ordered" => false,
          "group" => "work",
          "description" =>
            "mediaAsset doc-ids: screenshots, logs, exports produced while working. Arrays of references do not server-expand; fetch each by id.",
          "of" => %{"type" => "reference", "refType" => "mediaAsset"}
        },

        # ── CLOSE — what `bd close` should leave behind ──────────────────
        %{
          "name" => "outcome",
          "title" => "Outcome",
          "type" => "composite",
          "group" => "close",
          "description" =>
            "Written at close. summary = what shipped/changed; resolution = how it ended; actual_size = calibration vs estimate.size; commits = SHAs / PR URLs.",
          "fields" => [
            %{"name" => "summary", "title" => "Summary", "type" => "text", "rows" => 4},
            %{
              "name" => "resolution",
              "title" => "Resolution",
              "type" => "select",
              "options" => ["shipped", "fixed", "partial", "wont_do", "duplicate", "superseded"]
            },
            %{
              "name" => "actual_size",
              "title" => "Actual size",
              "type" => "select",
              "options" => ["xs", "s", "m", "l", "xl"]
            },
            %{
              "name" => "commits",
              "title" => "Commits / PRs",
              "type" => "arrayOf",
              "ordered" => true,
              "of" => %{"type" => "string"}
            }
          ]
        },

        # One-liner landing slot for `bd close --reason` (cheaper for an
        # agent to reach than the outcome composite). Paired with the
        # cancelled_needs_reason soft banner.
        %{
          "name" => "close_reason",
          "title" => "Close reason",
          "type" => "text",
          "rows" => 2,
          "group" => "close",
          "visibleWhen" => %{
            "field" => "lifecycle_status",
            "operator" => "in",
            "value" => ["done", "cancelled", "blocked"]
          },
          "description" => "One-line close rationale. For the full close-out use outcome."
        },

        # Retro shown only once the task is terminal. Wall-clock actuals
        # are derivable from claim.ts_iso/closed_at/epoch — retro captures
        # the part the engine can't: what to do differently.
        %{
          "name" => "retro",
          "title" => "Retro",
          "type" => "text",
          "rows" => 3,
          "group" => "close",
          "visibleWhen" => %{
            "field" => "lifecycle_status",
            "operator" => "in",
            "value" => ["done", "cancelled"]
          },
          "description" =>
            "One-paragraph retrospective: surprises, estimate drift, advice for the next agent on sibling tasks."
        },

        # ── SYSTEM — engine-owned ledger, declared for honesty ───────────
        # `select` (one option) instead of bare string: locks the value in
        # the Studio UI; @kinds stays the source of truth.
        %{
          "name" => "kind",
          "title" => "Kind",
          "type" => "select",
          "options" => kinds(),
          "group" => "system",
          "validation" => %{"required" => true},
          "description" =>
            "Discriminator; always \"task\". Everything is a task — a goal is a root task."
        },

        # v1 `object` = read-only JSON in Studio that emits NO form input,
        # so saves preserve it byte-identically — exactly right for the
        # fencing token. Sub-keys (engine-written, never schema-enforced):
        # worker, ts_iso, epoch, closed_by, closed_at, expired_at,
        # previous_worker. Hidden until a claim exists.
        %{
          "name" => "claim",
          "title" => "Claim (engine)",
          "type" => "object",
          "group" => "system",
          "visibleWhen" => %{"field" => "claim", "operator" => "non_empty"},
          "description" =>
            "Lease + fencing token. Read claim.epoch and pass it as observed_epoch on close. API is the single writer."
        },

        # LEGACY, kept declared so old docs still render their data: the
        # engine never reads this — task_edges is the only authoritative
        # dependency store (ready/claim/unblock all query edges).
        %{
          "name" => "dependencies",
          "title" => "Dependencies (legacy)",
          "type" => "array",
          "group" => "system",
          "visibleWhen" => %{"field" => "dependencies", "operator" => "non_empty"},
          "description" =>
            "DEAD KEY — do not write. Real dependencies are task_edges rows: POST /v1/tasks/edges {from_id,to_id,kind:\"blocks\"}."
        },

        # PROMOTED from undeclared. Stays a v1 array (read-only in Studio):
        # API single writer via /v1/tasks/:id/papers, and arrayOf-of-
        # reference rows would render as bare text inputs anyway. Values
        # ARE valid paper doc-ids (a paper's doc_id is its slug).
        %{
          "name" => "papers",
          "title" => "Linked papers",
          "type" => "array",
          "group" => "system",
          "description" =>
            "Paper doc-ids (= slugs) linked via POST /v1/tasks/:id/papers {add,remove}. For the primary design doc use design_doc (an expandable reference)."
        },

        # Compactor-owned: history is tail-replaced to last-3 on
        # compaction, history_summary is the rollup. Declared read-only so
        # the ledger is visible; never form-writable. compacted_at and
        # compaction_snapshot_revision_id stay DELIBERATELY UNDECLARED —
        # restore/2 strips them, and declaring them would render editable
        # text inputs a human could corrupt.
        %{
          "name" => "history",
          "title" => "History (engine)",
          "type" => "array",
          "group" => "system",
          "visibleWhen" => %{"field" => "history", "operator" => "non_empty"},
          "description" =>
            "Compactor-managed event tail. Live audit log is mutation_events, not this key."
        },
        %{
          "name" => "history_summary",
          "title" => "History summary (engine)",
          "type" => "object",
          "group" => "system",
          "visibleWhen" => %{"field" => "history_summary", "operator" => "non_empty"},
          "description" =>
            "Compaction rollup: event_count, first/last ts, status_transitions, workers."
        }
      ]
    }
  end

  # ─── Validation ────────────────────────────────────────────────────────────

  @doc """
  Validates the `content` map of a `type:task` document against the §1
  field contract.

  Returns `:ok` on success or `{:error, errors :: map()}` where the map's
  keys are the field names (`"kind"`, `"lifecycle_status"`, ...) and the
  values are lists of human-readable error messages — mirroring the
  shape `Barkpark.Content.Validation.validate/3` returns.

  Required fields: `kind` (must equal `"task"`), `lifecycle_status` (must
  be one of `lifecycle_statuses/0`).

  Shape-checked when present: `priority` (integer 0..4), `assignee`
  (string), `dependencies` (list of strings), `parent_id` (string),
  `claim` (map) — plus the dossier fields: `description` / `design` /
  `design_doc` / `due_at` / `blocked_reason` / `close_reason` / `retro`
  (strings), `papers` / `attachments` (lists of strings), `labels` /
  `history` (lists), `estimate` / `outcome` / `history_summary` (maps),
  `worklog` / `acceptance_criteria` (lists of maps). Top-level shape only,
  never sub-keys — the claim-map precedent.
  """
  @spec validate_task_content(map() | nil) :: :ok | {:error, map()}
  def validate_task_content(content), do: validate_kind_content("task", content)

  @doc """
  Validates `content` against the shape for the given `kind`. Dispatches
  to the per-kind validator; unknown kinds are rejected.

  Used by the document-write paths (`Content.create_document/4`,
  `Content.upsert_document/4`) when the `type` argument equals `"task"`.
  """
  @spec validate_kind_content(String.t(), map() | nil) :: :ok | {:error, map()}
  def validate_kind_content(kind, content) when kind in @kinds do
    content = content || %{}

    errors =
      %{}
      |> validate_kind_field(kind, content)
      |> validate_kind_specific(kind, content)

    if errors == %{}, do: :ok, else: {:error, errors}
  end

  def validate_kind_content(other, _content) do
    {:error, %{"kind" => ["unknown kind #{inspect(other)}; must be one of #{inspect(@kinds)}"]}}
  end

  # The shared "content.kind == <type>" check — every kind must self-identify.
  defp validate_kind_field(errors, expected_kind, content) do
    case Map.get(content, "kind") || Map.get(content, :kind) do
      ^expected_kind ->
        errors

      nil ->
        Map.put(errors, "kind", ["is required"])

      other ->
        Map.put(errors, "kind", [
          "expected #{inspect(expected_kind)}, got #{inspect(other)}"
        ])
    end
  end

  # Required + shape checks for `task`. Kept tight per the plan: only what the
  # live readers consume.

  defp validate_kind_specific(errors, "task", content) do
    errors
    |> require_string_in(content, "lifecycle_status", @lifecycle_statuses)
    |> check_optional_priority(content)
    |> check_optional_string(content, "assignee")
    |> check_optional_string(content, "parent_id")
    |> check_optional_string_list(content, "dependencies")
    |> check_optional_map(content, "claim")
    # Dossier fields — shape-only-when-present, following the claim
    # precedent (top-level shape, NO sub-key enforcement). Sub-key
    # contracts live in the schema field descriptions (agent-facing,
    # serialized in the capabilities manifest). Keeping these loose keeps
    # every existing writer (bd-shim, engine CAS updates, legacy docs)
    # green.
    |> check_optional_string(content, "description")
    |> check_optional_string(content, "design")
    |> check_optional_string(content, "design_doc")
    |> check_optional_string(content, "due_at")
    |> check_optional_string(content, "blocked_reason")
    |> check_optional_string(content, "close_reason")
    |> check_optional_string(content, "retro")
    |> check_optional_string_list(content, "papers")
    |> check_optional_string_list(content, "attachments")
    # any-element lists: reads already tolerate legacy W7-mirror label
    # lists, and history elements are compactor-owned event maps —
    # don't over-constrain either.
    |> check_optional_list(content, "labels")
    |> check_optional_list(content, "history")
    |> check_optional_map(content, "estimate")
    |> check_optional_map(content, "outcome")
    |> check_optional_map(content, "history_summary")
    |> check_optional_map_list(content, "worklog")
    |> check_optional_map_list(content, "acceptance_criteria")
  end

  # ─── Per-field micro-validators ────────────────────────────────────────────

  defp require_string_in(errors, content, key, allowed) do
    case Map.get(content, key) || Map.get(content, String.to_atom(key)) do
      v when is_binary(v) ->
        if v in allowed do
          errors
        else
          Map.put(errors, key, [
            "must be one of #{inspect(allowed)}, got #{inspect(v)}"
          ])
        end

      nil ->
        Map.put(errors, key, ["is required (one of #{inspect(allowed)})"])

      other ->
        Map.put(errors, key, ["must be a string, got #{inspect(other)}"])
    end
  end

  defp check_optional_string(errors, content, key) do
    case Map.get(content, key) || Map.get(content, String.to_atom(key)) do
      nil -> errors
      v when is_binary(v) -> errors
      other -> Map.put(errors, key, ["must be a string when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_string_list(errors, content, key) do
    case Map.get(content, key) || Map.get(content, String.to_atom(key)) do
      nil ->
        errors

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          errors
        else
          Map.put(errors, key, ["must be a list of strings, got #{inspect(list)}"])
        end

      other ->
        Map.put(errors, key, ["must be a list when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_priority(errors, content) do
    case Map.get(content, "priority") || Map.get(content, :priority) do
      nil ->
        errors

      v when is_integer(v) and v >= 0 and v <= 4 ->
        errors

      other ->
        Map.put(errors, "priority", ["must be an integer 0..4 when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_map(errors, content, key) do
    case Map.get(content, key) || Map.get(content, String.to_atom(key)) do
      nil -> errors
      v when is_map(v) -> errors
      other -> Map.put(errors, key, ["must be a map when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_list(errors, content, key) do
    case Map.get(content, key) || Map.get(content, String.to_atom(key)) do
      nil -> errors
      v when is_list(v) -> errors
      other -> Map.put(errors, key, ["must be a list when set, got #{inspect(other)}"])
    end
  end

  defp check_optional_map_list(errors, content, key) do
    case Map.get(content, key) || Map.get(content, String.to_atom(key)) do
      nil ->
        errors

      list when is_list(list) ->
        if Enum.all?(list, &is_map/1) do
          errors
        else
          Map.put(errors, key, ["must be a list of maps, got #{inspect(list)}"])
        end

      other ->
        Map.put(errors, key, ["must be a list when set, got #{inspect(other)}"])
    end
  end

  # ─── W7a step 2: typed dep graph (CRUD over `task_edges`) ─────────────────

  @doc """
  Edge kinds in this codebase today. `blocks` is the ready-query primitive;
  `discovered-from` records walk-back / derivation lineage between tasks.
  """
  @spec edge_kinds() :: [String.t()]
  def edge_kinds, do: Edge.kinds()

  @doc """
  Add a dependency edge: `child` blocks on `parent`.

  Mirrors `bd dep add <child> <parent>` — the FIRST argument depends on the
  SECOND. The edge is stored as `from_id = child_id, to_id = parent_id`
  so the W7-03 ready query can scan a candidate's outbound `blocks` edges
  to find its blockers.

  ## Arguments
    * `child_id`  — binary_id of the dependent document (the task that's
      blocked on something).
    * `parent_id` — binary_id of the blocker document.
    * `kind`      — `:blocks` (default), `:"discovered-from"`, or the
      string form `"blocks"` / `"discovered-from"`. Other strings are
      rejected by the changeset.

  ## Idempotency

  Re-adding the same `(from, to, kind)` triple is a no-op — the migration's
  unique index plus `on_conflict: :nothing` swallows the duplicate without
  raising. The returned `{:ok, edge}` carries the EXISTING edge when the
  insert was a no-op (fetched in a second query so callers always get a
  populated struct).

  Returns `{:ok, %Edge{}}` on success, `{:error, %Ecto.Changeset{}}` on
  validation failure (missing FK target, self-edge, unknown kind).
  """
  @spec add_dep(binary(), binary(), atom() | String.t()) ::
          {:ok, Edge.t()} | {:error, Ecto.Changeset.t()}
  def add_dep(child_id, parent_id, kind \\ :blocks) do
    kind_str = normalize_kind(kind)

    attrs = %{from_id: child_id, to_id: parent_id, kind: kind_str}
    changeset = Edge.changeset(%Edge{}, attrs)

    if changeset.valid? do
      # `on_conflict: :nothing` + the unique index = idempotent insert.
      # When the row already exists Postgres skips the INSERT but Ecto still
      # returns `{:ok, %Edge{}}` with the changeset's would-be values (the
      # `id` is the autogenerated one Ecto stamped on the cast struct, NOT
      # the existing row's id). To return the canonical edge — same id on
      # repeat calls — we always read the row back by its unique tuple.
      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:from_id, :to_id, :kind]
           ) do
        {:ok, %Edge{}} ->
          {:ok, fetch_edge!(child_id, parent_id, kind_str)}

        {:error, %Ecto.Changeset{} = cs} ->
          {:error, cs}
      end
    else
      {:error, changeset}
    end
  end

  @doc """
  Remove the `(child_id, parent_id, kind)` edge. Always returns `:ok` —
  removing an absent edge is a no-op (matches `bd dep rm`'s tolerance,
  and keeps the close-time `unblock_dependents` flow simple in W7-04).
  """
  @spec remove_dep(binary(), binary(), atom() | String.t()) :: :ok
  def remove_dep(child_id, parent_id, kind) do
    kind_str = normalize_kind(kind)

    from(e in Edge,
      where: e.from_id == ^child_id and e.to_id == ^parent_id and e.kind == ^kind_str
    )
    |> Repo.delete_all()

    :ok
  end

  @doc """
  The documents `task_id` depends on — the blockers, the `to_id` side of
  every outbound edge. The W7-03 ready query is a `NOT EXISTS` over this
  set; this function is the higher-level read for orchestrator surfaces
  (build pre-flight, debug `bd dep ls`).

  ## Options
    * `:kind` — filter to one kind (atom or string). Default: `:blocks`.
      Pass `:all` to return edges of every kind.

  Returns a list of `%Document{}` in insertion order of the edge.
  """
  @spec dependencies(binary(), keyword()) :: [Document.t()]
  def dependencies(task_id, opts \\ []) do
    kind_opt = Keyword.get(opts, :kind, :blocks)

    from(d in Document,
      join: e in Edge,
      as: :edge,
      on: e.to_id == d.id,
      where: e.from_id == ^task_id,
      order_by: e.inserted_at,
      select: d
    )
    |> maybe_filter_edge_kind(kind_opt)
    |> Repo.all()
  end

  @doc """
  The documents that depend on `task_id` — the dependents, the `from_id`
  side of every inbound edge. Called when `task_id` closes, to find which
  rows might be newly ready (the W7-04 close→unblock sweep).

  ## Options
    * `:kind` — filter to one kind (atom or string). Default: `:blocks`.
      Pass `:all` to return edges of every kind.
  """
  @spec dependents(binary(), keyword()) :: [Document.t()]
  def dependents(task_id, opts \\ []) do
    kind_opt = Keyword.get(opts, :kind, :blocks)

    from(d in Document,
      join: e in Edge,
      as: :edge,
      on: e.from_id == d.id,
      where: e.to_id == ^task_id,
      order_by: e.inserted_at,
      select: d
    )
    |> maybe_filter_edge_kind(kind_opt)
    |> Repo.all()
  end

  @doc """
  Low-level query: every edge touching `task_id` on either side.

  ## Options
    * `:direction` — `:outbound` (default — `from_id == task_id`),
      `:inbound` (`to_id == task_id`), or `:both`.
    * `:kind` — filter to one kind (atom or string), or `:all` (default).
  """
  @spec edges(binary(), keyword()) :: [Edge.t()]
  def edges(task_id, opts \\ []) do
    direction = Keyword.get(opts, :direction, :outbound)
    kind_opt = Keyword.get(opts, :kind, :all)

    base =
      case direction do
        :outbound ->
          from(e in Edge, as: :edge, where: e.from_id == ^task_id)

        :inbound ->
          from(e in Edge, as: :edge, where: e.to_id == ^task_id)

        :both ->
          from(e in Edge,
            as: :edge,
            where: e.from_id == ^task_id or e.to_id == ^task_id
          )
      end

    base
    |> maybe_filter_edge_kind(kind_opt)
    |> Repo.all()
  end

  defp maybe_filter_edge_kind(query, :all), do: query

  defp maybe_filter_edge_kind(query, kind) do
    kind_str = normalize_kind(kind)
    from [edge: e] in query, where: e.kind == ^kind_str
  end

  # The caller may pass `:blocks` / `:"discovered-from"` / `"blocks"` /
  # `"discovered-from"` — internally we always use the string column value.
  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind

  defp fetch_edge!(from_id, to_id, kind) do
    Repo.one!(
      from e in Edge,
        where: e.from_id == ^from_id and e.to_id == ^to_id and e.kind == ^kind
    )
  end

  # ─── W7a step 3: dependency-aware, phase-scoped ready-queue + claim ───────

  @ready_default_limit 50
  @ready_lifecycle_statuses ~w(open blocked)

  @doc """
  The ready-queue: task documents that are `claim/2`-eligible right now.

  A task is **ready** when ALL of these hold:

    * `type = "task"` AND `content->>'kind' = "task"` (defense in depth — the
      W7-01 validator already enforces it but the read path doesn't trust
      the application boundary);
    * `content->>'lifecycle_status'` ∈ `{"open", "blocked"}` (not
      `in_progress` / `done` / `cancelled`);
    * the task is in the **active phase** (when `:phase_id` is given,
      `content->>'parent_id' = <phase_doc_id>`; without the opt the
      result is phase-agnostic — handy for testing and for the dock's
      "everything ready in this workspace" feed);
    * **every outbound `blocks` edge points at a `done` document** —
      authoritative dep graph from `task_edges`; per W7-02 the FKs are
      on `documents.id` (uuid) NOT `documents.doc_id` (string), so the
      join is `e.to_id = b.id` (NOT `e.to_doc = b.doc_id` as the plan's
      illustrative SQL suggested);
    * the row is scoped to the caller's workspace/project (per the W2
      hard tenant boundary — `nil` workspace fails CLOSED via
      `Scope.scope_to_workspace_or_global/3`).

  The query is ordered by `content.priority` ASC (NULLS LAST) then
  `inserted_at` ASC — deterministic, lowest priority number first
  (mirroring `bd ready`'s priority semantics where 0 is highest).

  ## Options
    * `:workspace_id` — binary uuid. Required for tenant-scoped reads.
      A nil/missing value fails CLOSED (returns `[]`) per the W2 contract.
    * `:project_id`   — binary uuid. Narrows further within the workspace.
    * `:dataset`      — string dataset name. When omitted, no dataset
      filter is applied (matches `Content.list_documents/3`'s default).
    * `:phase_id`     — string doc_id of the parent phase document. When
      omitted, returns ready tasks across all phases in scope.
    * `:limit`        — integer max rows. Default
      #{@ready_default_limit}.

  Returns a list of `%Document{}` structs.

  ## Why string `phase_id` and not the uuid

  The W7-01 contract pins `content.parent_id` as the parent's `doc_id`
  string (e.g. `"phase-build-a1b2"`), mirroring `bd`'s `--parent <slug>`
  shape. The orchestrator surfaces the active phase as a slug from
  `<repo>/.paperflow/active-phase`; reading the row's `documents.id`
  uuid every time the statusline composes would be wasted DB chatter.
  """
  @spec ready(keyword()) :: [Document.t()]
  def ready(opts \\ []) do
    opts
    |> ready_query()
    |> Repo.all()
  end

  @doc """
  Claim ONE ready task atomically — W7-04 full primitives.

  Four guarantees, all tested in `tasks_claim_test.exs`:

    1. **Expected-version CAS** via `documents.rev`. The UPDATE WHERE clause
       carries `rev = <observed_rev>`; if Postgres reports 0 rows affected,
       another caller won and we return `{:error, :stale_claim}`. `rev` is
       the existing opaque-string mutation-spine identifier; every write in
       this module bumps it via `generate_rev/0`, matching the rest of the
       `Content` module's CAS surface (`ensure_rev/2`). A separate integer
       version column would mean a schema migration and a second source of
       truth — the existing `rev` already increments on every upsert per the
       W2 work and is the contract `Tasks.close/3` enforces.

    2. **Fencing epoch** bumped on EVERY claim and stored at
       `content.claim.epoch` (per the W7-01 field contract). The previous
       claim's epoch (if any) +1 becomes the new epoch; a brand-new claim
       starts at 1. Returned in `content.claim.epoch` so callers can pass it
       back to `close/3` / mutation paths; mismatch → `{:error, :fenced_off}`.
       This is the only protection against a stale-but-not-crashed worker
       writing after the TTL sweep (W7-05) takes its claim away.

    3. **Durable-then-ack** — a `mutation_events` row of kind `"task.claimed"`
       is INSERTED in the SAME transaction as the claim UPDATE, BEFORE the
       function returns. If the caller crashes between getting the doc and
       starting work, the claim is still durable + observable in the
       `mutation_events` log + sweepable by TTL (W7-05).

    4. **Concurrency** — `SELECT … FOR UPDATE SKIP LOCKED LIMIT 1` (the W7-03
       skeleton) still drives row selection; the new CAS guards against the
       reread-after-row-unlock race that SKIP LOCKED alone cannot prevent
       (a caller that picked a row before another caller's commit landed).

  ## Returns
    * `{:ok, %Document{}}` — claimed; `content.claim` carries `worker`,
      `ts_iso`, `epoch` (and the row's new `rev`).
    * `{:ok, nil}` — the ready queue was empty.
    * `{:error, :stale_claim}` — the row we picked was updated by another
      caller between our SELECT and our UPDATE (CAS failed).

  ## Arguments
    * `worker_id` — string identifier for the claimer (agent / worker
      label). Stamped into `content.claim.worker` and `content.assignee`.
    * `opts` — same as `ready/1`. `:phase_id` is recommended.
  """
  @spec claim(String.t(), keyword()) ::
          {:ok, Document.t() | nil} | {:error, :stale_claim}
  def claim(worker_id, opts \\ []) when is_binary(worker_id) do
    result =
      Repo.transaction(fn ->
        case opts
             |> ready_query()
             |> from(limit: 1, lock: "FOR UPDATE SKIP LOCKED")
             |> Repo.one() do
          nil ->
            {:ok, nil}

          %Document{} = doc ->
            do_claim(doc, worker_id)
        end
      end)

    case result do
      {:ok, {:ok, nil}} ->
        {:ok, nil}

      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Claim a SPECIFIC task by `doc_id` — targeted claim, the W7b counterpart to
  the queue-based `claim/2`.

  Why a separate primitive: `claim/2` picks the next ready row (queue semantics
  — caller doesn't name a row). `bd`'s `bd update <id> --claim` is targeted —
  caller DOES name a row. The bd-shim cannot translate one to the other
  without a wasted listAll() roundtrip plus losing semantics (the row the
  shim picks might not be the row the bd caller named). w7-08 wires this
  primitive so the shim's `bd update <id> --claim` semantics are preserved.

  Same advisory-lock + CAS-on-rev + epoch bump + durable mutation_event
  pattern as `claim/2`'s `do_claim`, but for ONE specific doc — and with
  explicit pre-flight checks for the four error modes:

    * `:not_found` — no doc with this `doc_id` under the caller's tenancy
    * `:not_ready` — lifecycle_status not in [`open`, `blocked`]
    * `:blocked_by_unsatisfied_deps` — has outbound `blocks` edges whose
      target's lifecycle_status is not `done`
    * `:stale_claim` — CAS lost (extremely rare under the advisory lock)

  ## Arguments
    * `doc_id`     — string doc_id of the target (e.g. `"paperflow-5wk"`).
    * `worker_id`  — string identifier for the claimer.
    * `opts`
      * `:workspace_id` (required for tenant scoping)
      * `:project_id`   (optional further narrowing)

  Returns `{:ok, %Document{}}` on success or `{:error, atom}`.
  """
  @spec claim_by_id(String.t(), String.t(), keyword()) ::
          {:ok, Document.t()}
          | {:error, :not_found | :not_ready | :blocked_by_unsatisfied_deps | :stale_claim}
  def claim_by_id(doc_id, worker_id, opts \\ [])
      when is_binary(doc_id) and is_binary(worker_id) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    result =
      Repo.transaction(fn ->
        # 1. Advisory lock (per-doc_id) — serializes concurrent targeted
        #    claims for the same row. Matches the close-side lock key shape:
        #    `"task:" <> task_id`. We don't yet know the row's uuid so the
        #    key is keyed off doc_id, which is unique within tenancy.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:" <> doc_id])

        with {:ok, doc} <- fetch_task_by_doc_id(doc_id, workspace_id, project_id),
             :ok <- check_ready_for_targeted_claim(doc),
             :ok <- check_deps_satisfied(doc) do
          do_claim(doc, worker_id)
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Everything is a task: the TARGETED `claim_by_id`/close paths fetch by
  # doc_id on `type == "task"`. Root/container tasks (a former "goal"/"phase")
  # are tasks too, so a single type filter covers them. The READY-QUEUE claim
  # (`claim/2` → `ready_query/1`) shares this `type == "task"` filter.
  #
  # Resolution rule: try the exact `doc_id` first. When no row is found AND
  # the caller did NOT already supply a `drafts.` prefix, retry with
  # `"drafts." <> doc_id`. Tasks created via the mutate endpoint always land
  # as `drafts.<id>`; the fallback lets callers use the bare id without
  # publishing first. An explicit `drafts.` prefix is treated as exact —
  # the fallback is never applied in reverse.
  #
  # Disambiguation: if both `t1` and `drafts.t1` exist (published + live
  # draft), the exact match on `t1` wins — the caller gets the published row.
  defp fetch_task_by_doc_id(doc_id, workspace_id, project_id) do
    case fetch_task_exact_locked(doc_id, workspace_id, project_id) do
      {:ok, _} = hit ->
        hit

      {:error, :not_found} ->
        if String.starts_with?(doc_id, "drafts.") do
          {:error, :not_found}
        else
          fetch_task_exact_locked("drafts." <> doc_id, workspace_id, project_id)
        end
    end
  end

  defp fetch_task_exact_locked(doc_id, workspace_id, project_id) do
    base =
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == "task",
        lock: "FOR UPDATE"
      )

    query =
      base
      |> then(fn q ->
        if is_nil(workspace_id), do: q, else: from(d in q, where: d.workspace_id == ^workspace_id)
      end)
      |> then(fn q ->
        if is_nil(project_id), do: q, else: from(d in q, where: d.project_id == ^project_id)
      end)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Document{} = doc -> {:ok, doc}
    end
  end

  defp check_ready_for_targeted_claim(%Document{content: content}) do
    case Map.get(content || %{}, "lifecycle_status") do
      s when s in @ready_lifecycle_statuses -> :ok
      _ -> {:error, :not_ready}
    end
  end

  defp check_deps_satisfied(%Document{} = doc) do
    deps = dependencies(doc.id, kind: :blocks)

    all_done? =
      Enum.all?(deps, fn %Document{content: c} ->
        Map.get(c || %{}, "lifecycle_status") == "done"
      end)

    if all_done?, do: :ok, else: {:error, :blocked_by_unsatisfied_deps}
  end

  defp do_claim(%Document{} = doc, worker_id) do
    observed_rev = doc.rev
    new_rev = generate_rev()
    next_epoch = current_epoch(doc) + 1
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    new_claim = %{
      "worker" => worker_id,
      "ts_iso" => ts_iso,
      "epoch" => next_epoch
    }

    new_content =
      doc.content
      |> Map.put("lifecycle_status", "in_progress")
      |> Map.put("assignee", worker_id)
      |> Map.put("claim", new_claim)

    # Expected-version CAS: WHERE id = ? AND rev = <observed_rev>.
    # update_all returns {rows_affected, _}. 0 → another caller won.
    {rows, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
      |> Repo.update_all(
        set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
      )

    case rows do
      1 ->
        updated = %{doc | content: new_content, rev: new_rev}
        ev = insert_mutation_event!(updated, @event_task_claimed, observed_rev)
        {:ok, updated, [task_broadcast(updated, @event_task_claimed, ev, observed_rev)]}

      0 ->
        {:error, :stale_claim}
    end
  end

  # ─── Post-commit PubSub (barkpark realtime parity for task ops) ────────────
  #
  # Every CAS write path in this module bypasses Content's canonical write
  # path (`tap_broadcast/5`), so without these the SSE listen endpoint and
  # StudioLive never see a claim/close/relabel live — only doc CRUD
  # broadcast. The fix: build a broadcast bundle INSIDE the transaction
  # (where the freshly-inserted `mutation_events` row id is known — the
  # listen controller drops messages without an `event_id`), and fire it via
  # `Content.broadcast_document_mutation/3` AFTER the transaction commits
  # (broadcasting inside the txn would let subscribers read uncommitted
  # state). Content stays the single owner of the topic shapes.

  defp task_broadcast(%Document{} = doc, kind, %MutationEvent{} = ev, previous_rev) do
    %{doc: doc, kind: kind, event_id: ev.id, previous_rev: previous_rev}
  end

  defp emit_broadcasts(broadcasts) when is_list(broadcasts) do
    Enum.each(broadcasts, fn %{doc: doc, kind: kind, event_id: eid, previous_rev: prev} ->
      Content.broadcast_document_mutation(doc, kind, event_id: eid, previous_rev: prev)
    end)

    :ok
  end

  @doc """
  Close (terminate) a claimed task — W7-04 full primitives.

  Five things, in one Postgres transaction:

    1. **Advisory lock** — `pg_advisory_xact_lock(hashtext('task:' || doc_id))`
       serializes ALL concurrent close attempts on the same task; one wins,
       the rest queue inside the lock and then fail CAS (because the winner
       already bumped `rev`). Per-task scope — closes on DIFFERENT tasks do
       NOT block each other.

    2. **Fencing check** — the caller must pass its observed epoch; mismatch
       (or no claim record) → `{:error, :fenced_off}` so the dead worker's
       late writes are rejected after a TTL sweep / re-claim.

    3. **Expected-version CAS** — `rev = <observed_rev>` guard, same as
       `claim/2`. 0 rows affected → `{:error, :stale_claim}`.

    4. **Cascading unblock** — every dependent (inbound `blocks` edge) whose
       full blocker set is now `done` flips its `lifecycle_status` from
       `"blocked"` to `"open"` in the same transaction. The advisory lock
       guarantees we are the only writer flipping the parent on this txn, so
       the recomputation we do for each dependent is consistent.

    5. **Durable-then-ack** — one `mutation_events` row of kind `"task.closed"`
       for the task itself, plus one `"task.mutated"` row per dependent
       whose `lifecycle_status` changed. All committed before the function
       returns.

  ## Arguments
    * `task_id` — `documents.id` (uuid) of the task being closed.
    * `worker_id` — string. Stamped on the event row.
    * `opts`
      * `:observed_epoch` (required integer) — the epoch the worker saw on
        claim. Must match the row's current `content.claim.epoch`.
      * `:observed_rev` (optional string) — when given, also CAS-guards on
        `documents.rev`. Defaults to the row's rev as read inside the txn
        AFTER the advisory lock (which is the natural CAS point under the
        per-task serialization).
      * `:lifecycle_status` (default `"done"`) — one of `done`/`cancelled`/
        `blocked`.

  ## Returns
    * `{:ok, %Document{}}` — closed successfully; the returned doc carries
      the new `content.lifecycle_status` and bumped `rev`.
    * `{:error, :not_found}` — no such task.
    * `{:error, :fenced_off}` — observed epoch ≠ row epoch.
    * `{:error, :stale_claim}` — CAS failed (extremely rare under the
      advisory lock, but covered for defense in depth).
    * `{:error, {:invalid_lifecycle, status}}` — disallowed terminal status.
  """
  @spec close(binary(), String.t(), keyword()) ::
          {:ok, Document.t()}
          | {:error, :not_found | :fenced_off | :stale_claim | {:invalid_lifecycle, term()}}
  def close(task_id, worker_id, opts \\ []) when is_binary(worker_id) do
    observed_epoch = Keyword.fetch!(opts, :observed_epoch)
    new_status = Keyword.get(opts, :lifecycle_status, "done")
    observed_rev_opt = Keyword.get(opts, :observed_rev)

    cond do
      new_status not in @closed_lifecycle_statuses ->
        {:error, {:invalid_lifecycle, new_status}}

      true ->
        do_close_txn(task_id, worker_id, observed_epoch, observed_rev_opt, new_status)
    end
  end

  defp do_close_txn(task_id, worker_id, observed_epoch, observed_rev_opt, new_status) do
    result =
      Repo.transaction(fn ->
        # 1. Advisory lock — per-task. hashtext('task:' || doc_id) gives a
        #    deterministic int4 key; pg_advisory_xact_lock takes an int4 or
        #    bigint and auto-releases at COMMIT/ROLLBACK.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = observed_rev_opt || doc.rev

            # Already-terminal guard. Under the advisory lock, a serialized
            # 2nd+ caller reads the row AFTER the winner committed → sees
            # `lifecycle_status` already in a terminal state. Without this
            # the default-observed-rev path would let every caller "succeed"
            # in turn (CAS passes against the just-read rev). Treat the
            # already-terminal row as a lost race; the explicit-rev CAS
            # path below still wins/loses on rev when callers pass their
            # own observation.
            cond do
              observed_rev_opt == nil and
                  Map.get(doc.content, "lifecycle_status") in @closed_lifecycle_statuses ->
                {:error, :stale_claim}

              true ->
                with :ok <- check_fencing(doc, observed_epoch),
                     {:ok, updated} <-
                       apply_close_update(doc, worker_id, observed_rev, new_status) do
                  ev = insert_mutation_event!(updated, @event_task_closed, observed_rev)
                  unblocked = cascade_unblock_dependents!(updated)

                  {:ok, updated,
                   [task_broadcast(updated, @event_task_closed, ev, observed_rev) | unblocked]}
                end
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  tt5: add/remove `content.labels` entries on a single task, advisory-lock +
  CAS-on-rev guarded, emitting a `task.relabeled` mutation_event. Powers the
  bd-shim's `bd update <id> --add-label/--remove-label` translation (which in
  turn backs paperflow-claim-files' `file-claim:<path>` ownership labels).

  `add` and `remove` are lists of exact label strings. The result is a union
  add (dedup-preserving) minus the remove set. Idempotent: re-adding an
  existing label or removing an absent one is a no-op on that label.

  Returns `{:ok, doc}` (always re-reads + persists, even on a no-op set —
  the rev bump + event keep the relabel observable), or `{:error, :not_found}`
  / `{:error, :stale_claim}`.
  """
  @spec relabel_by_id(binary(), [binary()], [binary()]) ::
          {:ok, Document.t()} | {:error, term()}
  def relabel_by_id(task_id, add, remove)
      when is_binary(task_id) and is_list(add) and is_list(remove) do
    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = doc.rev
            current = labels_of(doc.content)
            add = Enum.filter(add, &is_binary/1)
            remove = MapSet.new(Enum.filter(remove, &is_binary/1))

            # Union add (append new, preserve order), then drop the remove set.
            next =
              (current ++ add)
              |> Enum.uniq()
              |> Enum.reject(&MapSet.member?(remove, &1))

            new_content = Map.put(doc.content, "labels", next)
            new_rev = generate_rev()

            {rows, _} =
              from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
              |> Repo.update_all(
                set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
              )

            case rows do
              1 ->
                updated = %{doc | content: new_content, rev: new_rev}
                ev = insert_mutation_event!(updated, @event_task_relabeled, observed_rev)

                {:ok, updated, [task_broadcast(updated, @event_task_relabeled, ev, observed_rev)]}

              0 ->
                {:error, :stale_claim}
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # content.labels is a free-form JSON array (the W7 mirror writes goals/phases
  # with [kind, goal] etc.; tasks may have none). Defensive: coerce non-list /
  # missing to [].
  defp labels_of(%{"labels" => labels}) when is_list(labels), do: labels
  defp labels_of(_), do: []

  @doc """
  Phase A: add/remove `content.papers` entries (paper slugs) on a single task,
  advisory-lock + CAS-on-rev guarded, emitting a `task.referenced`
  mutation_event. Mirrors `relabel_by_id/3` byte-for-byte — the only difference
  is the content key (`"papers"`) and the event kind.

  `add_slugs` and `remove_slugs` are lists of exact paper-slug strings. The
  result is a union add (dedup-preserving) minus the remove set. Idempotent:
  re-adding an existing paper ref or removing an absent one is a no-op on that
  ref.

  Returns `{:ok, doc}` (always re-reads + persists, even on a no-op set —
  the rev bump + event keep the change observable), or `{:error, :not_found}`
  / `{:error, :stale_claim}`.
  """
  @spec update_paper_refs_by_id(binary(), [binary()], [binary()]) ::
          {:ok, Document.t()} | {:error, term()}
  def update_paper_refs_by_id(task_id, add_slugs, remove_slugs)
      when is_binary(task_id) and is_list(add_slugs) and is_list(remove_slugs) do
    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = doc.rev
            current = papers_of(doc.content)
            add = Enum.filter(add_slugs, &is_binary/1)
            remove = MapSet.new(Enum.filter(remove_slugs, &is_binary/1))

            # Union add (append new, preserve order), then drop the remove set.
            next =
              (current ++ add)
              |> Enum.uniq()
              |> Enum.reject(&MapSet.member?(remove, &1))

            new_content = Map.put(doc.content, "papers", next)
            new_rev = generate_rev()

            {rows, _} =
              from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
              |> Repo.update_all(
                set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
              )

            case rows do
              1 ->
                updated = %{doc | content: new_content, rev: new_rev}
                ev = insert_mutation_event!(updated, @event_task_referenced, observed_rev)

                {:ok, updated,
                 [task_broadcast(updated, @event_task_referenced, ev, observed_rev)]}

              0 ->
                {:error, :stale_claim}
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # content.papers is a JSON array of paper slugs. Defensive: coerce non-list /
  # missing to [].
  defp papers_of(%{"papers" => papers}) when is_list(papers), do: papers
  defp papers_of(_), do: []

  # Fencing applies only to tasks that carry a claim lease. Work-tasks are
  # claimed before close, so they have `content.claim.epoch` and the observed
  # epoch must match (the dead-worker guard).
  #
  # Generalized (everything-is-a-task): a task with NO claim record has no
  # lease to fence against, so it closes gracefully (return `:ok`). This is
  # what lets a never-claimed root/container task (a former "goal"/"phase")
  # close via this same path — the close is keyed on the absence of a lease,
  # not on the doc type. A task WITH a claim ALWAYS requires the epoch to
  # match — the fencing guarantee for real claimed work is unchanged.
  defp check_fencing(%Document{content: content}, observed_epoch) do
    case content do
      %{"claim" => %{"epoch" => row_epoch}} when row_epoch == observed_epoch -> :ok
      %{"claim" => %{"epoch" => _}} -> {:error, :fenced_off}
      # No claim lease — nothing to fence against, close cleanly.
      _ -> :ok
    end
  end

  defp apply_close_update(%Document{} = doc, worker_id, observed_rev, new_status) do
    new_rev = generate_rev()
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    # Stamp close metadata into the claim lease when one exists (work-tasks).
    # A never-claimed root/container task has no claim — close it without
    # inventing one; we only flip lifecycle_status. `Map.update/4`'s default
    # is used verbatim (NOT run through the fun), so a no-claim doc would
    # otherwise get a bare `claim => %{}`; the explicit branch keeps the doc
    # shape honest.
    new_content =
      case doc.content do
        %{"claim" => claim} when is_map(claim) ->
          updated_claim =
            claim
            |> Map.put("closed_by", worker_id)
            |> Map.put("closed_at", ts_iso)

          doc.content
          |> Map.put("lifecycle_status", new_status)
          |> Map.put("claim", updated_claim)

        _ ->
          Map.put(doc.content, "lifecycle_status", new_status)
      end

    {rows, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
      |> Repo.update_all(
        set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
      )

    case rows do
      1 -> {:ok, %{doc | content: new_content, rev: new_rev}}
      0 -> {:error, :stale_claim}
    end
  end

  # After a task flips to `done`, walk every inbound `blocks` edge and flip
  # the dependent's `lifecycle_status` from "blocked"→"open" IFF every one of
  # ITS blockers is now `done`. We do this in the same advisory-lock-guarded
  # transaction so two concurrent closes that both unblock the same
  # dependent can't double-flip it.
  #
  # Returns one broadcast bundle per flipped dependent (possibly []) so the
  # caller can announce the unblocks on PubSub after its transaction commits.
  defp cascade_unblock_dependents!(%Document{content: %{"lifecycle_status" => "done"}} = parent) do
    parent
    |> Map.fetch!(:id)
    |> dependents(kind: :blocks)
    |> Enum.flat_map(fn %Document{} = dep ->
      if all_blockers_done?(dep) and Map.get(dep.content, "lifecycle_status") == "blocked" do
        new_rev = generate_rev()
        new_content = Map.put(dep.content, "lifecycle_status", "open")

        {1, _} =
          from(d in Document, where: d.id == ^dep.id and d.rev == ^dep.rev)
          |> Repo.update_all(
            set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
          )

        unblocked = %{dep | content: new_content, rev: new_rev}
        ev = insert_mutation_event!(unblocked, @event_task_mutated, dep.rev)
        [task_broadcast(unblocked, @event_task_mutated, ev, dep.rev)]
      else
        []
      end
    end)
  end

  defp cascade_unblock_dependents!(_non_done_parent), do: []

  defp all_blockers_done?(%Document{} = dep) do
    dep.id
    |> dependencies(kind: :blocks)
    |> Enum.all?(fn %Document{content: c} ->
      Map.get(c, "lifecycle_status") == "done"
    end)
  end

  defp current_epoch(%Document{content: %{"claim" => %{"epoch" => e}}}) when is_integer(e), do: e
  defp current_epoch(_), do: 0

  # Mutation-events insert. The existing `mutation_events` schema (used by
  # the document spine) is reused verbatim — the `mutation` text column
  # carries our `task.claimed` / `task.closed` / `task.mutated` kinds, the
  # `document` map carries an Envelope-shaped view of the post-update row.
  # Tenancy stamps mirror `Content.save_event/5` so workspace-scoped
  # `recent_activity` reads surface task ops.
  defp insert_mutation_event!(%Document{} = doc, kind, previous_rev) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: doc.dataset,
      type: doc.type,
      doc_id: doc.doc_id,
      mutation: kind,
      rev: doc.rev,
      previous_rev: previous_rev,
      document: %{
        "doc_id" => doc.doc_id,
        "type" => doc.type,
        "title" => doc.title,
        "status" => doc.status,
        "content" => doc.content,
        "rev" => doc.rev
      },
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      dataset_id: doc.dataset_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  # New rev token, same shape as `Content.generate_rev/0`. Kept private here
  # so `Tasks` does not depend on a private function in another module.
  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc "The mutation_events kinds emitted by this module."
  @spec event_kinds() :: %{
          claimed: String.t(),
          closed: String.t(),
          mutated: String.t(),
          relabeled: String.t(),
          referenced: String.t()
        }
  def event_kinds do
    %{
      claimed: @event_task_claimed,
      closed: @event_task_closed,
      mutated: @event_task_mutated,
      relabeled: @event_task_relabeled,
      referenced: @event_task_referenced
    }
  end

  # The shared query the read-only `ready/1` and the row-locked `claim/2`
  # both ride on. Keeping ONE definition is what makes the
  # "claim returns exactly what ready would have picked" contract a
  # property of the code, not a documentation promise.
  defp ready_query(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    dataset = Keyword.get(opts, :dataset)
    phase_id = Keyword.get(opts, :phase_id)
    limit = Keyword.get(opts, :limit, @ready_default_limit)

    base =
      from(d in Document,
        as: :doc,
        where: d.type == "task",
        where: fragment("?->>'kind'", d.content) == "task",
        where: fragment("?->>'lifecycle_status'", d.content) in ^@ready_lifecycle_statuses,
        where:
          not exists(
            from e in Edge,
              join: b in Document,
              on: b.id == e.to_id,
              where:
                e.from_id == parent_as(:doc).id and
                  e.kind == "blocks" and
                  fragment("COALESCE(?->>'lifecycle_status', '')", b.content) != "done",
              select: 1
          ),
        order_by: [
          asc_nulls_last: fragment("(?->>'priority')::int", d.content),
          asc: d.inserted_at
        ],
        limit: ^limit
      )

    base
    |> maybe_filter_dataset(dataset)
    |> maybe_filter_phase(phase_id)
    |> Scope.scope_to_workspace(workspace_id, project_id)
  end

  defp maybe_filter_dataset(query, nil), do: query

  defp maybe_filter_dataset(query, dataset) when is_binary(dataset) do
    from [doc: d] in query, where: d.dataset == ^dataset
  end

  defp maybe_filter_phase(query, nil), do: query

  defp maybe_filter_phase(query, phase_id) when is_binary(phase_id) do
    from [doc: d] in query,
      where: fragment("?->>'parent_id'", d.content) == ^phase_id
  end
end
