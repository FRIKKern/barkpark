defmodule Barkpark.Tasks.Schema do
  @moduledoc """
  The `task` schema definition (the **task dossier**) — extracted from
  `Barkpark.Tasks` (behaviour-preserving facade split).

  Pure data-builder: `schema_definitions/1` and `task_schema/1` construct
  the `%SchemaDefinition{}` struct the seeds.exs and `Plugins.Bootstrap`
  paths register. No DB access. `Barkpark.Tasks` `defdelegate`s the public
  functions here so callers are unchanged.
  """

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Tasks.Validation

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

        # The what/why. The only free-text field a task create writes
        # (`bp task create --description`) — finally declared. `text` not
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
          "options" => Validation.lifecycle_statuses(),
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
        # mediaAsset doc-id strings; each Studio row mounts a per-row media
        # picker (tsk-dossier-ref-picker — ArrayField reference rows).
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
        # the Studio UI; Validation.kinds/0 stays the source of truth.
        %{
          "name" => "kind",
          "title" => "Kind",
          "type" => "select",
          "options" => Validation.kinds(),
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
        # the API is the single writer via /v1/tasks/:id/papers. Values
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
end
