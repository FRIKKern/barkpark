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
  Returns the `%SchemaDefinition{}` structs the task substrate needs:
  `task` (the dossier) and `listener` (fleet presence — see
  `listener_schema/1`).

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
    [task_schema(dataset), listener_schema(dataset)]
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
        # Thought states at the ladder bottom (task-lifecycle-visibility):
        # candidates being weighed or investigated, before they are felt ready
        # (open). Mirrors the closed-chip `{"in":[...]}` grouping pattern.
        %{
          "name" => "thinking",
          "title" => "Thinking",
          "filter" => %{
            "content.lifecycle_status" => %{"in" => ["considering", "researching"]}
          }
        },
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

        # The canonical, presentation-grade task brief. PortableDoc is kept
        # inline so every task read carries its full human/agent context; the
        # legacy description below remains the plain-text fallback/excerpt.
        %{
          "name" => "brief",
          "title" => "Portable brief",
          "type" => "object",
          "group" => "brief",
          "description" =>
            "Canonical PortableDoc document: {version: 1, blocks: [...]}. Use headings, sections, lists, code, tables, diagrams and callouts to make the work immediately understandable on every renderer. description remains the concise fallback for legacy and text-only surfaces."
        },

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
            "Concise plain-text/Markdown fallback and search excerpt. Put the presentation-grade brief in brief as PortableDoc; text-only clients read this field."
        },
        %{
          "name" => "purpose",
          "title" => "Purpose",
          "type" => "composite",
          "group" => "brief",
          "description" =>
            "Why this task exists, its intended endgame, scored importance/relevance with reasons, and evidence for the claims. Readers label any missing-value fallback as derived.",
          "fields" => [
            %{"name" => "part_of", "title" => "What this is part of", "type" => "string"},
            %{
              "name" => "impact",
              "title" => "What this blocks or enables",
              "type" => "text",
              "rows" => 2
            },
            %{
              "name" => "statement",
              "title" => "What this accomplishes",
              "type" => "text",
              "rows" => 3
            },
            %{
              "name" => "why",
              "title" => "Why this matters",
              "type" => "text",
              "rows" => 3,
              "description" =>
                "State the causal reason this task is necessary inside its parent mission: the problem, risk, or missing capability it resolves and why that contribution matters to the larger goal. Do not restate the title, acceptance criteria, or desired outcome."
            },
            %{"name" => "endgame", "title" => "Endgame", "type" => "text", "rows" => 3},
            %{
              "name" => "importance",
              "title" => "Importance",
              "type" => "composite",
              "fields" => [
                %{
                  "name" => "score",
                  "title" => "Score (0–100)",
                  "type" => "number",
                  "validation" => %{"min" => 0, "max" => 100}
                },
                %{"name" => "reason", "title" => "Reason", "type" => "text", "rows" => 2}
              ]
            },
            %{
              "name" => "relevance",
              "title" => "Relevance",
              "type" => "composite",
              "fields" => [
                %{
                  "name" => "score",
                  "title" => "Score (0–100)",
                  "type" => "number",
                  "validation" => %{"min" => 0, "max" => 100}
                },
                %{"name" => "reason", "title" => "Reason", "type" => "text", "rows" => 2}
              ]
            },
            %{
              "name" => "proof",
              "title" => "Proof",
              "type" => "arrayOf",
              "ordered" => true,
              "of" => %{
                "name" => "proof_item",
                "type" => "composite",
                "fields" => [
                  %{"name" => "claim", "title" => "Claim", "type" => "text", "rows" => 2},
                  %{"name" => "evidence", "title" => "Evidence", "type" => "text", "rows" => 2},
                  %{"name" => "source", "title" => "Source", "type" => "string"}
                ]
              }
            }
          ]
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
        # out of the ready queue.
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

        # Advisory execution routing only. The strict nested contract lives in
        # Tasks.ExecutionPolicy; no command/env/cwd/secret/security knobs exist.
        %{
          "name" => "execution_policy",
          "title" => "Execution policy",
          "type" => "composite",
          "group" => "brief",
          "description" =>
            "Optional version-1 advisory routing hints. Claim freezes a resolved snapshot; this policy cannot execute commands or set environment, cwd, secrets, permissions, or security controls.",
          "fields" => [
            %{
              "name" => "version",
              "title" => "Version",
              "type" => "number",
              "validation" => %{"required" => true, "min" => 1, "max" => 1}
            },
            %{
              "name" => "agent_type",
              "title" => "Agent type",
              "type" => "string",
              "description" => "Advisory typed-agent role, such as executor or verifier."
            },
            %{
              "name" => "model",
              "title" => "Model",
              "type" => "string",
              "description" => "Advisory model identifier; provider availability still governs."
            },
            %{
              "name" => "reasoning_effort",
              "title" => "Reasoning effort",
              "type" => "select",
              "options" => ~w(minimal low medium high xhigh)
            },
            %{
              "name" => "resource_class",
              "title" => "Resource class",
              "type" => "select",
              "options" => ~w(light standard heavy),
              "description" => "Advisory capacity class; it does not directly control a process."
            }
          ]
        },
        %{
          "name" => "queue_gate",
          "title" => "Execution gate",
          "type" => "composite",
          "group" => "brief",
          "description" =>
            "Optional strict version-1 execution gate. Legacy or absent gates are executable. foreign_claimed is derived from live claim state and cannot be stored.",
          "fields" => [
            %{
              "name" => "version",
              "title" => "Version",
              "type" => "number",
              "validation" => %{"required" => true, "min" => 1, "max" => 1}
            },
            %{
              "name" => "state",
              "title" => "State",
              "type" => "select",
              "options" => ~w(executable human_gated parked evidence_stalled)
            },
            %{
              "name" => "reason",
              "title" => "Reason",
              "type" => "text",
              "rows" => 3,
              "description" => "Required for every non-executable state; absent for executable."
            },
            %{
              "name" => "evidence",
              "title" => "Evidence",
              "type" => "string",
              "description" =>
                "Required for evidence_stalled; optional for other non-executable states."
            }
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

        # Weighted-label spine (authoring-excellence). Distinct from the legacy
        # free-form `labels` above (D11 — labels feeds Tasks.Similarity and is
        # untouched this epic): `tags` carries {tag, strength 1-100, rationale},
        # cross-member rules (1-12 count, distinct strengths, unique main tag)
        # enforced by Barkpark.Content.LabelSpine at the publish wall (mount is
        # ae-w1-publish-wall-mount). Per-leaf shape declared here so Studio + the
        # recursive validator reject malformed leaves early.
        %{
          "name" => "tags",
          "title" => "Tags",
          "type" => "arrayOf",
          "ordered" => false,
          "group" => "brief",
          "description" =>
            "Weighted labels: {tag ^[a-z0-9-]+$, strength 1-100 distinct, rationale}. 1-12 tags; the unique-max strength is the main tag.",
          "of" => %{
            "type" => "composite",
            "fields" => [
              %{
                "name" => "tag",
                "title" => "Tag",
                "type" => "string",
                "validation" => %{"required" => true, "pattern" => "^[a-z0-9-]+$"}
              },
              %{
                "name" => "strength",
                "title" => "Strength",
                "type" => "number",
                "validation" => %{"required" => true, "min" => 1, "max" => 100}
              },
              %{
                "name" => "rationale",
                "title" => "Rationale",
                "type" => "string",
                "validation" => %{"required" => true}
              }
            ]
          }
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
            "considering | researching | open | in_progress | blocked | done | cancelled. OPEN MEANS READY — only open|blocked is claimable. considering/researching are thought states (a candidate the strategizer names, or an investigation in flight) and carry their object in content.engagement. Engine-written by claim/close/sweep; agents do not set in_progress by hand."
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

        # Task 5 (session-handoff): session doc-ids this task was worked in,
        # via POST /v1/tasks/:id/sessions {add,remove}. Mirrors `attachments`
        # byte-for-byte — arrayOf reference, no server-side expansion.
        # Sessions are referenced by slug string only; no FK.
        %{
          "name" => "sessions",
          "title" => "Sessions",
          "type" => "arrayOf",
          "ordered" => false,
          "group" => "system",
          "description" =>
            "session doc-ids this task was worked in, via POST /v1/tasks/:id/sessions {add,remove}. Arrays of references do not server-expand; fetch each by id.",
          "of" => %{"type" => "reference", "refType" => "session"}
        },

        # ── CLOSE — durable completion context ───────────────────────────
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
              "options" => [
                "shipped",
                "fixed",
                "partial",
                "wont_do",
                "duplicate",
                "superseded",
                "discarded"
              ]
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

        # One-line landing slot for a close reason (cheaper for an
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

        # GATES READINESS (read-side, Barkpark.Tasks.Queue): a doc_id list on
        # the task itself. A task is NOT ready/claimable until every id here
        # resolves to a same-scope task with lifecycle_status="done"; a
        # missing/dangling id counts as unsatisfied (fail-closed). Complements —
        # does not replace — the authoritative task_edges `blocks` graph; both
        # gate. There is NO write-path materialization into edges: this is a pure
        # read-side gate.
        %{
          "name" => "dependencies",
          "title" => "Dependencies",
          "type" => "array",
          "group" => "system",
          "visibleWhen" => %{"field" => "dependencies", "operator" => "non_empty"},
          "description" =>
            "Doc-id list that GATES readiness: the task is not ready/claimable until every id here is a task with lifecycle_status=done (missing/dangling = unsatisfied, fail-closed). For a graph edge you can add/remove independently, use task_edges: POST /v1/tasks/edges {from_id,to_id,kind:\"blocks\"}."
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

  @doc """
  The `listener` schema struct — Personal Dev Fleet presence (Wave A).

  A listener is a dev-server/agent session that heartbeats its presence into
  the ledger via `POST /v1/fleet/beat` and is read back by
  `GET /v1/fleet/roster` (`Barkpark.Tasks.Fleet`). The type name is EXACTLY
  `"listener"` — NEVER `"task"`: the literal `type == "task"` filters in the
  GitHub outbox, `/v1/tasks/events` and `/v1/tasks/prime` are what
  structurally exclude listener rows from those feeds (a task-typed listener
  would leak as a fake GitHub issue).

  Content fields are FLAT, mirroring the task dossier idiom:

    * `worker` — the unique presence key (`_id` = `listener-<worker>`).
    * `agent` — what runs the session (`claude-code` | `codex` | `custom`).
    * `scope` — what the listener works on (free-form, e.g. a repo path).
    * `status` — self-declared via the beat: `idle | working | blocked`
      (PDF-D23; `provisioning` is stored vocab too, but written only by the
      cloud provisioner — Wave C — never beat-declarable). The roster
      OVERRIDES this to `"offline"` at read time when the beat is stale
      (fail-closed) — derived status is never stored.
    * `capacity` — free-form capacity hint (e.g. `"1 task"`).
    * `last_seen` — ISO8601, SERVER-stamped by the beat write only; clients
      never send a timestamp.
    * `ttl_s` — self-declared staleness budget in seconds, default 120.
  """
  @spec listener_schema(String.t()) :: SchemaDefinition.t()
  def listener_schema(dataset \\ "production") do
    %SchemaDefinition{
      name: "listener",
      title: "Listener",
      icon: "📡",
      # Presence rows are operational metadata, not public content — private
      # keeps them off the anonymous read API (the roster endpoint is
      # token-gated and reads the Repo directly).
      visibility: "private",
      dataset: dataset,
      list_preview: %{
        "badge" => "status",
        "meta" => %{"field" => "agent", "prefix" => ""}
      },
      fields: [
        %{
          "name" => "worker",
          "title" => "Worker",
          "type" => "string",
          "validation" => %{"required" => true},
          "description" =>
            "Unique presence key. The beat upserts on this — doc _id is listener-<worker>."
        },
        %{
          "name" => "agent",
          "title" => "Agent",
          "type" => "string",
          "description" => "What runs the session: claude-code | codex | custom."
        },
        %{
          "name" => "scope",
          "title" => "Scope",
          "type" => "string",
          "description" => "What the listener works on (repo, area, project)."
        },
        %{
          "name" => "status",
          "title" => "Status",
          "type" => "select",
          "options" => ["idle", "working", "blocked", "provisioning"],
          "description" =>
            "Self-declared via the beat: idle | working | blocked (provisioning is provisioner-written, Wave C). The roster computes offline from last_seen vs ttl_s at read time — offline is never stored."
        },
        %{
          "name" => "capacity",
          "title" => "Capacity",
          "type" => "string",
          "description" =>
            "Capacity for best-fit routing. A validated structured object — {size_class: light | standard | heavy | xl, slots_total, slots_free (<= slots_total), budget} — declared as a native map or a JSON-object string; or a legacy free-form hint, e.g. \"1 task\". Off-vocab size_class or negative/inverted slots are refused (never silently stored)."
        },
        %{
          "name" => "last_seen",
          "title" => "Last seen",
          "type" => "string",
          "description" =>
            "ISO8601, server-stamped by POST /v1/fleet/beat. Clients never send a timestamp."
        },
        %{
          "name" => "ttl_s",
          "title" => "TTL (s)",
          "type" => "number",
          "description" =>
            "Self-declared staleness budget in seconds (default 120). Older than this = offline on the roster."
        }
      ]
    }
  end
end
