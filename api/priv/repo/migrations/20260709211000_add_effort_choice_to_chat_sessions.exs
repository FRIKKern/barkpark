defmodule Barkpark.Repo.Migrations.AddEffortChoiceToChatSessions do
  use Ecto.Migration

  def change do
    alter table(:chat_sessions) do
      # The USER'S picked reasoning-effort tier (low/medium/high/xhigh/max),
      # nil = the CLI default. Mirrors `model_choice` (charter D48): choice is
      # intent — it rides the next spawn as `--effort`. There is no "observed
      # effort" fact off the result frame, so unlike model there is no paired
      # column; effort is intent-only.
      add :effort_choice, :string
    end
  end
end
