# Standalone owned-release integration proof; do not point at an existing library.
# The launcher supplies native-observed fixtures and starts the release in inert
# seed mode. No SQL sandbox is used: commits and outer rollback are real.
defmodule Barkpark.Media.PendingDeleteLiveTest do
  use ExUnit.Case, async: false
  alias Barkpark.{Content, Media, Repo}
  alias Barkpark.Plugins.Media.Assets

  defmodule HaltAsset do
    def lifecycle_hooks, do: %{before_delete: [&__MODULE__.halt/1]}
    def halt(%{doc: %{type: "mediaAsset"}}), do: {:halt, "owned pending-delete refusal"}
    def halt(_), do: :ok
  end

  defp query(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)

  defp row(request) do
    query("SELECT to_jsonb(m) FROM media_files m WHERE id=($1::jsonb->>'mediaId')::uuid", [
      request
    ]).rows
  end

  defp operation(request) do
    query(
      "SELECT to_jsonb(o) FROM media_delete_operations_v1 o WHERE operation_id=($1::jsonb->>'operationId')::uuid",
      [request]
    ).rows
  end

  defp opts(item) do
    [where_used: :cascade] ++
      Enum.flat_map([:workspace_id, :project_id], fn key ->
        case item["rawRow"][Atom.to_string(key)] do
          nil -> []
          value -> [{key, value}]
        end
      end)
  end

  defp unchanged(request) do
    bytes = File.read!(Path.join(request["root"]["path"], request["expectedKey"]))
    assert byte_size(bytes) == request["file"]["bytes"]
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == request["file"]["sha256"]
  end

  defp check(name), do: IO.puts("C105_CHECK " <> name)

  test "atomic pending deletion, refusal, rollback and durable retry on a real release" do
    input = System.fetch_env!("C105_PROOF_INPUT") |> File.read!() |> Jason.decode!()
    [target, refused, protected | _] = input["fixtures"]
    request = target["request"]
    call_opts = opts(target)

    if input["phase"] == "resume" do
      [[prior]] = operation(request)
      assert {:ok, receipt} = Media.commit_pending_delete(request, call_opts)
      assert receipt.operation == prior
      assert receipt.commit_state == :committed
      refute receipt.physical_deletion_settled
      assert row(request) == []
      unchanged(request)
      check("restart retains exact pending operation and no physical settlement")
    else
      assert row(request) == [[target["rawRow"]]]

      doc =
        Assets.find_by_media_file_id(request["mediaId"], target["rawRow"]["dataset"], call_opts)

      assert doc
      published = String.replace_prefix(doc.doc_id, "drafts.", "")
      assert {:ok, _} = Content.publish_document(published, "mediaAsset", doc.dataset, call_opts)

      assert {:ok, _} =
               Content.create_document(
                 "mediaAsset",
                 %{
                   "doc_id" => published,
                   "title" => doc.title <> " draft",
                   "content" => doc.content
                 },
                 doc.dataset,
                 call_opts
               )

      {:ok, file} = Media.get_file(request["mediaId"], call_opts)
      snapshots = Repo.transaction(fn -> Assets.pending_delete_snapshot(file) end) |> elem(1)
      assert length(snapshots) == 2
      check("fixture has real draft and published asset variants")

      wrong_root = put_in(request, ["root", "path"], request["root"]["path"] <> "-other")
      assert {:error, :media_root_mismatch} = Media.commit_pending_delete(wrong_root, call_opts)
      assert operation(request) == []
      check("root mismatch refuses before intent or row mutation")

      assert {:ok, {:error, :content_transaction_owner_required}} =
               Repo.transaction(fn -> Media.commit_pending_delete(request, call_opts) end)

      assert operation(request) == []
      check("unowned outer transaction refuses content dispatch ambiguity")

      assert {:error, :owned_rollback} =
               Content.Broadcast.with_deferred_queue(fn ->
                 Repo.transaction(fn ->
                   assert {:ok, receipt} = Media.commit_pending_delete(request, call_opts)
                   assert receipt.commit_state == :awaiting_outer_commit
                   assert receipt.operation["asset_documents"] == snapshots
                   assert row(request) == []

                   assert Assets.find_by_media_file_id(request["mediaId"], doc.dataset, call_opts) ==
                            nil

                   unchanged(request)
                   Repo.rollback(:owned_rollback)
                 end)
               end)

      assert operation(request) == []
      assert row(request) == [[target["rawRow"]]]
      {:ok, file} = Media.get_file(request["mediaId"], call_opts)
      assert {:ok, ^snapshots} = Repo.transaction(fn -> Assets.pending_delete_snapshot(file) end)
      unchanged(request)
      check("outer rollback restores exact row and both documents; intent absent and bytes exact")

      previous = Application.get_env(:barkpark, :plugins)

      try do
        Application.put_env(:barkpark, :plugins, [HaltAsset])
        assert {:error, _} = Media.commit_pending_delete(refused["request"], opts(refused))
      after
        if previous == nil,
          do: Application.delete_env(:barkpark, :plugins),
          else: Application.put_env(:barkpark, :plugins, previous)
      end

      assert operation(refused["request"]) == []
      assert row(refused["request"]) == [[refused["rawRow"]]]

      assert Assets.find_by_media_file_id(
               refused["request"]["mediaId"],
               refused["rawRow"]["dataset"],
               opts(refused)
             )

      unchanged(refused["request"])
      check("asset refusal restores row and document; no pending intent or byte effect")

      assert {:ok, receipt} = Media.commit_pending_delete(request, call_opts)
      assert receipt.commit_state == :committed
      assert receipt.state == :pending_cleanup
      assert receipt.operation["raw_row"] == target["rawRow"]
      assert receipt.operation["asset_documents"] == snapshots
      refute receipt.physical_deletion_settled
      refute receipt.recovery_allowed
      assert row(request) == []
      assert Assets.find_by_media_file_id(request["mediaId"], doc.dataset, call_opts) == nil
      unchanged(request)
      check("commit captures exact row and asset variants with pending cleanup; bytes retained")

      assert {:ok, ^receipt} = Media.commit_pending_delete(request, call_opts)
      check("exact retry preserves operation, captured documents and pending receipt")

      assert {:error, _} =
               Media.commit_pending_delete(
                 request,
                 Keyword.put(call_opts, :workspace_id, Ecto.UUID.generate())
               )

      assert {:error, _} =
               Media.commit_pending_delete(
                 Map.put(request, "operationId", Ecto.UUID.generate()),
                 call_opts
               )

      missing =
        request
        |> Map.put("operationId", Ecto.UUID.generate())
        |> Map.put("mediaId", Ecto.UUID.generate())

      assert {:error, _} = Media.commit_pending_delete(missing, call_opts)
      unchanged(request)
      check("different scope, competing operation and historical unknown row refuse")
    end

    assert row(protected["request"]) == [[protected["rawRow"]]]
    unchanged(protected["request"])
    check("independent protected row and original remain exact")
  end
end
