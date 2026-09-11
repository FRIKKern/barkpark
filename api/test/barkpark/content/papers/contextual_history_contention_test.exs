defmodule Barkpark.Content.Papers.ContextualHistoryContentionTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Repo.IdempotencyStore
  alias Barkpark.Tenancy
  alias Barkpark.TenancyFixtures

  @dataset "production"

  test "concurrent requests can consume one contextual history reference only once" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      workspace = TenancyFixtures.create_workspace!()
      project = TenancyFixtures.create_project!(workspace)
      principal = "user:history-consumer-#{Ecto.UUID.generate()}"
      {slug, paper} = seed_paper!(workspace.id, project.id)
      history_ref = Ecto.UUID.generate()
      first_request_id = Ecto.UUID.generate()
      second_request_id = Ecto.UUID.generate()

      owned_hashes = [
        paper_ops_key_hash(paper, history_ref, principal),
        paper_ops_key_hash(paper, first_request_id, principal),
        paper_ops_key_hash(paper, second_request_id, principal),
        history_consumption_hash(paper, history_ref, principal)
      ]

      try do
        assert {:ok, forward_receipt, :applied} =
                 Content.apply_paper_block_ops_once(
                   slug,
                   [patch_image_src("/after.png")],
                   @dataset,
                   history_ref,
                   principal,
                   workspace_id: workspace.id,
                   project_id: project.id,
                   if_rev: paper_rev(paper),
                   contextual_history: true
                 )

        parent = self()

        call = fn request_id ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :go ->
                Content.apply_paper_contextual_history_once(
                  slug,
                  history_ref,
                  "undo",
                  @dataset,
                  request_id,
                  principal,
                  workspace_id: workspace.id,
                  project_id: project.id,
                  if_rev: forward_receipt.rev,
                  after_idempotency_claim: fn ->
                    send(parent, {:claimed, self()})

                    receive do
                      :continue -> :ok
                    after
                      5_000 -> raise "contextual history consumers were not released"
                    end
                  end
                )
            end
          end)
        end

        first = Task.async(fn -> call.(first_request_id) end)
        second = Task.async(fn -> call.(second_request_id) end)
        Process.put(:contextual_history_contention_tasks, [first, second])

        assert_receive {:ready, first_pid}
        assert_receive {:ready, second_pid}
        send(first_pid, :go)
        send(second_pid, :go)

        assert_receive {:claimed, first_claimed_pid}, 5_000
        assert_receive {:claimed, second_claimed_pid}, 5_000
        send(first_claimed_pid, :continue)
        send(second_claimed_pid, :continue)

        results = [Task.await(first, 15_000), Task.await(second, 15_000)]

        assert Enum.count(results, &match?({:ok, _receipt, :applied}, &1)) == 1
        assert Enum.count(results, &(&1 == {:error, :history_ref_consumed})) == 1

        stored = scoped_paper(slug, workspace.id, project.id)
        assert paper_rev(stored) == forward_receipt.rev + 1
        assert image(stored)["src"] == "/before.png"
      after
        shutdown_owned_tasks()
        delete_idempotency_keys(owned_hashes)
        assert {:ok, _workspace} = Tenancy.delete_workspace(workspace)
      end
    end)
  end

  test "concurrent retries of one contextual history request replay one receipt after one write" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      workspace = TenancyFixtures.create_workspace!()
      project = TenancyFixtures.create_project!(workspace)
      principal = "user:history-replay-#{Ecto.UUID.generate()}"
      {slug, paper} = seed_paper!(workspace.id, project.id)
      history_ref = Ecto.UUID.generate()
      request_id = Ecto.UUID.generate()

      owned_hashes = [
        paper_ops_key_hash(paper, history_ref, principal),
        paper_ops_key_hash(paper, request_id, principal),
        history_consumption_hash(paper, history_ref, principal)
      ]

      try do
        assert {:ok, forward_receipt, :applied} =
                 Content.apply_paper_block_ops_once(
                   slug,
                   [patch_image_src("/after.png")],
                   @dataset,
                   history_ref,
                   principal,
                   workspace_id: workspace.id,
                   project_id: project.id,
                   if_rev: paper_rev(paper),
                   contextual_history: true
                 )

        parent = self()

        opts = [
          workspace_id: workspace.id,
          project_id: project.id,
          if_rev: forward_receipt.rev,
          after_idempotency_claim: fn ->
            send(parent, {:claimed, self()})

            receive do
              :continue -> :ok
            after
              5_000 -> raise "contextual history replay winner was not released"
            end
          end
        ]

        call = fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :go ->
                Content.apply_paper_contextual_history_once(
                  slug,
                  history_ref,
                  "undo",
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
        Process.put(:contextual_history_contention_tasks, [first, second])

        assert_receive {:ready, first_pid}
        assert_receive {:ready, second_pid}
        send(first_pid, :go)
        send(second_pid, :go)

        assert_receive {:claimed, claimed_pid}, 5_000
        refute_receive {:claimed, _other_pid}, 100
        send(claimed_pid, :continue)

        results = [Task.await(first, 15_000), Task.await(second, 15_000)]

        assert [{:ok, applied_receipt, :applied}, {:ok, replayed_receipt, :replayed}] =
                 Enum.sort_by(results, fn {:ok, _receipt, disposition} ->
                   if disposition == :applied, do: 0, else: 1
                 end)

        assert applied_receipt == replayed_receipt

        stored = scoped_paper(slug, workspace.id, project.id)
        assert paper_rev(stored) == forward_receipt.rev + 1
        assert image(stored)["src"] == "/before.png"
      after
        shutdown_owned_tasks()
        delete_idempotency_keys(owned_hashes)
        assert {:ok, _workspace} = Tenancy.delete_workspace(workspace)
      end
    end)
  end

  test "contextual history holds the physical paper row lock through persistence" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      workspace = TenancyFixtures.create_workspace!()
      project = TenancyFixtures.create_project!(workspace)
      principal = "user:history-row-lock-#{Ecto.UUID.generate()}"
      {slug, paper} = seed_paper!(workspace.id, project.id)
      history_ref = Ecto.UUID.generate()
      request_id = Ecto.UUID.generate()

      owned_hashes = [
        paper_ops_key_hash(paper, history_ref, principal),
        paper_ops_key_hash(paper, request_id, principal),
        history_consumption_hash(paper, history_ref, principal)
      ]

      try do
        assert {:ok, forward_receipt, :applied} =
                 Content.apply_paper_block_ops_once(
                   slug,
                   [patch_image_src("/after.png")],
                   @dataset,
                   history_ref,
                   principal,
                   workspace_id: workspace.id,
                   project_id: project.id,
                   if_rev: paper_rev(paper),
                   contextual_history: true
                 )

        parent = self()

        lock_probe = fn ->
          result =
            Task.async(fn ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                try do
                  Repo.transaction(fn ->
                    Repo.query!(
                      "SELECT id FROM documents WHERE id = $1 FOR UPDATE NOWAIT",
                      [Ecto.UUID.dump!(paper.id)]
                    )
                  end)
                rescue
                  error in Postgrex.Error -> {:error, error}
                end
              end)
            end)
            |> Task.await(5_000)

          send(parent, {:history_row_lock_probe, result})
        end

        assert {:ok, receipt, :applied} =
                 Content.apply_paper_contextual_history_once(
                   slug,
                   history_ref,
                   "undo",
                   @dataset,
                   request_id,
                   principal,
                   workspace_id: workspace.id,
                   project_id: project.id,
                   if_rev: forward_receipt.rev,
                   before_fenced_write: lock_probe
                 )

        assert_receive {:history_row_lock_probe, {:error, error}}, 5_000
        assert error.postgres.code == :lock_not_available
        assert error.postgres.pg_code == "55P03"

        stored = scoped_paper(slug, workspace.id, project.id)
        assert paper_rev(stored) == receipt.rev
        assert image(stored)["src"] == "/before.png"
      after
        delete_idempotency_keys(owned_hashes)
        assert {:ok, _workspace} = Tenancy.delete_workspace(workspace)
      end
    end)
  end

  defp seed_paper!(workspace_id, project_id) do
    slug = "history-contention-#{System.unique_integer([:positive])}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        slug: slug,
        blocks: [
          %{"id" => "intro", "type" => "paragraph", "text" => "Keep this paragraph."},
          %{
            "id" => "figure",
            "type" => "figure",
            "child" => %{
              "id" => "image",
              "type" => "image",
              "src" => "/before.png",
              "alt" => "Authored description",
              "title" => "Authored title",
              "metadata" => %{"credit" => "Fixture photographer"}
            }
          }
        ]
      })
      |> Map.merge(%{workspace_id: workspace_id, project_id: project_id})

    assert {:ok, paper} = Content.upsert_paper(attrs)
    {slug, paper}
  end

  defp patch_image_src(src) do
    %{"op" => "patch-block", "id" => "image", "patch" => %{"src" => src}}
  end

  defp scoped_paper(slug, workspace_id, project_id) do
    Content.get_paper(slug, @dataset, workspace_id: workspace_id, project_id: project_id)
  end

  defp image(paper) do
    paper.content["blocks"]
    |> Enum.find(&(&1["id"] == "figure"))
    |> Map.fetch!("child")
  end

  defp paper_rev(paper), do: paper.content["rev"] || 0

  defp paper_ops_key_hash(paper, request_id, principal) do
    deterministic_hash({
      "paper_ops:v1",
      paper.id,
      paper.workspace_id,
      paper.project_id,
      paper.dataset_id,
      paper.dataset,
      principal,
      request_id
    })
  end

  defp history_consumption_hash(paper, history_ref, principal) do
    deterministic_hash({
      "paper_contextual_history_consumption:v1",
      paper.id,
      paper.workspace_id,
      paper.project_id,
      paper.dataset_id,
      paper.dataset,
      principal,
      history_ref
    })
  end

  defp deterministic_hash(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp shutdown_owned_tasks do
    :contextual_history_contention_tasks
    |> Process.delete()
    |> List.wrap()
    |> Enum.each(fn task ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end)
  end

  defp delete_idempotency_keys(key_hashes) do
    Repo.delete_all(from(k in IdempotencyStore.Key, where: k.key_hash in ^key_hashes))
  end
end
