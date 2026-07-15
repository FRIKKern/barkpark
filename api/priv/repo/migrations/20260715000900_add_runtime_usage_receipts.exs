defmodule Barkpark.Repo.Migrations.AddRuntimeUsageReceipts do
  use Ecto.Migration

  # The provider telemetry columns/events were introduced by 20260715000200.
  # This forward repair adds only the retrieval-attribution receipt ledger.

  def change do
    create table(:chat_runtime_usage_receipts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :cycle_id, :uuid, null: false
      add :assignment_id, :uuid, null: false

      add :session_id,
          references(:chat_sessions, type: :binary_id, on_delete: :restrict),
          null: false

      add :task_id, references(:documents, type: :uuid, on_delete: :restrict), null: false
      add :task_doc_id, :text, null: false
      add :task_worker_id, :text, null: false
      add :task_epoch, :bigint, null: false
      add :task_work_digest, :text, null: false
      add :provider, :text, null: false
      add :provider_session_id, :text, null: false
      add :turn_id, :text, null: false
      add :boundary, :text, null: false
      add :observation_state, :text, null: false
      add :counter_domain, :text
      add :counters, :map, null: false, default: %{}
      add :reason_code, :text
      add :payload_hash, :text, null: false
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(
             :chat_runtime_usage_receipts,
             [:provider, :provider_session_id, :turn_id, :boundary],
             name: :chat_runtime_usage_receipts_provider_boundary_index
           )

    create index(:chat_runtime_usage_receipts, [:cycle_id, :assignment_id])

    create constraint(:chat_runtime_usage_receipts, :chat_runtime_usage_receipts_boundary,
             check: "boundary IN ('baseline', 'terminal')"
           )

    create constraint(:chat_runtime_usage_receipts, :chat_runtime_usage_receipts_state,
             check: "observation_state IN ('observed', 'unsupported')"
           )

    create constraint(:chat_runtime_usage_receipts, :chat_runtime_usage_receipts_shape,
             check: """
             (observation_state = 'observed' AND counter_domain IS NOT NULL AND reason_code IS NULL)
             OR
             (observation_state = 'unsupported' AND counter_domain IS NULL AND counters = '{}'::jsonb AND reason_code = 'provider_capability_absent')
             """
           )

    create constraint(:chat_runtime_usage_receipts, :chat_runtime_usage_receipts_task_epoch,
             check: "task_epoch > 0"
           )

    create constraint(
             :chat_runtime_usage_receipts,
             :chat_runtime_usage_receipts_task_work_digest,
             check: "task_work_digest ~ '^[0-9a-f]{16}$'"
           )

    create constraint(:chat_runtime_usage_receipts, :chat_runtime_usage_receipts_payload_hash,
             check: "payload_hash ~ '^[0-9a-f]{64}$'"
           )

    execute(
      """
      CREATE FUNCTION barkpark_runtime_usage_receipts_immutable()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'chat_runtime_usage_receipts is append-only (% forbidden)', TG_OP;
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION barkpark_runtime_usage_receipts_immutable()"
    )

    execute(
      """
      CREATE TRIGGER chat_runtime_usage_receipts_no_update_delete
      BEFORE UPDATE OR DELETE ON chat_runtime_usage_receipts
      FOR EACH ROW EXECUTE FUNCTION barkpark_runtime_usage_receipts_immutable();
      """,
      "DROP TRIGGER chat_runtime_usage_receipts_no_update_delete ON chat_runtime_usage_receipts"
    )
  end
end
