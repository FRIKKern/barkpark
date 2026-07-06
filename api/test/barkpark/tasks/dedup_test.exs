defmodule Barkpark.Tasks.DedupTest do
  @moduledoc """
  DB-backed tests for the find-or-create gate (task-obsession layer 1), driven
  through the real `Content.create_document/4` write path so the Writer hook,
  the candidate query, and the escape hatches are all exercised end-to-end.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}

  @dataset "production"

  setup do
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

  defp create_task(doc_id, title, scope, content_extra) do
    content =
      Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content_extra)

    Content.create_document(
      "task",
      %{"doc_id" => doc_id, "title" => title, "content" => content},
      @dataset,
      scope
    )
  end

  @rate_limit "add rate limiting to the mutate controller"
  @rate_limit_desc "throttle writes on the REST mutate endpoint per token bucket"

  test "a near-duplicate cross-epic task is REFUSED with the similar list", %{scope: scope} do
    {:ok, _} =
      create_task("existing-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a"
      })

    assert {:error, {:duplicate_task, payload}} =
             create_task("new-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b"
             })

    assert [%{id: "existing-rl"} | _] = payload.similar
  end

  test "a same-parent sibling is ALLOWED even when lexically near-identical", %{scope: scope} do
    {:ok, _} =
      create_task("sib-1", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "shared-epic"
      })

    # Same parent → structural sibling → never a duplicate.
    assert {:ok, _} =
             create_task("sib-2", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "shared-epic"
             })
  end

  test "distinct_from naming the match ALLOWS the create and persists the trail", %{scope: scope} do
    {:ok, _} =
      create_task("orig-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a"
      })

    assert {:ok, doc} =
             create_task("clone-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b",
               "distinct_from" => ["orig-rl"]
             })

    # The escape hatch is persisted on the doc as the queryable rejection trail.
    assert doc.content["distinct_from"] == ["orig-rl"]
  end

  test "a genuinely distinct task is ALLOWED", %{scope: scope} do
    {:ok, _} =
      create_task("rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a"
      })

    assert {:ok, _} =
             create_task("reader", "render markdown headings in the article reader", scope, %{
               "description" => "heading rhythm and vertical spacing in the paper reader",
               "parent_id" => "epic-b"
             })
  end

  test "a CANCELLED task never blocks a legitimate re-attempt (criterion 4)", %{scope: scope} do
    {:ok, _} =
      create_task("abandoned-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a",
        "lifecycle_status" => "cancelled"
      })

    # We decided not to do it → re-proposing the same work must be allowed.
    assert {:ok, _} =
             create_task("retry-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b"
             })
  end

  test "a DONE task DOES still surface (already-landed signal)", %{scope: scope} do
    {:ok, _} =
      create_task("shipped-rl", @rate_limit, scope, %{
        "description" => @rate_limit_desc,
        "parent_id" => "epic-a",
        "lifecycle_status" => "done"
      })

    assert {:error, {:duplicate_task, payload}} =
             create_task("redo-rl", @rate_limit, scope, %{
               "description" => @rate_limit_desc,
               "parent_id" => "epic-b"
             })

    assert Enum.any?(payload.similar, &(&1.lifecycle_status == "done"))
  end

  # ── tier-2 judge escalation ────────────────────────────────────────────────

  defmodule FakeJudge do
    def post(_url, _body, _headers) do
      case Application.get_env(:barkpark, :judge_fake) do
        {:ok, text} -> {:ok, 200, %{"content" => [%{"type" => "text", "text" => text}]}}
        {:error, r} -> {:error, r}
        other -> other
      end
    end
  end

  # A cross-epic pair with partial token overlap → lands in the ADVISE band
  # (sim ~0.42, below the 0.55 refuse floor), which is exactly where the judge
  # is consulted.
  @adv_title_a "alpha beta gamma delta"
  @adv_title_b "alpha beta gamma zeta"

  defp with_judge(fake) do
    Application.put_env(:barkpark, :judge_http_adapter, FakeJudge)
    Application.put_env(:barkpark, :anthropic_api_key, "sk-test")
    Application.put_env(:barkpark, :judge_fake, fake)

    on_exit(fn ->
      Application.delete_env(:barkpark, :judge_http_adapter)
      Application.delete_env(:barkpark, :anthropic_api_key)
      Application.delete_env(:barkpark, :judge_fake)
    end)
  end

  describe "tier-2 judge escalation" do
    test "a judged 'duplicate' escalates an advise-band match to a REFUSE", %{scope: scope} do
      with_judge({:ok, ~s({"relation":"duplicate","confidence":0.9,"reason":"same"})})
      {:ok, _} = create_task("adv-a", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:error, {:duplicate_task, payload}} =
               create_task("adv-b", @adv_title_b, scope, %{"parent_id" => "epic-b"})

      assert Enum.any?(payload.similar, &(&1.id == "adv-a"))
    end

    test "a judged 'distinct' leaves the advise match non-blocking (create allowed)", %{
      scope: scope
    } do
      with_judge({:ok, ~s({"relation":"distinct","confidence":0.9,"reason":"different"})})
      {:ok, _} = create_task("adv-a2", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} = create_task("adv-b2", @adv_title_b, scope, %{"parent_id" => "epic-b"})
    end

    test "a judge error fails open — the advise match does not block", %{scope: scope} do
      with_judge({:error, :timeout})
      {:ok, _} = create_task("adv-a3", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} = create_task("adv-b3", @adv_title_b, scope, %{"parent_id" => "epic-b"})
    end

    test "low judge confidence does not escalate", %{scope: scope} do
      with_judge({:ok, ~s({"relation":"duplicate","confidence":0.4,"reason":"maybe"})})
      {:ok, _} = create_task("adv-a4", @adv_title_a, scope, %{"parent_id" => "epic-a"})

      assert {:ok, _} = create_task("adv-b4", @adv_title_b, scope, %{"parent_id" => "epic-b"})
    end
  end
end
