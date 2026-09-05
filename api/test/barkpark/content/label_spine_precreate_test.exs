defmodule Barkpark.Content.LabelSpinePrecreateTest do
  @moduledoc """
  The label-spine publish wall was a PARTIAL WRITE (task-e89f4a9ed2f5ce0b,
  reproduced 2026-09-01): `bp task create --publish` committed the create half
  and THEN 422'd `label_spine` on the publish half, leaving an orphan
  `drafts.<id>` that no published-first reader can see, behind an rc=0 and a
  printed receipt that both read as success.

  These tests pin the SERVER half of the fix: the SHAPE half of
  `LabelSpine.validate/1` now runs on the CREATE path
  (`Content.Writer.create_document/4` — the one chokepoint all four
  create-family verbs funnel through) for `type:task`, BEFORE any row is
  persisted.

  ## Absence is asserted by the fixture's OWN id

  The fleet shares one test database, so a table-wide count proves nothing
  about this test. Every absence assertion below reads `drafts.<fixture-id>`
  by id — a `{:error, :not_found}` from `Content.get_document/4` on the exact
  id this test tried to create.

  ## MUTATION PROOF

  Removing the `refuse_malformed_label_spine/2` call from `create_document/4`
  makes `test "MUTATION SENTINEL — …"` and the two absence tests red: the
  create returns `{:ok, doc}` and `drafts.<id>` is PRESENT. Both runs are
  pasted in the PR body.

  `async: false` — it registers schemas into a shared dataset.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, DraftId, LabelSpine}

  @dataset "label_spine_precreate_test"

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

    %{scope: scope}
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp fresh_id, do: "task-precreate-#{System.unique_integer([:positive])}"

  defp base_content(extra) do
    %{"kind" => "task", "lifecycle_status" => "open"}
    |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
    |> Map.merge(extra)
  end

  defp create(id, content, scope) do
    Content.create_document(
      "task",
      %{"doc_id" => id, "title" => "Precreate fixture #{id}", "content" => content},
      @dataset,
      scope
    )
  end

  # The absence assertion, scoped to the fixture's OWN id — never a table-wide
  # count (the fleet shares one test database).
  defp assert_no_row!(id, scope) do
    assert {:error, :not_found} =
             Content.get_document(DraftId.draft_id(id), "task", @dataset, scope)

    # Belt-and-braces: the raw row, keyed on this id in this dataset only.
    refute Barkpark.Repo.get_by(Document,
             doc_id: DraftId.draft_id(id),
             type: "task",
             dataset: @dataset
           )
  end

  # ── C0 — the refusal happens BEFORE the write ─────────────────────────────

  describe "create refuses a malformed label spine before persisting" do
    test "MUTATION SENTINEL — flat string tags 422 label_spine and leave NO drafts.<id>",
         %{scope: scope} do
      id = fresh_id()

      # The EXACT shape the 2026-09-01 reproduction filed: flat legacy strings
      # where the spine wants {tag, strength, rationale} objects.
      assert {:error, {:label_spine, details}} =
               create(id, base_content(%{"tags" => ["barkpark", "tasks"]}), scope)

      assert details.field == "tags"
      assert details.rule =~ "must be a {tag, strength, rationale} object"
      assert details.index == 0

      assert_no_row!(id, scope)
    end

    test "tied strengths 422 and leave NO drafts.<id>", %{scope: scope} do
      id = fresh_id()

      tied = [
        %{"tag" => "alpha", "strength" => 50, "rationale" => String.duplicate("why alpha ", 4)},
        %{"tag" => "beta", "strength" => 50, "rationale" => String.duplicate("why beta ", 4)}
      ]

      assert {:error, {:label_spine, details}} =
               create(id, base_content(%{"tags" => tied}), scope)

      assert details.field == "strength"
      assert details.rule =~ "distinct strength"

      assert_no_row!(id, scope)
    end

    test "a scalar `tags` 422s rather than persisting", %{scope: scope} do
      id = fresh_id()

      assert {:error, {:label_spine, details}} =
               create(id, base_content(%{"tags" => "barkpark"}), scope)

      assert details.field == "tags"
      assert_no_row!(id, scope)
    end
  end

  # ── C0 — the POSITIVE CONTROL ─────────────────────────────────────────────

  describe "positive control: a well-formed create still lands as a draft" do
    test "a valid weighted spine lands as drafts.<id>, status draft", %{scope: scope} do
      id = fresh_id()

      assert {:ok, doc} = create(id, base_content(%{}), scope)
      assert doc.doc_id == DraftId.draft_id(id)
      assert doc.status == "draft"

      # Re-read by id — NOT a `^doc` pin: `create_document/4` returns the struct
      # it just inserted (associations unloaded, no preloads), so pinning the
      # whole struct compares Ecto bookkeeping rather than the row.
      assert {:ok, reread} = Content.get_document(DraftId.draft_id(id), "task", @dataset, scope)
      assert reread.id == doc.id
      assert reread.status == "draft"
      assert reread.content["tags"] == base_content(%{})["tags"]
    end

    test "DRAFTS STAY FREE — no tags and no description still lands", %{scope: scope} do
      id = fresh_id()

      # An unfinished draft is not a malformed one. The completeness rules
      # (description, minimum tag count) remain publish-time only — if this
      # ever reds, the pre-create gate has widened from `validate_shape/1` to
      # the full `validate/1` and every `bp task create` without tags is banned.
      assert {:ok, doc} =
               create(id, %{"kind" => "task", "lifecycle_status" => "open"}, scope)

      assert doc.status == "draft"
    end

    test "an empty tags array is unfinished, not malformed", %{scope: scope} do
      id = fresh_id()

      assert {:ok, _doc} =
               create(id, %{"kind" => "task", "lifecycle_status" => "open", "tags" => []}, scope)
    end

    test "a NON-task type with a malformed spine is untouched by this gate", %{scope: scope} do
      # The gate is scoped to type:task; `paper` births published through
      # `Papers.BlockOps.upsert_paper/2`, which already enforces the full wall
      # before its own Repo write.
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "lsp_post",
            "title" => "LSP Post",
            "visibility" => "public",
            "fields" => [%{"name" => "body", "type" => "string"}]
          },
          @dataset,
          scope
        )

      id = "lsp-post-#{System.unique_integer([:positive])}"

      assert {:ok, _doc} =
               Content.create_document(
                 "lsp_post",
                 %{"doc_id" => id, "title" => "Not a task", "content" => %{"tags" => ["flat"]}},
                 @dataset,
                 scope
               )
    end
  end

  # ── C2 — no regression on the publish wall ────────────────────────────────

  describe "a row created BEFORE this change is still refused at publish" do
    test "a directly-inserted malformed draft 422s label_spine at publish", %{scope: scope} do
      id = fresh_id()
      draft_id = DraftId.draft_id(id)

      # The pre-change population, materialised WITHOUT going through the new
      # gate: born well-formed through the normal path (so its tenancy stamp is
      # real — a hand-built row with a NULL dataset_id would be invisible to the
      # reads below and the refusal would be vacuous), then its tags rewritten
      # to the legacy flat shape by a direct UPDATE that no gate sees. The
      # resulting row is byte-identical to one a pre-PR `bp task create` filed.
      {:ok, _} = create(id, base_content(%{}), scope)

      legacy_content = %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "description" => "A legacy row filed before the pre-create gate existed, with flat tags.",
        "tags" => ["barkpark", "tasks"]
      }

      {1, _} =
        Barkpark.Repo.update_all(
          from(d in Document,
            where: d.doc_id == ^draft_id and d.type == "task" and d.dataset == ^@dataset
          ),
          set: [content: legacy_content]
        )

      # It is really there — otherwise the refusal below would be vacuous.
      assert {:ok, _} = Content.get_document(draft_id, "task", @dataset, scope)

      assert {:error, {:label_spine, details}} =
               Content.publish_document(draft_id, "task", @dataset, scope)

      assert details.field == "tags"
      assert details.rule =~ "must be a {tag, strength, rationale} object"

      # The draft SURVIVES a label_spine refusal — only `duplicate_of` discards.
      assert {:ok, _} = Content.get_document(draft_id, "task", @dataset, scope)
    end
  end

  # ── the unit half: validate_shape/1 is the judgeable subset of validate/1 ──

  describe "LabelSpine.validate_shape/1" do
    test "omits the completeness rules validate/1 enforces" do
      unfinished = %{"kind" => "task"}

      assert :ok = LabelSpine.validate_shape(unfinished)
      assert {:error, {:label_spine, _}} = LabelSpine.validate(unfinished)
    end

    test "still enforces every structural rule" do
      good = Barkpark.LabelFixtures.weighted_labels()
      assert :ok = LabelSpine.validate_shape(good)

      for bad <- [
            %{"tags" => ["flat"]},
            %{"tags" => "scalar"},
            %{
              "tags" => [
                %{
                  "tag" => "UPPER",
                  "strength" => 9,
                  "rationale" => "x" <> String.duplicate("y", 30)
                }
              ]
            },
            %{
              "tags" => [
                %{
                  "tag" => "ok",
                  "strength" => 900,
                  "rationale" => "x" <> String.duplicate("y", 30)
                }
              ]
            },
            %{"tags" => [%{"tag" => "ok", "strength" => 9, "rationale" => "short"}]}
          ] do
        result = LabelSpine.validate_shape(bad)

        assert match?({:error, {:label_spine, _}}, result),
               "expected validate_shape to refuse #{inspect(bad)}, got #{inspect(result)}"
      end
    end

    test "refuses more than 12 tags (a max is malformed at any stage)" do
      thirteen =
        for i <- 1..13 do
          %{"tag" => "t#{i}", "strength" => i, "rationale" => String.duplicate("reason ", 5)}
        end

      assert {:error, {:label_spine, %{field: "tags"}}} =
               LabelSpine.validate_shape(%{"tags" => thirteen})
    end
  end
end
