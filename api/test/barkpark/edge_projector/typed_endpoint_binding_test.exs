defmodule Barkpark.EdgeProjector.TypedEndpointBindingTest do
  @moduledoc """
  An edge's `from_id` binds to a pk of the SOURCE DOC'S OWN TYPE
  (task-464b89f30e3f8e41).

  `documents.doc_id` is unique per (scope, TYPE), so a `tag` document and a
  `task` document can carry the SAME doc_id — and epic roots routinely do,
  because the epic's name is also its tag. Both edge extractors emit `from_id`
  as a bare doc_id STRING, and `Content.Edges.resolve_doc_pks/3` resolves that
  string with `List.first(rows_for_slug)` and NO type predicate — so the winner
  is whichever row Postgres hands back first, in practice the FIRST-CREATED.

  MEASURED on prod 2026-09-06: the `wave_paper` and `papers` citations of the
  TASK `api-read-path-security-sweep` are stored with `from_id` = the pk of the
  same-named `tag` document. `GET /v1/graph/<paper>` renders them; every
  task-side reader rightly refuses them, because their source is not a task.
  The two citations were invisible for two weeks and were filed as a missing
  edge.

  The fixture creates the TAG FIRST on purpose — that is what makes the
  unpatched resolver pick it, and what makes this test a catch rather than a
  coin flip.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Edge
  alias Barkpark.EdgeProjector.Projector
  alias Barkpark.Plugins.Registry
  alias Barkpark.Plugins.Tasks, as: TasksPlugin

  import Ecto.Query

  @dataset "production"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    prev_plugins = Application.get_env(:barkpark, :plugins)
    Application.delete_env(:barkpark, :plugins)
    :ok = Registry.register(TasksPlugin, %{"plugin_name" => "tasks"})

    on_exit(fn ->
      Registry.reset()

      case prev_plugins do
        nil -> Application.delete_env(:barkpark, :plugins)
        v -> Application.put_env(:barkpark, :plugins, v)
      end
    end)

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp publish!(type, doc_id, content, scope) do
    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => "#{type} #{doc_id}", "content" => content},
        @dataset,
        scope
      )

    {:ok, doc} = Content.publish_document(doc_id, type, @dataset, scope)
    doc
  end

  defp mk_paper!(slug) do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: @dataset,
          blocks: [%{"id" => "b-intro", "type" => "paragraph", "text" => "the strategy"}]
        })
      )

    Content.get_paper(slug, @dataset)
  end

  test "a task's wave_paper citation binds to the TASK pk, not a same-named tag's",
       %{scope: scope} do
    name = uniq("epic-and-tag")
    paper_slug = uniq("typed-binding-paper")

    paper = mk_paper!(paper_slug)

    # ORDER MATTERS: the tag is created FIRST, so the unpatched type-blind
    # resolver (List.first over the slug's rows, no type predicate) picks it.
    tag = publish!("tag", name, %{"kind" => "tag"}, scope)

    task =
      publish!(
        "task",
        name,
        Map.merge(Barkpark.LabelFixtures.with_labels(), %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "wave_paper" => paper_slug,
          "acceptance_criteria" => [%{"criterion" => "cited", "met" => false}]
        }),
        scope
      )

    # NON-VACUITY: two distinct rows really do share one doc_id, and they are
    # distinct pks — so "the edge points at the task" is a real discrimination.
    assert tag.doc_id == task.doc_id
    assert tag.type == "tag"
    assert task.type == "task"
    refute tag.id == task.id

    {:ok, %{added: added}} =
      Projector.rebuild_scope(
        @dataset,
        [TasksPlugin.hydrate_edges(task)],
        [dataset: @dataset] ++ scope
      )

    assert added > 0, "the rebuild wrote no edges at all — the fixture is not exercising the path"

    stored =
      Edge
      |> where([e], e.to_id == ^paper.id and e.kind == "wave_paper")
      |> Repo.all()

    assert match?([_], stored),
           "expected exactly one wave_paper edge into the paper; got " <> inspect(stored)

    [%Edge{from_id: from_id}] = stored

    assert from_id == task.id,
           "the citation bound to the wrong document: expected the TASK pk #{task.id}, got " <>
             "#{from_id}" <> if(from_id == tag.id, do: " — which is the TAG's pk", else: "")

    refute from_id == tag.id
  end
end
