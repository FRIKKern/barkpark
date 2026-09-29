defmodule Barkpark.Content.DispositionOwnerGateTest do
  @moduledoc """
  The mutate door's fence on `content.disposition_owner` — the api half of
  pds-bl-disposition-owner-role-registry.

  Before this fence the key had no schema declaration, no validator and no code
  writer anywhere in `api/lib` or `internal/`, so a ledger census could only
  ever assert "non-empty and slug-shaped" and green on sixteen strings nobody
  had defined. PR #17836 defines them in
  `tooling/pds/disposition-owner-registry.json` and rules the expiring `wave-N`
  shape refused outright; this file proves the api door enforces that ruling.

  ## The fence is on the WRITE, not on the ROW

  The registry counted 8 live `wave-N` violations and ~22 distinct owners
  board-wide. A row-scoped rule would be RETROACTIVE — unrelated bookkeeping on
  every one of those rows would start failing. So `now == was` is not a change,
  and the `c2` cases below prove a row carrying a refused owner still reads and
  still patches every other field.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Tasks.Stage

  @token "barkpark-test-disposition-owner-token"
  @dataset "production"
  @owner_key "disposition_owner"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-disposition-owner", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Seeded through `Content.create_document/4`, the same door the dataset
  # importer and the ledger's own history used — this is how the live rows
  # carrying refused owners got there, and the c2 cases need exactly that row.
  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content = Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp set_patch(doc_id, set), do: %{"patch" => %{"id" => doc_id, "type" => "task", "set" => set}}

  defp mutate(ops, scope, extra \\ []) do
    Content.apply_mutations(ops, @dataset, Keyword.merge([source: :api] ++ scope, extra))
  end

  defp content_of(doc_id, scope) do
    {:ok, doc} = Content.get_document("drafts." <> doc_id, "task", @dataset, scope)
    doc.content
  end

  describe "c2 — an owner that is not a registered durable role is REFUSED" do
    test "a well-shaped garbage slug is refused, and the 422 names the registry",
         %{scope: scope} do
      id = uniq("owner-garbage")
      mk_task!(id, scope)

      assert {:error, {:invalid_task_content, %{@owner_key => [message]}}} =
               mutate([set_patch(id, %{@owner_key => "definitely-not-a-role"})], scope)

      # The refusal TEACHES where the vocabulary lives, the way its close,
      # claim and disposition siblings name the sanctioned verb.
      assert message =~ "tooling/pds/disposition-owner-registry.json"
      assert message =~ "durable-role"

      # And it wrote NOTHING — the batch is one transaction.
      refute Map.has_key?(content_of(id, scope), @owner_key)
    end

    test "the expiring wave-N shape is refused, naming the ruling's reason", %{scope: scope} do
      id = uniq("owner-wave")
      mk_task!(id, scope)

      assert {:error, {:invalid_task_content, %{@owner_key => [message]}}} =
               mutate([set_patch(id, %{@owner_key => "wave-31"})], scope)

      assert message =~ "wave-N"
      assert message =~ "self-clears"
      refute Map.has_key?(content_of(id, scope), @owner_key)
    end

    test "a ledger task id in the owner slot is refused as a task id", %{scope: scope} do
      id = uniq("owner-taskid")
      mk_task!(id, scope)

      assert {:error, {:invalid_task_content, %{@owner_key => [message]}}} =
               mutate([set_patch(id, %{@owner_key => "task-8ae44aede5a78260"})], scope)

      assert message =~ "TASK ID"
    end

    test "the fence runs on the createOrReplace and replace doors too", %{scope: scope} do
      # A patch-only fence leaves createOrReplace open, and createOrReplace is
      # the fleet's file-order shape (D53's lesson, re-derived).
      id = uniq("owner-doors")
      doc = mk_task!(id, scope)

      replace = %{
        "replace" => %{
          "_id" => id,
          "_type" => "task",
          "title" => id,
          "content" => Map.put(doc.content, @owner_key, "not-a-role-either")
        }
      }

      assert {:error, {:invalid_task_content, %{@owner_key => _}}} = mutate([replace], scope)

      cor = %{
        "createOrReplace" => %{
          "_id" => id,
          "_type" => "task",
          "title" => id,
          "content" => Map.put(doc.content, @owner_key, "not-a-role-either")
        }
      }

      assert {:error, {:invalid_task_content, %{@owner_key => _}}} = mutate([cor], scope)
    end

    test "a BIRTH through createOrReplace cannot mint an unregistered owner", %{scope: scope} do
      # This guard deliberately does NOT head on `("task", nil, …), do: :ok`:
      # it judges the value being written, a question a birth can answer.
      id = uniq("owner-birth")

      cor = %{
        "createOrReplace" => %{
          "_id" => id,
          "_type" => "task",
          "title" => id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            @owner_key => "wave-99"
          }
        }
      }

      assert {:error, {:invalid_task_content, %{@owner_key => _}}} = mutate([cor], scope)
    end
  end

  describe "c2 — the fence is on the WRITE, not on the row" do
    test "a row carrying a REFUSED owner still reads", %{scope: scope} do
      id = uniq("owner-legacy-read")
      mk_task!(id, scope, %{@owner_key => "wave-24"})

      assert content_of(id, scope)[@owner_key] == "wave-24"
    end

    test "a patch to ANOTHER field on a row carrying a refused owner SUCCEEDS", %{scope: scope} do
      id = uniq("owner-legacy-patch")
      mk_task!(id, scope, %{@owner_key => "wave-24", "priority" => 3})

      assert {:ok, _} = mutate([set_patch(id, %{"priority" => 1})], scope)

      content = content_of(id, scope)
      assert content["priority"] == 1
      # The refused owner is untouched — remediation is a separate, deliberate
      # act, not a side effect of unrelated bookkeeping.
      assert content[@owner_key] == "wave-24"
    end

    test "re-writing the SAME refused owner is not a change, so it passes", %{scope: scope} do
      id = uniq("owner-legacy-idem")
      mk_task!(id, scope, %{@owner_key => "pds-w25-round-terminal"})

      assert {:ok, _} =
               mutate([set_patch(id, %{@owner_key => "pds-w25-round-terminal"})], scope)
    end

    test "CLEARING a refused owner is always allowed — it is the remediation", %{scope: scope} do
      id = uniq("owner-clear")
      mk_task!(id, scope, %{@owner_key => "wave-24"})

      unset = %{"patch" => %{"id" => id, "type" => "task", "unset" => [@owner_key]}}
      assert {:ok, _} = mutate([unset], scope)
      refute Map.has_key?(content_of(id, scope), @owner_key)
    end

    test "replication is exempt — a mirror applies verbatim or wedges the batch", %{scope: scope} do
      id = uniq("owner-sync")
      mk_task!(id, scope)

      assert {:ok, _} =
               mutate([set_patch(id, %{@owner_key => "wave-24"})], scope, source: :sync)

      assert content_of(id, scope)[@owner_key] == "wave-24"
    end
  end

  describe "the accept arm" do
    test "a registered durable role is accepted — or, in a fail-closed build, is not",
         %{scope: scope} do
      id = uniq("owner-accept")
      mk_task!(id, scope)

      if Stage.owner_registry_loaded?() do
        role = List.first(Stage.durable_owner_roles())
        assert is_binary(role)

        assert {:ok, _} = mutate([set_patch(id, %{@owner_key => role})], scope)
        assert content_of(id, scope)[@owner_key] == role
      else
        # The registry has not merged (#17836). The door FAILS CLOSED: even a
        # slug that is a role in the registry is refused by a build that never
        # read it, and the message says so instead of blaming the slug.
        assert {:error, {:invalid_task_content, %{@owner_key => [message]}}} =
                 mutate([set_patch(id, %{@owner_key => "pds-harness-maintainer"})], scope)

        assert message =~ "ABSENT"
        assert message =~ "#17836"
      end
    end
  end
end
