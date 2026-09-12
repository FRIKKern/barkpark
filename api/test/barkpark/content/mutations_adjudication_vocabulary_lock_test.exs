defmodule Barkpark.Content.MutationsAdjudicationVocabularyLockTest do
  @moduledoc """
  THE LOCK on the raw door's adjudication vocabulary (task-60fcfd10f5e736aa).

  `Barkpark.Content.Mutations` screens the adjudication triple at
  `/v1/data/mutate` — the term, the rerun and the reopen trigger — and
  `Barkpark.Tasks.Stage` is the one sanctioned WRITER of that triple. Until
  this task, mutations.ex hand-copied the key names and the trigger-required
  term set as module literals (`@disposition_key "disposition"`,
  `@trigger_required_dispositions ~w(parked)`) eighty lines above a
  `Stage.dispositions()` call in the same function group. Two spellings of one
  truth table, and nothing that reds when they diverge: add a fourth term to
  Stage and both suites stay green while the mutate door and the verb disagree
  about what a park is.

  mutations.ex now READS Stage for all five (`disposition_key/0`,
  `reopen_trigger_key/0`, `disposition_rerun_key/0`, `dispositions/0`,
  `trigger_required_dispositions/0`). This file is the freshness lock that
  keeps it that way, and it is DERIVED, never enumerated: every assertion below
  iterates or reads a Stage function, so a term added to Stage moves the
  expectation with it. Retyping any of them back into a literal at the former
  copy site reds this file the moment the two sides differ — proven by mutation
  in both directions on the PR that introduced it.

  Sibling: `Barkpark.Tasks.SchemaAdjudicationTripleTest` locks the same
  vocabulary for the task SCHEMA (#17843).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Repo, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks
  alias Barkpark.Tasks.Stage

  @token "barkpark-test-mutations-vocab-lock-token"
  @dataset "production"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-mutations-vocab-lock", "test", ["read", "write", "admin"])

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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(doc_id, scope, content_extra) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, %Document{} = doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp mutate(ops, scope), do: Content.apply_mutations(ops, @dataset, [source: :api] ++ scope)

  defp set_patch(doc_id, set), do: %{"patch" => %{"id" => doc_id, "type" => "task", "set" => set}}

  defp unset_patch(doc_id, keys),
    do: %{"patch" => %{"id" => doc_id, "type" => "task", "unset" => keys}}

  defp refusal_keys({:error, {:invalid_task_content, details}}) when is_map(details),
    do: Map.keys(details)

  defp refusal_keys(other), do: {:not_a_refusal, other}

  # A row born carrying `term`, complete: a trigger-owing term is born with a
  # trigger so the BIRTH fence (a different guard) cannot be what refuses the
  # write under test.
  defp born_with(term, scope, extra \\ %{}) do
    content =
      %{Stage.disposition_key() => term}
      |> Map.merge(
        if term in Stage.trigger_required_dispositions(),
          do: %{Stage.reopen_trigger_key() => "the lock's seed trigger"},
          else: %{}
      )
      |> Map.merge(extra)

    mk_task!(uniq("vocab-lock-#{term}"), scope, content)
  end

  # ── 1. The KEY NAMES the door screens and names in its 422 ────────────────

  describe "the refusal details are keyed on Stage's key names, not retyped ones" do
    test "a raw disposition change is refused under Stage.disposition_key/0", %{scope: scope} do
      doc = born_with("open", scope)

      other =
        Enum.find(Stage.dispositions(), &(&1 != "open")) ||
          flunk("Stage.dispositions/0 has fewer than two terms")

      result = mutate([set_patch(doc.doc_id, %{Stage.disposition_key() => other})], scope)

      assert refusal_keys(result) == [Stage.disposition_key()],
             "the raw-door disposition refusal must be keyed on Stage.disposition_key/0 " <>
               "(#{inspect(Stage.disposition_key())}), got #{inspect(result)}"
    end

    test "a raw rerun change is refused under Stage.disposition_rerun_key/0", %{scope: scope} do
      doc = born_with("open", scope)

      result =
        mutate(
          [set_patch(doc.doc_id, %{Stage.disposition_rerun_key() => "git rev-parse HEAD"})],
          scope
        )

      assert refusal_keys(result) == [Stage.disposition_rerun_key()],
             "the raw-door rerun refusal must be keyed on Stage.disposition_rerun_key/0 " <>
               "(#{inspect(Stage.disposition_rerun_key())}), got #{inspect(result)}"
    end

    test "a trigger erasure is refused under Stage.reopen_trigger_key/0", %{scope: scope} do
      term =
        List.first(Stage.trigger_required_dispositions()) ||
          flunk("Stage.trigger_required_dispositions/0 is empty")

      doc = born_with(term, scope)

      result = mutate([unset_patch(doc.doc_id, [Stage.reopen_trigger_key()])], scope)

      assert refusal_keys(result) == [Stage.reopen_trigger_key()],
             "the trigger-erasure refusal must be keyed on Stage.reopen_trigger_key/0 " <>
               "(#{inspect(Stage.reopen_trigger_key())}), got #{inspect(result)}"
    end
  end

  # ── 2. The TRIGGER-REQUIRED SET, derived from Stage ───────────────────────

  describe "the trigger-erasure guard fires for exactly Stage.trigger_required_dispositions/0" do
    test "EVERY trigger-owing term refuses erasure", %{scope: scope} do
      owing = Stage.trigger_required_dispositions()

      assert owing != [],
             "precondition: Stage.trigger_required_dispositions/0 must name at least one term"

      for term <- owing do
        doc = born_with(term, scope)
        result = mutate([unset_patch(doc.doc_id, [Stage.reopen_trigger_key()])], scope)

        assert refusal_keys(result) == [Stage.reopen_trigger_key()],
               "#{inspect(term)} is in Stage.trigger_required_dispositions/0, so erasing its " <>
                 "reopen trigger through /v1/data/mutate must be refused — the mutate door is " <>
                 "reading a STALE copy of the trigger-required set. got #{inspect(result)}"

        # The refusal is side-effect-free: the trigger is still on the row.
        assert Repo.get!(Document, doc.id).content[Stage.reopen_trigger_key()] ==
                 "the lock's seed trigger"
      end
    end

    test "CONTROL: every NON-owing term allows the same erasure", %{scope: scope} do
      not_owing = Stage.dispositions() -- Stage.trigger_required_dispositions()

      assert not_owing != [],
             "precondition: Stage.dispositions/0 must carry a term that owes no trigger, " <>
               "or the control above proves nothing"

      for term <- not_owing do
        doc = born_with(term, scope, %{Stage.reopen_trigger_key() => "an unowed trigger"})

        result = mutate([unset_patch(doc.doc_id, [Stage.reopen_trigger_key()])], scope)

        assert match?({:ok, _}, result),
               "#{inspect(term)} is NOT in Stage.trigger_required_dispositions/0, so the " <>
                 "mutate door must not refuse erasing its reopen trigger. got " <>
                 "#{inspect(result)}"
      end
    end
  end

  # ── 3. The ADOPTION guard's vocabulary, derived from Stage ────────────────

  describe "the adoption guard admits exactly Stage.dispositions/0" do
    test "a reparent is allowed for EVERY term in Stage.dispositions/0", %{scope: scope} do
      parent = mk_task!(uniq("vocab-lock-parent"), scope, %{})

      for term <- Stage.dispositions() do
        doc = born_with(term, scope)

        result = mutate([set_patch(doc.doc_id, %{"parent_id" => parent.doc_id})], scope)

        assert match?({:ok, _}, result),
               "#{inspect(term)} is in Stage.dispositions/0, so a row carrying it is " <>
                 "ADJUDICATED and the adoption guard must let it be reparented — the mutate " <>
                 "door is reading a STALE copy of the vocabulary. got #{inspect(result)}"
      end
    end

    test "CONTROL: a reparent of an UNADJUDICATED row is still refused", %{scope: scope} do
      parent = mk_task!(uniq("vocab-lock-parent-ctl"), scope, %{})
      bare = mk_task!(uniq("vocab-lock-bare"), scope, %{})

      result = mutate([set_patch(bare.doc_id, %{"parent_id" => parent.doc_id})], scope)

      assert refusal_keys(result) == ["parent_id"],
             "a row with no disposition must still be refused adoption, or the case above " <>
               "passes because the guard never fires. got #{inspect(result)}"
    end
  end

  # ── 4. The mirror is GONE from the source ─────────────────────────────────

  test "mutations.ex retypes none of Stage's adjudication vocabulary" do
    source = File.read!("lib/barkpark/content/mutations.ex")

    retyped =
      for {label, literal} <- [
            {"Stage.disposition_key/0", Stage.disposition_key()},
            {"Stage.reopen_trigger_key/0", Stage.reopen_trigger_key()},
            {"Stage.disposition_rerun_key/0", Stage.disposition_rerun_key()}
          ],
          String.contains?(source, "@#{literal}_key ") or
            String.contains?(source, ~s(_key #{inspect(literal)})),
          do: label

    assert retyped == [],
           "mutations.ex re-declares #{inspect(retyped)} as a module literal. The mutate door " <>
             "must read Barkpark.Tasks.Stage — it is the one writer of an adjudication and " <>
             "therefore the one owner of its key names."

    for term <- Stage.trigger_required_dispositions() do
      refute String.contains?(source, "~w(#{term})"),
             "mutations.ex hand-copies the trigger-required set as ~w(#{term}). Call " <>
               "Stage.trigger_required_dispositions/0 instead."
    end
  end
end
