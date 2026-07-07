defmodule Barkpark.Plugins.Github.Fields do
  @moduledoc """
  The field-ownership matrix for the `github` bridge (epic charter Decision 5) —
  a single, pure, test-enumerable declaration of WHO owns each mirrored aspect
  of a task and WHICH WAY it is allowed to flow. This module IS the directional-
  purity invariant: there is no reverse GitHub→task field writer anywhere in the
  codebase, so bidirectionality is impossible BY CONSTRUCTION, not by discipline.

  Each entry declares:

    * `:owner` — `:barkpark` (the guerrilla ledger authors it), `:github`
      (an outsider authored it, read ONCE at intake), or `:derived` (Barkpark
      computes it from other ledger state — e.g. the `status` label).
    * `:direction` — one of:
        * `:outbound_only`       — Barkpark → GitHub only; NEVER read back.
        * `:inbound_intake_only` — read ONCE at issue birth to seed a task;
                                    Barkpark-owned forever after.
        * `:never`               — this aspect NEVER touches GitHub at all
                                    (claims/epochs/fencing/rail_rev stay in the
                                    ledger — the whole point of the seam).
    * `:issue_attr` — for a `:barkpark`/`:derived` outbound field, the SINGLE
      GitHub Issue attribute it projects onto (`:title`/`:body`/`:labels`/
      `:state`/`:sub_issue`). Exactly one per outbound field, so
      `Projection.task_to_issue/1` has an unambiguous target.
    * `:projects_field` — the Projects v2 single-select column it also feeds via
      GraphQL, when any. Read-only dashboard (charter D10); NEVER read back.

  There is DELIBERATELY no `:inbound` writer keyed off these entries. The only
  functions here READ the matrix (`all/0`, `outbound_fields/0`,
  `intake_fields/0`); none of them write a GitHub value into a task.

  The matrix is the machine-checked mirror of the Ownership table in
  `.claude/workflows/bp-github-bridge-epic-charter.md`; `fields_test.exs`
  property-asserts its invariants (no field has two directions, every barkpark
  outbound field maps to exactly one issue attr, the ledger-only primitives are
  `:never`).
  """

  @typedoc "Which side authors the value and whether Barkpark ever reads it back."
  @type owner :: :barkpark | :github | :derived
  @type direction :: :outbound_only | :inbound_intake_only | :never
  @type issue_attr :: :title | :body | :labels | :state | :sub_issue | nil

  @type entry :: %{
          owner: owner(),
          direction: direction(),
          issue_attr: issue_attr(),
          projects_field: atom() | nil
        }

  # The one true matrix. One entry per mirrored aspect. Keep it verbatim-aligned
  # with the charter's Ownership table — any drift here is a directional bug.
  @matrix %{
    # --- Barkpark-owned, outbound_only: the ledger authors, GitHub reflects. ---
    title: %{owner: :barkpark, direction: :outbound_only, issue_attr: :title, projects_field: nil},
    description: %{owner: :barkpark, direction: :outbound_only, issue_attr: :body, projects_field: nil},
    lifecycle_status: %{owner: :barkpark, direction: :outbound_only, issue_attr: :state, projects_field: nil},
    priority: %{owner: :barkpark, direction: :outbound_only, issue_attr: :labels, projects_field: :priority},
    worker: %{owner: :barkpark, direction: :outbound_only, issue_attr: :labels, projects_field: :worker},
    # `status` is DERIVED from lifecycle_status + claim, not stored — charter
    # marks it "(derived)"; still strictly outbound_only.
    status: %{owner: :derived, direction: :outbound_only, issue_attr: :labels, projects_field: :status},
    parent_id: %{owner: :barkpark, direction: :outbound_only, issue_attr: :sub_issue, projects_field: :goal},
    blocks: %{owner: :barkpark, direction: :outbound_only, issue_attr: :body, projects_field: nil},
    acceptance_criteria: %{owner: :barkpark, direction: :outbound_only, issue_attr: :body, projects_field: nil},

    # --- GitHub-origin, inbound_intake_only: read ONCE at birth, then owned by
    # Barkpark forever. No entry here is ever written back to GitHub as a field.
    src_labels: %{owner: :github, direction: :inbound_intake_only, issue_attr: nil, projects_field: nil},
    outsider_title: %{owner: :github, direction: :inbound_intake_only, issue_attr: nil, projects_field: nil},
    outsider_body: %{owner: :github, direction: :inbound_intake_only, issue_attr: nil, projects_field: nil},
    outsider_author: %{owner: :github, direction: :inbound_intake_only, issue_attr: nil, projects_field: nil},

    # --- Ledger-only primitives: NEVER represented on GitHub, in any direction.
    # These are the invariants the whole seam exists to protect.
    claim: %{owner: :barkpark, direction: :never, issue_attr: nil, projects_field: nil},
    epoch: %{owner: :barkpark, direction: :never, issue_attr: nil, projects_field: nil},
    fence: %{owner: :barkpark, direction: :never, issue_attr: nil, projects_field: nil},
    rail_rev: %{owner: :barkpark, direction: :never, issue_attr: nil, projects_field: nil}
  }

  @doc """
  The whole matrix, `field => entry`. This is the single source the property
  test enumerates.
  """
  @spec all() :: %{atom() => entry()}
  def all, do: @matrix

  @doc """
  Fields that flow Barkpark → GitHub (`:outbound_only`). These are the ONLY
  fields `Projection.task_to_issue/1` and the Projects writer read from a task.
  """
  @spec outbound_fields() :: %{atom() => entry()}
  def outbound_fields, do: filter_by_direction(:outbound_only)

  @doc """
  Fields read ONCE at issue birth to seed a `gh-<num>` task (`:inbound_intake_only`).
  After birth every one of them is Barkpark-owned; none is ever mirrored back.
  """
  @spec intake_fields() :: %{atom() => entry()}
  def intake_fields, do: filter_by_direction(:inbound_intake_only)

  @doc """
  Fields that NEVER touch GitHub (`:never`) — the claim/epoch/fence/rail_rev
  primitives that stay in the ledger.
  """
  @spec never_fields() :: %{atom() => entry()}
  def never_fields, do: filter_by_direction(:never)

  @doc "The valid direction atoms, for exhaustive test assertions."
  @spec directions() :: [direction()]
  def directions, do: [:outbound_only, :inbound_intake_only, :never]

  defp filter_by_direction(direction) do
    @matrix
    |> Enum.filter(fn {_field, entry} -> entry.direction == direction end)
    |> Map.new()
  end
end
