defmodule Barkpark.Tasks.Blockers do
  @moduledoc """
  ONE answer to "what is holding this task back" — the set, not the predicate.

  `Tasks.DependencySatisfaction` already single-sources the PREDICATE ("is this
  blocker finished and attributable"). This module single-sources the SET the
  predicate is applied to, which is the half that had drifted.

  ## The drift this closes

  Barkpark records a dependency in TWO stores, and until now the doors read
  different subsets of them:

  | door                      | `blocks` edges | `content.dependencies` |
  |---------------------------|----------------|------------------------|
  | `Tasks.Queue.ready/1`     | yes (axis 1)   | yes (axis 2)           |
  | `Tasks.Claim`             | yes            | **no**                 |
  | `Tasks.Close` (unblock)   | yes            | **no**                 |

  So a dependency written ONLY into `content.dependencies` was withheld by the
  queue and INVISIBLE to the claim door: the row never surfaced in
  `bp task ready` / `bp task next`, yet a targeted `bp task claim <id>` was
  allowed straight through, and a close of some other blocker would cascade it
  to `open` as if nothing held it. Silent in both directions — the queue
  refused without saying why, and the claim door said yes without looking.

  ## Which store is AUTHORITATIVE, and why this is a UNION anyway

  `task_edges` is authoritative and the code says so in four places —
  `Barkpark.Plugins.Tasks` ("the authoritative dependency store is the
  `task_edges` table, NOT `content.dependencies`"), `Tasks.Schema` ("does not
  replace — the authoritative task_edges `blocks` graph; both gate"),
  `Barkpark.Tasks` ("the authoritative `task_edges` dep graph") and
  `Tasks.Queue`'s own axis-1 comment. It is also the only one of the two with a
  WRITER: `POST /v1/tasks/edges` → `TasksController.add_edge` → `Tasks.add_dep`
  → `Edges.add_edge/4`, plus `Content.add_edge/4` and the twin-canonicalizing
  backfill. Nothing writes `content.dependencies` on purpose: no `bp task` verb
  emits it, and the only code that touches the key is
  `Tasks.Validation.check_optional_string_list/3` VALIDATING whatever a generic
  `doc mutate` put there.

  Authoritative does not mean "the only one that gates", and this module is
  deliberately a UNION rather than a switch to edges alone. `Tasks.Queue` has
  gated on BOTH since W7-03 and `Tasks.Schema` documents `content.dependencies`
  as a real read-side gate; dropping it here would silently release live rows
  that are held back today, which is the "is this feature worth keeping"
  question wearing a bugfix costume. The union makes every door agree, fails
  CLOSED in both stores, and leaves that question open for whoever wants to
  answer it on purpose.

  ## Fail-closed, exactly as the ready query fails closed

  A `content.dependencies` id is satisfied only by a SAME-SCOPE (`dataset`,
  `project_id`, `workspace_id`) task whose content passes
  `DependencySatisfaction.satisfied?/1`. `drafts.` is stripped on BOTH sides so
  a dep pointing at either twin matches. A dangling id — no row at all —
  resolves to nothing and is therefore UNSATISFIED, which is what the ready
  query's `count(*) = 0` arm does.
  """

  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.{DependencySatisfaction, Edges}

  @doc """
  Are ALL of this task's blockers — from BOTH stores — satisfied?

  The one call every door makes. `Tasks.Claim.check_deps_satisfied/1` and
  `Tasks.Close.all_blockers_done?/1` are thin wrappers over it, so a change to
  the set cannot reach one door and miss the other.
  """
  @spec all_satisfied?(Document.t()) :: boolean()
  def all_satisfied?(%Document{} = doc), do: unsatisfied(doc) == []

  @doc """
  The blocker ids that are NOT satisfied, edge-sourced first then
  `content.dependencies`-sourced, each id as written.

  Returned rather than a bare boolean because a dependent that never becomes
  ready with nobody able to say why is the exact failure this module exists to
  end — see `DependencySatisfaction.explain/2` for the sentence.
  """
  @spec unsatisfied(Document.t()) :: [String.t()]
  def unsatisfied(%Document{} = doc) do
    unsatisfied_edges(doc) ++ unsatisfied_declared(doc)
  end

  defp unsatisfied_edges(%Document{id: id}) do
    id
    |> Edges.dependencies(kind: :blocks)
    |> Enum.reject(fn %Document{content: c} -> DependencySatisfaction.satisfied?(c) end)
    |> Enum.map(& &1.doc_id)
  end

  defp unsatisfied_declared(%Document{} = doc) do
    case declared_ids(doc) do
      [] ->
        []

      ids ->
        satisfied = satisfied_published_ids(doc, ids)
        Enum.reject(ids, &MapSet.member?(satisfied, strip_draft(&1)))
    end
  end

  @doc """
  The `content.dependencies` entries, as written, keeping only non-blank
  strings. A non-list (or absent) value yields `[]` and never gates — the same
  `jsonb_typeof(...) = 'array'` tolerance the ready query applies.
  """
  @spec declared_ids(Document.t()) :: [String.t()]
  def declared_ids(%Document{content: content}) do
    case Map.get(content || %{}, "dependencies") do
      list when is_list(list) ->
        list
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  # Of `ids`, which resolve to a same-scope task that SATISFIES? Returned as a
  # MapSet of `drafts.`-stripped doc_ids so the caller can match either twin.
  defp satisfied_published_ids(%Document{} = doc, ids) do
    stripped = Enum.map(ids, &strip_draft/1)

    from(d in Document,
      where: d.type == "task",
      where: d.dataset == ^doc.dataset,
      where: fragment("? IS NOT DISTINCT FROM ?", d.project_id, type(^doc.project_id, Ecto.UUID)),
      where: fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id) in ^stripped,
      select: {fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id), d.content}
    )
    |> scope_workspace(doc.workspace_id)
    |> Repo.all()
    |> Enum.filter(fn {_id, content} -> DependencySatisfaction.satisfied?(content) end)
    |> MapSet.new(fn {id, _content} -> id end)
  end

  # `workspace_id` is nullable, and `= NULL` matches nothing — the ready query
  # carries the same split (`done.workspace_id IS NULL` vs `= ?`).
  defp scope_workspace(query, nil), do: from(d in query, where: is_nil(d.workspace_id))
  defp scope_workspace(query, ws_id), do: from(d in query, where: d.workspace_id == ^ws_id)

  defp strip_draft("drafts." <> rest), do: rest
  defp strip_draft(id), do: id
end
