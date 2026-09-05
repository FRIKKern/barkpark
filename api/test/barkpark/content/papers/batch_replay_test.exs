defmodule Barkpark.Content.Papers.BatchReplayTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Broadcast
  alias Barkpark.Repo
  alias Barkpark.Repo.IdempotencyStore
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "production"

  test "a retried structural batch replays its receipt without another write or broadcast" do
    {slug, paper} = seed_paper!()
    request_id = Ecto.UUID.generate()
    if_rev = paper_rev(paper)

    Phoenix.PubSub.subscribe(
      Barkpark.PubSub,
      Broadcast.paper_topic(slug, paper.workspace_id, @dataset)
    )

    ops = [
      %{
        "op" => "insert-after",
        "afterId" => "anchor",
        "block" => %{"id" => "inserted", "type" => "paragraph", "text" => "Once"}
      }
    ]

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               ops,
               @dataset,
               request_id,
               "viewer:stable-session",
               if_rev: if_rev
             )

    assert_receive {:paper_block, %{op_kind: :batch, rev: applied_rev}}
    assert applied_rev == receipt.rev
    assert receipt.rev == if_rev + 1

    assert {:ok, ^receipt, :replayed} =
             Content.apply_paper_block_ops_once(
               slug,
               ops,
               @dataset,
               request_id,
               "viewer:stable-session",
               if_rev: if_rev
             )

    refute_receive {:paper_block, _}, 50

    stored = Content.get_paper(slug)
    assert stored.content["rev"] == receipt.rev
    assert Enum.count(stored.content["blocks"], &(&1["id"] == "inserted")) == 1

    assert [%IdempotencyStore.Key{state: "completed", response_body: body}] =
             Repo.all(from(k in IdempotencyStore.Key, where: like(k.scope, "paper_ops:v1:%")))

    assert {:ok, %{"slug" => ^slug, "rev" => ^applied_rev}} = Jason.decode(body)
  end

  test "reusing a request id for different ops is refused and leaves the paper unchanged" do
    {slug, _paper} = seed_paper!()
    request_id = Ecto.UUID.generate()

    first = patch_text("First")
    second = patch_text("Different payload")
    initial_rev = paper_rev(Content.get_paper(slug))

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [first],
               @dataset,
               request_id,
               "user:one",
               if_rev: initial_rev
             )

    assert {:error, :idempotency_payload_mismatch} =
             Content.apply_paper_block_ops_once(
               slug,
               [second],
               @dataset,
               request_id,
               "user:one",
               if_rev: initial_rev
             )

    assert {:error, :idempotency_payload_mismatch} =
             Content.apply_paper_block_ops_once(
               slug,
               [first],
               @dataset,
               request_id,
               "user:one",
               if_rev: initial_rev + 1
             )

    stored = Content.get_paper(slug)
    assert stored.content["rev"] == receipt.rev
    assert block_text(stored, "anchor") == "First"
  end

  test "a nested expandable run applies once and replays after the run changed" do
    {slug, paper} = seed_nested_paper!()
    request_id = Ecto.UUID.generate()
    if_rev = paper_rev(paper)
    context = %{container_id: "details", container_run_ids: ["nested-a", "nested-b"]}

    ops = [
      %{"op" => "patch-block", "id" => "nested-a", "patch" => %{"text" => "Changed"}},
      %{
        "op" => "append-block",
        "block" => %{"id" => "nested-new", "type" => "paragraph", "text" => "New"}
      }
    ]

    assert {:ok, receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               ops,
               @dataset,
               request_id,
               "user:nested-run",
               if_rev: if_rev,
               canvas_run_context: context
             )

    assert Enum.map(expandable_children(Content.get_paper(slug)), & &1["id"]) ==
             ["nested-a", "nested-b", "nested-new"]

    assert {:ok, ^receipt, :replayed} =
             Content.apply_paper_block_ops_once(
               slug,
               ops,
               @dataset,
               request_id,
               "user:nested-run",
               if_rev: if_rev,
               canvas_run_context: context
             )

    assert Enum.count(expandable_children(Content.get_paper(slug)), &(&1["id"] == "nested-new")) ==
             1
  end

  test "nested run context is fingerprinted and cannot target or mint ids outside its boundary" do
    {slug, paper} = seed_nested_paper!()
    if_rev = paper_rev(paper)
    context = %{container_id: "details", container_run_ids: ["nested-a", "nested-b"]}
    request_id = Ecto.UUID.generate()

    assert {:error, {:block_not_found, "outside", "patch-block"}} =
             Content.apply_paper_block_ops_once(
               slug,
               [%{"op" => "patch-block", "id" => "outside", "patch" => %{"text" => "Escape"}}],
               @dataset,
               request_id,
               "user:nested-escape",
               if_rev: if_rev,
               canvas_run_context: context
             )

    assert {:error, :canvas_run_id_collision} =
             Content.apply_paper_block_ops_once(
               slug,
               [
                 %{
                   "op" => "append-block",
                   "block" => %{"id" => "outside", "type" => "paragraph", "text" => "Collision"}
                 }
               ],
               @dataset,
               Ecto.UUID.generate(),
               "user:nested-collision",
               if_rev: if_rev,
               canvas_run_context: context
             )

    patch = %{"op" => "patch-block", "id" => "nested-a", "patch" => %{"text" => "Applied"}}

    assert {:ok, _receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch],
               @dataset,
               request_id,
               "user:nested-escape",
               if_rev: if_rev,
               canvas_run_context: context
             )

    assert {:error, :idempotency_payload_mismatch} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch],
               @dataset,
               request_id,
               "user:nested-escape",
               if_rev: if_rev,
               canvas_run_context: %{context | container_run_ids: ["nested-a"]}
             )
  end

  test "nested run context requires an integer revision fence" do
    {slug, _paper} = seed_nested_paper!()
    context = %{container_id: "details", container_run_ids: ["nested-a", "nested-b"]}

    assert {:error, :invalid_canvas_run_context} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch_text("No fence")],
               @dataset,
               Ecto.UUID.generate(),
               "user:nested-no-fence",
               canvas_run_context: context
             )
  end

  test "a receipt-completion failure rolls back the document write and its claim" do
    {slug, _paper} = seed_paper!()
    request_id = Ecto.UUID.generate()
    before = Content.get_paper(slug)

    Phoenix.PubSub.subscribe(
      Barkpark.PubSub,
      Broadcast.paper_topic(slug, before.workspace_id, @dataset)
    )

    assert {:error, :idempotency_completion_failed} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch_text("Recovered")],
               @dataset,
               request_id,
               "user:rollback",
               before_idempotency_complete: fn ->
                 Repo.delete_all(
                   from(k in IdempotencyStore.Key, where: like(k.scope, "paper_ops:v1:%"))
                 )
               end
             )

    refute_receive {:paper_block, _}, 50

    unchanged = Content.get_paper(slug)
    assert unchanged.content["rev"] == before.content["rev"]
    assert block_text(unchanged, "anchor") == "Seed"

    assert Repo.aggregate(
             from(k in IdempotencyStore.Key, where: like(k.scope, "paper_ops:v1:%")),
             :count
           ) == 0

    assert {:ok, _receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch_text("Recovered")],
               @dataset,
               request_id,
               "user:rollback"
             )

    assert block_text(Content.get_paper(slug), "anchor") == "Recovered"
  end

  test "an outer transaction is rejected before mutation so rollback cannot emit phantom effects" do
    {slug, paper} = seed_paper!()
    request_id = Ecto.UUID.generate()

    Phoenix.PubSub.subscribe(
      Barkpark.PubSub,
      Broadcast.paper_topic(slug, paper.workspace_id, @dataset)
    )

    assert {:error, {:forced_rollback, {:error, :paper_ops_nested_transaction_unsupported}}} =
             Repo.transaction(fn ->
               result =
                 Content.apply_paper_block_ops_once(
                   slug,
                   [patch_text("Must not land")],
                   @dataset,
                   request_id,
                   "user:nested"
                 )

               Repo.rollback({:forced_rollback, result})
             end)

    refute_receive {:paper_block, _}, 50

    stored = Content.get_paper(slug)
    assert stored.content["rev"] == paper.content["rev"]
    assert block_text(stored, "anchor") == "Seed"

    assert Repo.aggregate(
             from(k in IdempotencyStore.Key, where: like(k.scope, "paper_ops:v1:%")),
             :count
           ) == 0
  end

  test "post-claim reload refuses a paper that moved outside the original tenant" do
    ws = TenancyFixtures.create_workspace!()
    project = TenancyFixtures.create_project!(ws)
    other_ws = TenancyFixtures.create_workspace!()
    other_project = TenancyFixtures.create_project!(other_ws)
    {slug, paper} = seed_paper!(nil, workspace_id: ws.id, project_id: project.id)

    assert {:error, :not_found} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch_text("Must not cross tenant")],
               @dataset,
               Ecto.UUID.generate(),
               "user:tenant-reload",
               workspace_id: ws.id,
               project_id: project.id,
               if_rev: paper_rev(paper),
               after_idempotency_claim: fn ->
                 paper
                 |> Ecto.Changeset.change(
                   workspace_id: other_ws.id,
                   project_id: other_project.id
                 )
                 |> Repo.update!()
               end
             )

    stored = Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: project.id)
    assert stored.id == paper.id
    assert stored.content["rev"] == paper.content["rev"]
    assert block_text(stored, "anchor") == "Seed"

    assert Repo.aggregate(
             from(k in IdempotencyStore.Key, where: like(k.scope, "paper_ops:v1:%")),
             :count
           ) == 0
  end

  test "concurrent callers sharing one request identity produce one write and one replay" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      ws = TenancyFixtures.create_workspace!()
      project = TenancyFixtures.create_project!(ws)
      request_id = Ecto.UUID.generate()
      principal = "user:concurrent-#{request_id}"
      ops = [patch_text("Concurrent #{request_id}")]
      {slug, paper} = seed_paper!(nil, workspace_id: ws.id, project_id: project.id)
      initial_rev = paper_rev(paper)
      parent = self()

      opts = [
        workspace_id: ws.id,
        project_id: project.id,
        if_rev: initial_rev,
        after_idempotency_claim: fn ->
          send(parent, {:claimed, self()})

          receive do
            :continue -> :ok
          after
            5_000 -> raise "concurrent replay test never released the winning claim"
          end
        end
      ]

      key_hash = paper_ops_key_hash_for_test(paper, request_id, principal)

      try do
        call = fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :go ->
                Content.apply_paper_block_ops_once(
                  slug,
                  ops,
                  @dataset,
                  request_id,
                  principal,
                  opts
                )
            end
          end)
        end

        first = Task.async(call)
        second = Task.async(call)
        Process.put(:paper_replay_contention_tasks, [first, second])

        assert_receive {:ready, first_pid}
        assert_receive {:ready, second_pid}
        send(first_pid, :go)
        send(second_pid, :go)

        assert_receive {:claimed, claimed_pid}, 5_000
        refute_receive {:claimed, _other_pid}, 100
        send(claimed_pid, :continue)

        results = [Task.await(first, 15_000), Task.await(second, 15_000)]

        assert [{:ok, first_receipt, :applied}, {:ok, second_receipt, :replayed}] =
                 Enum.sort_by(results, fn {:ok, _receipt, disposition} ->
                   if disposition == :applied, do: 0, else: 1
                 end)

        assert first_receipt == second_receipt

        stored =
          Content.get_paper(slug, @dataset,
            workspace_id: ws.id,
            project_id: project.id
          )

        assert paper_rev(stored) == initial_rev + 1
      after
        :paper_replay_contention_tasks
        |> Process.delete()
        |> List.wrap()
        |> Enum.each(fn task ->
          if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
        end)

        Repo.delete_all(from(k in IdempotencyStore.Key, where: k.key_hash == ^key_hash))
        assert {:ok, _workspace} = Tenancy.delete_workspace(ws)
      end
    end)
  end

  test "request identity is isolated by principal and physical tenant-scoped paper" do
    request_id = Ecto.UUID.generate()
    {slug, first} = seed_paper!()
    first_opts = [workspace_id: first.workspace_id, project_id: first.project_id]
    op = patch_text("Shared payload")

    assert {:ok, first_receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [op],
               @dataset,
               request_id,
               "user:a",
               first_opts
             )

    assert {:ok, second_principal_receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [op],
               @dataset,
               request_id,
               "user:b",
               first_opts
             )

    assert second_principal_receipt.rev == first_receipt.rev + 1

    ws = TenancyFixtures.create_workspace!()
    project = TenancyFixtures.create_project!(ws)
    {_same_slug, other} = seed_paper!(slug, workspace_id: ws.id, project_id: project.id)

    assert {:ok, other_receipt, :applied} =
             Content.apply_paper_block_ops_once(
               slug,
               [op],
               @dataset,
               request_id,
               "user:a",
               workspace_id: ws.id,
               project_id: project.id
             )

    assert other_receipt.rev == paper_rev(other) + 1
    assert block_text(Content.get_paper(slug, @dataset, first_opts), "anchor") == "Shared payload"

    assert block_text(
             Content.get_paper(slug, @dataset,
               workspace_id: ws.id,
               project_id: project.id
             ),
             "anchor"
           ) == "Shared payload"
  end

  test "request ids and principals fail closed, and exact pending claims are never reclaimed" do
    {slug, _paper} = seed_paper!()

    assert {:error, :invalid_request_id} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch_text("x")],
               @dataset,
               "not-a-uuid",
               "user:a"
             )

    assert {:error, :missing_principal} =
             Content.apply_paper_block_ops_once(
               slug,
               [patch_text("x")],
               @dataset,
               Ecto.UUID.generate(),
               "  "
             )

    old = DateTime.add(DateTime.utc_now(), -3_600, :second)

    Repo.insert!(%IdempotencyStore.Key{
      key_hash: String.duplicate("a", 64),
      scope: "paper_ops:v1:fingerprint",
      state: "pending",
      inserted_at: old
    })

    assert {:ok, :in_progress} =
             Repo.transaction(fn ->
               IdempotencyStore.claim_exact(
                 String.duplicate("a", 64),
                 "paper_ops:v1:fingerprint"
               )
             end)
  end

  defp seed_paper!(slug \\ nil, scope_attrs \\ []) do
    slug = slug || "paper-replay-#{System.unique_integer([:positive])}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        slug: slug,
        blocks: [%{"id" => "anchor", "type" => "paragraph", "text" => "Seed"}]
      })
      |> Map.merge(Map.new(scope_attrs))

    {:ok, paper} = Content.upsert_paper(attrs)
    {slug, paper}
  end

  defp seed_nested_paper! do
    slug = "paper-nested-replay-#{System.unique_integer([:positive])}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        slug: slug,
        blocks: [
          %{
            "id" => "details",
            "type" => "expandable",
            "summary" => "Details",
            "children" => [
              %{"id" => "nested-a", "type" => "paragraph", "text" => "A"},
              %{"id" => "nested-b", "type" => "paragraph", "text" => "B"}
            ],
            "blocks" => [%{"id" => "hidden", "type" => "paragraph", "text" => "Hidden"}]
          },
          %{"id" => "outside", "type" => "paragraph", "text" => "Outside"}
        ]
      })

    {:ok, paper} = Content.upsert_paper(attrs)
    {slug, paper}
  end

  defp expandable_children(paper) do
    paper.content["blocks"]
    |> Enum.find(&(&1["id"] == "details"))
    |> Map.fetch!("children")
  end

  defp patch_text(text),
    do: %{"op" => "patch-block", "id" => "anchor", "patch" => %{"text" => text}}

  defp block_text(paper, id) do
    paper.content["blocks"]
    |> Enum.find(&(&1["id"] == id))
    |> Map.fetch!("text")
  end

  defp paper_rev(paper), do: paper.content["rev"] || 0

  defp paper_ops_key_hash_for_test(paper, request_id, principal) do
    {
      "paper_ops:v1",
      paper.id,
      paper.workspace_id,
      paper.project_id,
      paper.dataset_id,
      paper.dataset,
      principal,
      request_id
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
