defmodule Barkpark.Content.PatchPathConcurrencyTest do
  @moduledoc """
  task-bfb66a2ff491f6e7 c1 — two clients patch sibling nested fields of one
  document at the same time, and both edits survive.

      A: patch seo.metaTitle        ── parked inside its transaction ──▶ commit
      B: patch seo.metaDescription  ── starts while A is parked

  Before the per-document patch lock, B read the same base as A, waited on A's
  row lock, then wrote its stale merge over A's commit: seo.metaTitle went back
  to the old value. Now B waits before reading, so it merges onto A's result.

  The batches are workspace-scoped like the /mutate door (an unscoped batch
  already serializes on the global audit-chain lock, which would hide the
  race). They commit for real, so the seeded rows are removed in `on_exit`.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo}
  alias Barkpark.Content.Document
  alias Ecto.Adapters.SQL.Sandbox

  @dataset "production"
  @barrier :barkpark_mutations_between_barrier

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    ws = Barkpark.TenancyFixtures.default_workspace_id!()
    id = "pp-race-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "doc_id" => id,
          "title" => "race",
          "content" => %{"seo" => %{"metaTitle" => "old", "metaDescription" => "old"}}
        },
        @dataset,
        workspace_id: ws
      )

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      Repo.delete_all(from(d in Document, where: d.doc_id in ^[id, "drafts." <> id]))
    end)

    {:ok, id: id, ws: ws}
  end

  defp patch(id, set), do: [%{"patch" => %{"id" => id, "type" => "post", "set" => set}}]

  test "concurrent patches to seo.metaTitle and seo.metaDescription both survive",
       %{id: id, ws: ws} do
    parent = self()

    a =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        Process.put(@barrier, fn ->
          send(parent, :a_parked)

          receive do
            :go -> :ok
          end
        end)

        Content.apply_mutations(patch(id, %{"seo.metaTitle" => "from A"}), @dataset,
          workspace_id: ws
        )
      end)

    assert_receive :a_parked, 10_000

    b =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)
        send(parent, :b_started)

        Content.apply_mutations(patch(id, %{"seo.metaDescription" => "from B"}), @dataset,
          workspace_id: ws
        )
      end)

    assert_receive :b_started, 10_000
    # Give B time to reach (and, before the fix, read past) the lock point.
    Process.sleep(300)
    send(a.pid, :go)

    assert {:ok, _} = Task.await(a, 20_000)
    assert {:ok, _} = Task.await(b, 20_000)

    {:ok, doc} = Content.get_document("drafts." <> id, "post", @dataset, workspace_id: ws)
    assert doc.content["seo"] == %{"metaTitle" => "from A", "metaDescription" => "from B"}
  end
end
