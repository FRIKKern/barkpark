defmodule Barkpark.Tasks.DedupDraftDebrisTest do
  @moduledoc """
  The dedup gate's refusal must be ACTIONABLE, and against a draft-only match it
  was not.

  ## The loop this pins

  `bp task create` sends no `doc_id`, so the server mints a fresh `task-<hex>`
  on every attempt, and `Content.create_document/4` writes every new doc as
  `drafts.<id>` (`create_document/4`: "New docs are always created as drafts").
  Under fleet load a create can raise
  `DBConnection.ConnectionError` on a checkout AFTER that draft row has landed —
  the caller sees `unknown error` and the draft survives. The retry mints a
  DIFFERENT id, so `prev_doc` is nil, the birth gate runs, and
  `Tasks.Dedup.fetch_candidates/2` fetches the orphan draft (nothing in
  `base_query/3` excludes a `drafts.` row; `DISTINCT ON` keeps it because it has
  no published twin). A byte-identical retry scores token-Jaccard 1.0, so
  `sim = 0.7 * 1.0 + 0.3 * 0.0 = 0.7` with no labels — over `@refuse 0.55` — and
  the create is refused by the caller's own debris.

  ## Why the refusal was unappealable

  `present/1` strips the `drafts.` prefix, so the payload named a canonical id
  while the message said "claim/extend it" and nothing said the match was a
  draft no board shows. The task read door now resolves the `drafts.` twin
  (`Barkpark.Tasks.TwinResolver`), so the note must not claim the id 404s
  (task-3a56dacebca54684: it said so, and `bp task get` answered 200).

  These tests assert STRUCTURE — which id, which flag, which verdict — never
  elapsed milliseconds. Every assertion is scoped to ids this test planted.
  """
  use Barkpark.DataCase, async: false

  # Plugins-off: the tasks plugin owns the task-content fences, lifecycle/claim/stage rules and task resolvers
  @moduletag :requires_plugins

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "production"

  # Unique per run: the task table is shared with the whole fleet, so a fixed id
  # could collide with another agent's row and turn a green into a false red.
  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  setup do
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

    %{scope: scope}
  end

  defp create_task(doc_id, title, scope, content_extra) do
    content =
      %{"kind" => "task", "lifecycle_status" => "open"}
      |> Map.merge(content_extra)
      # The Tasks plugin's :before_publish brief wall (inert until #19303).
      |> Barkpark.TaskBriefFixtures.with_brief()

    Content.create_document(
      "task",
      %{"doc_id" => doc_id, "title" => title, "content" => content},
      @dataset,
      scope
    )
  end

  @title "harden the payload sanitizer against nested block ids"
  @desc "walk nested blocks and strip attacker supplied identifiers before storage"

  # The minimum content.brief that satisfies portable_brief_gate/1: version 1
  # and at least one block of a bp-task-tui type. Only the PUBLISHED arm needs
  # it — the gate is a before_publish hook, so the draft arms are unaffected.
  @brief %{
    "version" => 1,
    "blocks" => [
      %{
        "id" => "purpose-copy",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => @desc}]
      }
    ]
  }

  test "THE MECHANISM: a byte-identical retry is refused by the debris draft its own failed create left behind",
       %{scope: scope} do
    debris = uid("debris")
    retry = uid("retry")

    # Attempt 1 landed the draft, then died on a later checkout. This is that row.
    {:ok, planted} = create_task(debris, @title, scope, %{"description" => @desc})

    # The write path stores every new doc as a DRAFT — this is what makes the
    # row invisible to `bp task get` while still being a dedup candidate.
    assert planted.doc_id == "drafts." <> debris

    # Attempt 2: the same command, a freshly minted id, nothing else different.
    assert {:error, {:duplicate_task, payload}} =
             create_task(retry, @title, scope, %{"description" => @desc})

    match = Enum.find(payload.similar, fn m -> m.id == debris end)

    assert match != nil,
           "the retry must be refused by the planted debris draft; similar=#{inspect(payload.similar)}"

    # 0.7 * jaccard(identical token bag) + 0.3 * jaccard(empty labels)
    #   = 0.7 * 1.0 + 0.3 * 0.0 = 0.7, over @refuse 0.55.
    assert match.similarity == 0.7
    assert match.relation == "cross"
  end

  test "a refusal names an UNPUBLISHED match as unpublished", %{scope: scope} do
    debris = uid("unpub")
    retry = uid("unpub-retry")

    {:ok, _} = create_task(debris, @title, scope, %{"description" => @desc})

    assert {:error, {:duplicate_task, payload}} =
             create_task(retry, @title, scope, %{"description" => @desc})

    match = Enum.find(payload.similar, fn m -> m.id == debris end)
    assert match != nil

    assert Map.get(match, :published) == false,
           "a draft-only match must be reported as unpublished so the caller is not sent to " <>
             "claim an id that 404s; got #{inspect(match)}"

    assert payload.message =~ "UNPUBLISHED DRAFT",
           "the refusal must name the draft recovery, not just say claim/extend it; got: " <>
             payload.message

    # task-3a56dacebca54684: every fact the note states must be true. The id it
    # names resolves through the SAME reader `bp task get` uses, so the note may
    # not say it 404s, nor send the caller away from a row it can inspect.
    assert {:ok, resolved} =
             Tasks.TwinResolver.resolve(
               debris,
               fn q ->
                 q
                 |> BarkparkWeb.TasksController.Params.maybe_filter_workspace(
                   scope[:workspace_id]
                 )
                 |> BarkparkWeb.TasksController.Params.maybe_filter_project(scope[:project_id])
               end,
               &Barkpark.Repo.all/1
             )

    assert resolved.doc_id == "drafts." <> debris

    # The ids are random (uid/1), so one can contain the digits "404"
    # (e.g. "unpub-404386"); strip the ids the note quotes before looking
    # for a 404 claim, or the test reds on a lucky number.
    prose = payload.message |> String.replace(debris, "") |> String.replace(retry, "")

    refute prose =~ "404",
           "the task read door resolves the draft, so the note must not say it 404s: " <>
             payload.message

    refute payload.message =~ "nothing there to claim",
           "a draft-only task is claimable; the note must not say otherwise: " <> payload.message

    assert payload.message =~ "bp task get <id>",
           "the note must name the inspect verb that works: " <> payload.message
  end

  test "a PUBLISHED match is still reported as published (the flag is not hardcoded)", %{
    scope: scope
  } do
    existing = uid("pub")
    newcomer = uid("pub-retry")

    # The publish wall (label_spine) requires 1–12 REGISTERED weighted tags, so
    # the PUBLISHED arm needs them; the fixture also supplies a description,
    # which is overridden here so both arms score on the same token bag.
    #
    # portable_brief_gate/1 (api/lib/barkpark/plugins/tasks.ex, from ee483fa4b
    # "feat(tasks): require PortableDoc briefs at publish") is a SECOND publish
    # wall: it halts any task publish whose content.brief is not a PortableDoc
    # {version: 1, blocks: [...]} of bp-task-tui block types. Without it this
    # publish returns {:error, {:halted, "task brief is required before
    # publish — ..."}} and the {:ok, published} match below raises a
    # MatchError — which is exactly how this test reds on origin/main.
    published_content =
      %{"description" => @desc, "brief" => @brief}
      |> Barkpark.LabelFixtures.with_registered_labels(@dataset)

    {:ok, _} = create_task(existing, @title, scope, published_content)
    {:ok, published} = Content.publish_document(existing, "task", @dataset, scope)

    assert published.doc_id == existing,
           "the fixture must actually be PUBLISHED for this test to mean anything"

    assert {:error, {:duplicate_task, payload}} =
             create_task(newcomer, @title, scope, %{"description" => @desc})

    match = Enum.find(payload.similar, fn m -> m.id == existing end)
    assert match != nil

    assert Map.get(match, :published) == true,
           "a published match must NOT be flagged as draft debris; got #{inspect(match)}"

    refute payload.message =~ "UNPUBLISHED DRAFT",
           "a published match must not carry the draft-recovery note; got: " <> payload.message
  end
end
