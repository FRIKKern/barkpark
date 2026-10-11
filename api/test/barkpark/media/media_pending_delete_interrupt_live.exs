# Owned release interruption proof. The parent interrupts PostgreSQL after the
# internal operation returns but while this outer transaction remains open.
input = System.fetch_env!("C105_PROOF_INPUT") |> File.read!() |> Jason.decode!()
item = Enum.at(input["fixtures"], 1)
opts = [where_used: :cascade] ++
  Enum.flat_map([:workspace_id, :project_id], fn key ->
    case item["rawRow"][Atom.to_string(key)] do
      nil -> []
      value -> [{key, value}]
    end
  end)

Barkpark.Content.Broadcast.with_deferred_queue(fn ->
  Barkpark.Repo.transaction(fn ->
    {:ok, receipt} = Barkpark.Media.commit_pending_delete(item["request"], opts)
    :awaiting_outer_commit = receipt.commit_state
    false = receipt.physical_deletion_settled
    File.write!(System.fetch_env!("C105_INTERRUPT_READY"), Jason.encode!(receipt))
    Process.sleep(120_000)
    raise "parent did not interrupt the owned transaction"
  end)
end)
