defmodule Barkpark.Repo.Migrations.AddRuntimeTelemetry do
  use Ecto.Migration

  def change do
    alter table(:chat_sessions) do
      add :observed_model, :string
      add :observed_effort, :string
      add :observed_input_tokens, :bigint
      add :observed_cached_input_tokens, :bigint
      add :observed_output_tokens, :bigint
      add :observed_reasoning_output_tokens, :bigint
      add :observed_total_tokens, :bigint
      add :observed_context_window, :bigint
      add :runtime_identity, :map
      add :runtime_telemetry_limitations, {:array, :string}
    end

    create table(:chat_runtime_telemetry_events, primary_key: false) do
      add :session_id,
          references(:chat_sessions, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :event_key, :string, primary_key: true
      add :kind, :string, null: false
      add :payload_hash, :string, null: false
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end
end
